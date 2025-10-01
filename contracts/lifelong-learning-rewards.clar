;; title: lifelong-learning-rewards
;; version: 1.0.0
;; summary: Token incentives for continuous education and verified skill development
;; description: Manages reward distribution and learning milestone tracking

;; constants
(define-constant CONTRACT_OWNER tx-sender)
(define-constant ERR_UNAUTHORIZED (err u4001))
(define-constant ERR_INSUFFICIENT_BALANCE (err u4002))
(define-constant ERR_INVALID_AMOUNT (err u4003))
(define-constant ERR_MILESTONE_NOT_FOUND (err u4004))
(define-constant REWARD_TOKEN_MULTIPLIER u100)
(define-constant BASIC_COMPLETION_REWARD u500)
(define-constant ADVANCED_COMPLETION_REWARD u1000)
(define-constant EXCELLENCE_BONUS u250)

;; data vars
(define-data-var next-milestone-id uint u1)
(define-data-var total-rewards-distributed uint u0)
(define-data-var contract-paused bool false)

;; data maps
;; Learning rewards balance for each user
(define-map learning-tokens principal uint)

;; Learning milestones
(define-map learning-milestones uint
  {
    learner: principal,
    milestone-type: (string-ascii 50),
    description: (string-ascii 200),
    completion-date: uint,
    reward-amount: uint,
    verified: bool,
    verifier: principal
  })

;; User learning statistics
(define-map learner-stats principal
  {
    total-milestones: uint,
    total-rewards-earned: uint,
    learning-streak: uint,
    last-activity: uint,
    level: uint
  })

;; public functions

;; Initialize user learning profile
(define-public (initialize-learner-profile)
  (begin
    (map-set learner-stats tx-sender {
      total-milestones: u0,
      total-rewards-earned: u0,
      learning-streak: u0,
      last-activity: stacks-block-height,
      level: u1
    })
    (map-set learning-tokens tx-sender u0)
    (ok true)
  )
)

;; Award learning milestone
(define-public (award-milestone
    (learner principal)
    (milestone-type (string-ascii 50))
    (description (string-ascii 200))
    (reward-amount uint))
  (let ((milestone-id (var-get next-milestone-id)))
    (asserts! (not (var-get contract-paused)) ERR_UNAUTHORIZED)
    (asserts! (> reward-amount u0) ERR_INVALID_AMOUNT)
    
    ;; Store milestone
    (map-set learning-milestones milestone-id {
      learner: learner,
      milestone-type: milestone-type,
      description: description,
      completion-date: stacks-block-height,
      reward-amount: reward-amount,
      verified: true,
      verifier: tx-sender
    })
    
    ;; Award tokens
    (let ((current-balance (default-to u0 (map-get? learning-tokens learner))))
      (map-set learning-tokens learner (+ current-balance reward-amount))
    )
    
    ;; Update learner stats
    (update-learner-stats learner reward-amount)
    
    (var-set next-milestone-id (+ milestone-id u1))
    (var-set total-rewards-distributed (+ (var-get total-rewards-distributed) reward-amount))
    
    (ok milestone-id)
  )
)

;; Redeem learning tokens (placeholder functionality)
(define-public (redeem-tokens (amount uint))
  (let ((current-balance (default-to u0 (map-get? learning-tokens tx-sender))))
    (asserts! (>= current-balance amount) ERR_INSUFFICIENT_BALANCE)
    (asserts! (> amount u0) ERR_INVALID_AMOUNT)
    
    (map-set learning-tokens tx-sender (- current-balance amount))
    (ok true)
  )
)

;; read only functions

;; Get learning token balance
(define-read-only (get-token-balance (learner principal))
  (default-to u0 (map-get? learning-tokens learner))
)

;; Get learner statistics
(define-read-only (get-learner-stats (learner principal))
  (map-get? learner-stats learner)
)

;; Get milestone details
(define-read-only (get-milestone (milestone-id uint))
  (map-get? learning-milestones milestone-id)
)

;; Get contract statistics
(define-read-only (get-contract-stats)
  {
    next-milestone-id: (var-get next-milestone-id),
    total-rewards-distributed: (var-get total-rewards-distributed),
    contract-paused: (var-get contract-paused)
  }
)

;; private functions

;; Update learner statistics
(define-private (update-learner-stats (learner principal) (reward-amount uint))
  (let (
    (current-stats (default-to 
      { total-milestones: u0, total-rewards-earned: u0, learning-streak: u0, last-activity: u0, level: u1 }
      (map-get? learner-stats learner)))
    (new-total-milestones (+ (get total-milestones current-stats) u1))
    (new-total-rewards (+ (get total-rewards-earned current-stats) reward-amount))
    (new-level (calculate-level new-total-rewards))
  )
    (map-set learner-stats learner {
      total-milestones: new-total-milestones,
      total-rewards-earned: new-total-rewards,
      learning-streak: (calculate-streak learner),
      last-activity: stacks-block-height,
      level: new-level
    })
  )
)

;; Calculate learning level based on rewards earned
(define-private (calculate-level (total-rewards uint))
  (if (>= total-rewards u10000) u5
    (if (>= total-rewards u5000) u4
      (if (>= total-rewards u2000) u3
        (if (>= total-rewards u500) u2 u1)
      )
    )
  )
)

;; Calculate learning streak (simplified)
(define-private (calculate-streak (learner principal))
  (match (map-get? learner-stats learner)
    stats (+ (get learning-streak stats) u1)
    u1
  )
)

