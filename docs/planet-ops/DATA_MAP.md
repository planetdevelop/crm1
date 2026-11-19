# Planet Ops: screen and data map, record links, migration outline (Phase 0)

Phase 0 deliverable from [the plan](../PLANET_OPS_IMPLEMENTATION_PLAN.md) §2. It maps the screens and
records Planet Ops reuses from Crewtavo and specifies the stable links later phases add. These
findings come from reading the code at upstream commit `bd6eae6`. The fork's `main` and
`planet-ops-staging` were both at that commit when Phase 0 started.

**Phase 0 adds no database migration.** Every schema change below is an outline for the phase that
first needs it, so staging and production databases are untouched until then.

## 1. Screens: what exists and what each phase adds

| Area (nav) | Existing Crewtavo screen and code | Planet Ops use | Phase |
| --- | --- | --- | --- |
| Requests | `apps/web/src/features/requests/` (RequestsPage, RequestPage, NewRequestDialog); `public.requests` (status `new → assessment_scheduled → assessment_complete → quoted → converted / archived`) | Intake; incomplete customer/property allowed | 2 |
| Pipeline | `apps/web/src/features/pipeline/PipelinePage.tsx`; `quotes.pipeline_stage`; API `routes/sales.ts` | Configurable stages, owner, next action, due date | 2 |
| **Estimating** *(new tab)* | None. Reuse `packages/core/src/estimates.ts`, `formulas.ts`, `money.ts` arithmetic only | Internal calculator, **New Estimate**, saved versions, **Create Quote / Proposal** | 0 spec, 3 build |
| **Quotes & Proposals** | `apps/web/src/features/quotes/` (QuotesPage, QuotePage, LineItems, QuoteSections, QuoteOptions, PaymentSchedule, SendDialog); documents `features/documents/build.ts`, `packages/core/src/documents.ts`, `contracts.ts`; PDF `apps/api/src/pdf/DocumentPdf.tsx`, `routes/documentPdf.ts` | Customer document: line-item quote or proposal layout, contract and payment terms, signatures | 1 |
| Client hub (portal) | `apps/web/src/features/hub/HubPage.tsx`; API `routes/public.ts` (`/hub/:token/...`, including `request-changes` and approval) | Customer view, **Request changes**, signing | 1 |
| Jobs | `apps/web/src/features/jobs/` (JobPage, ChangeOrders, ExpensesCard, ReceiptDrafts, jobCosts) | Create Job, Convert Quote / Proposal to Job, change orders, costs | 1, 4 |
| Change orders | `features/jobs/ChangeOrders.tsx`: a change order is a `quotes` row with `change_order_for = job.id` (migration `20261017002500`) | Mandatory customer signature before finalizing | 1 |
| Expenses / receipts | `public.expenses` (category free text), `public.expense_drafts`, `apps/api/src/services/receipts.ts`, `packages/core/src/receipts.ts` (`EXPENSE_CATEGORIES`) | Cost ledger, review queue, disposal | 4 |
| Files / Drive | `apps/web/src/features/drive/`, `public.drive_folders`, `public.attachments`, `plan_files`. This is the app's own file storage, **not Google Drive** | App storage stays the source of truth; Google Drive mirror is a new adapter | 4 |
| Schedule / field | `features/schedule/`, `features/field/` (My day, FieldVisitPage, SignaturePad, visitChecklists), `public.visits`, `visit_assignees`, `visit_equipment`, `checklist_templates`, `checklist_responses` | Crew assignment, tailgates, machine checks | 5 |
| Equipment | `features/equipment/`, `public.equipment`, `equipment_logs`, `equipment_plans`, booking migration `20261017002400` | Operator responsibility, daily checks, out-of-service | 5 |
| Timesheets / pay | `features/timesheets/`, `public.time_entries`, `time_entry_changes`, `pay_periods`, `pay_rates`, `packages/core/src/pay.ts` | Classified time segments, reports (no Gusto) | 6 |
| AI assistants | `apps/api/src/mcp.ts`, `apps/api/src/assistant-tools/`, `lib/assistants.ts` | Demolition estimating/benchmark tools under the same permissions | 8 |
| Settings → Roles / People | `features/settings/RolesSettings.tsx`, `TeamSettings.tsx`, `packages/core/src/roles.ts`, `public.company_roles`, `memberships` | Capability grants (see [PERMISSIONS.md](PERMISSIONS.md)) | 0 review, 1+ |

Navigation: Planet Ops adds **Estimating** and renames the customer-document area to **Quotes &
Proposals**. The two stay separate screens with separate records. Phase 1 adds the nav entry for
Quotes & Proposals (relabeling the existing Quotes screen). Phase 3 adds Estimating.

## 2. Shared records and stable links

Everything links **by ID**, never by matching names. All new tables follow the repository pattern:
`company_id` tenant scope with composite `(company_id, id)` foreign keys, `created_at`/`updated_at`,
RLS through `private.*` helpers, and an audit/activity row for consequential edits.

