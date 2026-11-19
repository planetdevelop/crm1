# Planet Ops — implementation plan and Claude handoff
## Consolidated specification · Ready for Phase 0

**Consolidated November 18, 2026. Includes the requirements and changes reviewed with the owner. The GitHub fork and Railway app already exist. Start with Phase 0 on a development branch and validate each phase in isolated staging. Production rollout and historical import follow Phase 9.**

This is the repository copy of the Planet Ops functional specification. Private source links, client records and owner-only setup prompts are kept out of this public repository. It does not claim that planned features are already built; see [PLANET_OPS_PROGRESS.md](PLANET_OPS_PROGRESS.md) for status.

### The goal

Turn the existing Crewtavo installation into Planet Ops: a demolition operating system that connects lead intake, estimating, signed customer agreements, job execution, costs, and completed-job knowledge. Build on the existing app rather than replacing its authentication, scheduling, quoting, and billing systems.

The first business feature to deliver is **line-item quotes and proposal-style agreements, with contract terms, payment terms, signatures, and change orders**. Establish the small amount of shared data structure and permissions those features need first.

**Employee login already exists.** Crewtavo supports individual accounts, employee roles, assigned visits, mobile field work, and time tracking. Extend that experience with assigned tasks, tailgate meetings, machine responsibilities, and daily sign-offs.

### Confirmed workflow: Estimating and Quotes & Proposals are separate tabs

**Estimating** is the internal calculator. **Quotes & Proposals** contains the customer-facing documents. They are separate screens and linked records, not two names for the same editor.

| Tab | Purpose | Primary action |
| --- | --- | --- |
| **Estimating** | Calculate labor, equipment, disposal, materials, other costs, contingency, markup/margin, and a suggested selling price. Keep assumptions, costs, and profit internal. | **New Estimate** |
| **Quotes & Proposals** | Prepare the customer scope, selling price, separate contract and payment terms, and signatures. Choose a line-item quote or narrative proposal here. | **New Quote / Proposal** |

From a saved internal estimate, **Create Quote / Proposal** copies the selected version's proposed selling price and customer-appropriate scope into a new customer-document draft, linked to that estimate version. Review the draft in the separate Quotes & Proposals tab before sending. The transfer never sends automatically or exposes internal cost calculations. Customer drafts can also be started directly in Quotes & Proposals.

The internal calculation and customer document have independent versions. Negotiating a quoted price does not rewrite the original estimated cost. Later calculator changes do not silently change a sent or signed document; an authorized user may explicitly refresh an unsigned draft and review the differences. Preserve sent versions and lock signed versions.

Specify both tabs and their link in Phase 0, deliver the customer-document workflow in Phase 1, and build the full Estimating calculator in Phase 3.

### Review decisions — confirmed requirements and proposed defaults

| Decision | Requirement or proposed starting point |
| --- | --- |
| Estimating versus customer documents | **Confirmed:** separate Estimating and Quotes & Proposals tabs. Estimating is an internal calculator; a quote or proposal is the customer-facing document. |
| Quote versus proposal | Two customer-facing layouts within Quotes & Proposals, using the same document pricing and agreement records. A proposal emphasizes narrative scope and a total; a quote displays priced line items. |
| Signatures | Both layouts include customer acceptance and a company-signature field. Whether a company countersignature is required is configurable. Keep contract terms and payment terms separate and visible before signing. |
| Customer change requests | **Confirmed:** both quotes and proposals have a **Request changes** action with a note field. Keep the request, original document, and resulting revisions in the activity history. |
| Change-order finalization | **Confirmed:** a change order cannot be finalized without the customer's signature on its exact final version, including zero-dollar changes and credits. A note, verbal approval, or staff status change cannot replace that signature. |
| Sales pipeline | Configurable stages, with an owner, next action, due date, and activity history on every active request. |
| Employee authority | Give estimating, cost approval, scheduling, payroll, and customer sending separate permissions. Assigning a task does not automatically grant financial access. |
| Receipt automation | Automatically read and suggest the job/category, file the original, and prepare the cost. A designated employee verifies amounts/allocations before they count as approved actuals. |
| Machine accountability | A crew can be assigned to a machine, but each shift has a named person responsible for inspection and greasing. Critical defects mark the machine unavailable until resolved. |
| Google Drive | The app is the working system. Drive holds the permanent PDOS copies, job exports, and source evidence. First release uses one-way app-to-Drive backup, without silently importing edits made in Drive. |
| Job-folder timing | **Confirmed:** create the job folders automatically in **Jobs Awarded** only after **Create Job** or **Convert Quote / Proposal to Job** successfully creates the job. No job-folder creation at lead, estimate, or quote/proposal stage. |
| Estimate pricing history | **Confirmed:** keep one internal summary document per estimate with all project details and pricing, even when the bid is lost or the customer does not respond. Before job creation, store it directly in existing **Jobs Bid**, without creating a project folder. |
| Estimating formulas | Preserve the sheet's intended calculation sequence, then correct identified inconsistencies through an explicitly reviewed mapping. Rates and owner-pay settings are configurable, not hardcoded. |
| Customer follow-up | Internal reminders and message drafts first. Automatic customer sequences are configurable and disabled until their messages, timing, and stop rules are approved. |
| AI | Use the existing assistant connection and add demolition-specific tools. AI produces sourced suggestions and draft estimates; a person approves the price and customer document. |
| History and payroll integrations | Historical-job import happens after the app passes acceptance. Gusto integration is a later project. |

## 1. Build order

| Phase | Deliverable | Why it belongs here |
| --- | --- | --- |
| 0 | Fork/staging baseline, shared records, permissions, Planet Ops name | Prevent rework and protect the existing deployment. Keep this foundation small. |
| 1 | Quotes, proposals, contract/payment sections, signatures, change orders | Your highest-priority workflow. |
| 2 | Real request pipeline and follow-up system | Every inquiry gets tracked through a clear next action. |
| 3 | Demolition estimating workspace based on your sheet | Creates the original budget that actual costs will be measured against. |
| 4 | Receipts, disposal, actual costs, and Google Drive backup | Captures reliable evidence in the app and PDOS. |
| 5 | Crew assignments, scheduling permissions, tailgates, daily machine checks | Connects field execution to the job and its costs. |
| 6 | Time classifications, payroll reporting, and loaded labor | Makes employee time useful for workers' comp reporting and job costing. |
| 7 | OpenPhone, WhatConverts, and Zapier | Connects intake and communications to the established pipeline. |
| 8 | Closeout, benchmarks, and ChatGPT estimating tools | Turns structured job evidence into future estimating knowledge. |
| 9 | Training, acceptance, then historical import and launch | Load your prior jobs only into a finished and verified workflow. |

