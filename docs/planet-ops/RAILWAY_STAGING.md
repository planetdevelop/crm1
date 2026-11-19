# Planet Ops: deployment audit and Railway staging runbook (Phase 0)

Claude had no Railway access in the Phase 0 session (no Railway token or connector), so nothing in
Railway was changed or inspected live. This document records what the repository shows and gives the
exact dashboard steps for the owner. **Production stays unchanged.**

## 1. What the repository says about the live deployment

| Question | Finding (from `deploy/README.md`, `.railway/railway.ts`, `Dockerfile`, `.github/workflows/release.yml`) |
| --- | --- |
| Services | Five: `crewtavo` (public app), `db`, `auth`, `rest`, `storage`. Only `crewtavo` is public; it proxies `/auth/v1`, `/rest/v1`, `/storage/v1` over Railway's private network (`apps/api/src/lib/stack.ts`) |
| App source in the template | **Docker image `ghcr.io/jviars/crewtavo:latest`, with auto updates on.** That is upstream's image, built by upstream's release workflow. It is not this fork |
| db source in the template | Image `ghcr.io/jviars/crewtavo-db:pg17` (upstream), auto updates overnight |
| auth / rest / storage | Pinned images: `public.ecr.aws/supabase/gotrue:v2.197.0`, `postgrest:v16.4`, `storage-api:v1.82.1` |
| Build when built from source | Root `Dockerfile`, build context = repository root (not `apps/web`): web app, API and background tasks in one image |
| Port / health | `PORT=8080`; healthcheck `/api/health`; timeout 600 s (`RAILWAY_HEALTHCHECK_TIMEOUT_SEC=600`) |
| Migrations | **Applied automatically when the app starts**, whenever `SUPABASE_DB_URL` is set (`scripts/migrate.mjs`). Verify the database target *before* the first staging deploy |
| Backups | Nightly `pg_dump` by the app (Settings → Your data); restore with `scripts/restore.mjs`. The secrets `JWT_SECRET`/`ENCRYPTION_KEY` (crewtavo) and `POSTGRES_PASSWORD` (db) are not in those backups |

**What this means.** Unless the service source was changed after deploying the template, production
runs **upstream's** image. It installs every upstream release by itself within hours, and runs its
migrations on the production database. Editing or merging this fork changes nothing in production
until the app service's source is switched, which is the Phase 9 cutover.

### How to confirm which source production uses (2 minutes, read-only)

1. Railway → your project → environment **production** → service **crewtavo** → **Settings → Source**.
   - It shows **Image `ghcr.io/jviars/crewtavo:latest`** (or a version tag): it runs upstream's image.
   - It shows **GitHub repo `planetdevelop/crm1`** (or `jviars/crewtavo`) with a branch: it builds from that repo.
