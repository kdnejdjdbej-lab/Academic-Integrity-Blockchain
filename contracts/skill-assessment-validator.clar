;; title: skill-assessment-validator
;; version: 1.0.0
;; summary: Blockchain-verified skill tests and competency assessments with proctoring
;; description: Manages test creation, administration, result verification with anti-cheating mechanisms

;; constants
(define-constant CONTRACT_OWNER tx-sender)
(define-constant ERR_UNAUTHORIZED (err u2001))
(define-constant ERR_ASSESSMENT_NOT_FOUND (err u2002))
(define-constant ERR_INVALID_PARAMETERS (err u2003))
(define-constant ERR_ASSESSMENT_EXPIRED (err u2004))
(define-constant ERR_ALREADY_TAKEN (err u2005))
(define-constant ERR_INVALID_SCORE (err u2006))
(define-constant ERR_NOT_ELIGIBLE (err u2007))
(define-constant ERR_PROCTORING_FAILED (err u2008))
(define-constant MAX_SCORE u1000)
(define-constant MIN_PASSING_SCORE u600) ;; 60% passing
(define-constant ASSESSMENT_VALIDITY_PERIOD u52560) ;; ~1 year in blocks
(define-constant MAX_RETAKES u3)

;; data vars
(define-data-var next-assessment-id uint u1)
(define-data-var next-result-id uint u1)
(define-data-var total-assessments uint u0)
(define-data-var contract-paused bool false)
(define-data-var proctoring-enabled bool true)

;; data maps
;; Assessment templates created by authorized providers
(define-map assessment-templates uint
  {
    provider: principal,
    title: (string-ascii 100),
    skill-domain: (string-ascii 50),
    difficulty-level: uint, ;; 1-5 scale
    max-score: uint,
    passing-score: uint,
    time-limit: uint, ;; in minutes
    proctoring-required: bool,
    active: bool,
    created-date: uint,
    validity-period: uint,
    prerequisites: (list 10 uint)
  })

;; Individual assessment results
(define-map assessment-results uint
  {
    candidate: principal,
    assessment-id: uint,
    score: uint,
    max-score: uint,
    percentage: uint,
    passed: bool,
    completion-date: uint,
    time-taken: uint, ;; in minutes
    proctored: bool,
    proctor-id: (optional principal),
    verification-hash: (buff 32),
    retake-number: uint,
    valid-until: uint
  })

;; Authorized assessment providers
(define-map authorized-providers principal
  {
    name: (string-ascii 100),
    specialization: (string-ascii 50),
    authorized-date: uint,
    active: bool,
    assessments-created: uint,
    reputation-score: uint
  })

;; Authorized proctors for supervised assessments
(define-map authorized-proctors principal
  {
    name: (string-ascii 100),
    certification: (string-ascii 50),
    authorized-date: uint,
    active: bool,
    assessments-proctored: uint,
    success-rate: uint
  })

;; Candidate assessment history
(define-map candidate-assessments principal (list 100 uint))

;; Provider assessment tracking
(define-map provider-assessments principal (list 500 uint))

;; Assessment attempt tracking (to prevent cheating)
(define-map assessment-attempts
  { candidate: principal, assessment-id: uint }
  {
    attempts: uint,
    last-attempt: uint,
    best-score: uint,
    locked-until: (optional uint)
  })

;; Skill verification certificates
(define-map skill-certificates uint
  {
    candidate: principal,
    skill-domain: (string-ascii 50),
    proficiency-level: uint, ;; 1-5 scale
    assessment-results: (list 20 uint),
    issue-date: uint,
    expiry-date: uint,
    verified: bool
  })

(define-data-var next-certificate-id uint u1)

;; public functions

;; Initialize contract
(define-public (initialize-contract)
  (if (is-eq tx-sender CONTRACT_OWNER)
    (begin
      (var-set contract-paused false)
      (var-set proctoring-enabled true)
      (ok true)
    )
    ERR_UNAUTHORIZED
  )
)

;; Authorize assessment provider
(define-public (authorize-provider
    (provider principal)
    (name (string-ascii 100))
    (specialization (string-ascii 50)))
  (if (is-eq tx-sender CONTRACT_OWNER)
    (begin
      (map-set authorized-providers provider {
        name: name,
        specialization: specialization,
        authorized-date: stacks-block-height,
        active: true,
        assessments-created: u0,
        reputation-score: u500 ;; Starting reputation
      })
      (ok true)
    )
    ERR_UNAUTHORIZED
  )
)

;; Authorize proctor
(define-public (authorize-proctor
    (proctor principal)
    (name (string-ascii 100))
    (certification (string-ascii 50)))
  (if (is-eq tx-sender CONTRACT_OWNER)
    (begin
      (map-set authorized-proctors proctor {
        name: name,
        certification: certification,
        authorized-date: stacks-block-height,
        active: true,
        assessments-proctored: u0,
        success-rate: u0
      })
      (ok true)
    )
    ERR_UNAUTHORIZED
  )
)

