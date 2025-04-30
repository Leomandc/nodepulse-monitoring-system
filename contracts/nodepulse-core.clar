;; nodepulse-core.clar
;; A smart contract for the NodePulse Monitoring System
;; This contract manages node registration, monitoring reports, and reputation scoring
;; for Stacks blockchain nodes, enabling a decentralized reputation system.

;; =============================
;; Constants and Error Codes
;; =============================

;; Error codes for authorization
(define-constant ERR-NOT-AUTHORIZED (err u100))
(define-constant ERR-ADMIN-ONLY (err u101))

;; Error codes for node registration
(define-constant ERR-NODE-ALREADY-REGISTERED (err u200))
(define-constant ERR-NODE-NOT-REGISTERED (err u201))
(define-constant ERR-INSUFFICIENT-STAKE (err u202))
(define-constant ERR-INVALID-NODE-TYPE (err u203))
(define-constant ERR-INVALID-URL (err u204))

;; Error codes for validator operations
(define-constant ERR-VALIDATOR-ALREADY-REGISTERED (err u300))
(define-constant ERR-VALIDATOR-NOT-REGISTERED (err u301))
(define-constant ERR-REPORT-TOO-SOON (err u302))
(define-constant ERR-INVALID-METRICS (err u303))
(define-constant ERR-DUPLICATE-REPORT (err u304))

;; Error codes for reward/slashing operations
(define-constant ERR-NO-REWARDS-AVAILABLE (err u400))
(define-constant ERR-CANNOT-WITHDRAW-YET (err u401))

;; General error codes
(define-constant ERR-TRANSFER-FAILED (err u500))
(define-constant ERR-INVALID-ARGUMENTS (err u501))

;; System parameters
(define-constant MIN-STAKE-AMOUNT u1000000) ;; 1 STX minimum stake 
(define-constant REWARD-CYCLE-LENGTH u144) ;; Approximately 1 day (144 blocks)
(define-constant COOLDOWN-PERIOD u1008) ;; Approximately 7 days (1008 blocks)
(define-constant MIN-REPORT-INTERVAL u36) ;; Minimum 6 hours between reports (36 blocks)

;; Node types
(define-constant NODE-TYPE-MINER u1)
(define-constant NODE-TYPE-FOLLOWER u2)
(define-constant NODE-TYPE-SEED u3)

;; Weights for reputation scoring
(define-constant WEIGHT-UPTIME u50)
(define-constant WEIGHT-RESPONSE-TIME u20)
(define-constant WEIGHT-CONSENSUS u30)

;; =============================
;; Data Maps and Variables
;; =============================

;; Contract administrator
(define-data-var contract-admin principal tx-sender)

;; Track the current cycle for rewards
(define-data-var current-cycle uint u0)

;; Store node registrations with metadata
(define-map nodes
  { node-id: uint }
  {
    owner: principal,
    url: (string-ascii 256),
    node-type: uint,
    stake-amount: uint,
    registered-at: uint,
    reputation-score: uint,
    total-reports: uint,
    active: bool,
    cooldown-until: uint
  }
)

;; Store validator registrations
(define-map validators
  { address: principal }
  {
    registered-at: uint,
    reports-submitted: uint,
    reputation: uint,
    last-reward-cycle: uint
  }
)

;; Store node performance reports
(define-map node-reports
  { node-id: uint, validator: principal, cycle: uint }
  {
    uptime: uint,
    response-time: uint,
    consensus-participation: uint,
    reported-at: uint,
    verified: bool
  }
)

;; Track the mapping of node URLs to node IDs for uniqueness check
(define-map node-url-to-id
  { url: (string-ascii 256) }
  { node-id: uint }
)

;; Track reward pools
(define-data-var validator-reward-pool uint u0)
(define-data-var node-reward-pool uint u0)

;; Track the next node ID
(define-data-var next-node-id uint u1)

;; =============================
;; Private Functions
;; =============================

;; Generate a new node ID
(define-private (generate-node-id)
  (let ((node-id (var-get next-node-id)))
    (var-set next-node-id (+ node-id u1))
    node-id))

