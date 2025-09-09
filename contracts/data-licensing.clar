;; data-licensing.clar
;; Athletic performance data licensing and marketplace smart contract
;; Manages licensing agreements, revenue distribution, and access controls

;; ==========================
;; Constants and error codes
;; ==========================

(define-constant ERR-NOT-AUTHORIZED (err u400))
(define-constant ERR-NOT-FOUND (err u404))
(define-constant ERR-ALREADY-EXISTS (err u409))
(define-constant ERR-INVALID-INPUT (err u400))
(define-constant ERR-LICENSE-EXPIRED (err u410))
(define-constant ERR-INSUFFICIENT-PAYMENT (err u402))
(define-constant ERR-ACCESS-DENIED (err u403))

;; License types
(define-constant LICENSE-EXCLUSIVE u1)
(define-constant LICENSE-NON-EXCLUSIVE u2)
(define-constant LICENSE-TIME-LIMITED u3)
(define-constant LICENSE-USAGE-BASED u4)

;; Platform settings
(define-constant PLATFORM-FEE-PERCENTAGE u5) ;; 5% platform fee
(define-constant MIN-LICENSE-DURATION u144) ;; ~1 day in blocks
(define-constant MAX-LICENSE-DURATION u1051200) ;; ~1 year in blocks

;; ==========================
;; Data variables
;; ==========================

(define-data-var platform-admin principal tx-sender)
(define-data-var next-license-id uint u1)
(define-data-var platform-treasury principal tx-sender)

;; ==========================
;; Data maps
;; ==========================

;; Athletic performance data registry
(define-map athlete-data
  { athlete: principal }
  {
    total-datasets: uint,
    active-licenses: uint,
    total-revenue: uint,
    verified: bool,
    created-at: uint
  }
)

;; Dataset information
(define-map datasets
  { athlete: principal, dataset-id: uint }
  {
    name: (string-ascii 100),
    description: (string-ascii 300),
    data-type: (string-ascii 50), ;; "performance", "biometric", "training", "competition"
    price-per-access: uint,
    created-at: uint,
    is-active: bool
  }
)

;; License agreements
(define-map licenses
  { id: uint }
  {
    athlete: principal,
    licensee: principal,
    dataset-id: uint,
    license-type: uint,
    price: uint,
    start-height: uint,
    end-height: uint,
    usage-limit: (optional uint),
    usage-count: uint,
    status: uint, ;; 1=active, 2=expired, 3=cancelled
    created-at: uint
  }
)

;; Revenue tracking
(define-map revenue-records
  { athlete: principal, period: uint }
  {
    gross-revenue: uint,
    platform-fees: uint,
    net-revenue: uint,
    license-count: uint
  }
)

;; Access permissions
(define-map access-permissions
  { licensee: principal, license-id: uint }
  {
    granted-at: uint,
    last-access: uint,
    access-count: uint,
    expires-at: uint
  }
)

;; ==========================
;; Administrative functions
;; ==========================

(define-read-only (get-platform-admin)
  (ok (var-get platform-admin))
)

(define-private (is-platform-admin)
  (is-eq tx-sender (var-get platform-admin))
)

(define-public (set-platform-admin (new-admin principal))
  (if (is-platform-admin)
      (begin
        (var-set platform-admin new-admin)
        (ok true)
      )
      ERR-NOT-AUTHORIZED
  )
)

(define-public (set-platform-treasury (new-treasury principal))
  (if (is-platform-admin)
      (begin
        (var-set platform-treasury new-treasury)
        (ok true)
      )
      ERR-NOT-AUTHORIZED
  )
)

;; ==========================
;; Athlete and dataset management
;; ==========================

(define-public (register-athlete)
  (let ((existing (map-get? athlete-data { athlete: tx-sender })))
    (if (is-some existing)
        ERR-ALREADY-EXISTS
        (begin
          (map-set athlete-data { athlete: tx-sender }
            {
              total-datasets: u0,
              active-licenses: u0,
              total-revenue: u0,
              verified: false,
              created-at: block-height
            }
          )
          (ok true)
        )
    )
  )
)

(define-public (verify-athlete (athlete principal))
  (if (is-platform-admin)
      (match (map-get? athlete-data { athlete: athlete })
        data
          (begin
            (map-set athlete-data { athlete: athlete } (merge data { verified: true }))
            (ok true)
          )
        ERR-NOT-FOUND
      )
      ERR-NOT-AUTHORIZED
  )
)

