;; Drought Response Management Contract
;; Implements water conservation measures during shortage periods

;; Constants
(define-constant CONTRACT-OWNER tx-sender)
(define-constant ERR-NOT-AUTHORIZED (err u400))
(define-constant ERR-INVALID-LEVEL (err u401))
(define-constant ERR-INVALID-STATUS (err u402))
(define-constant ERR-RESTRICTION-NOT-FOUND (err u403))
(define-constant ERR-ZONE-NOT-FOUND (err u404))

;; Drought levels
(define-constant DROUGHT-LEVEL-NORMAL u0)
(define-constant DROUGHT-LEVEL-MILD u1)
(define-constant DROUGHT-LEVEL-MODERATE u2)
(define-constant DROUGHT-LEVEL-SEVERE u3)
(define-constant DROUGHT-LEVEL-EXTREME u4)

;; Restriction types
(define-constant RESTRICTION-OUTDOOR-WATERING u1)
(define-constant RESTRICTION-CAR-WASHING u2)
(define-constant RESTRICTION-POOL-FILLING u3)
(define-constant RESTRICTION-INDUSTRIAL-USE u4)
(define-constant RESTRICTION-EMERGENCY-ONLY u5)

;; Data Variables
(define-data-var current-drought-level uint DROUGHT-LEVEL-NORMAL)
(define-data-var zone-counter uint u0)
(define-data-var restriction-counter uint u0)
(define-data-var total-water-saved uint u0)

;; Data Maps
(define-map drought-zones
  { zone-id: uint }
  {
    name: (string-ascii 100),
    area-description: (string-ascii 200),
    population: uint,
    current-level: uint,
    water-reserves: uint,
    consumption-baseline: uint,
    is-active: bool
  }
)

(define-map water-restrictions
  { restriction-id: uint }
  {
    zone-id: uint,
    restriction-type: uint,
    drought-level: uint,
    description: (string-ascii 300),
    penalty-amount: uint,
    effective-block: uint,
    expiry-block: (optional uint),
    is-active: bool
  }
)

(define-map conservation-measures
  { zone-id: uint, drought-level: uint }
  {
    target-reduction: uint,
    mandatory-restrictions: (list 5 uint),
    voluntary-measures: (string-ascii 500),
    emergency-protocols: (string-ascii 500),
    public-messaging: (string-ascii 300)
  }
)

(define-map violation-records
  { user-id: principal, restriction-id: uint }
  {
    violation-block: uint,
    penalty-paid: bool,
    evidence: (string-ascii 200),
    reported-by: principal,
    resolved-block: (optional uint)
  }
)

(define-map emergency-supplies
  { zone-id: uint }
  {
    water-trucks: uint,
    distribution-points: uint,
    daily-capacity: uint,
    current-stock: uint,
    last-updated: uint
  }
)

(define-map conservation-incentives
  { user-id: principal, period: uint }
  {
    baseline-usage: uint,
    actual-usage: uint,
    reduction-percentage: uint,
    reward-amount: uint,
    claimed: bool
  }
)

;; Public Functions

;; Create a new drought management zone
(define-public (create-zone (name (string-ascii 100)) (area-description (string-ascii 200)) (population uint) (water-reserves uint) (consumption-baseline uint))
  (let ((zone-id (+ (var-get zone-counter) u1)))
    (asserts! (is-eq tx-sender CONTRACT-OWNER) ERR-NOT-AUTHORIZED)

    (map-set drought-zones
      { zone-id: zone-id }
      {
        name: name,
        area-description: area-description,
        population: population,
        current-level: DROUGHT-LEVEL-NORMAL,
        water-reserves: water-reserves,
        consumption-baseline: consumption-baseline,
        is-active: true
      }
    )

    ;; Initialize emergency supplies
    (map-set emergency-supplies
      { zone-id: zone-id }
      {
        water-trucks: u0,
        distribution-points: u0,
        daily-capacity: u0,
        current-stock: u0,
        last-updated: block-height
      }
    )

    (var-set zone-counter zone-id)
    (ok zone-id)
  )
)

;; Update drought level for a zone
(define-public (update-drought-level (zone-id uint) (new-level uint))
  (let ((zone-data (unwrap! (map-get? drought-zones { zone-id: zone-id }) ERR-ZONE-NOT-FOUND)))
    (asserts! (is-eq tx-sender CONTRACT-OWNER) ERR-NOT-AUTHORIZED)
    (asserts! (<= new-level DROUGHT-LEVEL-EXTREME) ERR-INVALID-LEVEL)

    (map-set drought-zones
      { zone-id: zone-id }
      (merge zone-data { current-level: new-level })
    )

    ;; Activate appropriate conservation measures
    (activate-conservation-measures zone-id new-level)

    ;; Update global drought level if this is the highest
    (if (> new-level (var-get current-drought-level))
        (var-set current-drought-level new-level)
        true
    )

    (ok true)
  )
)

