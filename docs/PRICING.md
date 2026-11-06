# SurGo pricing policy (presentation build)

All money is integer **centavos**. `Money.format` is the only renderer.

## Rides — implemented

```
platformFee  = min(30.00, max(5.00, distanceKm * 2.00))
customerTotal = providerFare + platformFee
```

- `providerFare` is the agreed fare. The provider receives **100%** of it.
- `platformFee` is a separate charge paid by the customer on top of the fare.
- The old 10% ride commission is retired. `FeeRates.bpsFor(ServiceType.ride)`
  throws rather than returning a stale rate.
- Rates live in `assets/db/config.json` under `platformFee` and are loaded into
  `RidePricing` at boot.
- Distance is a mock/demo value. `TripDistance.source` records whether it came
  from a seeded trip or a straight line between two mock places. No live GPS or
  routing result is claimed.

### Cash basis

The prototype collects cash. A ride's platform fee is recorded on
`PlatformLedger` as **earned** (`isRemitted: false`) at settlement. It only
counts as **collected** after `isRemitted` is set. The Platform Revenue screen
therefore shows remitted cash and outstanding fees separately.

## Pasuyo — unresolved

Pasuyo still uses the legacy percentage commission from
`config.json` → `commissionBps.pasuyo` (default 15%). The helper receives
`budget - commission`.

This policy has **not** been reviewed or replaced in this sprint. Open
questions: whether the fee should be a flat platform fee like rides, who pays
it (customer on top vs. deducted from the helper), and whether it varies by
errand distance or value.

## Rentals — unresolved

Rentals still use the legacy percentage commission from
`config.json` → `commissionBps.rental` (default 10%). The vehicle owner receives
`totalFare - commission`.

This policy has **not** been reviewed or replaced in this sprint. Open
questions: owner vs. platform responsibility for fuel/deposit/insurance,
per-day vs. per-booking fee, and how late returns or damage charges are split.

Neither Pasuyo nor rental pricing should be presented as final in the demo.
