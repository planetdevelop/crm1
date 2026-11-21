# PDOS Google Drive backup: setup, checks and recovery

Phase 4 mirrors the app's own copy of each file to the PDOS Google Drive, the official record. It
runs only when the owner sets it up below; until then every file stays in the app and waits (it is
never lost). Code: `apps/api/src/services/pdos.ts` (worker), `pdosStore.ts` (database and storage),
`supabase/migrations/20261127000100_planet_ops_job_costs.sql` (queue and folder records).

## What it does

| Record | Drive destination | When |
| --- | --- | --- |
| Estimate Summary, before a job (also lost and unanswered bids) | One standalone file directly in **Jobs Bid** (no folder) | When the estimate is made; updated as it changes |
| Job folder | **Jobs Awarded / {Project address} - {Project type} - {Year}** with **Documents & Permits**, **Reciepts**, **Dump Tickets** | Only after Create Job or converting a signed agreement succeeds |
| Media folder | **PDOS / Media / {the same name}** | With the job folder |
| The Estimate Summary, once its job exists | Moved into the job's Documents & Permits (same Drive file id) | After the job's folders exist |
| Receipts, supplier invoices | Job folder / Reciepts | Once the document has a job |
| Dump tickets | Job folder / Dump Tickets | Once it has a job |
| Job photos uploaded as cost documents | PDOS / Media / {job folder name} | Once it has a job |
| Files with no job yet | Held in the app (nothing in Drive) | Until a job is chosen |

Naming: the property's first address line, the estimate's project type (else the job title), the
job's creation year; characters Drive or the index can't take become spaces. Another job with the
same name gets " - Job {number}" on the end (never merged). The existing **Reciepts** spelling is kept.

Every Drive object the worker makes carries an `appProperties` tag (`planetOpsJob` = job id on
folders, `planetOpsSource` = the app record's id on files), so a retry after a timeout finds what it
made instead of making it twice. Each folder id is saved as soon as it exists, so a partial failure
resumes the same folder set. Failures retry after 1, 5 and 30 minutes, then hourly.

## Setup (owner, once; in staging first)

1. **Choose the Google account** that owns the PDOS folders (or a dedicated one with edit access to
   them). Confirm the three folders exist: **Jobs Bid**, **Jobs Awarded**, **Operating System
   (PDOS) / Media**. Do not reorganize legacy folders.
2. **Google Cloud**: in the project used for the app's Google sign-in (or a new one), enable the
   **Google Drive API**; create an **OAuth client** (Web application). Add the redirect URI you use to
   get the refresh token (e.g. the OAuth Playground, `https://developers.google.com/oauthplayground`).
3. **Refresh token**: sign in as the account from step 1 with scope
   `https://www.googleapis.com/auth/drive` (needed to move existing files and write into folders the
   app didn't create), request offline access, and copy the refresh token. Keep it out of the
   repository and chat.
4. **Railway (staging service only)**: set `PDOS_GOOGLE_CLIENT_ID`, `PDOS_GOOGLE_CLIENT_SECRET`,
   `PDOS_GOOGLE_REFRESH_TOKEN`. Use **test folders** first (copies named e.g. "TEST Jobs Bid"), not
   the real PDOS folders.
5. **Settings → PDOS Drive backup** (owner or admin): paste each folder's id (the part of its Drive
   address after `/folders/`), switch **Back up to Drive** on, Save.

## Staging test (fictional records only)

1. Start an estimate for a fictional request: within a few minutes Settings → PDOS Drive backup shows
   1 backed up; the test Jobs Bid has one HTML file named like the estimate's summary. No folder.
2. Mark a second fictional bid Lost: its summary stays in Jobs Bid.
3. Approve, make a proposal, sign it (in person, fictional), convert: the test Jobs Awarded gets one
   folder with the three subfolders, Media gets its folder, and the summary moves into Documents &
   Permits (same file: its Drive "Activity" shows a move, not a new file).
4. Convert again (or click twice): still one folder.
5. Upload a fictional receipt and a dump ticket on the job: they appear in Reciepts and Dump Tickets.
6. Failure drill: temporarily set a wrong folder id, upload a file: the status screen shows it failed
   with Drive's error; restore the id, press **Retry failed and waiting now**: it backs up once.

## Recovery

- **Status**: Settings → PDOS Drive backup lists counts, the last backup time and each failure with
  its error and next try. `pdos_files` / `job_folder_provisioning` hold the same in the database.
- **Credentials expired or revoked**: everything fails with "Google sign-in for PDOS failed"; get a
  new refresh token (step 3), update the Railway variable, press Retry. Nothing is lost meanwhile.
- **A folder deleted in Drive by hand**: clear its ids (`job_folder_provisioning.steps`, `folder_id`,
  `media_folder_id`) and set status `pending` for that job; the worker finds or remakes it. Files
  whose parent is gone: set their `status` to `pending` and `drive_file_id` to null to upload again.
- **Duplicates suspected**: search Drive for `appProperties has { key='planetOpsJob' and value='<job id>' }`
  (Drive API) to list every object the app made for a job.
- **Turning it off**: switch Back up to Drive off (files keep queuing and wait). Deleting in the app
  never deletes in Drive (archive and audit instead).
- The Drive copy is not a database backup: keep Railway's database backups as configured separately.

## Not done here

- No live connection was made from development (no credentials). The worker is tested against an
  in-memory Drive (`apps/api/test/pdos.test.ts`); the queue and naming in the database tests.
- Two-way sync, importing files added in Drive by hand, moving a completed job to **Completed Jobs**,
  the Master Job Index and pre-job/closeout records are later steps (Phase 8 closeout, Phase 9).
