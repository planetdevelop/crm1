# Planet Ops (fork of Crewtavo)

Planet Ops turns this Crewtavo fork into Planet Demolition's operating system. Work phase by phase:

- Requirements: [docs/PLANET_OPS_IMPLEMENTATION_PLAN.md](docs/PLANET_OPS_IMPLEMENTATION_PLAN.md)
- Status, verification evidence, pending owner inputs: [docs/PLANET_OPS_PROGRESS.md](docs/PLANET_OPS_PROGRESS.md)
- Phase 0 references: [docs/planet-ops/](docs/planet-ops/) (data map and migration outline,
  permissions review, mockups, Railway staging runbook)

## Rules

- Branches: start each phase from the latest `planet-ops-staging`; open the PR into
  `planet-ops-staging` on `planetdevelop/crm1` (never `jviars/crewtavo`). Production cutover is Phase 9 only.
- Reuse Crewtavo's existing features and patterns (React/TypeScript web app in `apps/web`, Hono API
  in `apps/api`, shared logic in `packages/core`, Supabase/Postgres migrations in `supabase/migrations`).
  No framework rewrite, no second auth system.
- Branding: user-facing name comes from `packages/core/src/brand.ts` (`PRODUCT_NAME`, applied by the
  i18n `t()` layer). Don't blind-rename `crewtavo` package names, the Railway service name, storage
  keys, env vars or database objects. Keep upstream LICENSE/NOTICE/TERMS and the "Crewtavo Terms" wording.
- Migrations: new versioned files only; never edit a released one; they must work on existing rows
  and with the previous app version running. The app applies migrations on start, so check the
  database target before deploying anywhere.
- Permissions: enforce in the API (`requireCompany`) **and** RLS (`private.level_permissions()`),
  and for files, exports and assistant tools (see docs/planet-ops/PERMISSIONS.md).
- This is a public repository: no client records, private Google links, or secrets in commits.
- Deferred: Gusto, historical-job import (Phase 9), two-way Drive sync. No real customer sends or
  live payments from development or staging.

## Checks

`npm run typecheck`, `npm test` (vitest in each workspace), `npm run test:db` (throwaway Postgres in
Docker), `npm run test:upgrade`, `npm run build:server`. Browser/e2e tests need a local Supabase
(see `.github/workflows/ci.yml`, job `browser`). Record pre-existing failures separately from new ones.