;; Calculate reputation score from metrics
;; Returns a value between 0-100
(define-private (calculate-reputation (uptime uint) (response-time uint) (consensus uint))
  (let 
    (
      ;; Convert all metrics to scores out of 100
      ;; Uptime is already 0-100
      ;; Response time: lower is better, so we inverse the score (capped at 5000ms)
      (response-score (if (> response-time u5000) 
                        u0 
                        (/ (* (- u5000 response-time) u100) u5000)))
      ;; Consensus: higher is better (0-100)
      (consensus-score (if (> consensus u100) u100 consensus))
      
      ;; Calculate weighted score
      (weighted-uptime (* uptime WEIGHT-UPTIME))
      (weighted-response (* response-score WEIGHT-RESPONSE-TIME))
      (weighted-consensus (* consensus-score WEIGHT-CONSENSUS))
    )
    ;; Return weighted average out of 100
    (/ (+ weighted-uptime weighted-response weighted-consensus) u100)
  )
)

;; Update node reputation based on a new report
(define-private (update-node-reputation (node-id uint) (uptime uint) (response-time uint) (consensus uint))
  (match (map-get? nodes { node-id: node-id })
    node-data
    (let
      (
        (current-score (get reputation-score node-data))
        (total-reports (get total-reports node-data))
        (new-score (calculate-reputation uptime response-time consensus))
        ;; Calculate a weighted average that increasingly favors historical data
        (updated-score (if (= total-reports u0)
                        new-score
                        (/ (+ (* current-score total-reports) new-score) (+ total-reports u1))))
      )
      (map-set nodes
        { node-id: node-id }
        (merge node-data {
          reputation-score: updated-score,
          total-reports: (+ total-reports u1)
        })
      )
      updated-score
    )
    u0
  )
)

;; Check if a principal is the contract administrator
(define-private (is-admin)
  (is-eq tx-sender (var-get contract-admin)))

;; Check if the current block is in a new reward cycle
(define-private (is-new-reward-cycle)
  (let 
    (
      (current-height block-height)
      (last-cycle-change (/ (var-get current-cycle) REWARD-CYCLE-LENGTH))
      (current-cycle-should-be (/ current-height REWARD-CYCLE-LENGTH))
    )
    (> current-cycle-should-be last-cycle-change)
  )
)

;; Update the current cycle if necessary
(define-private (update-cycle)
  (if (is-new-reward-cycle)
    (var-set current-cycle (/ block-height REWARD-CYCLE-LENGTH))
    true
  )
)

;; Validate node type
(define-private (is-valid-node-type (node-type uint))
  (or
    (is-eq node-type NODE-TYPE-MINER)
    (is-eq node-type NODE-TYPE-FOLLOWER)
    (is-eq node-type NODE-TYPE-SEED)
  )
)

;; Validate monitoring metrics are within acceptable ranges
(define-private (are-valid-metrics (uptime uint) (response-time uint) (consensus-participation uint))
  (and
    (<= uptime u100)  ;; Uptime must be between 0-100%
    (<= consensus-participation u100)  ;; Consensus participation must be between 0-100%
    ;; Response time can be any positive number, so no validation needed
    true
  )
)

;; Process rewards distribution at the end of a cycle
(define-private (process-cycle-rewards)
  (let 
    (
      (validator-pool (var-get validator-reward-pool))
      (node-pool (var-get node-reward-pool))
    )
    ;; Logic for reward distribution would go here
    ;; For this implementation, we'll just reset the pools
    (var-set validator-reward-pool u0)
    (var-set node-reward-pool u0)
    true
  )
)

;; =============================
;; Read-Only Functions
;; =============================

;; Get node details
(define-read-only (get-node-info (node-id uint))
  (map-get? nodes { node-id: node-id }))

;; Get validator details
(define-read-only (get-validator-info (address principal))
  (map-get? validators { address: address }))

;; Get report details
(define-read-only (get-node-report (node-id uint) (validator principal) (cycle uint))
  (map-get? node-reports { node-id: node-id, validator: validator, cycle: cycle }))

;; Get the current reward cycle
(define-read-only (get-current-cycle)
  (var-get current-cycle))

;; Get node ID from URL
(define-read-only (get-node-id-by-url (url (string-ascii 256)))
  (map-get? node-url-to-id { url: url }))

;; Get reward pools
(define-read-only (get-reward-pools)
  {
    validator-pool: (var-get validator-reward-pool),
    node-pool: (var-get node-reward-pool)
  })

;; Check if node exists
(define-read-only (is-node-registered (node-id uint))
  (is-some (map-get? nodes { node-id: node-id })))

