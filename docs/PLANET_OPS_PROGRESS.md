# Planet Ops progress

Requirements: [PLANET_OPS_IMPLEMENTATION_PLAN.md](PLANET_OPS_IMPLEMENTATION_PLAN.md). Keep each
phase's acceptance evidence here.

| Phase | Status |
| --- | --- |
| 0: fork/staging baseline, shared records, permissions, Planet Ops name | **Merged** (PR #1). Railway staging exists (owner-confirmed): https://crewtavo-staging.up.railway.app/ |
| 1: quotes, proposals, terms, signatures, change orders | **In progress**: 1a and 1b merged (PR #2, #3); 1b follow-up, 1c, 1d, 1e in stacked PRs (see Phase 1) |
| 2–9 | Not started. Gusto and historical import remain deferred |

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

