;; performance-nft.clar
;; Performance NFT contract for athletic achievements and collectibles
;; Implements SIP-009 NFT standard with performance verification

;; ==========================
;; Constants and error codes
;; ==========================

(define-constant ERR-NOT-AUTHORIZED (err u500))
(define-constant ERR-NOT-FOUND (err u501))
(define-constant ERR-ALREADY-EXISTS (err u502))
(define-constant ERR-INVALID-INPUT (err u503))
(define-constant ERR-MINT-FAILED (err u504))
(define-constant ERR-TRANSFER-FAILED (err u505))
(define-constant ERR-NOT-OWNER (err u506))
(define-constant ERR-INSUFFICIENT-PAYMENT (err u507))

;; NFT categories
(define-constant CATEGORY-ACHIEVEMENT u1)
(define-constant CATEGORY-EVENT u2)
(define-constant CATEGORY-COLLECTIBLE u3)
(define-constant CATEGORY-UTILITY u4)

;; Achievement types
(define-constant ACHIEVEMENT-PERSONAL-RECORD u10)
(define-constant ACHIEVEMENT-COMPETITION-WIN u11)
(define-constant ACHIEVEMENT-MILESTONE u12)
(define-constant ACHIEVEMENT-CHAMPIONSHIP u13)

;; Platform settings
(define-constant PLATFORM-MINT-FEE u1000000) ;; 1 STX in microSTX
(define-constant ROYALTY-PERCENTAGE u10) ;; 10% royalty

;; ==========================
;; Data variables
;; ==========================

(define-data-var contract-owner principal tx-sender)
(define-data-var next-token-id uint u1)
(define-data-var platform-treasury principal tx-sender)

;; ==========================
;; NFT Definition (SIP-009)
;; ==========================

(define-non-fungible-token performance-nft uint)

;; ==========================
;; Data maps
;; ==========================

;; Token metadata
(define-map token-metadata
  { token-id: uint }
  {
    athlete: principal,
    title: (string-ascii 100),
    description: (string-ascii 500),
    image-uri: (string-ascii 200),
    category: uint,
    achievement-type: (optional uint),
    event-date: uint,
    performance-data: (string-ascii 300),
    verified: bool,
    created-at: uint
  }
)

;; Athlete collections
(define-map athlete-collections
  { athlete: principal }
  {
    total-nfts: uint,
    achievements: uint,
    collectibles: uint,
    total-sales: uint,
    verified-athlete: bool
  }
)

;; NFT market data
(define-map nft-market
  { token-id: uint }
  {
    listed-price: (optional uint),
    listed-at: (optional uint),
    last-sale-price: (optional uint),
    sale-count: uint,
    royalty-recipient: principal
  }
)

;; Performance verification
(define-map performance-verifications
  { token-id: uint }
  {
    verifier: principal,
    verification-data: (string-ascii 300),
    verified-at: uint,
    confidence-score: uint ;; 0-100
  }
)

;; ==========================
;; Administrative functions
;; ==========================

(define-read-only (get-contract-owner)
  (ok (var-get contract-owner))
)

(define-private (is-contract-owner)
  (is-eq tx-sender (var-get contract-owner))
)

(define-public (set-contract-owner (new-owner principal))
  (if (is-contract-owner)
      (begin
        (var-set contract-owner new-owner)
        (ok true)
      )
      ERR-NOT-AUTHORIZED
  )
)

(define-public (set-platform-treasury (new-treasury principal))
  (if (is-contract-owner)
      (begin
        (var-set platform-treasury new-treasury)
        (ok true)
      )
      ERR-NOT-AUTHORIZED
  )
)

;; ==========================
;; SIP-009 Implementation
;; ==========================

(define-read-only (get-last-token-id)
  (ok (- (var-get next-token-id) u1))
)

(define-read-only (get-token-uri (token-id uint))
  (match (map-get? token-metadata { token-id: token-id })
    metadata (ok (some (get image-uri metadata)))
    (ok none)
  )
)

(define-read-only (get-owner (token-id uint))
  (ok (nft-get-owner? performance-nft token-id))
)

(define-public (transfer (token-id uint) (sender principal) (recipient principal))
  (let ((owner (unwrap! (nft-get-owner? performance-nft token-id) ERR-NOT-FOUND)))
    (if (and (is-eq tx-sender sender) (is-eq sender owner))
        (match (nft-transfer? performance-nft token-id sender recipient)
          success (ok success)
          error ERR-TRANSFER-FAILED
        )
        ERR-NOT-AUTHORIZED
    )
  )
)

;; ==========================
;; Minting functions
;; ==========================

(define-private (get-next-token-id)
  (let ((current-id (var-get next-token-id)))
    (begin
      (var-set next-token-id (+ current-id u1))
      current-id
    )
  )
)

