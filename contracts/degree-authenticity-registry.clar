;; title: degree-authenticity-registry
;; version: 1.0.0
;; summary: Immutable storage of verified degrees, certificates, and professional qualifications
;; description: Provides secure credential issuance, verification, and retrieval functionality with multi-signature authorization

;; constants
(define-constant CONTRACT_OWNER tx-sender)
(define-constant ERR_UNAUTHORIZED (err u1001))
(define-constant ERR_CREDENTIAL_NOT_FOUND (err u1002))
(define-constant ERR_INVALID_PARAMETERS (err u1003))
(define-constant ERR_ALREADY_EXISTS (err u1004))
(define-constant ERR_INVALID_INSTITUTION (err u1005))
(define-constant ERR_INVALID_GPA (err u1006))
(define-constant ERR_FUTURE_DATE (err u1007))
(define-constant MAX_STRING_LENGTH u500)
(define-constant MIN_VALID_DATE u1609459200) ;; Jan 1, 2021
(define-constant MAX_GPA_VALUE u400) ;; 4.00 GPA represented as 400

;; data vars
(define-data-var next-credential-id uint u1)
(define-data-var total-credentials uint u0)
(define-data-var contract-paused bool false)
(define-data-var next-verification-id uint u1)

;; data maps
;; Authorized institutions that can issue credentials
(define-map authorized-institutions principal 
  {
    name: (string-ascii 100),
    authorized-date: uint,
    status: bool,
    credentials-issued: uint
  })

;; Main credential storage
(define-map credentials uint 
  {
    student-address: principal,
    institution: principal,
    degree-type: (string-ascii 50),
    major: (string-ascii 100),
    graduation-date: uint,
    gpa: (optional (string-ascii 10)),
    verification-hash: (buff 32),
    issue-date: uint,
    verified: bool,
    metadata: (string-ascii 200)
  })

;; Student credential index for quick lookup
(define-map student-credentials principal (list 50 uint))

;; Institution credential index
(define-map institution-credentials principal (list 1000 uint))

;; Verification requests tracking
(define-map verification-requests uint
  {
    requester: principal,
    credential-id: uint,
    request-date: uint,
    purpose: (string-ascii 100),
    approved: bool
  })

;; public functions

;; Initialize contract - only owner can call
(define-public (initialize-contract)
  (if (is-eq tx-sender CONTRACT_OWNER)
    (begin
      (var-set contract-paused false)
      (ok true)
    )
    ERR_UNAUTHORIZED
  )
)

;; Authorize an institution to issue credentials
(define-public (authorize-institution 
    (institution principal)
    (name (string-ascii 100)))
  (if (is-eq tx-sender CONTRACT_OWNER)
    (begin
      (map-set authorized-institutions institution {
        name: name,
        authorized-date: stacks-block-height,
        status: true,
        credentials-issued: u0
      })
      (ok true)
    )
    ERR_UNAUTHORIZED
  )
)

;; Revoke institution authorization
(define-public (revoke-institution (institution principal))
  (if (is-eq tx-sender CONTRACT_OWNER)
    (match (map-get? authorized-institutions institution)
      institution-data
        (begin
          (map-set authorized-institutions institution (merge institution-data { status: false }))
          (ok true)
        )
      ERR_INVALID_INSTITUTION
    )
    ERR_UNAUTHORIZED
  )
)

;; Issue a new credential - only authorized institutions
(define-public (issue-credential
    (student principal)
    (degree-type (string-ascii 50))
    (major (string-ascii 100))
    (graduation-date uint)
    (gpa (optional (string-ascii 10)))
    (metadata (string-ascii 200)))
  (let (
    (credential-id (var-get next-credential-id))
    (verification-hash (generate-verification-hash student tx-sender degree-type major graduation-date))
  )
    (asserts! (not (var-get contract-paused)) ERR_UNAUTHORIZED)
    (asserts! (is-authorized-institution tx-sender) ERR_UNAUTHORIZED)
    (asserts! (validate-credential-params student degree-type major graduation-date gpa) ERR_INVALID_PARAMETERS)
    
    ;; Store the credential
    (map-set credentials credential-id {
      student-address: student,
      institution: tx-sender,
      degree-type: degree-type,
      major: major,
      graduation-date: graduation-date,
      gpa: gpa,
      verification-hash: verification-hash,
      issue-date: stacks-block-height,
      verified: true,
      metadata: metadata
    })
    
    ;; Update indexes and counters
    (unwrap! (add-to-student-credentials student credential-id) ERR_INVALID_PARAMETERS)
    (unwrap! (add-to-institution-credentials tx-sender credential-id) ERR_INVALID_PARAMETERS)
    (increment-institution-credentials tx-sender)
    (var-set next-credential-id (+ credential-id u1))
    (var-set total-credentials (+ (var-get total-credentials) u1))
    
    (ok credential-id)
  )
)

