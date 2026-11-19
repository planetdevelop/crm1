# Planet Ops progress

Requirements: [PLANET_OPS_IMPLEMENTATION_PLAN.md](PLANET_OPS_IMPLEMENTATION_PLAN.md). Keep each
phase's acceptance evidence here.

| Phase | Status |
| --- | --- |
| 0: fork/staging baseline, shared records, permissions, Planet Ops name | **Repository work done (PR into `planet-ops-staging`)**; Railway staging pending owner |
| 1: quotes, proposals, terms, signatures, change orders | Not started |
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