2. Open `https://<your-production-address>/api/health`. `"version":"0.x.y"` means a released
   upstream image. `"version":"dev"` means it was built from source (the Dockerfile's default).
3. Note the `db` service's source the same way.

Please send Claude the non-secret results (source type, image/tag or repo/branch, health version).

### Production risk to decide on (no change made)

With upstream auto updates on, production keeps moving ahead of this fork. That is fine until
cutover, but the fork must be **merged with upstream up to (or past) the version production runs**
before production is switched to the fork. Otherwise the fork would be older than the production
database (`/api/health` reports `"problem":"newer_database"`). Turning off auto updates (Settings →
Source → Configure auto updates) would freeze production on its current version. That is your
call; Claude has not changed it.

## 2. Create an isolated `staging` environment (owner steps, Railway dashboard)

1. Project → environment dropdown (top) → **+ New Environment** → **Duplicate Environment** (from
   production) → name it **`staging`**. Railway puts the copied configuration in **staged changes**.
   **Do not deploy yet.**
2. **Volumes:** confirm `db` and `storage` in staging have their **own new volumes** (empty), not
   production's. Never point staging at production's volume or database.
3. **db (staging)** → Variables: set a **new** `POSTGRES_PASSWORD` (any long random hex string). Keep
   `POSTGRES_HOST=/var/run/postgresql`, `POSTGRES_PORT=5432`, `PGPORT=5432`, `POSTGRES_DB=postgres`.
   Keep the source image `ghcr.io/jviars/crewtavo-db:pg17`. Turn **auto updates off** for staging so
   it changes only when you choose.
4. **crewtavo (staging)** → **Settings → Source**: **Disconnect** the image, **Connect Repo** →
   `planetdevelop/crm1`, branch **`planet-ops-staging`**. Builder **Dockerfile**, path `Dockerfile`,
   root directory empty (repository root). Optional watch paths: `apps/**`, `packages/**`,
   `supabase/migrations/**`, `scripts/**`, `Dockerfile`, `package-lock.json`.
5. **crewtavo (staging)** → **Settings → Networking**: **Generate Domain** (port `8080`). Healthcheck
   path `/api/health`.
6. **crewtavo (staging)** → **Variables**. Every reference must resolve to the **staging** services.
   Keep them as `${{service.VAR}}` references, never literal production URLs:

   | Variable | Staging value |
   | --- | --- |
   | `PORT` | `8080` |
   | `APP_URL` | `https://${{RAILWAY_PUBLIC_DOMAIN}}` (the staging domain) |
   | `JWT_SECRET` | **New** value: a 64-character random hex string, different from production |
   | `ENCRYPTION_KEY` | Remove it, or set a **new** one. Never production's |
   | `SUPABASE_DB_URL` | `postgres://postgres:${{db.POSTGRES_PASSWORD}}@${{db.RAILWAY_PRIVATE_DOMAIN}}:5432/postgres` |
   | `SUPABASE_AUTH_URL` | `http://${{auth.RAILWAY_PRIVATE_DOMAIN}}:9999` |
   | `SUPABASE_REST_URL` | `http://${{rest.RAILWAY_PRIVATE_DOMAIN}}:3000` |
   | `SUPABASE_STORAGE_URL` | `http://${{storage.RAILWAY_PRIVATE_DOMAIN}}:5000` |
   | `RAILWAY_HEALTHCHECK_TIMEOUT_SEC` | `600` |
   | `RAILWAY_DEPLOYMENT_DRAINING_SECONDS` | `30` |

   **Test-only outbound:** delete from staging (or replace with test-mode keys) anything that sends or
   charges for real: `RESEND_API_KEY`, `EMAIL_FROM`, `TWILIO_ACCOUNT_SID`, `TWILIO_AUTH_TOKEN`,
   `TWILIO_FROM_NUMBER`, `STRIPE_SECRET_KEY`, `STRIPE_WEBHOOK_SECRET` (test mode `sk_test_…` only),
   `QUICKBOOKS_*`, `ZOHO_*`, `GOOGLE_CLIENT_ID`/`GOOGLE_CLIENT_SECRET` (a separate test OAuth client if
   needed), `ANTHROPIC_API_KEY` (optional; a separate key). Company-level connections (Stripe, email,
   texting, Google) live in the database, so a fresh staging database starts with none.
7. **auth / rest / storage (staging)**: keep their images and variables. Check that each
   `${{db…}}`, `${{crewtavo…}}` and `${{rest…}}` reference resolves inside **staging**. In
   particular, auth's `API_EXTERNAL_URL`, `GOTRUE_SITE_URL` and `GOTRUE_URI_ALLOW_LIST` come from
   `${{crewtavo.APP_URL}}`, which is the staging domain.
8. **Verify isolation before the first deploy** (migrations run on start): open each staged
   variable list and confirm there is **no literal production hostname, password or domain**. Then
   **Deploy** the staged changes.
9. After deploy: open `https://<staging-domain>/api/setup`, which should show `"ready":true` with
   `needsOwner`. Create the owner account with a fictional/test identity, then check:
   `/api/health` answers `{"ok":true,...}`, the sidebar shows **Planet Ops**, sign-in works, one
   fictional client/request can be created, and one photo upload succeeds.
10. Create the permission test accounts listed in [PERMISSIONS.md](PERMISSIONS.md).
11. Save staging's `JWT_SECRET` and `POSTGRES_PASSWORD` in your password manager, separately from
    production's.

Mark test records as fictional (for example, client names starting with `TEST –`). Phase 4 adds a
separate **test Google Drive root**. Do not connect staging to the real PDOS folders.

If the account's plan can't run a second environment, use the local stack instead (`npm run
instance`, docker compose) until staging is available. Never use the production database as the
substitute.

## 3. Backup and restore before any production migration

Phase 0 adds no migration. Before the first phase that does reaches production: confirm a recent
good nightly backup under Settings → Your data, a Railway volume backup (Pro), saved secrets, and a
rehearsed restore into staging ([docs/deploy.md](../deploy.md#restoring-a-backup)).

## 4. Fork CI (GitHub Actions)

Actions is enabled in the fork. At the owner's request, the upstream-only restrictions are removed
and every build and test check is kept:

- **`ci.yml`**: runs on every pull request (including those into `planet-ops-staging`) and on pushes
  to `main` and `planet-ops-staging`. Jobs: `check` (typecheck, unit tests, `test:db`, server build),
  `upgrade`, `instance` (the whole Docker stack) and `browser` (lifecycle and Playwright tests).
  Upstream's **Authorship** step was removed. It required every commit to be by upstream's owner with
  no co-authors.
- **`upgrade` job**: the fork has no release tags, so it fetches upstream's `v*` tags (the releases a
  production instance runs) and checks the upgrade from the latest one behind HEAD. On a pull
  request it also checks the upgrade from the PR's base commit.
- **`close-pull-requests.yml`**: removed. It closed every PR not opened by the repository owner.
- **PR template**: replaced upstream's "contributions not accepted" text with a Planet Ops checklist.
- **`release.yml`**: unchanged. Pushing a `v*` tag would publish images to the fork's own GHCR
  namespace, so don't push version tags unless you intend to. LICENSE, NOTICE and TERMS are unchanged.