All phases are part of the requested scope. The order is a dependency order, not an instruction to leave later phases unfinished. Work can be reviewed in staging after each phase. Importing prior jobs is deliberately last.

## 2. Phase 0 — start with the existing app

### First Claude task: Phase 0

1. Verify the user's existing fork, the commit actually deployed on Railway, and the production database/storage connections. The reviewed upstream commit is `bd6eae6c0143e08631f3978d500ecc20ad6a5c7c`; the fork and deployed image may differ. Check whether the app service currently runs an upstream Docker image or builds from the user's repository; a fork does not automatically change Railway's source.
2. Read repository instructions and inspect existing quote, signing, change-order, role, job-cost, checklist, equipment, and assistant code before adding replacements.
3. Work on a development branch based on `planet-ops-staging`, and prepare a separate Railway `staging` deployment/database/storage. Reuse them if already configured correctly. Use fictional test records, clearly marked and excluded from real reporting, plus a separate test Drive destination and test-only outbound settings. Verify isolation before starting the app because its startup can apply database migrations. Confirm backup/restore coverage before any production migration.
4. Run the existing baseline checks and record existing failures separately from new failures.
5. Produce a short screen/data map, the migration outline, and mockups for the separate **Estimating** calculator and **Quotes & Proposals** tab, including the **Create Quote / Proposal** handoff. Show the customer **Request changes** note flow and the required customer-signature step for change orders. Complete and verify the Phase 0 foundation, then implement Phase 1 in small, reviewable changes using the continuation prompt in section 16.

### Shared records

Reuse existing clients, properties, requests, quotes, jobs, visits, employees, equipment, invoices, payments, and file records. Add fields or linked tables where necessary.

Keep stable links among the customer, property, request, internal estimate, customer agreement, job, change order, cost, and source file. Internal estimates and customer documents have distinct IDs and version histories, with an explicit link to the estimate version used for a document. A request can begin with incomplete intake information; require a resolved customer/property/address before creating the production job. Record links by ID rather than matching names.

Define common cost codes early: labor/burden, equipment rental, owned equipment, equipment upkeep, fuel, hauling, disposal, materials/fill, tools/supplies/PPE, permits/testing, subcontractors, travel/per diem, and other. Display groupings can match the sheet without forcing every cost into a generic “materials” bucket.

### Permissions

Use existing custom roles and database access rules. Apply the same restrictions in the interface, API, file downloads, exports, and AI tools.

| Capability | Owner/admin | Estimator | Scheduler | Cost manager | Crew lead | Field employee |
| --- | --- | --- | --- | --- | --- | --- |
| Assigned jobs/tasks | All | Assigned/relevant | All needed for schedule | Relevant | Assigned crew | Own assignments |
| Build estimates | Yes | Yes | Optional | Optional | Optional | No by default |
| View margin and internal costs | Yes | Relevant estimates | No by default | Yes | Optional | No by default |
| Approve/send customer pricing | Yes | Separately granted | No | No | No by default | No |
| Assign crews/equipment and dates | Yes | Optional | Yes | Optional | Own crew if granted | No |
| Upload receipts/tickets/photos | Yes | Yes | Yes | Yes | Yes | Assigned work |
| Approve/reclassify job costs | Yes | Optional | No by default | Yes | Optional | No |
| Run tailgates/assign checks | Yes | No by default | Assign only if granted | No by default | Assigned crew | Own sign-offs |
| View pay/classification reports | Yes | No by default | No by default | Separate payroll grant | Limited time review | Own time only |

A person may hold several capabilities. An employee's access role, job title, pay rate, and workers' comp classification are separate concepts.

### Branding

Use **Planet Ops** in the app title, navigation, login, installed-app name, customer portal, generated documents, and notification branding. Use the Planet Ops artwork developed during the branding review: the full-color shield/crest related to the main Planet Demolition logo, with **Planet Ops on one line** and the orbital planet symbol as the **O** in Ops. Brand blue is **#1C50E4** and green is **#17801B**. The later full-color crest direction supersedes the earlier black-text-only wordmark variation. Use the supplied approved artwork rather than redrawing the crest or substituting another font; derive small app/icon treatments from it with readable sizing. If the selected image file has not been supplied to Claude, record that asset as pending and continue unrelated foundation work.

Keep customer documents under the appropriate Planet Demolition business identity. Preserve upstream license/copyright notices and mark the modified version appropriately. Avoid a blind repository-wide rename that breaks package names, service references, or integrations.

**Done when:** staging runs, permissions are demonstrable with separate test accounts, shared links are specified, and the app displays Planet Ops.

## 3. Phase 1 — quotes, proposals, and change orders

### New customer-document flow

Open **Quotes & Proposals → New Quote / Proposal**. This is the customer-document workflow; **Estimating → New Estimate** opens the separate internal calculator. The document choice is:

- **Line-item quote:** service descriptions, quantities/units when appropriate, unit prices, and line totals.
- **Proposal:** project overview, narrative scope in work order, inclusions/exclusions, assumptions, optional alternates, and a clear total or approved phase totals.

Both formats include distinct **Contract Terms**, **Payment Terms**, and **Signatures/Acceptance** sections. The client must see the same material terms in the web view and PDF. Reusable templates can fill these sections, with job-specific edits before sending.

Keep the internal estimate separate from the customer presentation. Internal wages, cost assumptions, markup, contingency, and owner-pay calculations do not appear merely because the customer selected a line-item layout.

### How to implement it

- Extend existing quote records with a presentation type and structured narrative sections. Reuse existing items, payment schedules, document rendering, contract-term templates, client portal, and signature service.
- Use one authoritative customer-document total for both presentation layouts; switching layouts must not create competing totals. Keep the internal estimate's cost/pricing calculation separate and link its saved version when used as the document's starting point.
- Switching an unsigned draft between layouts preserves prices, scope, contract text, and payment terms. Show a preview before sending.
- Store document revisions. Signing captures the exact document version, sections, amounts, selected options, signer identity, acceptance timestamp, and signature evidence.
- Lock the signed snapshot. Later changes create a new version or change order; they never silently alter the agreement already signed.
- Separate “customer accepted,” “company countersigned if required,” “deposit received,” and “ready to schedule.” One state must not imply the others.
- Preserve pending, sent, viewed, changes requested, accepted, declined, expired, and superseded document states with an activity trail. A change request is neither acceptance nor rejection.