;; Check if validator exists
(define-read-only (is-validator-registered (address principal))
  (is-some (map-get? validators { address: address })))

;; =============================
;; Public Functions
;; =============================

;; Update contract administrator
(define-public (set-admin (new-admin principal))
  (begin
    (asserts! (is-admin) ERR-ADMIN-ONLY)
    (ok (var-set contract-admin new-admin))))

;; Register a new node
(define-public (register-node (url (string-ascii 256)) (node-type uint) (stake-amount uint))
  (let
    (
      (node-id (generate-node-id))
      (sender tx-sender)
    )
    ;; Update the cycle first
    (update-cycle)
    
    ;; Validate inputs
    (asserts! (is-valid-node-type node-type) ERR-INVALID-NODE-TYPE)
    (asserts! (>= (len url) u5) ERR-INVALID-URL) ;; Minimal URL validation
    (asserts! (>= stake-amount MIN-STAKE-AMOUNT) ERR-INSUFFICIENT-STAKE)
    
    ;; Check URL is not already registered
    (asserts! (is-none (map-get? node-url-to-id { url: url })) ERR-NODE-ALREADY-REGISTERED)
    
    ;; Transfer staked tokens to contract
    (match (stx-transfer? stake-amount sender (as-contract tx-sender))
      success
      (begin
        ;; Register the node
        (map-set nodes
          { node-id: node-id }
          {
            owner: sender,
            url: url,
            node-type: node-type,
            stake-amount: stake-amount,
            registered-at: block-height,
            reputation-score: u50, ;; Start with neutral score
            total-reports: u0,
            active: true,
            cooldown-until: u0
          }
        )
        
        ;; Map URL to node ID
        (map-set node-url-to-id
          { url: url }
          { node-id: node-id }
        )
        
        (ok node-id)
      )
      error
      ERR-TRANSFER-FAILED
    )
  )
)

;; Register as a validator
(define-public (register-validator)
  (let ((sender tx-sender))
    ;; Update the cycle first
    (update-cycle)
    
    ;; Check if already registered
    (asserts! (is-none (map-get? validators { address: sender })) ERR-VALIDATOR-ALREADY-REGISTERED)
    
    ;; Register the validator
    (map-set validators
      { address: sender }
      {
        registered-at: block-height,
        reports-submitted: u0,
        reputation: u50, ;; Start with neutral reputation
        last-reward-cycle: (var-get current-cycle)
      }
    )
    
    (ok true)
  )
)

;; Submit a monitoring report for a node
(define-public (submit-report (node-id uint) (uptime uint) (response-time uint) (consensus-participation uint))
  (let
    (
      (validator tx-sender)
      (current-cycle-value (var-get current-cycle))
    )
    ;; Update the cycle first
    (update-cycle)
    
    ;; Validate inputs
    (asserts! (is-node-registered node-id) ERR-NODE-NOT-REGISTERED)
    (asserts! (is-validator-registered validator) ERR-VALIDATOR-NOT-REGISTERED)
    (asserts! (are-valid-metrics uptime response-time consensus-participation) ERR-INVALID-METRICS)
    
    ;; Get validator info
    (match (map-get? validators { address: validator })
      validator-data
      (let
        (
          (report-key { node-id: node-id, validator: validator, cycle: current-cycle-value })
        )
        ;; Check if already reported in this cycle
        (asserts! (is-none (map-get? node-reports report-key)) ERR-DUPLICATE-REPORT)
        
        ;; Check if enough time has passed since the last report
        (match (map-get? node-reports { node-id: node-id, validator: validator, cycle: (- current-cycle-value u1) })
          last-report
          (asserts! (>= block-height (+ (get reported-at last-report) MIN-REPORT-INTERVAL)) ERR-REPORT-TOO-SOON)
          true
        )
        
        ;; Store the report
        (map-set node-reports
          report-key
          {
            uptime: uptime,
            response-time: response-time,
            consensus-participation: consensus-participation,
            reported-at: block-height,
            verified: false
          }
        )
        
        ;; Update validator stats
        (map-set validators
          { address: validator }
          (merge validator-data {
            reports-submitted: (+ (get reports-submitted validator-data) u1)
          })
        )
        
        ;; Update node reputation
        (let
          ((new-score (update-node-reputation node-id uptime response-time consensus-participation)))
          (ok new-score)
        )
      )
      ERR-VALIDATOR-NOT-REGISTERED
    )
  )
)