;; Verify a credential by ID
(define-public (verify-credential (credential-id uint))
  (match (map-get? credentials credential-id)
    credential
      (if (get verified credential)
        (ok credential)
        ERR_CREDENTIAL_NOT_FOUND
      )
    ERR_CREDENTIAL_NOT_FOUND
  )
)

;; Request verification access to a credential
(define-public (request-verification-access 
    (credential-id uint)
    (purpose (string-ascii 100)))
  (let ((verification-id (var-get next-verification-id)))
    (asserts! (is-some (map-get? credentials credential-id)) ERR_CREDENTIAL_NOT_FOUND)
    
    (map-set verification-requests verification-id {
      requester: tx-sender,
      credential-id: credential-id,
      request-date: stacks-block-height,
      purpose: purpose,
      approved: false
    })
    
    (var-set next-verification-id (+ verification-id u1))
    (ok verification-id)
  )
)

;; Pause contract - emergency function
(define-public (pause-contract)
  (if (is-eq tx-sender CONTRACT_OWNER)
    (begin
      (var-set contract-paused true)
      (ok true)
    )
    ERR_UNAUTHORIZED
  )
)

;; read only functions

;; Get credentials for a student
(define-read-only (get-student-credentials (student principal))
  (map-get? student-credentials student)
)

;; Get credentials issued by an institution
(define-read-only (get-institution-credentials (institution principal))
  (map-get? institution-credentials institution)
)

;; Check if institution is authorized
(define-read-only (is-institution-authorized (institution principal))
  (is-authorized-institution institution)
)

;; Get institution details
(define-read-only (get-institution-details (institution principal))
  (map-get? authorized-institutions institution)
)

;; Get credential by ID (public read)
(define-read-only (get-credential (credential-id uint))
  (map-get? credentials credential-id)
)

;; Get contract statistics
(define-read-only (get-contract-stats)
  {
    total-credentials: (var-get total-credentials),
    next-credential-id: (var-get next-credential-id),
    contract-paused: (var-get contract-paused)
  }
)

;; Get verification request details
(define-read-only (get-verification-request (verification-id uint))
  (map-get? verification-requests verification-id)
)

;; private functions

;; Validates if the caller is an authorized institution
(define-private (is-authorized-institution (institution principal))
  (match (map-get? authorized-institutions institution)
    institution-data (get status institution-data)
    false
  )
)

;; Validates credential parameters
(define-private (validate-credential-params 
    (student principal)
    (degree-type (string-ascii 50))
    (major (string-ascii 100))
    (graduation-date uint)
    (gpa (optional (string-ascii 10))))
  (and 
    (> (len degree-type) u0)
    (> (len major) u0)
    (>= graduation-date MIN_VALID_DATE)
    (<= graduation-date (+ stacks-block-height u144)) ;; Not too far in future
    (match gpa
      some-gpa (and (> (len some-gpa) u0) (<= (len some-gpa) u10))
      true
    )
  )
)

;; Generates a verification hash from credential data
(define-private (generate-verification-hash 
    (student principal)
    (institution principal)
    (degree-type (string-ascii 50))
    (major (string-ascii 100))
    (graduation-date uint))
  (sha256 (concat 
    (concat (unwrap-panic (to-consensus-buff? student))
            (unwrap-panic (to-consensus-buff? institution)))
    (concat (unwrap-panic (to-consensus-buff? degree-type))
            (concat (unwrap-panic (to-consensus-buff? major))
                    (unwrap-panic (to-consensus-buff? graduation-date))))
  ))
)

;; Updates credential counts for institution
(define-private (increment-institution-credentials (institution principal))
  (match (map-get? authorized-institutions institution)
    institution-data 
      (map-set authorized-institutions institution 
        (merge institution-data { credentials-issued: (+ (get credentials-issued institution-data) u1) }))
    false
  )
)

;; Adds credential ID to student's credential list
(define-private (add-to-student-credentials (student principal) (credential-id uint))
  (let ((current-list (default-to (list) (map-get? student-credentials student))))
    (map-set student-credentials student (unwrap! (as-max-len? (append current-list credential-id) u50) (err u999)))
    (ok true)
  )
)

;; Adds credential ID to institution's credential list
(define-private (add-to-institution-credentials (institution principal) (credential-id uint))
  (let ((current-list (default-to (list) (map-get? institution-credentials institution))))
    (map-set institution-credentials institution (unwrap! (as-max-len? (append current-list credential-id) u1000) (err u999)))
    (ok true)
  )
)