;; Create water restriction
(define-public (create-restriction (zone-id uint) (restriction-type uint) (drought-level uint) (description (string-ascii 300)) (penalty-amount uint) (duration-blocks uint))
  (let (
    (zone-data (unwrap! (map-get? drought-zones { zone-id: zone-id }) ERR-ZONE-NOT-FOUND))
    (restriction-id (+ (var-get restriction-counter) u1))
  )
    (asserts! (is-eq tx-sender CONTRACT-OWNER) ERR-NOT-AUTHORIZED)
    (asserts! (and (>= restriction-type RESTRICTION-OUTDOOR-WATERING) (<= restriction-type RESTRICTION-EMERGENCY-ONLY)) ERR-INVALID-LEVEL)
    (asserts! (<= drought-level DROUGHT-LEVEL-EXTREME) ERR-INVALID-LEVEL)

    (map-set water-restrictions
      { restriction-id: restriction-id }
      {
        zone-id: zone-id,
        restriction-type: restriction-type,
        drought-level: drought-level,
        description: description,
        penalty-amount: penalty-amount,
        effective-block: block-height,
        expiry-block: (if (> duration-blocks u0) (some (+ block-height duration-blocks)) none),
        is-active: true
      }
    )

    (var-set restriction-counter restriction-id)
    (ok restriction-id)
  )
)

;; Report restriction violation
(define-public (report-violation (user-id principal) (restriction-id uint) (evidence (string-ascii 200)))
  (let ((restriction-data (unwrap! (map-get? water-restrictions { restriction-id: restriction-id }) ERR-RESTRICTION-NOT-FOUND)))
    (asserts! (get is-active restriction-data) ERR-INVALID-STATUS)

    (map-set violation-records
      { user-id: user-id, restriction-id: restriction-id }
      {
        violation-block: block-height,
        penalty-paid: false,
        evidence: evidence,
        reported-by: tx-sender,
        resolved-block: none
      }
    )
    (ok true)
  )
)

;; Pay violation penalty
(define-public (pay-penalty (restriction-id uint))
  (let (
    (violation-data (unwrap! (map-get? violation-records { user-id: tx-sender, restriction-id: restriction-id }) ERR-RESTRICTION-NOT-FOUND))
    (restriction-data (unwrap! (map-get? water-restrictions { restriction-id: restriction-id }) ERR-RESTRICTION-NOT-FOUND))
  )
    (asserts! (not (get penalty-paid violation-data)) ERR-INVALID-STATUS)

    (map-set violation-records
      { user-id: tx-sender, restriction-id: restriction-id }
      (merge violation-data {
        penalty-paid: true,
        resolved-block: (some block-height)
      })
    )
    (ok (get penalty-amount restriction-data))
  )
)

;; Update emergency water supplies
(define-public (update-emergency-supplies (zone-id uint) (water-trucks uint) (distribution-points uint) (daily-capacity uint) (current-stock uint))
  (let ((zone-data (unwrap! (map-get? drought-zones { zone-id: zone-id }) ERR-ZONE-NOT-FOUND)))
    (asserts! (is-eq tx-sender CONTRACT-OWNER) ERR-NOT-AUTHORIZED)

    (map-set emergency-supplies
      { zone-id: zone-id }
      {
        water-trucks: water-trucks,
        distribution-points: distribution-points,
        daily-capacity: daily-capacity,
        current-stock: current-stock,
        last-updated: block-height
      }
    )
    (ok true)
  )
)

;; Record conservation achievement for incentive
(define-public (record-conservation (user-id principal) (period uint) (baseline-usage uint) (actual-usage uint))
  (begin
    (asserts! (is-eq tx-sender CONTRACT-OWNER) ERR-NOT-AUTHORIZED)
    (asserts! (< actual-usage baseline-usage) ERR-INVALID-STATUS)

    (let (
      (reduction-percentage (/ (* (- baseline-usage actual-usage) u100) baseline-usage))
      (reward-amount (calculate-conservation-reward reduction-percentage baseline-usage))
    )
      (map-set conservation-incentives
        { user-id: user-id, period: period }
        {
          baseline-usage: baseline-usage,
          actual-usage: actual-usage,
          reduction-percentage: reduction-percentage,
          reward-amount: reward-amount,
          claimed: false
        }
      )

      ;; Update total water saved
      (var-set total-water-saved (+ (var-get total-water-saved) (- baseline-usage actual-usage)))

      (ok reward-amount)
    )
  )
)

