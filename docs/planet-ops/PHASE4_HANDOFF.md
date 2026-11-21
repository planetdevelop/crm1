# Phase 4 handoff: what Phase 3 leaves for costs, disposal and Drive records

Planning only: nothing here is built. Phase 4's requirements are in
[../PLANET_OPS_IMPLEMENTATION_PLAN.md](../PLANET_OPS_IMPLEMENTATION_PLAN.md) §6. This lists what
Phase 3 already records that Phase 4 should consume, and the rules it must keep.

## The estimate baseline and versions

- `estimates.baseline_version_id`: the **original approved estimate** (first approved version). Null
  until one is approved. Never moves once set.
- `estimate_versions`: every version, with `status` (`draft`, `locked` = used for a customer document
  without approval, `approved`), `based_on_version_id`, `revision_reason`, and the stored totals
  (`base_cost`, `risk_reserve`, `subtotal`, `markup_amount`, `price_before_owner_pay`, `owner_pay`,
  `selling_price`). Approved and locked versions never change (database triggers).
- `estimate_lines`: per line, `section`, `count × hours × days × unit_cost`, `rate_snapshot` (the
  rate as taken), `risk_pct`, burden/fuel flags, and for disposal `est_tons`, `est_loose_cy`,
  `container_cy`, `expected_loads` kept apart. Costs are readable only through
  `estimate_version_costs` (*See estimating costs*).
- For the **original approved cost vs revised budget vs actual** comparison: original = the baseline
  version's `base_cost` (and lines); revised = the job's estimate version (below) or a later approved
  revision; **actual** = Phase 4's approved ledger. If an estimate was never approved (approval off),
  there is no baseline: compare against the job's estimate version and label it *not approved*.
  Don't treat a missing actual as $0.

## The job's link

- `jobs.estimate_version_id`: set only when a signed document is converted, to the estimate version
  its signed version carried (`quote_versions.estimate_version_id`); never changed afterwards. Jobs
  made directly (Create Job) or from documents without an estimate have none: don't guess one.
- `jobs.quote_version_id`: the exact signed document version (Phase 1e).

## The pending Drive record

- `estimate_summaries` (one per estimate): `title` (*Estimate {number} - {address} - {project type}
  - {year}*), `drive_destination` (`jobs_bid` until a job exists, then `job`), `job_id` (set when a
  job is made from it), `drive_status` (`not_backed_up` today; `backed_up` / `failed` reserved),
  `drive_file_id` (empty). The content is `public.estimate_summary(estimate_id)`.
- Phase 4 should: render the summary (internal, private; costs only for those allowed), back it up
  as a standalone file directly in **Jobs Bid** while `drive_destination = 'jobs_bid'`, and move the
  same file (same Drive file id) to the job's **Documents & Permits** once `job_id` is set. Record
  status and file id on this row; retry idempotently; never make a folder for an estimate or quote.
- Folders are made only by successful job creation (`job_folder_provisioning`, Phase 1e): Phase 3
  added no folder triggers (tested: estimates, documents and Won-without-a-job make none).

## Disposal estimates for the register

The estimate's disposal lines carry the estimated tons, loose CY, container capacity and loads apart
from what's billed, matching the register's rule that a container's capacity isn't measured debris.
Phase 4 can compare estimated tons/loads with weighed tickets per job; nothing is imported.

## Not to change

Signed documents, approved/locked estimate versions and their lines, the baseline link, and the
job's estimate link are immutable by design. Phase 4 adds records next to them.