### Customer requests for changes

Both customer-facing formats offer **Request changes** alongside the signing action. Clicking it opens a required note field labeled **What would you like changed?** and a **Send request** button. Show confirmation after the request is saved.

- Save the note exactly as entered, customer identity, timestamp, document ID, and version they reviewed. Keep repeated requests and staff responses in the history.
- Mark the pending document **Changes requested**, notify the assigned estimator/document owner in the app, and create a visible follow-up task. Display the note next to the document for review.
- Customer notes do not edit prices, scope, contract terms, or payment terms themselves. Staff review the request, prepare a new draft revision, preview it, and deliberately send it for review/signature. The old sent version remains accessible in history and is superseded when the revised version is issued.
- After **Changes requested**, pause signing of that pending version until the request is resolved and the correct version is explicitly made available for acceptance. Superseded versions cannot be signed.
- Once an agreement is signed, preserve it. A later customer request is logged against the signed agreement and, for an active job, routed into a proposed change order. The note itself does not change the signed scope or price.

Contract wording and payment rules come from approved business templates. Do not have the coding assistant invent legal terms or deposit limits.

### Creating a job from a customer document

Provide **Convert Quote / Proposal to Job** and a direct **Create Job** path. Link the new job to the selected request, estimate, and exact customer-document version where applicable. Both paths trigger the same folder-provisioning workflow after the job record is successfully created: a correctly named folder in **Jobs Awarded**, its standard subfolders, and the matching central Media folder. The Drive integration is delivered in Phase 4. A sent, viewed, signed, or won document/request alone does not create folders unless it actually completes job creation. Repeating conversion must open the existing linked job rather than create another job or folder set.

### Change orders for active jobs

Add **Create Change Order** to the job. Extend the existing change-order quote relationship instead of creating an unrelated second quoting system.

Capture the change reason, added/removed scope, supporting photos/documents, price increase or credit, schedule impact, and any specific payment terms. Allow either line-item or proposal presentation. Both include the customer **Request changes** note flow and require a customer signature before finalization.

**Required finalization rule:** a change order remains pending until the customer signs its exact current version and any configured company countersignature is complete. This applies to added charges, credits, and scope/schedule-only changes with no price change. Use explicit states such as draft, sent/awaiting signature, changes requested, declined, cancelled, and finalized. In this plan, an “approved change order” means one that has passed this signature requirement and is finalized.

Enforce the requirement in the API and database transition rules as well as the interface; a staff status toggle, API request, automation, customer note, or verbal approval cannot bypass it. Record signer identity, timestamp, signature evidence, and the signed document version. If scope, price, schedule, or terms change after signature, preserve that signed version and require a newly signed revision before finalizing the new version. An already finalized version stays in history; a replacement revision must adjust its financial effect rather than count both versions.

Show original contract, each change order and its status, total approved changes, revised contract total, invoiced amount, paid amount, and remaining amounts separately.

Financial rules:

- Revised contract value = original signed agreement + approved change orders, including credits.
- Draft, changes-requested, declined, cancelled, and unsigned changes do not affect the approved contract total, approved revised budget, or invoiceable scope.
- Only finalized, customer-signed changes update the revised budget and invoiceable scope, exactly once. Retried signature events must not apply the same change twice.
- Approval alone does not create a payment or an accounts-receivable balance; those follow the invoice/payment workflow.
- If work was performed before approval, flag it explicitly rather than treating it as signed.
- Cancellation/reversal of an approved change is an auditable action, not deletion of its history.

**Done when:** Quotes & Proposals is distinct from the internal Estimating calculator; a customer draft can use either format with matching totals; terms and signatures persist in PDF and portal; customers can submit change notes on both formats and staff can issue a traceable revision; signed agreements cannot mutate. Verify that unsigned change orders cannot be finalized through the interface or API and have no approved financial effect. Customer-signed positive and credit change orders update the job/invoiceable balance exactly once; zero-dollar changes also require a signature. Verify the calculator-to-document handoff when the Phase 3 calculator is delivered.

## 4. Phase 2 — a real sales pipeline

### Proposed stages

New inquiry → Contacting → Site visit scheduled → Site visit complete → Estimating → Quote/proposal sent → Follow-up → Won.

Provide separate **Nurture/on hold**, **Lost**, and **Unqualified/spam** outcomes. Stage labels/order are editable. “Viewed” and “overdue” can be badges rather than extra pipeline stages.

Sales status remains separate from production status: won, permitting/pre-start, scheduled, in progress, and completed are different events. An existing client can have several requests or properties.

### Every request should show

Customer and property, contact methods, source/campaign, requested service, request owner, assigned estimator, stage, last contact, next action, next-action date, estimate link, communication history, and outcome/lost reason.

Keep the estimate-summary document and linked quote/proposal pricing history available for every outcome, including lost and awaiting response. Record the last contact and follow-up date; silence is not automatically a lost bid. Allow pricing-history filters by service, location, date, estimator, and outcome. Lost/no-response bid prices remain sales evidence, not completed-job actual costs or production benchmarks.

Provide board and list views plus filters for “needs first response,” “follow-up due,” “overdue,” “waiting on customer,” “no next action,” and assigned employee.

### Lead nurturing

- Create stage-based follow-up tasks and reusable call/text/email templates.
- Make follow-up cadence configurable; a suggested starter is first response, post-site-visit check-in, post-proposal follow-up, and later nurture.
- Record calls/messages against the request and client without duplicating the lead.
- Pause outbound sequences when the customer replies, the job is won/lost, the contact opts out, or a staff member pauses it.
- Start with internal reminders and drafts. Enable automatic sending only after the business configures the channel, approved text, recipients, and timing.
- Report request counts, aging, conversion, response time, source, and won/lost value using defined dates.

**Done when:** every active request has an owner and visible next action; moving stages preserves history; one client can have two independent opportunities; accepting a quote links the correct request/job without generating duplicates.

## 5. Phase 3 — the Estimating tab: internal calculator and database

Build a dedicated **Estimating** tab with saved internal estimates, a **New Estimate** action, and the guided calculator below. Its costs, assumptions, rates, and profit calculations are internal. Customer layout, sending, change-request review, and signing belong in **Quotes & Proposals**.

### Use your actual Google Sheets as the blueprint

Read and map the current **Bid_Template_2026** workbook, especially:

- `Bid Template`: rate settings; labor; travel/per diem; heavy equipment; hauling/disposal; materials/other; risk reserve; markup; owner pay; final bid; closeout comparison.
- the sample job `Expenses` tab: receipt total, allocated job cost, excluded amount, category, source, and notes.
- the sample job `Loads` tab: load identity, material, facility, truck/driver, weight, container capacity, cost, expense link, and running totals.

Also use the **Master Completed-Job Bid Intelligence** workbook's four sections: Completed Job History, Benchmarks & Lessons, Future Bid Checklist, and SF & CY Benchmarks.

This is a schema/formula reference exercise. **Do not import historical job records during this phase or edit the original sheets.**

### Resolve sheet inconsistencies before porting calculations

The inspected base tab contains per-line price/SF formulas referring to `I3`, while the area input is associated with `I4`. Its travel-rate formatting, truck-fuel note, and some summary labels also need reconciliation. The base tab's owner percentage is not proof that every job should use that setting.

Create a field/formula mapping that records source cells, meaning, units, expected calculation, rounding, and any proposed correction. Compare a handful of representative sheet calculations with app calculations. Preserve original source values as evidence and explain intended differences instead of silently reproducing defects.

### Estimator-friendly workflow

1. Select the request, property, service type, and assigned estimator.
2. Enter site survey information: structure areas, dimensions, materials/layers, foundation, contents, access, utilities, hazards, and included/excluded work.
3. Build labor: crew size, role, hours/day, days, overtime assumptions, and burden.
4. Choose rented/owned equipment, equipment class, duration/hours, attachments, transport, fuel, and internal cost rates.
5. Estimate disposal by material and facility: tons, loose debris volume or nominal container capacity, loads, hauling, and tipping fees. Keep fill deliveries separate.
6. Add permits/testing, subcontractors, materials/tools, travel/per diem, and contingency.
7. Review risk, pricing method, markup/target margin, and owner-pay treatment with clearly explained totals.
8. Save the internal estimate and obtain pricing approval if required. Use **Create Quote / Proposal** to choose the customer layout and open a linked, unsent draft in the separate **Quotes & Proposals** tab. Preview and send from that tab.

Add unit labels, explanations, saved templates, a missing-input checklist, and an assumption log. The person learning the system should be able to follow this sequence without understanding the database.

### One internal summary document for every estimate

On the first saved estimate, generate one readable **Estimate Summary** document in the app and queue its Drive copy directly in the existing **Jobs Bid** folder. Use a unique title such as **Estimate {Estimate ID} - {Project address} - {Project type} - {Year}**. This creates a document, not a job folder. The app estimate record remains the source of truth; the summary is its readable record, not another calculator or customer quote.

Include the full project and pricing detail:

- Estimate ID/version, date, estimator, customer, property/address, contact details, lead source, and links to the request and customer documents.
- Project type, measurements/areas, structures, materials, access, site conditions, scope, inclusions/exclusions, assumptions, and links to site photos, plans, notes, and supporting files.
- Itemized labor, equipment, hauling, disposal, materials, permits/testing, subcontractors, and other costs, with quantities, units, rate snapshots, duration, and calculation assumptions.
- Estimated base cost, contingency, markup or target margin, owner-pay treatment, calculated selling price, and projected profit. Distinguish internal calculated price from each price actually sent and the accepted price, if any; an unsent price must not be labeled a customer bid.
- A dated pricing/revision history, customer-requested changes, current outcome, last contact, next follow-up, and any known reason for losing the bid. Preserve unanswered bids without inventing a reason or competing price.

Update the same summary document when the estimate or linked pricing/outcome changes, preserving its stable link, estimate-version snapshots, and dated price history. Keep one current summary per estimate rather than creating a new standalone file on every save. Multiple revisions of one estimate stay together; genuinely separate estimates retain their own IDs and documents. Losing a bid, archiving a request, or receiving no reply must not delete its summary or price history.

Keep this document internal because it contains costs and profit. When a job is created, move its existing summary and appropriate supporting files into the new job's destinations while preserving file IDs and the original estimate/request links. Do not generate a duplicate summary. If no job is created, the standalone summary remains in Jobs Bid. This history can later support pricing comparisons, while completed-job cost benchmarks continue to require verified actuals.

### Data and calculation rules

- Store quantities, units, rates, rate versions/effective dates, categories, assumptions, and source links. Copy rates into each estimate version so a later rate change does not rewrite old estimates.
- Model labor, equipment, disposal, and other costs with appropriate units instead of blindly multiplying Count × Hours × Days for every line.
- Separate base cost, risk reserve, selling price, owner-pay allocation, and profit metrics. Label markup and margin correctly.
- Preserve the intended sheet order of risk allowance, markup, and owner-pay addition unless the owner changes it.
- If target-margin pricing is offered, make it an explicit alternative calculation; do not accidentally apply both markup and margin uplift.
- Record whether labor rates already include burden and whether equipment rates already include fuel/wear. Prevent a second charge for the same component.
- Store **calculated bid**, **sent price**, **signed/sold price**, **original estimated cost**, **approved revised budget**, **actual cost**, **invoices**, and **payments** separately.
- Freeze the approved original estimate as the baseline. Show later revisions alongside it.
- Link customer drafts to the exact internal estimate version used. Keep calculator edits, quoted-price negotiations, and customer document revisions separate; none silently overwrites another. Refreshing an unsigned draft is an explicit, permission-controlled action with a difference preview.
- Pricing floors and comparable-job adjustments are configurable, scope-specific rules with an explanation and source.

**Done when:** a new estimator can finish a sample calculation in Estimating, save it, and create either customer format as an unsent draft in Quotes & Proposals. Approved reference calculations reconcile; old estimates do not change when rates change; the original budget and customer price remain distinct; editing either record does not silently modify the other or expose private calculations to the customer. Each estimate has one internal summary with project details and dated pricing, including lost/no-response estimates; repeated saves update that summary and create no job folders. Verify Drive placement and moving the same summary into a job during Phase 4.

## 6. Phase 4 — costs, disposal, and permanent Drive records

### One upload workflow

An employee opens the job and uploads a photo, PDF, receipt, or ticket. Support a general upload inbox when the job is unknown.

Reuse the existing receipt-reading service. Extract vendor, date, document/ticket number, amount, taxes/fees, category, and suggested job. Route a dump ticket into the disposal workflow. Automatically organize the original, while marking the extracted financial data pending review.

Provide confidence/missing-field indicators, a clear correction screen, and a bulk review queue. A reviewer can approve, change category/job, split allocations, exclude a reference-only document, or reject a duplicate. Never discard the original.

### Cost ledger