;; Create new assessment template
(define-public (create-assessment
    (title (string-ascii 100))
    (skill-domain (string-ascii 50))
    (difficulty-level uint)
    (max-score uint)
    (passing-score uint)
    (time-limit uint)
    (proctoring-required bool)
    (prerequisites (list 10 uint)))
  (let ((assessment-id (var-get next-assessment-id)))
    (asserts! (not (var-get contract-paused)) ERR_UNAUTHORIZED)
    (asserts! (is-authorized-provider tx-sender) ERR_UNAUTHORIZED)
    (asserts! (validate-assessment-params difficulty-level max-score passing-score time-limit) ERR_INVALID_PARAMETERS)
    
    (map-set assessment-templates assessment-id {
      provider: tx-sender,
      title: title,
      skill-domain: skill-domain,
      difficulty-level: difficulty-level,
      max-score: max-score,
      passing-score: passing-score,
      time-limit: time-limit,
      proctoring-required: proctoring-required,
      active: true,
      created-date: stacks-block-height,
      validity-period: ASSESSMENT_VALIDITY_PERIOD,
      prerequisites: prerequisites
    })
    
    ;; Update tracking
    (unwrap! (add-to-provider-assessments tx-sender assessment-id) ERR_INVALID_PARAMETERS)
    (increment-provider-assessments tx-sender)
    (var-set next-assessment-id (+ assessment-id u1))
    (var-set total-assessments (+ (var-get total-assessments) u1))
    
    (ok assessment-id)
  )
)

;; Take assessment
(define-public (take-assessment
    (assessment-id uint)
    (score uint)
    (time-taken uint)
    (proctor-id (optional principal)))
  (let (
    (result-id (var-get next-result-id))
    (assessment (unwrap! (map-get? assessment-templates assessment-id) ERR_ASSESSMENT_NOT_FOUND))
    (attempt-key { candidate: tx-sender, assessment-id: assessment-id })
    (current-attempts (default-to { attempts: u0, last-attempt: u0, best-score: u0, locked-until: none } 
                                  (map-get? assessment-attempts attempt-key)))
  )
    (asserts! (not (var-get contract-paused)) ERR_UNAUTHORIZED)
    (asserts! (get active assessment) ERR_ASSESSMENT_NOT_FOUND)
    (asserts! (<= score (get max-score assessment)) ERR_INVALID_SCORE)
    (asserts! (< (get attempts current-attempts) MAX_RETAKES) ERR_NOT_ELIGIBLE)
    (asserts! (check-prerequisites assessment-id tx-sender) ERR_NOT_ELIGIBLE)
    
    ;; Validate proctoring if required
    (asserts! (if (get proctoring-required assessment)
                (and (is-some proctor-id) (is-authorized-proctor (unwrap-panic proctor-id)))
                true) ERR_PROCTORING_FAILED)
    
    (let (
      (percentage (calculate-percentage score (get max-score assessment)))
      (passed (>= percentage (get passing-score assessment)))
      (verification-hash (generate-assessment-hash tx-sender assessment-id score time-taken))
    )
      ;; Store result
      (map-set assessment-results result-id {
        candidate: tx-sender,
        assessment-id: assessment-id,
        score: score,
        max-score: (get max-score assessment),
        percentage: percentage,
        passed: passed,
        completion-date: stacks-block-height,
        time-taken: time-taken,
        proctored: (is-some proctor-id),
        proctor-id: proctor-id,
        verification-hash: verification-hash,
        retake-number: (+ (get attempts current-attempts) u1),
        valid-until: (+ stacks-block-height ASSESSMENT_VALIDITY_PERIOD)
      })
      
      ;; Update attempt tracking
      (map-set assessment-attempts attempt-key {
        attempts: (+ (get attempts current-attempts) u1),
        last-attempt: stacks-block-height,
        best-score: (if (> score (get best-score current-attempts)) score (get best-score current-attempts)),
        locked-until: (if (not passed) (some (+ stacks-block-height u144)) none) ;; 24 hour cooldown if failed
      })
      
      ;; Update indexes
      (unwrap! (add-to-candidate-assessments tx-sender result-id) ERR_INVALID_PARAMETERS)
      (var-set next-result-id (+ result-id u1))
      
      ;; Update proctor stats if proctored
      (if (is-some proctor-id)
        (increment-proctor-stats (unwrap-panic proctor-id) passed)
        true
      )
      
      (ok result-id)
    )
  )
)

;; Issue skill certificate
(define-public (issue-skill-certificate
    (candidate principal)
    (skill-domain (string-ascii 50))
    (proficiency-level uint)
    (result-list (list 20 uint)))
  (let ((certificate-id (var-get next-certificate-id)))
    (asserts! (is-authorized-provider tx-sender) ERR_UNAUTHORIZED)
    (asserts! (validate-certificate-requirements result-list proficiency-level) ERR_INVALID_PARAMETERS)
    
    (map-set skill-certificates certificate-id {
      candidate: candidate,
      skill-domain: skill-domain,
      proficiency-level: proficiency-level,
      assessment-results: result-list,
      issue-date: stacks-block-height,
      expiry-date: (+ stacks-block-height (* ASSESSMENT_VALIDITY_PERIOD u2)), ;; 2 years validity
      verified: true
    })
    
    (var-set next-certificate-id (+ certificate-id u1))
    (ok certificate-id)
  )
)