(define-public (create-dataset 
    (dataset-id uint)
    (name (string-ascii 100))
    (description (string-ascii 300))
    (data-type (string-ascii 50))
    (price-per-access uint)
  )
  (let ((athlete-info (map-get? athlete-data { athlete: tx-sender })))
    (if (and (is-some athlete-info) (> price-per-access u0))
        (let ((existing (map-get? datasets { athlete: tx-sender, dataset-id: dataset-id })))
          (if (is-some existing)
              ERR-ALREADY-EXISTS
              (begin
                (map-set datasets { athlete: tx-sender, dataset-id: dataset-id }
                  {
                    name: name,
                    description: description,
                    data-type: data-type,
                    price-per-access: price-per-access,
                    created-at: block-height,
                    is-active: true
                  }
                )
                (map-set athlete-data { athlete: tx-sender }
                  (merge (unwrap-panic athlete-info) 
                         { total-datasets: (+ (get total-datasets (unwrap-panic athlete-info)) u1) }
                  )
                )
                (ok dataset-id)
              )
          )
        )
        ERR-INVALID-INPUT
    )
  )
)

;; ==========================
;; License management
;; ==========================

(define-private (get-next-license-id)
  (let ((current-id (var-get next-license-id)))
    (begin
      (var-set next-license-id (+ current-id u1))
      current-id
    )
  )
)

(define-private (calculate-platform-fee (amount uint))
  (/ (* amount PLATFORM-FEE-PERCENTAGE) u100)
)

(define-public (create-license
    (athlete principal)
    (dataset-id uint)
    (license-type uint)
    (duration-blocks uint)
    (usage-limit (optional uint))
  )
  (let (
    (dataset (map-get? datasets { athlete: athlete, dataset-id: dataset-id }))
    (license-id (get-next-license-id))
  )
    (match dataset
      data
        (if (and (get is-active data)
                 (>= duration-blocks MIN-LICENSE-DURATION)
                 (<= duration-blocks MAX-LICENSE-DURATION))
            (let (
              (price (get price-per-access data))
              (platform-fee (calculate-platform-fee price))
              (net-payment (- price platform-fee))
            )
              (if (>= (stx-get-balance tx-sender) price)
                  (begin
                    ;; Transfer payment
                    (try! (stx-transfer? platform-fee tx-sender (var-get platform-treasury)))
                    (try! (stx-transfer? net-payment tx-sender athlete))
                    
                    ;; Create license
                    (map-set licenses { id: license-id }
                      {
                        athlete: athlete,
                        licensee: tx-sender,
                        dataset-id: dataset-id,
                        license-type: license-type,
                        price: price,
                        start-height: block-height,
                        end-height: (+ block-height duration-blocks),
                        usage-limit: usage-limit,
                        usage-count: u0,
                        status: u1,
                        created-at: block-height
                      }
                    )
                    
                    ;; Grant access permission
                    (map-set access-permissions { licensee: tx-sender, license-id: license-id }
                      {
                        granted-at: block-height,
                        last-access: u0,
                        access-count: u0,
                        expires-at: (+ block-height duration-blocks)
                      }
                    )
                    
                    (ok license-id)
                  )
                  ERR-INSUFFICIENT-PAYMENT
              )
            )
            ERR-INVALID-INPUT
        )
      ERR-NOT-FOUND
    )
  )
)

;; ==========================
;; Access control
;; ==========================

(define-public (access-data (license-id uint))
  (match (map-get? licenses { id: license-id })
    license
      (let ((permission (map-get? access-permissions { licensee: tx-sender, license-id: license-id })))
        (if (and (is-eq (get licensee license) tx-sender)
                 (is-eq (get status license) u1)
                 (<= block-height (get end-height license))
                 (is-some permission))
            (let ((perm (unwrap-panic permission)))
              (begin
                (map-set access-permissions { licensee: tx-sender, license-id: license-id }
                  (merge perm 
                    { 
                      last-access: block-height,
                      access-count: (+ (get access-count perm) u1)
                    }
                  )
                )
                (map-set licenses { id: license-id }
                  (merge license { usage-count: (+ (get usage-count license) u1) })
                )
                (ok true)
              )
            )
            ERR-ACCESS-DENIED
        )
      )
    ERR-NOT-FOUND
  )
)

;; ==========================
;; Read-only functions
;; ==========================

(define-read-only (get-athlete-data (athlete principal))
  (match (map-get? athlete-data { athlete: athlete })
    data (ok data)
    ERR-NOT-FOUND
  )
)

(define-read-only (get-dataset (athlete principal) (dataset-id uint))
  (match (map-get? datasets { athlete: athlete, dataset-id: dataset-id })
    data (ok data)
    ERR-NOT-FOUND
  )
)

(define-read-only (get-license (license-id uint))
  (match (map-get? licenses { id: license-id })
    license (ok license)
    ERR-NOT-FOUND
  )
)

(define-read-only (get-access-permission (licensee principal) (license-id uint))
  (match (map-get? access-permissions { licensee: licensee, license-id: license-id })
    permission (ok permission)
    ERR-NOT-FOUND
  )
)

(define-read-only (has-active-license (licensee principal) (license-id uint))
  (match (map-get? licenses { id: license-id })
    license
      (ok (and (is-eq (get licensee license) licensee)
               (is-eq (get status license) u1)
               (> (get end-height license) block-height)))
    (ok false)
  )
)