;; Unstake and withdraw from a node
(define-public (unstake-node (node-id uint))
  (let ((sender tx-sender))
    ;; Update cycle first
    (update-cycle)
    
    ;; Check node exists and caller is the owner
    (match (map-get? nodes { node-id: node-id })
      node-data
      (begin
        (asserts! (is-eq sender (get owner node-data)) ERR-NOT-AUTHORIZED)
        (asserts! (get active node-data) ERR-NODE-NOT-REGISTERED)
        
        ;; Put node in cooldown period
        (map-set nodes
          { node-id: node-id }
          (merge node-data {
            active: false,
            cooldown-until: (+ block-height COOLDOWN-PERIOD)
          })
        )
        
        (ok true)
      )
      ERR-NODE-NOT-REGISTERED
    )
  )
)

;; Complete withdrawal after cooldown period
(define-public (complete-withdrawal (node-id uint))
  (let ((sender tx-sender))
    ;; Check node exists and caller is the owner
    (match (map-get? nodes { node-id: node-id })
      node-data
      (begin
        (asserts! (is-eq sender (get owner node-data)) ERR-NOT-AUTHORIZED)
        (asserts! (not (get active node-data)) ERR-INVALID-ARGUMENTS)
        (asserts! (>= block-height (get cooldown-until node-data)) ERR-CANNOT-WITHDRAW-YET)
        
        ;; Return staked amount
        (match (as-contract (stx-transfer? (get stake-amount node-data) tx-sender sender))
          success
          (begin
            ;; Remove node data (could alternatively mark as withdrawn)
            (map-delete nodes { node-id: node-id })
            (ok true)
          )
          error
          ERR-TRANSFER-FAILED
        )
      )
      ERR-NODE-NOT-REGISTERED
    )
  )
)

;; Update node URL
(define-public (update-node-url (node-id uint) (new-url (string-ascii 256)))
  (let ((sender tx-sender))
    ;; Check node exists and caller is the owner
    (match (map-get? nodes { node-id: node-id })
      node-data
      (begin
        (asserts! (is-eq sender (get owner node-data)) ERR-NOT-AUTHORIZED)
        (asserts! (get active node-data) ERR-NODE-NOT-REGISTERED)
        (asserts! (>= (len new-url) u5) ERR-INVALID-URL)
        
        ;; Check if new URL is already registered to a different node
        (match (map-get? node-url-to-id { url: new-url })
          existing-id
          (asserts! (is-eq node-id (get node-id existing-id)) ERR-NODE-ALREADY-REGISTERED)
          true
        )
        
        ;; Update URL mapping
        (map-delete node-url-to-id { url: (get url node-data) })
        (map-set node-url-to-id { url: new-url } { node-id: node-id })
        
        ;; Update node data
        (map-set nodes
          { node-id: node-id }
          (merge node-data { url: new-url })
        )
        
        (ok true)
      )
      ERR-NODE-NOT-REGISTERED
    )
  )
)

;; Add additional stake to a node
(define-public (add-stake (node-id uint) (additional-amount uint))
  (let ((sender tx-sender))
    ;; Check node exists and caller is the owner
    (match (map-get? nodes { node-id: node-id })
      node-data
      (begin
        (asserts! (is-eq sender (get owner node-data)) ERR-NOT-AUTHORIZED)
        (asserts! (get active node-data) ERR-NODE-NOT-REGISTERED)
        (asserts! (> additional-amount u0) ERR-INVALID-ARGUMENTS)
        
        ;; Transfer additional staked tokens to contract
        (match (stx-transfer? additional-amount sender (as-contract tx-sender))
          success
          (begin
            ;; Update node stake amount
            (map-set nodes
              { node-id: node-id }
              (merge node-data {
                stake-amount: (+ (get stake-amount node-data) additional-amount)
              })
            )
            
            (ok true)
          )
          error
          ERR-TRANSFER-FAILED
        )
      )
      ERR-NODE-NOT-REGISTERED
    )
  )
)

;; Initialize the contract - can only be called once
(define-public (initialize (admin principal))
  (begin
    (asserts! (is-eq tx-sender (var-get contract-admin)) ERR-NOT-AUTHORIZED)
    (var-set contract-admin admin)
    (var-set current-cycle (/ block-height REWARD-CYCLE-LENGTH))
    (ok true)
  )
)