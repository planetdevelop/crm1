# Planet Ops: permissions review (Phase 0)

Phase 0 reviews how the plan's capability matrix ([plan](../PLANET_OPS_IMPLEMENTATION_PLAN.md) §2,
"Permissions") maps onto Crewtavo's existing, enforced access model. Phase 0 does not change access
rules. The gaps below are assigned to the phases that first need them.

## How access works today

Two layers, enforced in the API (`requireCompany(roles, area)`) **and** in Postgres RLS
(`private.level_permissions()`, `private.is_member`, `private.has_role`). The same rules cover the
interface, API, file downloads, exports and the AI assistant tools (`apps/api/src/lib/assistants.ts`
checks `memberPermissions`).

1. **Access level** (`public.member_role`, `packages/core/src/roles.ts` `ROLES`): owner, admin,
   office, estimator, crew_lead, field_crew, subcontractor. The level decides which records a person
   can reach.
2. **Areas** (`PERMISSIONS`): sales, invoices, job_costs, reports, marketing, automations, schedule,
   timesheets, settings, kb_edit, team, apps, equipment, subs, hiring. A **custom role**
   (`public.company_roles`, Settings → Roles) can only switch areas off within a level, never add
   ones the level doesn't allow (`memberPermissions`).

Access level, job title, pay rate and (later) workers' comp classification are already separate
fields (`memberships.role`, `custom_role_id`, `pay_rates`). The plan requires that.

## Plan roles mapped to existing levels and areas

| Plan role | Configure as (existing) | Areas on | Notes |
| --- | --- | --- | --- |
| Owner/admin | `owner` / `admin` | all | Unchanged |
| Estimator | `estimator` level | sales, schedule (optional), equipment | Reaches clients, requests, quotes and the schedule; no invoices or job costs. Today the `sales` area lets them both build **and** send customer pricing (gap 1) |
| Scheduler | `crew_lead` level + `schedule` area, as a custom role "Scheduler" | schedule, equipment | Assigns every crew, dates and equipment; crew_lead sees no prices. No payroll |
| Cost manager | `office` level, custom role "Cost manager" | job_costs, reports (invoices optional) | Sees job costs and profit. Today `job_costs` also reveals pay rates (gap 3) |
| Crew lead | `crew_lead` level | schedule off unless granted, timesheets, equipment | Runs their own crew and sees its time; no prices |
| Field employee | `field_crew` level | none | Own visits and time only; no prices |
| Subcontractor | `subcontractor` level | none | Own jobs and paperwork (not in the plan's matrix; unchanged) |

## Gaps (the plan requires a separate grant that doesn't exist yet)

| # | Plan capability | Today | Resolution | Phase |
| --- | --- | --- | --- | --- |
| 1 | **Approve/send customer pricing** separate from building estimates/quotes | One `sales` area covers building and sending | New area `send_pricing`; sending, approving a price or issuing a revision requires it; enforced in API and RLS | 1 |
| 2 | **View margin and internal costs** on *relevant* estimates, without job-cost access | `job_costs` is job-level only; estimates don't exist yet | New area `internal_costs` for the Estimating records; customer documents never expose internal lines | 1 (area), 3 (records) |
| 3 | **Pay/classification reports** as a separate payroll grant | `seesPayRates`: office + `job_costs` sees rates | New area `payroll`; `seesPayRates` moves to it; cost managers lose rates unless granted | 6 |
| 4 | **Approve/reclassify job costs** separately from viewing them | `job_costs` covers both | Approval is a separate action guarded by `job_costs` + reviewer designation in the review queue | 4 |
| 5 | **Run tailgates / assign checks**; field employees sign only their own | No tailgate records | Crew leads for assigned crews; each employee signs only their own acknowledgment (no proxy signing) | 5 |
| 6 | Assigning a task must not grant financial access | Holds today: visit assignment grants no area | Keep; covered by tests when tasks arrive | 5 |

The new areas follow the existing pattern: add them to `PERMISSIONS` and `LEVEL_PERMISSIONS`, then to
`private.level_permissions()` in a new migration. Existing custom roles keep their current reach
(a new area defaults on only where the level already had the equivalent power), and the parity tests
(`packages/core/test/roles.test.ts`, `supabase/tests/`) cover each one.

## Demonstrating permissions in staging (Phase 0 "done when")

Use fictional people with `+staging` email aliases (or the copy-link option if staging email isn't
set up). Create them in staging under **Settings → People → Invite**, and the custom roles under
**Settings → Roles**:

| Test account (fictional) | Level | Custom role / areas | Check |
| --- | --- | --- | --- |
| `owner+staging@…` | owner | all | Sees everything, Settings → Roles |
| `estimator+staging@…` | estimator | default | Can open Quotes; **cannot** open Invoices or job profit |
| `scheduler+staging@…` | crew_lead | "Scheduler": schedule, equipment | Schedules any crew; quote/job prices hidden |
| `costs+staging@…` | office | "Cost manager": job_costs, reports | Sees job costs/profit; no Settings → People |
| `lead+staging@…` | crew_lead | default | Own crew's schedule and time; no prices |
| `field+staging@…` | field_crew | — | My day shows only assigned visits; no prices, no other people's time |

Record what each account could and couldn't open in `docs/PLANET_OPS_PROGRESS.md`. Never reuse a
production person's account or email in staging.
