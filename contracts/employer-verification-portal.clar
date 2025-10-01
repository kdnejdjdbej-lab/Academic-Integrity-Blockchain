;; title: employer-verification-portal
;; version: 1.0.0
;; summary: Instant credential verification for employers with privacy-preserving queries
;; description: Allows employers to verify credentials without accessing personal data

;; constants
(define-constant CONTRACT_OWNER tx-sender)
(define-constant ERR_UNAUTHORIZED (err u3001))
(define-constant ERR_INVALID_REQUEST (err u3002))
(define-constant ERR_ACCESS_DENIED (err u3003))
(define-constant ERR_CREDENTIAL_NOT_FOUND (err u3004))
(define-constant VERIFICATION_FEE u1000) ;; STX microtokens

;; data vars
(define-data-var next-verification-id uint u1)
(define-data-var total-verifications uint u0)
(define-data-var contract-paused bool false)

;; data maps
;; Authorized employers
(define-map authorized-employers principal
  {
    company-name: (string-ascii 100),
    industry: (string-ascii 50),
    authorized-date: uint,
    active: bool,
    verifications-performed: uint
  })

;; Verification requests
(define-map verification-requests uint
  {
    employer: principal,
    candidate: principal,
    request-type: (string-ascii 20),
    status: (string-ascii 20),
    created-date: uint,
    verified: bool,
    result: (optional (string-ascii 500))
  })

;; public functions

;; Authorize employer
(define-public (authorize-employer
    (employer principal)
    (company-name (string-ascii 100))
    (industry (string-ascii 50)))
  (if (is-eq tx-sender CONTRACT_OWNER)
    (begin
      (map-set authorized-employers employer {
        company-name: company-name,
        industry: industry,
        authorized-date: stacks-block-height,
        active: true,
        verifications-performed: u0
      })
      (ok true)
    )
    ERR_UNAUTHORIZED
  )
)

;; Request credential verification
(define-public (request-verification
    (candidate principal)
    (request-type (string-ascii 20)))
  (let ((verification-id (var-get next-verification-id)))
    (asserts! (not (var-get contract-paused)) ERR_UNAUTHORIZED)
    (asserts! (is-authorized-employer tx-sender) ERR_UNAUTHORIZED)
    
    (map-set verification-requests verification-id {
      employer: tx-sender,
      candidate: candidate,
      request-type: request-type,
      status: "pending",
      created-date: stacks-block-height,
      verified: false,
      result: none
    })
    
    (var-set next-verification-id (+ verification-id u1))
    (var-set total-verifications (+ (var-get total-verifications) u1))
    
    (ok verification-id)
  )
)

;; read only functions

;; Get verification result
(define-read-only (get-verification-result (verification-id uint))
  (map-get? verification-requests verification-id)
)

;; Check if employer is authorized
(define-read-only (is-employer-authorized (employer principal))
  (is-authorized-employer employer)
)

;; private functions

(define-private (is-authorized-employer (employer principal))
  (match (map-get? authorized-employers employer)
    employer-data (get active employer-data)
    false
  )
)