(define-public (mint-achievement-nft
    (title (string-ascii 100))
    (description (string-ascii 500))
    (image-uri (string-ascii 200))
    (achievement-type uint)
    (event-date uint)
    (performance-data (string-ascii 300))
    (recipient principal)
  )
  (let ((token-id (get-next-token-id)))
    (if (>= (stx-get-balance tx-sender) PLATFORM-MINT-FEE)
        (begin
          ;; Transfer mint fee
          (try! (stx-transfer? PLATFORM-MINT-FEE tx-sender (var-get platform-treasury)))
          
          ;; Mint NFT
          (try! (nft-mint? performance-nft token-id recipient))
          
          ;; Store metadata
          (map-set token-metadata { token-id: token-id }
            {
              athlete: tx-sender,
              title: title,
              description: description,
              image-uri: image-uri,
              category: CATEGORY-ACHIEVEMENT,
              achievement-type: (some achievement-type),
              event-date: event-date,
              performance-data: performance-data,
              verified: false,
              created-at: block-height
            }
          )
          
          ;; Initialize market data
          (map-set nft-market { token-id: token-id }
            {
              listed-price: none,
              listed-at: none,
              last-sale-price: none,
              sale-count: u0,
              royalty-recipient: tx-sender
            }
          )
          
          ;; Update athlete collection
          (let ((collection (default-to 
                             { total-nfts: u0, achievements: u0, collectibles: u0, total-sales: u0, verified-athlete: false }
                             (map-get? athlete-collections { athlete: tx-sender }))))
            (map-set athlete-collections { athlete: tx-sender }
              (merge collection 
                {
                  total-nfts: (+ (get total-nfts collection) u1),
                  achievements: (+ (get achievements collection) u1)
                }
              )
            )
          )
          
          (ok token-id)
        )
        ERR-INSUFFICIENT-PAYMENT
    )
  )
)

(define-public (mint-collectible-nft
    (title (string-ascii 100))
    (description (string-ascii 500))
    (image-uri (string-ascii 200))
    (event-date uint)
    (performance-data (string-ascii 300))
    (recipient principal)
    (mint-price uint)
  )
  (let ((token-id (get-next-token-id))
        (total-fee (+ PLATFORM-MINT-FEE mint-price)))
    (if (>= (stx-get-balance tx-sender) total-fee)
        (begin
          ;; Transfer fees
          (try! (stx-transfer? PLATFORM-MINT-FEE tx-sender (var-get platform-treasury)))
          (if (> mint-price u0)
              (try! (stx-transfer? mint-price tx-sender recipient))
              true
          )
          
          ;; Mint NFT
          (try! (nft-mint? performance-nft token-id recipient))
          
          ;; Store metadata
          (map-set token-metadata { token-id: token-id }
            {
              athlete: tx-sender,
              title: title,
              description: description,
              image-uri: image-uri,
              category: CATEGORY-COLLECTIBLE,
              achievement-type: none,
              event-date: event-date,
              performance-data: performance-data,
              verified: false,
              created-at: block-height
            }
          )
          
          ;; Initialize market data
          (map-set nft-market { token-id: token-id }
            {
              listed-price: none,
              listed-at: none,
              last-sale-price: (some mint-price),
              sale-count: u1,
              royalty-recipient: tx-sender
            }
          )
          
          ;; Update athlete collection
          (let ((collection (default-to 
                             { total-nfts: u0, achievements: u0, collectibles: u0, total-sales: u0, verified-athlete: false }
                             (map-get? athlete-collections { athlete: tx-sender }))))
            (map-set athlete-collections { athlete: tx-sender }
              (merge collection 
                {
                  total-nfts: (+ (get total-nfts collection) u1),
                  collectibles: (+ (get collectibles collection) u1),
                  total-sales: (+ (get total-sales collection) mint-price)
                }
              )
            )
          )
          
          (ok token-id)
        )
        ERR-INSUFFICIENT-PAYMENT
    )
  )
)

;; ==========================
;; Verification functions
;; ==========================

(define-public (verify-performance (token-id uint) (verification-data (string-ascii 300)) (confidence-score uint))
  (if (is-contract-owner)
      (match (map-get? token-metadata { token-id: token-id })
        metadata
          (begin
            (map-set token-metadata { token-id: token-id } (merge metadata { verified: true }))
            (map-set performance-verifications { token-id: token-id }
              {
                verifier: tx-sender,
                verification-data: verification-data,
                verified-at: block-height,
                confidence-score: confidence-score
              }
            )
            (ok true)
          )
        ERR-NOT-FOUND
      )
      ERR-NOT-AUTHORIZED
  )
)

;; ==========================
;; Read-only functions
;; ==========================

(define-read-only (get-token-metadata (token-id uint))
  (match (map-get? token-metadata { token-id: token-id })
    metadata (ok metadata)
    ERR-NOT-FOUND
  )
)

(define-read-only (get-athlete-collection (athlete principal))
  (match (map-get? athlete-collections { athlete: athlete })
    collection (ok collection)
    ERR-NOT-FOUND
  )
)

(define-read-only (get-market-data (token-id uint))
  (match (map-get? nft-market { token-id: token-id })
    market (ok market)
    ERR-NOT-FOUND
  )
)

(define-read-only (get-verification (token-id uint))
  (match (map-get? performance-verifications { token-id: token-id })
    verification (ok verification)
    ERR-NOT-FOUND
  )
)

(define-read-only (is-verified (token-id uint))
  (match (map-get? token-metadata { token-id: token-id })
    metadata (ok (get verified metadata))
    (ok false)
  )
)