```text
client ──< property
  │           │
  └──< request (may start with incomplete client/property) ──────────────┐
          │                                                             │
          ├──< estimate (internal; Phase 3) ──< estimate_version ──┐    │
          │                                                        │    │
          └──< quote (customer document; existing) ──< quote_revision (Phase 1)
                    │   └─ source_estimate_version_id ─────────────┘
                    │   └─ signed snapshot (exact revision, signer, evidence)
                    └─ converted to ─> job (requires resolved client + property/address)
                                         ├──< change order (= quote with change_order_for)
                                         ├──< visits / crews / equipment bookings
                                         ├──< expenses (cost_code) ── source file (attachments)
                                         └── drive provisioning record (Phase 4, unique per job)
estimate ── estimate_summary (unique per estimate; Phase 3/4) ── Drive file mapping
```

| Link | Where it lives today | Phase 0 decision |
| --- | --- | --- |
| request → client, property | `requests.client_id`, `property_id` | Reuse. Job creation must require a resolved client and property (check exists in Phase 1 conversion) |
| quote → request | `quotes.request_id` | Reuse |
| quote → estimate version | none | Phase 1 adds nullable `quotes.source_estimate_version_id`, with the FK enforced once Phase 3 creates the table |
| quote → job | conversion (`quotes.converted_at`, `job_line_items.source_quote_id`) | Reuse. Phase 1 stores the exact signed revision on the job |
| change order → job | `quotes.change_order_for` | Reuse; Phase 1 adds finalization state and signature requirement |
| expense → job, file | `expenses.job_id`, `receipt_path` | Reuse; Phase 4 adds `cost_code` and an allocation table for split/multi-job |
| estimate → summary document | none | Phase 3/4: unique `(company_id, estimate_id)` |
| job → Drive folder set | none | Phase 4: unique `(company_id, job_id)` provisioning record |

### Common cost codes

Defined in code now, in `packages/core/src/costCodes.ts`: labor, equipment_rental, equipment_owned,
equipment_upkeep, fuel, hauling, disposal, materials_fill, tools_supplies_ppe, permits_testing,
subcontractors, travel_per_diem, other. Each existing expense category maps to one code; unknown
text maps to `other`, never to a guess. Display groups follow the estimating sheet. Nothing stores a
code until Phase 3/4 adds the column.

### Money fields that must stay distinct

calculated bid (estimate) · sent price (quote revision as sent) · signed/sold price (signed
snapshot) · original estimated cost (frozen estimate baseline) · approved revised budget (baseline +
finalized change orders) · actual cost (approved expenses) · invoices · payments.

## 3. Migration outline (later phases)

New, versioned files under `supabase/migrations/`. A released migration is never edited. Each
migration must work against existing rows and keep the previous app version working while it runs
(`npm run test:upgrade`, `scripts/migrate.mjs`).

| Phase | Migration (proposed name) | Contents |
| --- | --- | --- |
| 1 | `planet_ops_quote_presentation` | `quotes.presentation` (`line_items` / `proposal`), structured narrative sections (overview, scope in work order, inclusions, exclusions, assumptions, alternates); `quotes.source_estimate_version_id` (nullable) |
| 1 | `planet_ops_quote_revisions` | `quote_revisions` (immutable snapshot per sent version: sections, lines, totals, contract and payment terms, state); `superseded` state; signing pinned to a revision |
| 1 | `planet_ops_change_requests` | `quote_change_requests` (note as entered, customer identity, timestamp, revision reviewed, staff response, follow-up task link); replaces the untyped `messages` note the current `request-changes` endpoint writes |
| 1 | `planet_ops_signatures` | Signature evidence per revision (signer, timestamp, IP/user agent, method), separate states: customer accepted, company countersigned, deposit received, ready to schedule |
| 1 | `planet_ops_change_order_finalization` | Change-order states (draft, sent, changes_requested, declined, cancelled, finalized). A trigger refuses `finalized` without a customer signature on the current revision, so no API path or staff toggle can bypass it. Idempotent financial effect (applied once, keyed by revision) |
| 1 | `planet_ops_capabilities` | New permission areas `send_pricing` and `internal_costs` (see PERMISSIONS.md), added to `private.level_permissions()` |
| 2 | `planet_ops_pipeline` | Configurable stages per company, request owner, next action/date, outcomes (nurture, lost, unqualified) |
| 3 | `planet_ops_estimates` | `estimates`, `estimate_versions`, `estimate_lines` (cost_code, unit, quantity, rate snapshot), rate tables with effective dates, assumption log; `estimate_summaries` unique per estimate |
| 4 | `planet_ops_costs_disposal_drive` | `expenses.cost_code`, `expense_allocations`, `disposal_loads`, file checksums, `drive_file_mappings`, `drive_sync_jobs`, `job_drive_provisioning` (unique per job) |
| 5 | `planet_ops_field` | Tailgate templates, meetings, attendees and acknowledgments; machine operator assignments; checklist versions and responses per shift; out-of-service records |
| 6 | `planet_ops_time_classification` | Work classifications with effective dates, classification per time segment, correction audit |
| 7 | `planet_ops_integration_events` | External event IDs, delivery attempts, unmatched inbox |
| 8 | `planet_ops_benchmarks` | Closeout records, benchmark facts with basis and confidence |

Before any production migration: confirm the nightly database backup (Settings → Your data) and a
Railway volume backup exist, and test restore on staging (`scripts/restore.mjs`).
