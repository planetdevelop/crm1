# Planet Ops progress

Requirements: [PLANET_OPS_IMPLEMENTATION_PLAN.md](PLANET_OPS_IMPLEMENTATION_PLAN.md). Keep each
phase's acceptance evidence here.

| Phase | Status |
| --- | --- |
| 0: fork/staging baseline, shared records, permissions, Planet Ops name | **Merged** into `planet-ops-staging` (PR #1); Railway staging pending owner |
| 1: quotes, proposals, terms, signatures, change orders | **In progress**: slice 1a (change-order signature gate) in review; 1b–1e to follow |
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

Delivered as small PRs into `planet-ops-staging`, in this order:

| Slice | Scope | Status |
| --- | --- | --- |
| 1a | **Every acceptance needs the customer's drawn signature on the exact version; no staff bypass** (database, API, UI) | PR open |
| 1b | Quotes & Proposals: line-item quote vs proposal layout (one authoritative total), narrative sections, separate editable Contract Terms and Payment Terms, configurable drawn company countersignature, nav relabel | PR open |
| 1c | Document revisions: a snapshot per sent version, superseded versions can't be signed; **Request changes** note tied to the revision reviewed, office notice and follow-up task, signing paused until a revision is issued | To do |
| 1d | `send_pricing` permission (build vs approve/send customer pricing); separate states for customer accepted, company countersigned, deposit received, ready to schedule; job summary of original contract, change orders, revised total, invoiced, paid, remaining | To do |
| 1e | Convert Quote / Proposal to Job links the exact signed revision; repeat conversion opens the existing job | To do |

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
