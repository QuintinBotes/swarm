---
schema: swarm-spec
schema_version: "2.0"
spec_id: 2026-09-16_dst-night-count-off-by-one
kind: bugfix
status: Draft
owner: sam@example.com
area: billing
---

## Outcome

Bookings that span a daylight-saving transition are billed for the correct
number of nights. A booking from 28 March to 30 March in a timezone that shifts
on 29 March is billed as two nights, matching what the customer was quoted at
checkout.

## Scope Boundaries

- `billing/invoices/` — invoice rendering is correct already and is not touched
- `billing/tax/` — tax calculation consumes the night count and needs no change
- The broader migration off naive datetimes across the codebase — tracked
  separately; this spec fixes one function

## Constraints

- No behaviour change for bookings that do not cross a DST boundary
- Existing stored bookings must not be mutated by this change; correction of
  already-billed records is a separate, explicitly approved operation
- The fix must not change the public signature of `calculate_nights`

## Root Cause

**Symptom:** Bookings spanning a daylight-saving transition are billed one night
short. Reported by three customers in March 2026 and again in the October
transition.

**Reproduction:**
1. Set the account timezone to `Europe/London`.
2. Create a booking from `2026-03-28` to `2026-03-30`.
3. Open the invoice. It shows 1 night. It should show 2.

**Cause:** `billing/nights.py::calculate_nights` subtracts two naive
`datetime` objects and divides the resulting `timedelta` by 24 hours. On a
spring-forward day the real elapsed time is 23 hours, so integer division floors
to one fewer night. The function must compare calendar dates in the property's
local timezone rather than measuring elapsed time.

**References:** BILL-2241; error-tracker event `7f3a91`; original report in the
2026-03-30 support thread.

## Task Breakdown

- [ ] T1 Add failing regression tests for the spring-forward and fall-back transitions (files: tests/billing/test_nights_dst.py)
- [ ] T2 Rewrite the night calculation to compare localized calendar dates (files: billing/nights.py)
- [ ] T3 Add a read-only reconciliation report listing affected historical bookings (files: billing/reports/dst_reconciliation.py) (after: T2)

## Verification Criteria

- `[programmatic]` `pytest tests/billing/test_nights_dst.py` fails before T2 and passes after
- `[programmatic]` `pytest tests/billing` passes with no existing test modified
- `[programmatic]` When a booking spans a spring-forward transition, the system shall report the calendar-date difference — covered by `test_spring_forward_counts_two_nights`
- `[programmatic]` When a booking spans a fall-back transition, the system shall report the calendar-date difference — covered by `test_fall_back_counts_two_nights`
- `[programmatic]` `ruff check billing` reports no new findings
- `[human]` The reconciliation report's output is reviewed before any historical correction is proposed