Track date, vendor, category, description, receipt total, job-allocated amount, excluded/unallocated amount, status, source file, reviewer, and notes. Support credits/refunds and multi-job purchases.

Keep estimated, committed, provisional, approved actual, and paid statuses separate. A signed subcontract commitment is not automatically a paid actual expense. Display approved cost and provisional exposure separately.

Match duplicate files by checksum and likely duplicate transactions by vendor/date/amount/document number. Permit reviewed exceptions. A single source can be linked to several records without creating duplicate expenses.

### Disposal register

Track load date, hauler, facility, ticket/invoice number, material stream, truck/trailer, driver, gross/tare/net weight when available, short tons, container capacity, reported loose volume, quantity basis, hauling charge, tipping fees, related expense, and ticket/photo.

Show running totals for loads, weighed tons, disposal charges, hauling charges, nonmetal volume, and metal/recycling volume and credits.

Preserve distinctions already present in PDOS:

- A container's capacity is not measured debris volume.
- Delivered fill is not outgoing debris.
- Metal weight can be unknown even when its container volume is known.
- A mixed-scope job cannot automatically become a house-only benchmark.
- A disposal register links to the expense ledger; it does not add the same cost twice.
- Benchmark-only evidence can be kept without treating it as a job expense.

### Google Drive backup — follow the current folder standard

Use the current PDOS subfolder structure and address/project-type/year naming rule. **The owner's confirmed timing change in this plan overrides older instructions to create folders during lead intake or bidding:** new app-managed job folders start in **Jobs Awarded**, only upon successful job creation. Existing legacy folders remain intact; do not reorganize them during this feature build.

### Automatic folders only when the job exists

- Trigger the same workflow from a successful direct **Create Job** or **Convert Quote / Proposal to Job** operation, after the job record is committed. Opening a form, saving a lead or estimate, sending/revising a quote, customer signing without job conversion, or changing a pipeline stage must not provision job folders.
- Validate the project address and project type before job creation. Generate one normalized name using **{Project address} - {Project type} - {Year}** and store it on the job. Use the job's creation year and the same normalization consistently. If a different job has the same name, append its unique Job ID rather than merging unrelated jobs. Use stored IDs to recognize the same job on retries.
- Create the main folder under the configured **Jobs Awarded** folder, with **Documents & Permits**, **Reciepts**, and **Dump Tickets**. Create the matching **PDOS / Media / {exact job folder name}** at the same point, not during bidding. Keep media out of the individual job folder.
- Create/update the job's pre-job record and blank post-job closeout in its main folder, using the established templates. Save the folder, record, and Media links on the job and in the Master Job Index.
- Move the linked estimate summary, relevant customer documents, and pre-job uploads into their proper destinations, preserving file identities and history. Previously saved internal summaries remain private. The estimate/request history continues to link to them after the move.
- Store provisioning status and folder IDs against the stable job ID. Repeated clicks, conversion retries, concurrent events, and partial Drive failures must resume the same folder set, never create duplicates. Show pending/failed status and retry automatically; an outage must not lose the job or its files.

Before job creation, retain estimates and uploads in app storage and back up the standalone summary and supporting files directly under existing **Jobs Bid**, using estimate/request IDs in filenames. Create no per-request, per-estimate, per-job, or central job-media folders yet. When a job is completed, move its existing main folder to **Completed Jobs**, preserving IDs and links; its central Media folder stays where it is.

| Record | Permanent PDOS destination |
| --- | --- |
| Estimate summary and pre-job files before job creation | Standalone files directly in existing **Jobs Bid**; no new job folder |
| Newly created job folder | **Jobs Awarded / {Project address} - {Project type} - {Year}**; created only by successful job creation/conversion |
| Completed job folder | Move the same existing folder to **Completed Jobs**; preserve its identity |
| Internal estimate summary, proposals, quotes, signed agreements, change orders, permits, reports, approvals after job creation | Job folder / **Documents & Permits**; keep internal summaries private |
| Fuel, tools, materials, payroll cost evidence, rentals, subcontract bills and other receipts | Job folder / **Reciepts** — preserve the existing spelling and folder identity |
| Scale tickets, load documents and disposal evidence | Job folder / **Dump Tickets** |
| Job photos, videos, drone footage and voice/audio recordings | **Operating System (PDOS) / Media / {exact job folder name}** |
| Pre-job and closeout records | Main job folder |
| Job links and status | Existing PDOS Master Job Index |

In-app categories such as Fuel, Tools, and Materials provide automatic sorting. Initially use metadata, filters, and informative filenames under the established Drive folders; do not introduce a new category-folder tree without changing this plan.

A receipt image is a cost document, not general job media. Keep it in its document destination.

### How to make backup dependable

- Save the original to app storage first. Queue a Drive copy with a stable file ID, request/estimate mapping and job mapping when available, version, checksum, and status. Apply the pre-job standalone-file rule until a job exists; uploading a file must never bypass the folder-creation trigger.
- Use an asynchronous worker with retries and idempotency. A Drive outage must not lose the app upload or create duplicates after retry.
- Display “pending,” “backed up,” and “failed” states, last successful sync, and an admin retry/reconciliation screen.
- Preserve file IDs when standalone bid files move into a newly created job or when a job changes lifecycle location. Keep its central Media folder linked; avoid recreating it.
- Back up generated PDFs and evidence as well as uploads: signed agreements, change orders, meeting/checklist exports, estimates, costs, load registers, and closeout reports.
- Provide structured CSV/JSON exports and a manifest of record/file relationships. Separately configure recoverable database and storage backups; copying files alone is not a database backup.
- Do not propagate an app deletion into permanent Drive deletion by default. Archive and audit it.
- Keep Drive access private and aligned with app permissions; payroll and internal estimates must not appear in client shares.
- First release is a one-way operational mirror. Files manually added to Drive are brought into the app only through an explicit import/link workflow; two-way synchronization is a separate decision.

**Done when:** creating/saving an estimate produces one standalone summary in Jobs Bid and no new folders; lost/no-response pricing stays available. Direct job creation and quote/proposal conversion each create exactly one correctly named folder set in Jobs Awarded and the matching central Media folder. Retried/partially failed provisioning creates no duplicates, and bid documents move without losing links. One fuel receipt and one dump ticket appear in the correct app categories and PDOS folders; the ticket cost counts once; a duplicate is caught; a failed Drive copy retries successfully; a restore exercise can recover a sample job and its evidence.

## 7. Phase 5 — field employees, crews, scheduling, and sign-offs

### Employee home screen

