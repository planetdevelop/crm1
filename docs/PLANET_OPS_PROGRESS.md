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
| 1a | **Change orders finalize only with the customer's signature on the exact version** (database, API, UI) | PR open |
| 1b | Quotes & Proposals: line-item quote vs proposal layout (one authoritative total), narrative sections, separate editable Contract Terms and Payment Terms, configurable drawn company countersignature, nav relabel | PR open |
| 1c | Document revisions: a snapshot per sent version, superseded versions can't be signed; **Request changes** note tied to the revision reviewed, office notice and follow-up task, signing paused until a revision is issued | To do |
| 1d | `send_pricing` permission (build vs approve/send customer pricing); separate states for customer accepted, company countersigned, deposit received, ready to schedule; job summary of original contract, change orders, revised total, invoiced, paid, remaining | To do |
| 1e | Convert Quote / Proposal to Job links the exact signed revision; repeat conversion opens the existing job | To do |

Owner inputs still needed: contract terms wording, payment terms, and whether the company must
countersign. Until then, documents use the existing contract-section library and clearly marked
placeholders; no legal text is invented.

### 1a: customer acceptance tied to the complete document version; change-order signature gate

- Before: staff "Mark approved" on a change order (a trigger then added its lines to the job), and
  "Convert / Add to job" on an unsigned one (it saved a "manual" approval first), both finalized it
  without the customer. A signature was tied to the total only. Any signed-in person could call the
  in-person signing step directly with made-up signer details, or write a customer-looking approval.
  A finalized change order could be reopened and approved again.
- Now (migration `20261120000100_planet_ops_change_order_signature.sql`):
  - **Document version.** `private.quote_version()` covers everything the document offers: lines
    (names, descriptions, quantities, units, prices, tax, optional/grouped), options, schedule,
    payment terms (deposit, payment schedule), discount, tax, promo, contract sections' wording, and
    the template's terms and signature settings. It leaves out the customer's own choices (option,
    add-ons), which are recorded with the approval and its amounts. The fingerprint changes at the same
    price too.
  - **Signing.** The client hub and the in-person screen send the fingerprint of the version they
    showed. The database refuses a signature from an outdated page, and a change order can't be
    signed without one. The approval keeps the fingerprint and a copy of the signed version
    (`approval.document`), so the original signed document is preserved.
  - **Only the customer signs.** Only the server writes a customer signature (the hub approval; in-person
    signing through the API, which checks the person and the drawn signature). Signed-in users can't
    write or alter one, and `sign_quote` is no longer callable from the browser.
  - **Finalizing a change order** needs that customer signature on the version it is now, for added
    charges, credits and $0 changes.
  - **A finalized change order stays as signed.** It can't be reopened, archived, moved, deleted or
    re-signed, and its signed lines can't change. A revised agreement is a new change order, signed
    again.
  - Change orders finalized before the migration keep their state.
- Interface: the quote page hides "Mark approved" and "Add to job" on an unsigned change order and says
  why; the job's change-order list shows "Awaiting customer signature".
- Tests: `supabase/tests/planet_ops_change_order_signature_test.sql` (43 checks): every staff bypass;
  fabricated signatures (direct write, approval with forged metadata, direct `sign_quote`, rewriting
  the signer or the fingerprint); outdated pages after a same-price scope change, a schedule change,
  a deposit change, payment-terms wording, contract-terms wording, and a section removed; signing the
  version shown; the signed version kept; retries applied once; reopen, draft, archive, delete and edits
  of a signed change order refused; credits and $0 changes; the office's manual approval and
  countersignature on ordinary quotes still working; deleting a job or company still working. Also
  `packages/core/test/changeOrders.test.ts`. Existing database tests now sign change orders as the
  customer would, and expect reopening a signed one to be refused.
- Checks: typecheck pass; unit tests api 2574, web 1983, core 1221 pass; `test:db` all pass;
  `test:upgrade` from `v0.5.3` passes with this migration applied to a database with rows.
- **Drawn signatures required (owner decision).** A customer signature is three separate fields: the
  printed name, the signing time and a signature drawn with a finger, mouse or stylus (a PNG from the
  signature pad). The database refuses any customer acceptance without the drawing, on quotes,
  proposals and change orders; a typed name alone never signs. The client hub's API requires the
  drawing too, and its pad says "Draw your signature with your finger, mouse or stylus". Tests cover a
  typed name only, words in place of the drawing, a non-PNG picture, and each of the three fields
  missing.

### 1b: Quotes & Proposals, separate terms, configurable countersignature

- Migration `20261120000200_planet_ops_quotes_and_proposals.sql`:
  - `quotes.presentation` (`line_items` / `proposal`), `quotes.narrative` (only overview, scope,
    inclusions, exclusions, assumptions, alternates), `quotes.contract_terms`, `quotes.payment_terms`.
  - A new quote starts with the company's default Contract Terms and Payment Terms
    (`settings.quotes.contract_terms` / `payment_terms`); each is edited per job.
  - All of these are part of the signed document version; once signed they stay as signed.
  - Company countersignature, configurable (`settings.quotes.countersign_required`, off unless set).
    When required it must be drawn (with who signed and when); a change order the customer signed
    waits for it before it's added to the job, and is re-checked against the signed version as it
    joins. The hub no longer adds a saved company signature as the customer signs when a
    countersignature is required.
- App: quote page "Customer document" card (layout switch, proposal sections, Contract Terms, Payment
  Terms, "Use the company's terms", a placeholder warning); "awaiting your company's countersignature"
  state; Settings → Quotes and payments: countersignature switch and default terms; documents (office,
  client hub, print, PDF) print a proposal's sections and one total without priced lines, and both
  terms sections on either layout; a signed document prints from the copy kept with the signature;
  Copy as new draft keeps layout, sections and terms; nav and page renamed "Quotes & Proposals",
  "New Quote / Proposal". Estimating is untouched (Phase 3).
- Tests: `supabase/tests/planet_ops_quotes_proposals_test.sql` (defaults, per-job edits, layouts with
  one total, the version including layout/narrative/terms, an outdated page refused, signed terms
  locked, countersignature off/on, a name or typed words refused as a required countersignature, a
  change while awaiting countersignature refused); `packages/core/test/proposals.test.ts`;
  `apps/web/test/planetOpsProposals.test.ts`; PDF tests for both layouts.
- Owner input still needed: the approved Contract Terms and Payment Terms wording (enter it in
  Settings → Quotes and payments).
