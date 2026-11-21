# Planet Ops progress

Requirements: [PLANET_OPS_IMPLEMENTATION_PLAN.md](PLANET_OPS_IMPLEMENTATION_PLAN.md). Keep each
phase's acceptance evidence here.

| Phase | Status |
| --- | --- |
| 0: fork/staging baseline, shared records, permissions, Planet Ops name | **Merged** (PR #1). Railway staging exists (owner-confirmed): https://crewtavo-staging.up.railway.app/ |
| 1: quotes, proposals, terms, signatures, change orders | **In progress**: 1a and 1b merged (PR #2, #3); 1b follow-up, 1c, 1d, 1e in stacked PRs (see Phase 1) |
| 2: a real sales pipeline | **In progress**: 2a (data, rules, reports) in a PR stacked on Phase 1e (#7); 2b and 2c (screens) stacked on 2a. See Phase 2 |
| 3: estimating (internal calculator and database) | **In progress**: 3a (data, rates, calculation, privacy) stacked on 2d; 3b (workspace) and 3c (customer-document handoff, summaries, job linkage) stacked on 3a. See Phase 3 |
| 4–9 | Not started. Gusto and historical import remain deferred |

## Phase 0 (branch `claude/phase-0-foundation`)

### Starting point

- Fork `planetdevelop/crm1`: `main` and `planet-ops-staging` were both exactly upstream commit
  `bd6eae6c0143e08631f3978d500ecc20ad6a5c7c`, the commit the plan reviewed. The fork is public.
- No GitHub Actions run had happened in the fork (Actions not yet enabled).
- Railway was **not** accessible from the session (no token or connector). See
  [planet-ops/RAILWAY_STAGING.md](planet-ops/RAILWAY_STAGING.md) for what the repository shows
  about the deployment: the template runs upstream's **image** `ghcr.io/jviars/crewtavo:latest`
  with auto updates, not this fork. The owner must confirm the live source.

### Done

- **Branding (Planet Ops)**, done in central places instead of a blind rename:
  - `packages/core/src/brand.ts`: `PRODUCT_NAME`, brand colors `#1C50E4` / `#17801B`, fork
    `SOURCE_URL`, and `brandText()`. That function swaps the product name and keeps "Crewtavo Terms",
    "Crewtavo docs" and attribution as written.
  - Applied in the i18n layer (`t()`, plurals; English and Spanish; before placeholders are filled,
    so a company's own name is never touched). This covers navigation, sign-in, setup, field
    screens, notifications and server messages that go through the translator.
  - API error responses (`app.onError`), MCP server title/instructions, ChatGPT agent name, PDF
    creator/producer, default email sender name, service-worker notifications, page title, iPhone
    Home Screen name, installed-app manifest name/description, client hub "Powered by", time-change
    labels, first-run setup screen.
  - Fixed an issue that branding exposed: Spanish error translation (`translateError`) took a renamed
    but untranslated English line for a translation and skipped its pattern fallback.
  - **Logo**: the approved full-color crest (supplied by the owner, kept as
    `docs/brand/planet-ops-crest.png`) on the sign-in pages and as the installed-app icons
    (`icon-192/512`, maskable, Apple touch). For small sizes where the crest isn't readable (sidebar,
    favicon, boot screen, chat avatar, hub footer), the mark is the orbital planet "O" **cropped from
    the crest's wordmark** on a dark tile (`planet-ops-mark.png`, `favicon*`). Nothing was redrawn.
    It replaces the Crewtavo logo, which NOTICE §7(e) forbids on a modified version.
  - **Modified-version marking**: NOTICE has a "Planet Ops modified version" paragraph; the license
    screen says Planet Ops is a modified version (not an official Crewtavo release) and links both
    sources (AGPL §13). LICENSE, TERMS and the "Crewtavo Terms" acceptance text are unchanged.
- **Shared records foundation**: `packages/core/src/costCodes.ts` defines the plan's 13 common cost
  codes and display groups, and maps every existing expense category to one (unknown text maps to
  `other`). No database change.
- **Screen/data map, link spec and migration outline**: [planet-ops/DATA_MAP.md](planet-ops/DATA_MAP.md).
- **Permissions review**: [planet-ops/PERMISSIONS.md](planet-ops/PERMISSIONS.md). The plan's roles map
  onto the existing levels, areas and custom roles. Gaps are assigned: `send_pricing` and
  `internal_costs` (Phase 1/3), `payroll` separate from job costs (Phase 6), cost approval
  (Phase 4), tailgates (Phase 5). The staging test-account recipe is included.
- **Mockups**: [planet-ops/MOCKUPS.md](planet-ops/MOCKUPS.md): Estimating, the **Create Quote /
  Proposal** handoff, the Quotes & Proposals editor, customer **Request changes**, and the
  change-order customer-signature gate.
- **Staging runbook**: [planet-ops/RAILWAY_STAGING.md](planet-ops/RAILWAY_STAGING.md).
- **Repository instructions**: `CLAUDE.md`; this file; the repository copy of the plan, with private
  links, client/job names and owner-only prompts removed.

### Migrations

None in Phase 0.

### Checks

Baseline = untouched `planet-ops-staging` (`bd6eae6`), run in a clean worktree. After = this branch.

| Check | Baseline | After Phase 0 |
| --- | --- | --- |
| `npm run typecheck` | pass | pass |
| `npm test`: api | 116 files, 2574 tests, pass | 116 files, 2574 tests, pass |
| `npm test`: web | 151 files, 1983 tests, pass | 151 files, 1983 tests, pass |
| `npm test`: core | 65 files, 1208 tests, pass | 66 files, 1215 tests, pass (adds `planetOps.test.ts`) |
| `npm run test:db` (throwaway Postgres 17 in Docker) | 203 test files, all passed | unchanged: no migration or SQL change |
| `npm run build:server` | — | pass; built server answers `/api/health` `{"ok":true,"version":"dev"}`, page title, manifest and setup screen show Planet Ops (desktop and phone screenshots) |
| `npm run instance` (full five-service Docker stack) | — | **blocked in the session**: the image's `apk add postgresql17-client` step can't reach `dl-cdn.alpinelinux.org` (session network policy). The app build stage inside Docker completed. Railway builds on its own network |
| `npm run test:upgrade` | — | pass from upstream `v0.5.3` and from the PR base `bd6eae6` (24,100 rows in 177 tables, 0 new migrations) |
| `test:e2e`, `test:browser` | not run locally (need a local Supabase CLI stack) | run in CI (`browser` job) |

No baseline failures existed. Every test change in this branch is an expected product-name text
update: an assertion now expects "Planet Ops" where the code path is branded, and stays "Crewtavo"
where the message is still raw (see "Remaining").

### Remaining / blocked (owner)

- **Logo**: supplied as a raster image (1277×1232). A vector (SVG) or larger PNG export would
  give sharper large icons; swap `docs/brand/planet-ops-crest.png` and regenerate the icons.
- **Railway**: confirm the production app's source (runbook §1), then create `staging` following
  runbook §2. Claude did not configure Railway.
- **GitHub Actions**: enabled by the owner. At the owner's request, the upstream-only Authorship step
  and the auto-close PR workflow were removed, and the build and test jobs are kept. CI runs on PRs
  into `planet-ops-staging` (runbook §4).
- **Upstream sync before cutover**: if production auto-updates from upstream, merge upstream into
  the fork before Phase 9 (runbook §1).

### Remaining (code, low risk)

- Some server-generated messages that bypass `t()` and `onError` still say "Crewtavo": raw strings
  in storage/hosting/backup/address services, a few direct `c.json` responses (MCP tool refusals,
  assistant guard, review asks by text), the notification titles those services write, and email
  setup steps such as "name the app password Crewtavo". They are mostly owner/admin hosting
  messages. Sweep them with `brandText` as each area is touched; no blind rename.
- `crewtavo.com/docs` help links still point at upstream docs, labelled as Crewtavo docs.

### Staging acceptance (fill in after deploy)

- [ ] `/api/health` ok; version `dev` (built from the fork)
- [ ] Sidebar, sign-in, tab title and installed-app name show Planet Ops
- [ ] Fictional client/request created; one upload works
- [ ] Each permission test account opens only what PERMISSIONS.md lists

## Phase 1 (in progress)

Delivered as small PRs into `planet-ops-staging`. Three kinds of evidence are kept apart:
**Implemented** (code on a branch), **Automated** (unit, database and CI browser tests pass) and
**Staging** (checked by hand on https://crewtavo-staging.up.railway.app/).

| Slice | Scope | Implemented | Automated | Staging (manual) |
| --- | --- | --- | --- | --- |
| 1a | Every acceptance needs the customer's drawn signature on the exact version; no staff bypass | Merged, PR #2 (`a0d5d8e`) | Yes: CI green on `42b2bb6` and on the merge | Deployed (web bundle has the 1a/1b screens; health ok). Not exercised by hand: no staging sign-in available to Claude |
| 1b | Line-item quote / proposal layouts, separate Contract and Payment Terms, configurable countersignature, nav relabel | Merged, PR #3 (`ad1c0fc`) | Yes: CI green on `d9c4b09` and on the merge | Deployed; not exercised by hand (as above) |
| 1b+ | Document type chosen first (New Quote / Proposal), shown at the top of a draft; Edit / Preview kept apart from it | Branch `claude/phase-1b-creation-choice` | Unit tests; browser test `e2e/proposals.spec.ts` (CI) | Not yet |
| 1c | Document versions (snapshot per issued version, supersession) and customer Request changes | Branch `claude/phase-1c-revisions` (stacked on 1b+) | `planet_ops_document_versions_test.sql`, API hub tests, browser test `e2e/change-requests.spec.ts` (CI) | Not yet |
| 1d | `send_pricing` permission; accepted / countersigned / deposit / ready states; job contract summary | Branch `claude/phase-1d-pricing-readiness` (stacked on 1c) | `planet_ops_send_pricing_contract_test.sql`, API send/sign refusals, core `agreementFacts` tests (CI runs the full suite) | Not yet |
| 1e | Convert the exact signed revision to a job; retry- and race-safe; job-created handoff | Branch `claude/phase-1e-convert-signed-revision` (stacked on 1d) | `planet_ops_convert_signed_revision_test.sql` (incl. two conversions at once via dblink), API retry test; signed-version link guarded (staff SQL updates, lifecycle API updates) (CI runs the full suite) | Not yet |

Staging access: Claude can reach the staging app (health, setup, the deployed bundle) but has no
sign-in there (single-company mode, email off), so every hand check on staging is the owner's until a
test login is arranged. Physical iPad / finger / stylus signing is the owner's in any case.

Owner inputs still needed: the approved Contract Terms and Payment Terms wording, and whether to turn
on the (configurable) company countersignature. Until the wording arrives, new quotes carry clearly
marked `[PLACEHOLDER]` terms; no legal text is invented.

### 1a: customer signature required for every acceptance, tied to the exact document version

Owner decisions applied (Nov 2026 review): a drawn customer signature is mandatory for quotes,
proposals and change orders; every acceptance carries the version fingerprint; staff approval never
stands in for the customer.

- Before: staff could "Mark approved" any quote (a manual approval), drop a quote on "Approved" on the
  sales board, or "Convert to job" an unsigned quote (it saved a manual approval first). A change
  order joined its job the same way. A signature was tied to the total only, and the fingerprint was
  optional outside change orders. The drawing was checked by its PNG header only (a one-pixel image
  passed), and a signed-in person could call the in-person signing step with made-up details.
- Now (migration `20261120000100_planet_ops_change_order_signature.sql`, not yet released):
  - **Customer signature required.** A quote, proposal or change order becomes `approved` only with
    a customer signature (printed name, drawn signature, server signing time) on its exact version,
    and becomes a job (`converted`, or `jobs.quote_id`) only from that. Direct status updates, inserts
    as approved/converted, manual approvals, the convert function and job inserts are all refused
    otherwise, whoever runs them. Quotes approved by the office before this migration keep their state
    but can't be converted without a signature. Jobber imports of approved quotes come in as sent.
  - **Version fingerprint required everywhere.** The client hub and the in-person screen must send
    the fingerprint of the version they showed (API: 400 without one; database: refused without one,
    and refused when the document changed since). The version covers lines (names, descriptions,
    quantities, units, prices, tax, optional/grouped), options offered and their prices, schedule,
    deposit and payment schedule, discount, tax, promo, contract sections, and the template's terms and
    signature settings. The customer's own choices are recorded with the signature:
    `approval.choices` (option, add-ons picked, subtotal, discount, tax, total).
  - **Original signed document preserved.** `approval.document` keeps the signed version;
    `approval.fingerprint` its fingerprint; `approval.signed_at` is set by the database. A signed
    quote, proposal or change order can't be reopened, marked lost, archived, deleted, re-signed or
    edited; a change is a new revision (for a job, a new change order) signed again.
  - **Drawn signature validated.** The API decodes the whole PNG (`apps/api/src/lib/drawnSignature.ts`:
    chunk checksums, image end, decompressed size, row filters) and counts ink. It refuses blank pads,
    a single tap, one-pixel and tiny images, malformed or truncated files, other formats and typed
    text; a short real signature passes. The database checks the PNG structure and size too.
  - **Only the server writes a customer signature** (hub approval; in-person signing through the API
    with the signed-in seller checked). `sign_quote` is callable by the server only.
- Interface: "Mark approved" is gone; "Convert to job" / "Add to job" shows only once the customer
  has signed; the sales board refuses a drop on "Approved"; the roofing and paving flows wait for the
  signature; the in-person signing screen waits for the version to load and always sends it.
- Test fixtures: real signature-pad drawings (`apps/api/test/fixtures/signaturePad.ts`, captured from
  the app's pad in Chromium: full, short, initials, a tap, blank). Database tests sign through
  `planet_test.sign()` (the server's path) instead of writing approvals directly.
- Tests: `supabase/tests/planet_ops_change_order_signature_test.sql` covers every staff bypass on
  quotes and change orders; fabricated signatures; missing, typed, one-pixel, JPEG and truncated
  drawings and a missing name on both signing paths; missing fingerprints and outdated pages after a
  same-price scope change, schedule, Contract Terms, Payment Terms, deposit and option-price changes;
  the recorded choices, server time and preserved document; reopen/lost/delete/edit/re-sign of a
  signed quote and change order; credit (link) and $0 (in person) change orders; legacy office
  approvals refused at conversion. API: `drawnSignature.test.ts`, plus hub and in-person endpoint
  tests for missing fingerprints and blank/tap/one-pixel/truncated/typed signatures, and conversion
  refusals (`NOT_SIGNED_YET`) for staff and the assistant.
- Checks (this round): typecheck pass; unit tests api 2582, web 1976, core 1222 pass; `test:db` all
  pass; `build:server` pass.
- **Price set on site in the version; total required** (pre-merge review). The "Price adjustment"
  lines a price set on site writes were left out of the version, and `expected_total` was optional,
  so an office change to that price didn't make an open page outdated when no total was sent. Now:
  - the adjustment lines are in the version like any other line, so changing, adding or removing a
    price set on site is a new version, refused on the customer link and in person, with or without
    a total;
  - the customer's own choice of another option as they sign (which takes the shown option's price
    set on site off) still signs: the version they're held to is the one just before that choice
    in their own signing step (`private.offered_version`); an office switch of the shown option is
    a change like any other;
  - the API requires `expected_total` on both paths (400 without it); credits and $0 still sign.
  - Tests: `planet_ops_change_order_signature_test.sql` (price changed or removed, stale page on
    both paths with and without the total, choosing the other option, the shown option at the site
    price on both paths, an office switch); API hub and in-person tests for a missing or non-number
    total, a stale total, and credit/$0 totals. Run against the earlier rule, the new database tests
    fail at "a change to the price set on site is a new version".
- Countersignature (configurable) is in 1b.

### 1b: Quotes & Proposals, separate terms, configurable countersignature

- Migration `20261120000200_planet_ops_quotes_and_proposals.sql` (not yet released):
  - `quotes.presentation` (`line_items` / `proposal`), `quotes.narrative` (only overview, scope,
    inclusions, exclusions, assumptions, alternates), `quotes.contract_terms`, `quotes.payment_terms`.
  - **Terms.** A new quote starts with the company's default Contract Terms and Payment Terms
    (`settings.quotes.contract_terms` / `payment_terms`), each edited per job before signing. Until
    the company saves its approved wording, new quotes get clearly marked `[PLACEHOLDER]` terms (the
    quote page warns while they're placeholders); a default saved empty means none.
  - All of these are part of the signed document version (with a price set on site, as in 1a); once
    signed they stay as signed, and the signed copy (`approval.document`) keeps them.
  - **Company countersignature, configurable** (`settings.quotes.countersign_required`, off unless
    set). A countersignature is an intentional act for one agreement, after the customer's signature:
    drawn now, or the signer's own saved drawing applied on purpose (`approval.company.method`
    `drawn` / `saved`). The database records the signer (`user_id`, which must be the person signed
    in), stamps its own time and the fingerprint of the version the customer signed, and refuses one
    that's a name, typed words, a one-pixel image, applied automatically, in someone else's name,
    before the customer signs, or on a document that changed since. It can't be changed or removed.
  - Nothing is signed for the company as the customer signs (the hub no longer adds the
    salesperson's saved signature; in person, the seller draws or taps "Use my saved signature").
  - When required, a quote or proposal becomes a job, and a change order joins its job, only once
    it's countersigned (convert, status, and job inserts are all refused before). Turned on after a
    customer signed, it's still needed.
- App: quote page "Customer document" card (layout switch, proposal sections, Contract Terms, Payment
  Terms, "Use the company's terms", a placeholder warning); "awaiting your company's countersignature"
  state, with "Sign for …" (draw) and "Use my saved signature" (explicit); "Convert to job" waits for a
  required countersignature; the in-person screen asks the seller to draw or choose their saved
  signature; Settings → Quotes and payments: countersignature switch and default terms; documents
  (office, client hub, print, PDF) print a proposal's sections and one total without priced lines,
  and both terms sections on either layout; a signed document prints from the copy kept with the
  signature; Copy as new draft keeps layout, sections and terms; nav and page renamed "Quotes &
  Proposals", "New Quote / Proposal". Estimating is untouched (Phase 3).
- Tests: `supabase/tests/planet_ops_quotes_proposals_test.sql` (placeholders and defaults, per-job
  edits, layouts with one total, the version including layout/narrative/both terms, outdated pages
  refused on both signing paths and a page without a version, proposals signed on the link and in
  person with the document preserved, countersignature off (optional, still bound) and on (before the
  customer, name only, typed, one-pixel, no method, automatic, someone else's, drawn, saved, changed or
  removed after, convert/status/job refused before, in person with and without, turned on after
  signing), change orders waiting for it, a change while awaiting refused); API: explicit saved use,
  never implicit, hub never adds a company signature; `packages/core/test/proposals.test.ts`;
  `apps/web/test/planetOpsProposals.test.ts`; PDF tests for both layouts.
- Owner input still needed: the approved Contract Terms and Payment Terms wording (enter it in
  Settings → Quotes and payments), and whether to turn the countersignature on.

### 1c: document versions and customer change requests

Migration `20261121000100_planet_ops_document_versions.sql` (not yet released).

- **Versions** (`quote_versions`): every issue to the customer keeps an immutable copy of the whole
  offered document (`private.quote_version`: scope, lines, options and prices, schedule, deposit
  and payment schedule, Contract Terms, Payment Terms, section words, template terms), its
  fingerprint, totals, number in sequence, who issued it and how (sent, signed in person, priced on
  site). Issued on send (status to sent, a resend, the exact price or the range sent again), by
  `issue_quote_version` (resend / make available again), by a price set on site on a sent estimate,
  and by in-person signing. A new version supersedes the pending one; versions can't be edited or
  deleted; later default, template or price-list changes don't touch them. Documents already with
  customers got their current version as version 1 (`existing`).
- **Draft revisions**: editing a sent document changes nothing for the customer. Their link keeps
  the issued version; the API shows only "An updated … is on its way" (no draft content is sent),
  and the database refuses a link signature on anything but the current issued version. The quote
  page shows "Draft revision, not sent" with "Send the update".
- **Signing**: on the link, only the current issued version (never superseded, never an unsent
  draft); in person, the screen's document is issued as it's signed. The approval records
  `version_id` / `version_number`; the version records `signed_at`.
- **Change requests** (`quote_change_requests`, `request_quote_changes`, server only): the note
  exactly as typed, the client, which link (own / office copy) and IP, the server's time, and the
  version reviewed (by the page's fingerprint). A request key from the page makes retries one
  request. A pending quote, proposal or change order becomes "Changes requested" and signing pauses
  (link and in person) until the office sends it again: a revision (new version) or the same version
  made available again; sending answers open requests and closes their follow-ups. A request on a
  signed agreement leaves it untouched, is logged against the signed version and, for an active
  job, starts a proposed change order (a draft). Each request creates one follow-up task
  (`follow_up_tasks`, unique per request) for the document's salesperson (else the office) and an
  in-app notification (the existing automation tells the office on "Changes requested"). The office
  replies once per request (`respond_to_change_request`); replies and requests are kept as history.
- **Customer page**: "Request changes" beside approval (note "What would you like changed?",
  "Send request", confirmation); after a request, the note and "signing is paused" instead of the
  signing steps, with "Add to your request"; a signed agreement offers "Request a change".
- **Office page**: Versions and change requests card (versions with View of each copy, requests with
  version, reply, follow-up and Mark done, "Send it again" while paused).
- Tests: `supabase/tests/planet_ops_document_versions_test.sql` (issue on send, immutability,
  defaults changing later, draft revision not signable, supersession, retried and repeated requests,
  follow-up and notification, signing paused on both paths, reply, revision sent and signed, every
  version kept, a proposal and a change order taking requests, in-person issue on signing, a request
  on a signed agreement making a proposed change order), API hub tests (version shown, draft
  revision hidden, note as typed with key and version, signed agreement request), and
  `e2e/change-requests.spec.ts` (portal request → paused → office reply → revision hidden → sent
  as version 2 → signed). Existing database tests send their documents before signing
  (`planet_test.sign` / `planet_test.approval` issue the version, as the office does).

### 1d: preparing pricing apart from sending it; agreement facts; the job's contract

Migration `20261121000200_planet_ops_send_pricing_and_contract.sql` (not yet released).

- **send_pricing** ("Send pricing to customers"): a new area. `sales` prepares quotes, proposals
  and change orders; sending one (first send, resend, exact price, range, making it available again
  after a change request, in-person signing) needs `send_pricing` too. Enforced in the database for
  anyone signed in (status to sent, sent/exact/range times, inserts as sent, `issue_quote_version`),
  and checked by the API before anything goes out (`lib/sendPricing.ts`: send, send range, in-person
  sign; the assistant's send_quote uses the same service). A price set on site by someone without
  it stays a draft revision. Owners, admins, office and estimators have it by default and every
  existing custom role that sells kept it, so nobody lost access; a custom role can now prepare
  without sending (Settings → Team). The send dialogs explain it instead of opening.
  No "Mark approved" bypass came back.
- **Agreement facts** (core `agreementFacts`, quote page and job page): Customer accepted (their
  drawn signature), Company countersigned (Not required / Waiting / Signed), Deposit (from its
  invoice's payments: none / owed / partly paid / received; `quote_deposit_status`), Ready to
  schedule (the signatures, plus the deposit only if Settings → Quotes and payments → "Ready to
  schedule waits for the deposit" is on; off by default). None implies another.
- **Contract summary** (`job_contract_summary`, job page "Contract"): original signed agreement
  (signed amount and version), each change order with its state and amount, finalized changes
  (credits included, each once; a credit counts its signed subtotal since totals can't go below
  zero), revised contract total, and, with invoices access, invoiced, paid, outstanding on invoices
  and not yet invoiced. Unsigned, declined, cancelled and changes-requested change orders count for
  nothing; the revised total creates no invoice, payment or balance.
- Decision for the owner: whether "Ready to schedule" should wait for the deposit (a switch, off),
  and which roles should prepare without sending (custom roles).

### 1e: a job from the exact signed revision, once

Migration `20261121000300_planet_ops_convert_signed_revision.sql` (not yet released).

- Converting links the job to its customer and property (as before), the request
  (`jobs.request_id`, new) and the exact version the customer signed (`jobs.quote_version_id`, new:
  the version the signature recorded, never a later edit). The customer's signature and a required
  countersignature are still checked as it's converted. **Linking an internal estimate is deferred
  to Phase 3** (no internal estimate record exists before then), so none is linked yet.
- The signed-version link is protected in the database (`jobs_signed_version_stays`), for staff,
  the API, assistants and the server alike: it must be the exact version the job's own quote was
  signed on (never another quote's, even in the same company, an unsigned one, or one the signature
  didn't record); once set it can't be cleared or replaced, nor the job moved to another quote under
  it; it's set only as a signed document is converted, so Create Job and jobs made before versions
  were kept stay without one (no signed history invented). It goes only if the version itself is
  deleted with its quote or company. Tested signed in as staff straight at the table
  (`planet_ops_convert_signed_revision_test.sql`) and through the API in the lifecycle test.
- Converting again returns the job it made (the API answers with it; the database does too). Two
  at once: the quote is locked while it's converted, so the second waits and gets the first's job;
  a unique index keeps one job per quote (created only if no old duplicates exist).
- Job-created handoff (`job_folder_provisioning`): one pending record per job, made as the job is
  created, by Create Job (`direct`) or a conversion (`converted`), the same workflow either way.
  Requests, sends and signatures make none. No folders are made; Phase 4 does the Drive work.
- Create Job stays separate: it can't claim an unsigned quote and records no acceptance.
- The job's Contract card says which signed version it was made from and links the request.
- **Only converting sets the signed-version link** (fix after review): a job inserted straight into
  the table with its correct quote and exact signed version was accepted. `convert_quote_to_job` now
  runs as its owner and checks who may convert itself (owners, admins, office and estimators with the
  sales area; the server: as its quote and job rules allowed before); it marks the quote it's
  converting for its transaction, and the guard accepts a new link only from the function's owner
  with that mark. Staff, the API, the service role and a direct write are refused even with the right
  values (or the marker set by hand), and nothing is left behind. Tested in
  `planet_ops_convert_signed_revision_test.sql` and through the API in the lifecycle test.

## Phase 2: a real sales pipeline (in progress)

Built on Phase 1e (`claude/phase-1e-convert-signed-revision`, PR #7), since Phase 1 isn't merged yet:
merge Phase 1 first (#4 → #5 → #6 → #7), then 2a → 2b → 2c.

| Slice | Scope | Implemented | Automated | Staging (manual) |
| --- | --- | --- | --- | --- |
| 2a | Stages, owner/estimator/next action/outcomes per request, history, contacts and pauses, follow-up cadence and templates (data), report and pricing history | PR #8, branch `claude/phase-2a-pipeline-model` | `planet_ops_pipeline_test.sql`, core `pipeline.test.ts` (CI runs the full suite) | Not yet |
| 2b | Pipeline board and list with the filters; the request's pipeline card, contact log, follow-ups and history | PR #9, branch `claude/phase-2b-pipeline-screens` (stacked on 2a) | Browser test `e2e/pipeline.spec.ts` (CI), web unit tests | Not yet |
| 2c | Settings → Sales pipeline (default owner, reminders, stages, cadence, templates); Report and Pricing history | PR #10, branch `claude/phase-2c-pipeline-settings-reports` (stacked on 2b) | Browser test `e2e/pipeline-settings.spec.ts` (CI), web unit tests | Not yet |
| 2d | Resume restores the current stage's follow-ups; snooze/reschedule; a follow-up as the next action; Won as a sales call with a note | PR #11, branch `claude/phase-2d-pipeline-followups` (stacked on 2c) | `planet_ops_pipeline_followups_test.sql`, browser test `e2e/pipeline-followups.spec.ts` (CI) | Not yet |

### 2a: the pipeline's data and rules

Migration `20261122000100_planet_ops_pipeline.sql` (not yet released).

- **Stages** (`pipeline_stages`), per business, from the plan: New inquiry → Contacting → Site visit
  scheduled → Site visit complete → Estimating → Quote/proposal sent → Follow-up → Won, with
  Nurture/on hold, Lost and Unqualified/spam kept apart. Labels, order and each stage's next action
  are editable (Settings); custom open stages can be added and removed when empty. The starter stages
  keep their kind and can't be deleted; New inquiry, Won and the outcomes stay on. Viewed / overdue
  are badges, not stages.
- **Every request** carries its stage (apart from its status and any job's production status), its
  owner (`assigned_to`: the zip code's salesperson as before, else the pipeline's default owner when
  one is chosen; with neither it's flagged "No owner", as Crewtavo leaves it unassigned today), the
  assigned estimator, its next action and date (each stage sets one on entry unless one is given),
  last contact and first response (from logged contacts only), campaign, requested service, and its
  outcome with a reason (Lost and Unqualified need one). Existing requests join at the stage their
  status means; archived ones stay out (no reason is invented).
- **Moves**: the existing flows move a request forward, never back and never out of an outcome a
  person chose (site visit booked or done, quote/proposal sent); a job made from it makes it Won,
  once. Outcomes clear the next action and stop its follow-ups; moving back into the pipeline starts
  them again.
- **History** (`request_pipeline_events`): stage moves (with the labels as they read then), owner,
  estimator, next action, outcome, pauses and resumes, contacts, with who and when. Kept as it
  happened: no edits or deletes.
- **Contacts** (`log_request_contact`): a call, text, email or note is kept in the client's messages
  on the request (never a new lead) and is never sent from here. It sets the last contact and first
  response. An inbound one pauses the request's follow-ups, as do a customer's inbound message
  anywhere, an opt-out, a win or a loss; staff can pause and resume.
- **Follow-ups**: each stage's cadence steps (`pipeline_cadence_steps`; the plan's suggested starter:
  first response, post-site-visit check-in, post-proposal follow-up, later nurture) make internal
  reminders (`follow_up_tasks`) for the owner as a request enters the stage, once per entry; the last
  stage's are closed (as left behind) and a paused request gets none. Follow-ups can be added by hand
  (`add_request_follow_up`) and go with the request to a new owner. Reusable call/text/email
  templates (`pipeline_templates`) are written by the business: none are preset.
- **No automatic customer messages.** Sending needs an approved channel, text, recipients and timing;
  it comes with the communication integrations (Phase 7). Until then everything here is reminders and
  drafts.
- **Reports** (`pipeline_report`), on defined dates: requests that came in in the period (by source
  and current stage); open requests' aging and days in stage; first-response time; outcomes decided in
  the period with conversion = won ÷ (won + lost), unqualified apart, also by source; won and lost
  value = the quoted amount (signed, else the latest sent).
- **Pricing history** (`pipeline_pricing_history`): every sent quote/proposal for a request (not
  change orders), filterable by service, location, date, estimator and outcome, lost and unanswered
  included. Sales evidence, never actual costs or benchmarks. The internal estimate summary joins it
  in Phase 3 (Estimating).
- **Who**: the pipeline is the Sales area's (owners, admins, office and estimators with it); stages,
  cadence, templates and pipeline settings are Settings'. Enforced in the database for anyone signed
  in (screens, API, assistants); a crew lead sees no history or templates.
- Shared rules for the screens (`packages/core/src/pipeline.ts`): what Needs first response, Follow-up
  due, Overdue, Waiting on customer, No next action and No owner mean; silence never closes a request.

### 2b: the pipeline's screens

- **Sales pipeline** (`/pipeline`, from Requests → Sales board): a **Requests** tab (the pipeline) and
  the existing **Quotes** board, unchanged. Requests show as a **board** (one column per active open
  stage and Nurture, sorted by next-action date, with the quoted value) or a **list** (stage and days
  in it, owner and estimator, next action and date, last contact, quoted amount), remembered per
  viewer. Filters: Active, Needs first response, Follow-up due, Overdue, Waiting on customer, No next
  action, No owner, Decided (30 days), and whose (mine, no owner, a person). Dragging a card moves its
  request; Won, Lost and Unqualified drop zones ask why (Won by hand is a sales call only: see 2d).
- **The request page**: a Sales pipeline card (stage, owner, estimator, last contact, first response,
  days in stage, the reason once decided, next action and date, requested service, campaign, pause or
  resume follow-ups) and a Follow-ups and contact history section (open follow-ups with Done and Add,
  log a call/text/email/note with a template to start from, and the full history: moves, changes,
  pauses and contacts with who and when). The client card's Salesperson is now Owner.

### 2c: pipeline settings, report and pricing history

- **Settings → Team → Sales pipeline** (owners, admins and office with Settings): a reminder that the
  pipeline only makes reminders and drafts; the **default owner** and whether stage cadence makes
  reminders (owners and admins); **stages** (rename, next action and days, on/off, order, add and
  delete custom ones; the starter outcomes stay on); the **follow-up cadence** (per stage: reminder,
  after how many days, how, which template, on/off); and **templates** (call scripts, text and email
  drafts, in the business's own words; none preset; on/off).
- **Sales pipeline → Report**: 30 days, 90 days or 12 months, the dates on screen: requests in (by
  source, with conversion by source, and where they are now), median first-response time, conversion
  (won ÷ (won + lost) decided in the period), won and lost value (quoted amounts), and open requests'
  aging.
- **Sales pipeline → Pricing history**: sent prices on requests by service, location, sent dates,
  estimator and outcome, each linked to its request and quote/proposal, with the reason once decided;
  labelled as sales evidence, not costs or benchmarks.

### 2d: follow-ups that pause, resume and move; Won as a sales call

Migration `20261123000100_planet_ops_pipeline_followups.sql` (not yet released).

- **Resume policy**: resuming restores the *current stage's* unfinished cadence reminders, once. Those
  the pause closed are reopened as the same follow-ups (due when they were, or today if that day has
  passed); a step the pause kept from being made (the stage was entered while paused) is made, due as
  it would have been, or today. Completed reminders stay completed; reminders from an earlier stage
  stay closed; manual follow-ups were never closed by a pause. Repeated resumes and retries make
  nothing twice (each reminder's identity is its stage entry and step). A decided request (Won, Lost,
  Unqualified) can't be resumed by hand (move it back into the pipeline), nor one whose customer opted
  out of messages or texts.
- **History** says what happened to each follow-up: created, done, cancelled (and why: paused, the
  customer replied, opted out, moved to another stage, won, lost), restored, moved (from → to).
- **Snooze and reschedule**: Tomorrow, +1 week, or Move… to a day; the same follow-up moves, never to
  a past day on the business's own date, and a closed one can't be moved. A follow-up can be made the
  request's next action: snoozing it moves the next action's date; doing it clears the next action;
  typing a next action by hand unlinks it.
- **Won without a job**: someone in sales may mark a request Won with a note saying why. It is a
  sales classification only: no job, invoice, payment, deposit, signature or folder handoff is made,
  and the quote stays as it was (tested). Converting the signed agreement later still links the one
  job to the request, and Won stays once in the history. Production status stays with the job.

### Phase 2 against the plan's "done when"

- Every active request has an owner and a visible next action: every stage gives a next action on
  entry, and a request comes in with its zip's salesperson or the default owner. **Owner input:**
  choose a default owner (Settings → Sales pipeline) so none arrives without one; until then such a
  request is flagged No owner on the board, the list and its page.
- Moving stages preserves history (`request_pipeline_events`, kept as it happened; tested).
- One client can have two independent opportunities (tested in the database and the browser).
- Accepting a quote links the correct request/job without duplicates: converting the signed quote
  makes one job linked to its request and marks the request Won once, again on retry (tested). Won
  by hand (2d) is a noted sales call that makes no job.

### Phase 2 deferred or for the owner

- Automatic customer messages (sequences that send): Phase 7, once a channel, approved wording,
  recipients and timing are set. Templates hold no preset wording.
- The internal estimate and its summary on each request and in pricing history: Phase 3.
- The starter stage labels, next actions and cadence are the plan's suggestions, for the owner to
  confirm or change in Settings.
- Not covered by a connected assistant's own tools yet (assistants read and write requests under the
  same database rules).

## Phase 3: Estimating, the internal calculator and database (in progress)

Built on Phase 2d (`claude/phase-2d-pipeline-followups`, PR #11), since Phases 1 and 2 aren't merged:
merge #4 → #5 → #6 → #7 → #8 → #9 → #10 → #11, then 3a → 3b → 3c.

Reference: [planet-ops/ESTIMATING_MAPPING.md](planet-ops/ESTIMATING_MAPPING.md) (the workbooks read
cell by cell, the verified calculation order, the issues found, the app's rules, and the parity check).

| Slice | Scope | Implemented | Automated | Staging (manual) |
| --- | --- | --- | --- | --- |
| 3a | Estimating areas; rates with effective dates; estimates, versions (draft → approved baseline → revisions), lines; exact totals; cost privacy; one summary record per estimate | PR #12, branch `claude/phase-3a-estimating-model` (stacked on 2d) | `planet_ops_estimating_test.sql`, core `estimating.test.ts`, parity script against the real workbook (local, 44/45 to the cent) | Not yet |
| 3b | The Estimating tab: list and search, New estimate (from a request or alone), the guided editor (project and site, labor, equipment, disposal and hauling, other costs, pricing review, versions), Settings → Estimating (rates, approval), Start estimate on a request | PR #13, branch `claude/phase-3b-estimating-workspace` (stacked on 3a) | Browser test `e2e/estimating.spec.ts` (CI; includes tablet and phone width checks), web unit tests | Not yet |
| 3c | Create quote / proposal from an estimate version (unsent draft, prices only); explicit refresh with differences; issued versions and the job keep the exact estimate version; the Estimate Summary; estimator guide | Branch `claude/phase-3c-estimate-handoff` (stacked on 3b) | `planet_ops_estimate_handoff_test.sql`, browser test `e2e/estimate-handoff.spec.ts` (CI; checks the customer's page and data hold nothing internal) | Not yet |

### 3a: data, rates, calculation, privacy

Migration `20261124000100_planet_ops_estimating.sql` (not yet released).

- **Areas** (Settings → Roles): *Prepare internal estimates* (`estimate`), *See estimating costs, rates
  and profit* (`estimate_costs`), *Approve estimates* (`estimate_approve`), apart from Quotes and sales
  and Send pricing. Owners and admins have all three; office and estimators prepare and see costs;
  approving is owners' and admins' (and General manager's) unless given. Existing custom roles that
  sell were given prepare and costs; none was given approve except admin-level ones.
- **Rates** (`estimate_rates`): code, section, name, unit, cost, includes burden / fuel, owned, and the
  day it takes effect. A new cost is a new row from its day; the earlier one ends the day before; a
  cost can't be edited in place. Setting rates needs costs and Settings. **No rates are preset**: the
  business enters its own (the workbook's values are not loaded).
- **Estimates** (`estimates`, number per business, linked to the request, customer, property and
  estimator), **versions** (`estimate_versions`: draft → approved; the first approved is the
  **original baseline**; later approved versions are revisions; a revision copies the latest version
  with its rate snapshots and a reason; approved versions and their lines are frozen; versions are
  never deleted) and **lines** (`estimate_lines`: count × hours × days × unit cost, unit, risk %, rate
  and its snapshot, labor role / overtime / burden, equipment owned / fuel, disposal stream, facility,
  estimated tons, loose CY, container CY and loads kept apart, the customer item each line rolls up to).
- **Calculation** in the database (`private.estimate_totals`, exact `numeric`) and the same in
  `packages/core/src/estimating.ts`, in the workbook's verified order; rounding half up to the cent
  once; each line's share of the selling price for the customer document (adds up exactly). Missing
  rates, owner pay on without its %, and impossible values leave an estimate **unresolved**: it can't
  be approved. Markup and target margin are exclusive; owner pay is none or a % of the price before it.
- **Saving** carries the revision it was made from; a save from an older revision is refused (no lost
  changes). A retried *New estimate* with the same key returns the same estimate.
- **Privacy**: costs, percentages, totals, prices and rate costs are in columns nobody signed in can
  read; `estimate_version_costs` and `estimate_rate_list` return them only with `estimate_costs`. A
  preparer without it sees scope, quantities and rate names, can change quantities, and can't see or
  change a cost or the pricing. Crews, other businesses and the customer pages see nothing.
- **Summary** (`estimate_summaries`): one per estimate, made with it, titled *Estimate {number} -
  {address} - {project type} - {year}* and kept current; its permanent copy is to go to **Jobs Bid**
  until a job exists, then the job's folder (Phase 4 does the Drive work: nothing is backed up yet).
- Estimating makes no quote, job or folder (tested).

### 3b: the estimating workspace

- **Estimating** (main menu, for people with *Prepare internal estimates*): every estimate with its
  customer, address, estimator, version and status, the request and its outcome; search; **New
  estimate** (from a request it takes the request's customer, property and title; a retried click
  opens the one it made). A banner says costs stay internal.
- **The guided editor**, in the order of the bid workbook and the Future Bid Checklist:
  1. *Project and site*: title, type, customer and property (for an estimate without a request),
     estimator, area, structures (sq ft, stories), materials and layers, foundation, access,
     utilities, hazards, testing assumptions, internal inclusions/exclusions, site notes, supporting
     file links, the customer-facing scope a proposal will say, and the **assumption log** (each
     assumption with its source).
  2. *Labor*: people × hours/day × days at a rate; role, overtime, "rate already includes burden".
  3. *Equipment* (and travel): owned/rented, "rate already includes fuel", fuel lines tied to their
     machine (a double charge is flagged).
  4. *Disposal and hauling*: priced by what's billed, with material stream, facility, estimated
     tons, loose CY, container CY and expected loads each in its own field.
  5. *Other costs*: materials, permits and testing, subcontractors, other (credits allowed), and
     contingency (warned when missing).
  6. *Pricing review* (costs only): markup **or** target margin, owner pay none **or** % of the
     price before it, labor burden, default risk %, and every figure with its definition: base cost,
     risk reserve, subtotal, markup, price before owner pay, owner pay, calculated selling price,
     profit if the reserve isn't used, sheet margin, price per sq ft.
  7. *Versions and documents*: approve (owners/admins by default; frozen; the first is the original
     baseline), every version with its dates, open an older one.
  A side panel shows the calculated price as you type (the same arithmetic the database saves), and
  what's missing before it can be approved. **Revise** makes the next draft with a reason. Rates
  picked from Settings carry their unit, cost and includes; a preparer without cost access sees
  quantities and rate names only.
- **Settings → Estimating**: approval required for customer documents (on by default; owners and
  admins switch it); the business's rates with unit, cost, from-day and includes, and "New cost"
  (from a day; earlier estimates keep theirs). None preset.
- **Request page**: its estimates and **Start estimate**.

### 3c: from the estimate to the customer's document, the summary, and the job

Migration `20261125000100_planet_ops_estimate_handoff.sql` (not yet released).

- **Create quote / proposal** (from a saved, complete estimate version; approved first while Settings
  → Estimating requires it, the default): needs Estimating and Quotes and sales; asks line-item quote
  or proposal; makes an **unsent draft** for the estimate's customer, property and request, linked to
  that exact version (`quotes.estimate_version_id`), and opens it in Quotes & Proposals. Only customer
  items at their selling prices (lines grouped by their customer name; the shares add up to the
  calculated price exactly) and the customer-facing scope cross; the quote line's own `unit_cost`
  stays empty; no wage, cost, rate, markup, reserve, owner pay or internal note. A retry returns the
  same draft. Staff can't set the link by hand. Sales tax, if the business charges it, is added by
  Quotes & Proposals on top of the selling price.
- **Separate histories** (tested): negotiating the document never changes the estimate; revising the
  estimate never changes a document. **Refresh from estimate…** on an unsigned document shows the
  differences first (lines and subtotals now and after), then replaces its lines (and, if chosen, its
  scope); a sent one becomes a draft revision until sent again (Phase 1c); a signed one is never
  refreshed.
- **Each issued document version keeps the estimate version** it carried
  (`quote_versions.estimate_version_id`), and **converting the signed version links the job to that
  exact estimate version** (`jobs.estimate_version_id`), even when a newer estimate version exists.
  Only conversion sets it (the same guard as the signed-version link); documents and jobs without an
  estimate stay without one; Create Job links none; no link is guessed from names or prices.
- **The Estimate Summary** (Summary on the estimate; printable): estimate and version, estimator,
  dates, customer, property, request; scope, conditions, assumptions and files; the itemized lines
  with quantities and units (and, with cost access, unit costs, the rate as taken, base, risk and each
  line's selling share); base, reserve, pricing method, owner pay, the **calculated** selling price
  and profit; every version's dated figures; the **prices actually sent** (each document version,
  with the estimate version it carried) and **accepted**, kept apart from the calculated price; any
  job; the request's outcome, last contact, next follow-up and lost reason. One per estimate, kept
  current, never duplicated. Someone without cost access gets it without a single cost, total or
  price; nobody without Estimating gets it.
- **Phase 4 handoff, recorded only**: the summary's permanent copy belongs in **Jobs Bid** until a job
  exists, then in the **job's folder** (set when the job is made); its status says **not backed up**.
  No folder is made for an estimate or a quote (tested); no Drive sync runs.
- **Customer pages**: the hub reads only the document's own columns; the browser test checks the
  customer's page and its data carry no internal line name, note or cost.
- **Assistants** read estimates under the same rules (rows by role and area; costs only through the
  costs function with *See estimating costs*); estimating writes aren't among the assistants' write
  functions, so they can't change estimates.
- Guide for estimators: [planet-ops/ESTIMATOR_GUIDE.md](planet-ops/ESTIMATOR_GUIDE.md).

### Phase 3 decisions for the owner

- The workbook issues **P1–P9** in [planet-ops/ESTIMATING_MAPPING.md](planet-ops/ESTIMATING_MAPPING.md)
  §4: per-sq-ft area, travel by mileage vs fuel, the truck-fuel quantity, labels, whether a global
  risk reserve applies, the OT rate's meaning, contingency as a line or a reserve, and whether owner
  pay is a cost or profit (the app shows it apart from profit until decided).
- **Rates**: enter the business's own rates (none are preset; the workbook's are not loaded).
- **Labor burden**: whether rates are fully loaded or a burden % applies (no default).
- **Approval**: who approves estimates (owners, admins and General manager by default), and whether
  approval stays required before a customer document (on by default).
- **Sales tax** on demolition services: Quotes & Proposals applies the business's tax settings on
  top of the estimate's selling price.

## Phase 1 staging acceptance checklist (owner)

Run on https://crewtavo-staging.up.railway.app/ with fictional records once PRs #4–#7 are merged
in order (#4, #5, #6, #7). Physical iPad / finger / stylus checks need a real device.

- [ ] **Create**: New Quote / Proposal starts with Document type; a proposal's draft shows the type
      at the top and Edit / Preview apart from it; switching keeps price, sections and both terms.
- [ ] **Proposal output**: customer page (phone and desktop), print and PDF show the narrative
      scope and total without priced lines; a line-item quote shows its lines.
- [ ] **Terms**: Contract Terms and Payment Terms are separate, `[PLACEHOLDER]` until approved
      wording is saved, and kept in the signed copy.
- [ ] **Signatures**: a drawn signature signs; blank, tap-only and typed-name-only are refused.
- [ ] **Outdated pages**: after a scope, price, schedule or terms change (and a price set on
      site), an open customer page or iPad screen can't sign.
- [ ] **Options**: choosing another option on the link signs at its price; an office switch of the
      shown option makes an open page outdated.
- [ ] **Request changes** (quote, proposal, change order): note saved, confirmation, signing
      paused, follow-up and notification for the salesperson; reply; revision hidden from the
      customer until sent; sent as the next version and signed; earlier versions kept.
- [ ] **Signed agreement request**: kept as signed; a draft change order appears on the active job.
- [ ] **Send pricing**: a custom role without "Send pricing to customers" prepares but can't send.
- [ ] **Agreement status**: accepted, countersigned (off and on), deposit owed/received from real
      payments, ready to schedule (switch off and on).
- [ ] **Change orders**: charge, credit and $0 each signed and applied once; the Contract card
      totals only finalized ones; the revised total makes no invoice.
- [ ] **Convert**: the job links the signed version and request; converting twice (double click,
      back and retry) opens the same job.
- [ ] **iPad (physical device)**: in-person signing with a finger and with a stylus; blank and
      single-tap refused; an old screen refused after an office change; the company line asks to
      draw or use the saved signature.


## Phase 2 staging acceptance checklist (owner)

Run with fictional records once Phase 1 and PRs #8, #9 and the 2c PR are merged in order.

- [ ] **Settings → Sales pipeline**: confirm or edit the stage names, next actions and cadence;
      choose a default owner; write any call/text/email templates (none are preset).
- [ ] **New request** (booking form, Client Hub, phone): lands in New inquiry with an owner (its zip's
      salesperson or the default owner) and the next action "Make first contact"; a first-response
      reminder appears for the owner.
- [ ] **Board and list**: each filter (Needs first response, Follow-up due, Overdue, Waiting on
      customer, No next action, No owner, Decided) and the owner filter; drag a card between stages;
      Lost and Unqualified ask why; Won isn't offered.
- [ ] **Request page**: change stage, estimator, next action and date, service, campaign; log a
      call, a text from the customer (follow-ups pause), an internal note; resume follow-ups; add and
      complete a follow-up; the history lists each with who and when.
- [ ] **Existing flows**: scheduling and finishing a site visit, sending a quote/proposal and
      converting the signed one move the request forward, and the job makes it Won once.
- [ ] **Two opportunities**: two requests for one client move independently.
- [ ] **Report and pricing history**: numbers match the period's requests; lost and unanswered
      prices appear, labelled as sales evidence.
- [ ] **Roles**: a custom role without Sales can't move requests, log contacts or see the history.
- [ ] **No customer messages** were sent by the pipeline at any point.

## Phase 3 staging acceptance checklist (owner)

Run with fictional records once Phases 1–2 and PRs #12, #13 and the 3c PR are merged in order.

- [ ] **Settings → Estimating**: add a few rates (labor with and without burden, an owned and a rented
      machine, a disposal per-ton fee); give one a new cost from today and check an earlier estimate
      keeps the old one.
- [ ] **Start estimate** from a request; fill Project and site and the assumption log; add labor,
      equipment (with a fuel line for a fuel-included machine: warned), disposal (tons, CY, container
      and loads apart), other costs and contingency.
- [ ] **Pricing review**: markup and target margin each; owner pay none and on; burden; every metric's
      definition; an incomplete estimate (a line without a rate) can't be approved.
- [ ] **Roles**: a custom role with *Prepare internal estimates* only sees quantities, not costs, and
      can't change pricing; a crew lead and a seller without Estimating see no estimate.
- [ ] **Approve** (baseline frozen); **Revise** with a reason; the baseline's figures stay.
- [ ] **Create quote / proposal** (both kinds): an unsent draft with customer lines only; review and
      send it from Quotes & Proposals; on the customer's page (phone and desktop, print/PDF) nothing
      internal appears.
- [ ] Negotiate the document's price: the estimate doesn't change. Revise the estimate: the document
      doesn't change until **Refresh from estimate…** (differences shown first); a signed one can't be.
- [ ] Sign and convert: the job links the signed version's estimate version (not a newer one); the
      summary now says its copy belongs with the job (not backed up); no folder before the job.
- [ ] **Summary**: one per estimate after many saves; prints; sent and accepted prices apart from the
      calculated price; a lost bid keeps it with its reason.
- [ ] Tablet and phone: the estimate editor and summary are usable (physical devices are the owner's).