Extend the existing mobile My Day experience with assigned jobs/visits, tasks, job instructions, today's tailgate, assigned machines/checks, upload receipt/ticket/photo, and the time clock.

Respect job access. Do not reveal company-wide pay, profit, or customer pricing to field employees unless specifically granted.

### Tailgate meetings

Create reusable meeting templates and a meeting instance assigned to a job, date/time, crew, and leader. Include topic, discussion, job-specific hazards, controls, attachments, and the actual attendees.

Each employee signs their own acknowledgment in the app. Record individual identity, timestamp, meeting/content version, and signature. Track absent/not-yet-signed people and allow a late attendee to acknowledge the same briefing or a supplemental one.

Freeze completed acknowledgments. Changes after signatures create an amended/new briefing and show who still needs to sign. Generate a downloadable record and back it up to Documents & Permits.

Reuse existing checklists and signature components where appropriate, but add the meeting/attendance records needed to distinguish “assigned,” “attended,” and “signed.” A manager cannot silently sign for an employee.

### Machines assigned to crews and operators

Extend existing equipment bookings and maintenance records with job/visit, crew, named responsible employee, date/shift, and handover details. A machine can have multiple authorized users, but responsibility for each required check must be explicit.

Create configurable checklist templates per asset or machine type, based on the business's equipment instructions. Support greasing, fluids, leaks/damage, attachments, guards, and other approved checks without inventing one universal procedure.

Each day's/shift's record includes yes/no/not-applicable responses, notes/photos, meter reading where relevant, operator signature, timestamp, and checklist version. No automatic carry-forward of yesterday's answers.

Critical failures mark the machine out of service and notify the responsible manager. Resolution records who released it and the repair/check evidence. Missing checks remain visible. A change of operator creates a handover requirement.

Checklist completion must not block an employee from recording paid working time. Machine-readiness status and payroll/time recording remain independent.

### Scheduling

Grant selected employees authority to assign dates, crews, individual tasks, and equipment without giving them payroll access. Warn about conflicting bookings and unavailable equipment. Rescheduling a visit should update associated meeting/check assignments deliberately, preserving completed history.

Use the existing mobile/offline approach where it fits. New uploads and signatures need explicit pending/synced states and safe retries; never show a sign-off as received by the office while it is only on a disconnected device.

**Done when:** a crew member sees only assigned work, personally signs a tailgate, completes a daily machine check, reports a defect, and sees a clear sync state; the supervisor sees missing sign-offs and can reassign/handover equipment.

## 8. Phase 6 — time, workers' comp classifications, and labor cost

Use the existing clock/timesheets as the base.

- Allow multiple eligible work classifications per employee, with a default, descriptive job titles, configured class codes, and effective dates.
- Record the **actual classification on each time segment**, alongside employee, job, task/activity, date, hours, and applicable rate version.
- Switching from demolition labor to equipment operation during the day creates another segment. It must not change the earlier segment retroactively.
- Give supervisors a review/correction workflow with a reason and audit trail. Preserve approved payroll periods.
- Report employee/job/classification totals and separate regular hours, overtime hours, other pay buckets, wages, and premiums as supported by validated payroll inputs.
- Keep approved payroll actuals, employer taxes, and workers' comp allocations linked to labor cost, replacing provisional labor estimates without double counting.

**Existing limitation to address:** Crewtavo's pay calculation presently uses straight-time dollar amounts with weekly-hours indicators; this is not a complete payroll calculation engine. Do not represent it as one.

For this phase, deliver reliable classified time records and approved/exportable reports. Use confirmed payroll data or a separately validated calculation configuration for actual wages/burden. Do not infer workers' comp classification rules, eligible wages, or overtime treatment from a label or a remembered percentage.

**Gusto is explicitly deferred.** Keep stable employee IDs, earning/classification fields, and export mappings so a future integration is possible. Do not build or activate Gusto API synchronization now.

**Done when:** one employee can split a day between two classifications, an authorized reviewer can correct it with an audit trail, reports reconcile by job/classification, and payroll actuals do not duplicate existing labor costs.

## 9. Phase 7 — communications and lead integrations

Build adapters against one shared request/client/activity model, with a queue, external IDs, retry history, and an integration status screen.

### WhatConverts and Zapier

- Receive new call/form/chat leads through an authenticated intake endpoint. Support WhatConverts direct webhooks or Zapier as the delivery route.
- Preserve WhatConverts lead ID, contact details, source/medium/campaign and available attribution, initial message, and event time.
- Match/create the client and request carefully. Repeated delivery of the same event must not create another request.
- Match contact identity separately from opportunity identity: the same person can legitimately request another job.
- If both a website form and WhatConverts report one submission, use available shared identifiers and a review queue rather than assuming every matching phone number is a duplicate job.
- Allow approved won/lost and value updates to flow back through the chosen route where supported. Define whether “value” means quoted, sold, or collected; never silently interchange them.
- Choose one authoritative intake route per event type. Do not enable two parallel routes without deduplication.

### OpenPhone

OpenPhone's current developer documentation is under Quo. Verify available events and account features during implementation.

Bring calls, messages, and available summaries/transcripts into a client/request communication timeline. Use phone normalization and external conversation/message/call IDs, with an unmatched-inbox review workflow when several requests might match.

Support staff-initiated replies through the existing number if the verified API/account permits it; otherwise provide a clear open-in-provider action. Verify attachment/MMS capabilities rather than promising they match SMS.

Missed calls can create callback tasks. Responses should pause the appropriate follow-up sequence. Store permitted communication evidence and files with the relevant job when linked, respecting access and retention settings.

Validate webhook authenticity using the provider's supported method, protect credentials on the server, handle retries/out-of-order events, and log failures without exposing secrets.

**Done when:** a test lead arrives once, gets an owner/next action, and an associated call/message appears on the right record; replayed events do not duplicate records; staff can see failed deliveries and recover them.

## 10. Phase 8 — closeout, benchmarks, and ChatGPT

### Estimated versus actual

Build a job comparison that shows original estimate, approved revised budget, recorded actuals, variance in dollars/percent, and explanation by cost category.

Compare physical quantities too: labor hours, equipment hours/class, days, loads, tons, debris volume, delivered fill, and fuel. Keep contract value, invoiced amount, collected amount, and accounting revenue distinct.

Reuse the current pre-job and post-job templates for readable exports. Require a closeout review covering missing costs/tickets, final scope, assumptions that changed, what went well, surprises, and how the next estimate should change.