;; Pause contract
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

;; Get assessment template
(define-read-only (get-assessment (assessment-id uint))
  (map-get? assessment-templates assessment-id)
)

;; Get assessment result
(define-read-only (get-assessment-result (result-id uint))
  (map-get? assessment-results result-id)
)

;; Get candidate assessments
(define-read-only (get-candidate-assessments (candidate principal))
  (map-get? candidate-assessments candidate)
)

;; Get skill certificate
(define-read-only (get-skill-certificate (certificate-id uint))
  (map-get? skill-certificates certificate-id)
)

;; Check if provider is authorized
(define-read-only (is-provider-authorized (provider principal))
  (is-authorized-provider provider)
)

;; Get contract statistics
(define-read-only (get-contract-stats)
  {
    total-assessments: (var-get total-assessments),
    next-assessment-id: (var-get next-assessment-id),
    next-result-id: (var-get next-result-id),
    contract-paused: (var-get contract-paused),
    proctoring-enabled: (var-get proctoring-enabled)
  }
)

;; private functions

;; Check if provider is authorized
(define-private (is-authorized-provider (provider principal))
  (match (map-get? authorized-providers provider)
    provider-data (get active provider-data)
    false
  )
)

;; Check if proctor is authorized
(define-private (is-authorized-proctor (proctor principal))
  (match (map-get? authorized-proctors proctor)
    proctor-data (get active proctor-data)
    false
  )
)

;; Validate assessment parameters
(define-private (validate-assessment-params
    (difficulty-level uint)
    (max-score uint)
    (passing-score uint)
    (time-limit uint))
  (and
    (>= difficulty-level u1)
    (<= difficulty-level u5)
    (> max-score u0)
    (<= max-score MAX_SCORE)
    (> passing-score u0)
    (<= passing-score max-score)
    (> time-limit u0)
    (<= time-limit u480) ;; Max 8 hours
  )
)

;; Calculate percentage score
(define-private (calculate-percentage (score uint) (max-score uint))
  (if (> max-score u0)
    (/ (* score u100) max-score)
    u0
  )
)

;; Generate verification hash
(define-private (generate-assessment-hash
    (candidate principal)
    (assessment-id uint)
    (score uint)
    (time-taken uint))
  (sha256 (concat
    (concat (unwrap-panic (to-consensus-buff? candidate))
            (unwrap-panic (to-consensus-buff? assessment-id)))
    (concat (unwrap-panic (to-consensus-buff? score))
            (unwrap-panic (to-consensus-buff? time-taken)))
  ))
)

;; Check prerequisites
(define-private (check-prerequisites (assessment-id uint) (candidate principal))
  ;; Simplified - in real implementation would check actual prerequisite completions
  true
)

;; Validate certificate requirements
(define-private (validate-certificate-requirements (result-list (list 20 uint)) (proficiency-level uint))
  (and
    (>= proficiency-level u1)
    (<= proficiency-level u5)
    (> (len result-list) u0)
  )
)

;; Add assessment to candidate tracking
(define-private (add-to-candidate-assessments (candidate principal) (result-id uint))
  (let ((current-list (default-to (list) (map-get? candidate-assessments candidate))))
    (map-set candidate-assessments candidate (unwrap! (as-max-len? (append current-list result-id) u100) (err u999)))
    (ok true)
  )
)

;; Add assessment to provider tracking
(define-private (add-to-provider-assessments (provider principal) (assessment-id uint))
  (let ((current-list (default-to (list) (map-get? provider-assessments provider))))
    (map-set provider-assessments provider (unwrap! (as-max-len? (append current-list assessment-id) u500) (err u999)))
    (ok true)
  )
)

;; Increment provider assessment count
(define-private (increment-provider-assessments (provider principal))
  (match (map-get? authorized-providers provider)
    provider-data
      (map-set authorized-providers provider 
        (merge provider-data { assessments-created: (+ (get assessments-created provider-data) u1) }))
    false
  )
)

;; Update proctor statistics
(define-private (increment-proctor-stats (proctor principal) (assessment-passed bool))
  (match (map-get? authorized-proctors proctor)
    proctor-data
      (let (
        (current-proctored (get assessments-proctored proctor-data))
        (current-success-rate (get success-rate proctor-data))
        (new-proctored (+ current-proctored u1))
        (new-success-rate (if assessment-passed
                           (/ (+ (* current-success-rate current-proctored) u100) new-proctored)
                           (/ (* current-success-rate current-proctored) new-proctored)))
      )
        (map-set authorized-proctors proctor 
          (merge proctor-data {
            assessments-proctored: new-proctored,
            success-rate: new-success-rate
          }))
      )
    false
  )
)