;; Claim conservation reward
(define-public (claim-conservation-reward (period uint))
  (let ((incentive-data (unwrap! (map-get? conservation-incentives { user-id: tx-sender, period: period }) ERR-RESTRICTION-NOT-FOUND)))
    (asserts! (not (get claimed incentive-data)) ERR-INVALID-STATUS)

    (map-set conservation-incentives
      { user-id: tx-sender, period: period }
      (merge incentive-data { claimed: true })
    )
    (ok (get reward-amount incentive-data))
  )
)

;; Private Functions

;; Activate conservation measures based on drought level
(define-private (activate-conservation-measures (zone-id uint) (drought-level uint))
  (let (
    (restrictions (get-restrictions-for-level drought-level))
    (target-reduction (get-target-reduction drought-level))
  )
    (map-set conservation-measures
      { zone-id: zone-id, drought-level: drought-level }
      {
        target-reduction: target-reduction,
        mandatory-restrictions: restrictions,
        voluntary-measures: "Reduce shower time, fix leaks, use drought-resistant plants",
        emergency-protocols: "Activate emergency water distribution if needed",
        public-messaging: "Water conservation is critical during drought conditions"
      }
    )
  )
)

;; Get restrictions list for drought level
(define-private (get-restrictions-for-level (drought-level uint))
  (if (is-eq drought-level DROUGHT-LEVEL-MILD)
      (list RESTRICTION-OUTDOOR-WATERING)
      (if (is-eq drought-level DROUGHT-LEVEL-MODERATE)
          (list RESTRICTION-OUTDOOR-WATERING RESTRICTION-CAR-WASHING)
          (if (is-eq drought-level DROUGHT-LEVEL-SEVERE)
              (list RESTRICTION-OUTDOOR-WATERING RESTRICTION-CAR-WASHING RESTRICTION-POOL-FILLING)
              (if (is-eq drought-level DROUGHT-LEVEL-EXTREME)
                  (list RESTRICTION-OUTDOOR-WATERING RESTRICTION-CAR-WASHING RESTRICTION-POOL-FILLING RESTRICTION-INDUSTRIAL-USE RESTRICTION-EMERGENCY-ONLY)
                  (list)
              )
          )
      )
  )
)

;; Get target reduction percentage for drought level
(define-private (get-target-reduction (drought-level uint))
  (if (is-eq drought-level DROUGHT-LEVEL-MILD)
      u10
      (if (is-eq drought-level DROUGHT-LEVEL-MODERATE)
          u20
          (if (is-eq drought-level DROUGHT-LEVEL-SEVERE)
              u35
              (if (is-eq drought-level DROUGHT-LEVEL-EXTREME)
                  u50
                  u0
              )
          )
      )
  )
)

;; Calculate conservation reward based on reduction achieved
(define-private (calculate-conservation-reward (reduction-percentage uint) (baseline-usage uint))
  (let ((base-reward (/ (* baseline-usage reduction-percentage) u1000)))
    (if (>= reduction-percentage u30)
        (* base-reward u3)
        (if (>= reduction-percentage u20)
            (* base-reward u2)
            base-reward
        )
    )
  )
)

;; Read-only Functions

;; Get drought zone information
(define-read-only (get-zone (zone-id uint))
  (map-get? drought-zones { zone-id: zone-id })
)

;; Get water restriction information
(define-read-only (get-restriction (restriction-id uint))
  (map-get? water-restrictions { restriction-id: restriction-id })
)

;; Get conservation measures for zone and level
(define-read-only (get-conservation-measures (zone-id uint) (drought-level uint))
  (map-get? conservation-measures { zone-id: zone-id, drought-level: drought-level })
)

;; Get violation record
(define-read-only (get-violation (user-id principal) (restriction-id uint))
  (map-get? violation-records { user-id: user-id, restriction-id: restriction-id })
)

;; Get emergency supplies for zone
(define-read-only (get-emergency-supplies (zone-id uint))
  (map-get? emergency-supplies { zone-id: zone-id })
)

;; Get conservation incentive
(define-read-only (get-conservation-incentive (user-id principal) (period uint))
  (map-get? conservation-incentives { user-id: user-id, period: period })
)

;; Get current drought status
(define-read-only (get-drought-status)
  {
    current-level: (var-get current-drought-level),
    total-zones: (var-get zone-counter),
    total-restrictions: (var-get restriction-counter),
    total-water-saved: (var-get total-water-saved)
  }
)