A job can be operationally complete while financial closeout is still open. Only verified eligible facts should feed production benchmarks. Do not label a gross margin as net margin when overhead, owner pay, or other required costs remain unknown.

### Benchmark database

Store source job, work category, scope boundaries, structure/material details, area and its basis, equipment class, labor/machine hours, tons, volume and its basis, disposal facility/rate, costs, dates, lessons, confidence, and source evidence.

| Metric | Calculation / constraint |
| --- | --- |
| Tons per sq. ft. | Verified short tons ÷ relevant measured area |
| Pounds per sq. ft. | Short tons × 2,000 ÷ area |
| Yards per sq. ft. / per 100 sq. ft. | Relevant CY ÷ area; retain volume basis |
| Labor productivity | Labor hours ÷ area and/or area ÷ labor hours; distinguish labor-hours from elapsed crew-hours |
| Machine productivity | Quantity ÷ machine hours, grouped by equipment class and comparable scope |
| Disposal rate | Appropriate disposal charges ÷ matched weighed tons; show hauling separately |
| Cost and selling price per sq. ft. | Approved comparable costs/price ÷ the correct scope denominator |
| Estimate accuracy | Original/revised assumptions compared with verified actual quantities/costs |

Never fill missing evidence with zero. Separate measured, owner-reported, allocated, nominal-capacity, and planning values. Filter mixed scopes and outliers, show sample counts and source jobs, and keep equipment-class comparisons separate. Preserve category-specific pricing floors and scope cautions from the benchmark reference.

Incomplete historical jobs can contribute a verified quantity metric without being promoted to fully verified financial benchmarks.

### ChatGPT connection and AI estimating

Crewtavo already has an MCP assistant connector. Extend it with authorized tools for demolition estimates, disposal, actual costs, closeout, and benchmarks instead of granting direct database-admin access.

Suggested operations:

- Find comparable jobs with scope/equipment filters.
- Read original estimate, revised budget, costs, and source evidence.
- Explain benchmark calculations and data quality.
- Prepare a draft estimate and a list of missing inputs.
- Compare estimate versus actual and draft closeout lessons.
- Save an approved draft through the same validation and permission rules as the app.

Every AI estimate should show the comparable jobs, quantities, rates, assumptions, exclusions, confidence, and adjustments used. Deterministic application calculations produce totals. AI must not invent missing source costs or silently overwrite the signed agreement.

Distinguish the **ChatGPT connection used from ChatGPT** from **AI running inside the app**. Use the existing integration pattern for each and verify current official setup/account availability when connecting. Do not assume one subscription or connection configures both.

Build and test the tools using staging fixtures before historical import. Real comparable-job recommendations become useful after verified history is loaded. Use retrieval and calculated benchmarks first; model training is not required for the initial release.

**Done when:** an authorized estimator can ask for comparable jobs and receive traceable evidence, create a draft estimate with reproducible arithmetic, and review it before generating customer documents. A field-only user cannot obtain payroll or margin data through AI.

## 11. Phase 9 — training, final acceptance, historical import, launch

### Make it teachable throughout the build

Add short field descriptions and workflow help as each screen is built. At the end, deliver an estimator guide, office/cost-review guide, scheduler guide, and field-employee guide using the app's existing knowledge base where practical.

Provide a training workspace or clearly isolated sample job. A new estimator should complete intake → site survey → internal estimate → approval → customer document without editing code or asking the owner how every field works.

### Historical import — only after the system is finished

1. Inventory selected prior job folders, bid tabs, closeouts, tickets, expense sheets, and benchmark sources.
2. Map source fields to app records and retain source URLs/identities. Preserve originals unchanged.
3. Produce a dry-run report showing proposed records, matches, duplicates, conflicts, missing values, allocations, and benchmark eligibility.
4. Review a small pilot set with the owner, then import the approved set.
5. Reconcile financial totals, quantities, source-file counts, and links. Re-running the import must not create duplicate jobs, costs, tickets, or media.
6. Keep planning estimates, sold prices, actual costs, and collected payments distinct. “Completed” in a folder name is not proof all costs are final.
7. Exclude training fixtures and unverified/misclassified quantities from real benchmark calculations.

### Acceptance scenario

Use one fictional demolition job to demonstrate the complete workflow:

- A lead arrives and is assigned a next action, with no job-folder creation.
- An estimator creates a budget in **Estimating**, then creates a linked draft in **Quotes & Proposals** and previews both customer layouts.
- The customer requests a change with a note; the assigned employee sees it and sends a revised document while preserving the original.
- The customer signs the selected document containing distinct contract and payment sections.
- The estimate summary records its complete project details and price history; a separate lost/no-response test estimate remains searchable without job folders.
- Successful job creation/conversion provisions the correctly named Jobs Awarded folder set once and moves the existing estimate summary without breaking its link. The correct job, crew, schedule, and equipment are linked.
- Employees sign a tailgate and their machine checks.
- Classified time, receipts, and disposal tickets are captured.
- An unsigned change order cannot be finalized or affect approved totals. A customer-signed change order changes scope/value exactly once, and any later material revision requires a new signature.
- Drive receives each file in the right PDOS destination.
- An authorized employee reviews actual costs and closeout variances.
- Eligible facts appear in benchmarks and ChatGPT can explain them.
- Unauthorized employee/client accounts cannot see private costs, pay, or internal documents.

Also demonstrate duplicate receipt/event handling, Drive failure/retry, expired/replaced signature links, stale document revisions, operator handovers, missing signatures, and interruption/reconnection on mobile.

### Release requirements

Deliver working screens, database migrations, permission rules, tests, documentation, and a deploy/rollback guide. Record which integrations were actually tested with provider test data and which remain awaiting credentials.

After acceptance, deploy the agreed version to the user's Railway service from the user's fork. Preserve existing data and verify login, uploads, signatures, jobs, costs, and backups after migration. Do not switch production merely because a staging build compiles.

## 12. Claude implementation notes

### Reuse these existing areas

Paths below are starting points from the reviewed repository, not a guarantee that the deployed version has identical files.

| Work | Starting points |
| --- | --- |
| Quote/proposal layout, customer change notes, and signing | `apps/web/src/features/quotes/`, `apps/web/src/features/documents/build.ts`, `packages/core/src/documents.ts`, `packages/core/src/contracts.ts`, client portal and API signing/document-PDF services |
| Change orders and mandatory customer signature | `apps/web/src/features/jobs/ChangeOrders.tsx`, quote-to-job/change-order relationships, API/database finalization rules, signature evidence and billing helpers |
| Pipeline | `apps/web/src/features/pipeline/`, `requests/`, API sales routes |
| Permissions | `packages/core/src/roles.ts`, web settings roles, Supabase role/RLS migrations and tests |
| Estimating | A dedicated internal calculator feature and tab using shared core estimates/formulas/money utilities. Keep its records and UI separate from customer documents; reuse arithmetic utilities where appropriate. |
| Receipt and cost capture | `apps/api/src/services/receipts.ts`, receipt routes, `packages/core/src/receipts.ts`, job costs and reports |
| Drive mirror and award-stage folders | Existing app file/storage/Drive code plus a Google Drive adapter and durable queue. Provision folders only after job creation; support standalone pre-job summaries and moving the same files on conversion. |
| Field/scheduling/equipment | Existing field, schedule, equipment, checklists, visit assignments, and equipment-booking migrations |
| Time/classification | Timesheets, `packages/core/src/pay.ts`, API pay services, classified time-segment extensions |
| ChatGPT tools | `apps/api/src/mcp.ts`, `apps/api/src/assistant-tools/`, assistant-access checks |
| Database changes | New versioned migrations under `supabase/migrations/`; regenerate database types as needed |

Keep the current React/TypeScript web app, API, and database stack. Avoid a framework rewrite, a second authentication system, or new generic platform infrastructure when the existing app already provides the necessary pattern.

### Data additions to evaluate

Extend existing tables first; exact names follow repository conventions. Likely additions include document presentation/revisions; customer change-request notes linked to document versions and follow-up tasks; change-order finalization linked to customer signature evidence; internal estimate versions/lines/rate snapshots and explicit customer-document links; configurable pipeline stages and follow-up tasks; disposal loads and cost allocations; Drive file mappings and sync jobs; tailgate meetings/attendees; machine operator assignments/checklist responses; work classifications and classified time segments; closeout/benchmark evidence; integration-event identities.

Every new business record needs tenant scope, foreign keys, timestamps, appropriate permissions, and an audit trail for consequential edits. File access must follow its linked record's permissions. Add a unique estimate-to-summary mapping with dated price/outcome history and a unique job-to-folder provisioning record so repeated events cannot create extra summaries or folders.

### Tests and delivery process

Use the repository's existing test infrastructure. The inspected scripts include `npm run typecheck`, `npm test`, `npm run test:db`, `npm run test:upgrade`, `npm run test:e2e`, and `npm run test:browser`. Read their setup requirements before executing them, and run database/migration tests only against an isolated test database.

Add focused tests for pricing, independent calculator/document versions, customer change notes and superseded-link signing, signed revisions, mandatory customer signatures before change-order finalization, change-order accounting, duplicate costs/events, rate/classification history, role restrictions, benchmark denominators, and retry-safe Drive operations. Include API attempts to bypass signature requirements and repeated signature callbacks. Add browser coverage for the primary office and field workflows. Preserve existing quoting, billing, and mobile behavior.

Test that lead/estimate/quote activity creates no job folders, every saved estimate keeps a single summary, lost/no-response history remains available, both job-creation paths provision the correct named folders once, name collisions do not merge unrelated jobs, and retrying a partial Drive operation preserves the same file/folder IDs. Verify that moving an estimate summary into a job preserves its pricing history and permissions.

For each phase, report what works, how it was verified, remaining gaps, migrations, and a preview. Do not call an integration finished based only on a mocked success response. Keep the plan's phase IDs in implementation tickets so review comments remain easy to track.

## 13. Deferred work

- Gusto synchronization.
- Historical-job loading until the final phase.
- Two-way Google Drive editing/synchronization unless explicitly added.
- Custom model training beyond retrieval and structured benchmark calculations.
- Unrelated modules or a broad redesign outside the prioritized workflows.

## 14. Source references

The owner's private handoff keeps the full source list (Google Docs/Sheets, PDOS lifecycle rules,
templates, ChatGPT library files). They are deliberately not in this public repository. Public
references: the upstream Crewtavo repository (https://github.com/jviars/crewtavo, reviewed at commit
`bd6eae6c0143e08631f3978d500ecc20ad6a5c7c`), Crewtavo's docs (https://crewtavo.com/docs), Railway's
environment docs (https://docs.railway.com/environments) and the provider docs named in Phase 7.

## 15. Handoff instruction for Claude

> This is the consolidated Planet Ops implementation specification. When the owner starts the coding task, begin with **Phase 0 only** in the selected fork on a development branch based on `planet-ops-staging`. Complete its foundation work and tests, document any external setup the owner must perform, and return a pull request targeting the user's staging branch. Continue phase by phase using section 16. Work within the requested phase without repeatedly asking permission for routine reversible implementation choices.
>
> Confirmed workflow requirements: **Estimating** is a separate internal calculator tab; **Quotes & Proposals** is the customer-document tab. Creating a customer document from a saved estimate creates a linked, unsent draft. Both customer layouts support **Request changes** with a saved customer note and traceable revisions. **Every change order requires the customer's signature on its final version before it can be finalized or affect approved totals; there is no unsigned staff override.** Preserve signed history and independent calculation/document versions.
>
> Keep one internal **Estimate Summary** document per estimate with full project details, costs, pricing history, and outcome, including lost/no-response bids. Before job creation, store it as a standalone file in existing **Jobs Bid**. **Create job folders only when direct Create Job or quote/proposal conversion successfully creates a job, and create them in Jobs Awarded using the normalized address/project-type/year name.** Provision standard subfolders and matching central Media at that point, move the same estimate summary into the job, and make all retries duplicate-safe. This confirmed timing rule overrides older lifecycle instructions that create folders during lead intake or bidding.
>
> Extend the existing Crewtavo fork in the phase order above, starting with the deployment/permission baseline and then quotes/proposals plus change orders. Preserve working app behavior and existing source records. Use the user's actual PDOS folder rules and estimating-sheet mapping. Deliver complete working features with appropriate migrations, permissions, tests, and documentation. Keep Gusto deferred and import historical jobs only after final workflow acceptance. Verify differences between this plan, the current fork, and the deployed version before relying on them. Development and staging work do not authorize a production cutover, customer messages, live payments, or bulk historical import; those occur at their specified release/setup steps.

## 16. Owner setup

Owner setup for staging (Railway) lives in [docs/planet-ops/RAILWAY_STAGING.md](planet-ops/RAILWAY_STAGING.md).
Phase status, verification evidence and pending owner inputs live in
[docs/PLANET_OPS_PROGRESS.md](PLANET_OPS_PROGRESS.md).
