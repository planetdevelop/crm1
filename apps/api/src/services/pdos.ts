/**
 * Planet Ops Phase 4: the PDOS Google Drive record (docs/PLANET_OPS_IMPLEMENTATION_PLAN.md §6,
 * docs/planet-ops/PDOS_DRIVE_RUNBOOK.md). The app keeps its own copy first; this worker mirrors it to
 * Drive, which is the official record:
 *
 *   folders  for each job the database says needs them (job_folder_provisioning: made only by Create
 *            Job or a signed conversion), Jobs Awarded / {name} with Documents & Permits, Reciepts and
 *            Dump Tickets, and PDOS / Media / {name}. Every Drive object it makes carries the job's id
 *            (appProperties.planetOpsJob), so a retry after a timeout finds what it made instead of
 *            making it twice; each step's id is saved as soon as it exists (pdos_folder_progress).
 *   files    each queued file (pdos_files) to its destination: Jobs Bid before a job, the job's folders
 *            after. A file already copied is updated and, if its destination changed (a bid summary
 *            once the job exists), moved, keeping its Drive id. Each carries appProperties.planetOpsSource.
 *
 * Nothing runs unless the company has PDOS set up (settings.pdos.enabled and its folder ids) and the
 * server has Drive credentials (PDOS_GOOGLE_CLIENT_ID / _SECRET / _REFRESH_TOKEN). Tests run it against
 * FakeDrive (apps/api/test/pdos.test.ts).
 */

export interface DriveApi {
  /** A file or folder carrying this appProperty (optionally under a parent), or null. */
  findByProperty(key: string, value: string, parent?: string): Promise<{ id: string; parents: string[] } | null>;
  /** A folder of this name directly under parent, or null. */
  findChildFolder(name: string, parent: string): Promise<string | null>;
  createFolder(name: string, parent: string, properties: Record<string, string>): Promise<string>;
  upload(name: string, parent: string, mime: string, body: Uint8Array, properties: Record<string, string>): Promise<string>;
  update(fileId: string, name: string, mime: string, body: Uint8Array): Promise<void>;
  move(fileId: string, fromParent: string | null, toParent: string): Promise<void>;
}

export interface PdosConfig {
  jobs_bid_folder_id: string;
  jobs_awarded_folder_id: string;
  media_folder_id: string;
}

export interface FolderClaim {
  job_id: string;
  company_id: string;
  folder_name: string;
  steps: Record<string, string>;
}

export interface FileClaim {
  id: string;
  company_id: string;
  source_kind: string;
  source_id: string;
  job_id: string | null;
  destination: "jobs_bid" | "job_root" | "job_documents" | "job_receipts" | "job_dump_tickets" | "media" | "held";
  file_name: string;
  version: number;
  drive_file_id: string | null;
  drive_parent_id: string | null;
  folders: Record<string, string> | null;
}

/** The database side (supabase/migrations/20261127000100_planet_ops_job_costs.sql). */
export interface PdosStore {
  claim(limit: number): Promise<{ folders: FolderClaim[]; files: FileClaim[] }>;
  folderProgress(jobId: string, steps: Record<string, string>, done: boolean, error?: string): Promise<void>;
  fileResult(id: string, version: number, driveFileId: string | null, parent: string | null, error?: string): Promise<void>;
  config(companyId: string): Promise<PdosConfig | null>;
  /** The file's current content (the app's copy). */
  content(file: FileClaim): Promise<{ mime: string; body: Uint8Array }>;
}

export const SUBFOLDERS = { documents: "Documents & Permits", receipts: "Reciepts", dump_tickets: "Dump Tickets" } as const;

const reason = (error: unknown) => (error instanceof Error ? error.message : String(error)).slice(0, 900);

/** Makes (or finds) a job's folder set, saving each id as soon as it exists. */
export async function provisionFolders(drive: DriveApi, store: PdosStore, cfg: PdosConfig, claim: FolderClaim): Promise<Record<string, string>> {
  const steps: Record<string, string> = { ...claim.steps };
  const save = async (key: string, id: string) => {
    steps[key] = id;
    await store.folderProgress(claim.job_id, { [key]: id }, false);
  };
  const props = { planetOpsJob: claim.job_id };
  if (!steps.folder) {
    const found = await drive.findByProperty("planetOpsJob", claim.job_id, cfg.jobs_awarded_folder_id);
    await save("folder", found?.id ?? (await drive.createFolder(claim.folder_name, cfg.jobs_awarded_folder_id, props)));
  }
  for (const [key, name] of Object.entries(SUBFOLDERS)) {
    if (steps[key]) continue;
    const found = await drive.findChildFolder(name, steps.folder!);
    await save(key, found ?? (await drive.createFolder(name, steps.folder!, props)));
  }
  if (!steps.media) {
    const found = await drive.findByProperty("planetOpsJob", claim.job_id, cfg.media_folder_id);
    await save("media", found?.id ?? (await drive.createFolder(claim.folder_name, cfg.media_folder_id, props)));
  }
  return steps;
}

/** Where a claimed file goes: its folder's Drive id. */
export function parentFor(file: FileClaim, cfg: PdosConfig): string | null {
  const f = file.folders ?? {};
  switch (file.destination) {
    case "jobs_bid": return cfg.jobs_bid_folder_id;
    case "job_root": return f.folder ?? null;
    case "job_documents": return f.documents ?? null;
    case "job_receipts": return f.receipts ?? null;
    case "job_dump_tickets": return f.dump_tickets ?? null;
    case "media": return f.media ?? null;
    default: return null;
  }
}

/** Copies one file to its destination: updates (and moves) the copy it already has, or finds or uploads one. */
export async function copyFile(drive: DriveApi, store: PdosStore, cfg: PdosConfig, file: FileClaim): Promise<{ id: string; parent: string }> {
  const parent = parentFor(file, cfg);
  if (!parent) throw new Error(`No Drive folder for ${file.destination} yet`);
  const { mime, body } = await store.content(file);
  let id = file.drive_file_id;
  let currentParent = file.drive_parent_id;
  if (!id) {
    const found = await drive.findByProperty("planetOpsSource", file.source_id);
    if (found) {
      id = found.id;
      currentParent = found.parents[0] ?? null;
    }
  }
  if (id) {
    await drive.update(id, file.file_name, mime, body);
    if (currentParent !== parent) await drive.move(id, currentParent, parent);
  } else {
    id = await drive.upload(file.file_name, parent, mime, body, { planetOpsSource: file.source_id, planetOpsKind: file.source_kind });
  }
  return { id, parent };
}

/** One pass: claims due work, makes folders, copies files; each failure is recorded for a later retry. */
export async function runPdos(store: PdosStore, driveFor: (companyId: string) => Promise<DriveApi | null>, limit = 20) {
  const { folders, files } = await store.claim(limit);
  const result = { folders: 0, files: 0, failed: 0, skipped: 0 };
  const setup = new Map<string, { cfg: PdosConfig; drive: DriveApi } | null>();
  const ready = async (companyId: string) => {
    if (!setup.has(companyId)) {
      const [cfg, drive] = await Promise.all([store.config(companyId), driveFor(companyId)]);
      setup.set(companyId, cfg && drive ? { cfg, drive } : null);
    }
    return setup.get(companyId)!;
  };
  for (const claim of folders) {
    const s = await ready(claim.company_id);
    if (!s) {
      await store.folderProgress(claim.job_id, {}, false, "PDOS Drive isn't set up for this business yet");
      result.skipped++;
      continue;
    }
    try {
      await provisionFolders(s.drive, store, s.cfg, claim);
      await store.folderProgress(claim.job_id, {}, true);
      result.folders++;
    } catch (error) {
      await store.folderProgress(claim.job_id, {}, false, reason(error));
      result.failed++;
    }
  }
  for (const file of files) {
    const s = await ready(file.company_id);
    if (!s) {
      await store.fileResult(file.id, file.version, null, null, "PDOS Drive isn't set up for this business yet");
      result.skipped++;
      continue;
    }
    try {
      const { id, parent } = await copyFile(s.drive, store, s.cfg, file);
      await store.fileResult(file.id, file.version, id, parent);
      result.files++;
    } catch (error) {
      await store.fileResult(file.id, file.version, null, null, reason(error));
      result.failed++;
    }
  }
  return result;
}

/** An in-memory Drive for tests and dry runs, with failures to inject. */
export class FakeDrive implements DriveApi {
  items = new Map<string, { id: string; name: string; parents: string[]; folder: boolean; properties: Record<string, string>; body?: Uint8Array; updates: number }>();
  private next = 1;
  /** Calls (by method name) that fail once, in order: e.g. ["createFolder:2"] fails the 2nd createFolder. */
  failures = new Set<string>();
  calls: Record<string, number> = {};

  private tick(method: string) {
    const n = (this.calls[method] = (this.calls[method] ?? 0) + 1);
    if (this.failures.has(`${method}:${n}`)) throw new Error(`Drive: 503 backend error (${method} #${n})`);
  }
  root(name: string) {
    const id = `root-${this.next++}`;
    this.items.set(id, { id, name, parents: [], folder: true, properties: {}, updates: 0 });
    return id;
  }
  async findByProperty(key: string, value: string, parent?: string) {
    this.tick("findByProperty");
    for (const item of this.items.values()) if (item.properties[key] === value && (!parent || item.parents.includes(parent))) return { id: item.id, parents: item.parents };
    return null;
  }
  async findChildFolder(name: string, parent: string) {
    this.tick("findChildFolder");
    for (const item of this.items.values()) if (item.folder && item.name === name && item.parents.includes(parent)) return item.id;
    return null;
  }
  async createFolder(name: string, parent: string, properties: Record<string, string>) {
    this.tick("createFolder");
    const id = `f-${this.next++}`;
    this.items.set(id, { id, name, parents: [parent], folder: true, properties, updates: 0 });
    return id;
  }
  async upload(name: string, parent: string, _mime: string, body: Uint8Array, properties: Record<string, string>) {
    this.tick("upload");
    const id = `d-${this.next++}`;
    this.items.set(id, { id, name, parents: [parent], folder: false, properties, body, updates: 0 });
    return id;
  }
  async update(fileId: string, name: string, _mime: string, body: Uint8Array) {
    this.tick("update");
    const item = this.items.get(fileId);
    if (!item) throw new Error(`Drive: file ${fileId} not found`);
    Object.assign(item, { name, body, updates: item.updates + 1 });
  }
  async move(fileId: string, fromParent: string | null, toParent: string) {
    this.tick("move");
    const item = this.items.get(fileId);
    if (!item) throw new Error(`Drive: file ${fileId} not found`);
    item.parents = [...item.parents.filter((p) => p !== fromParent), toParent].filter((p, i, a) => a.indexOf(p) === i);
    if (fromParent === null) item.parents = [toParent];
  }
  /** Names under a folder (for assertions). */
  childrenOf(parent: string) {
    return [...this.items.values()].filter((i) => i.parents.includes(parent)).map((i) => i.name).sort();
  }
}

/** Google Drive v3 with an OAuth refresh token (the PDOS owner's or a dedicated account's). */
export class GoogleDrive implements DriveApi {
  private token: { value: string; until: number } | null = null;
  constructor(private creds: { clientId: string; clientSecret: string; refreshToken: string }, private fetcher: typeof fetch = fetch) {}

  private async auth(): Promise<string> {
    if (this.token && this.token.until > Date.now() + 60_000) return this.token.value;
    const response = await this.fetcher("https://oauth2.googleapis.com/token", {
      method: "POST",
      headers: { "content-type": "application/x-www-form-urlencoded" },
      body: new URLSearchParams({ client_id: this.creds.clientId, client_secret: this.creds.clientSecret, refresh_token: this.creds.refreshToken, grant_type: "refresh_token" }),
      signal: AbortSignal.timeout(20_000),
    });
    if (!response.ok) throw new Error(`Google sign-in for PDOS failed (${response.status})`);
    const body = (await response.json()) as { access_token: string; expires_in: number };
    this.token = { value: body.access_token, until: Date.now() + body.expires_in * 1000 };
    return body.access_token;
  }
  private async call<T>(url: string, init: RequestInit = {}): Promise<T> {
    const response = await this.fetcher(url, { ...init, headers: { authorization: `Bearer ${await this.auth()}`, ...(init.headers ?? {}) }, signal: AbortSignal.timeout(60_000) });
    if (!response.ok) throw new Error(`Drive: ${response.status} ${(await response.text()).slice(0, 300)}`);
    return (response.status === 204 ? undefined : await response.json()) as T;
  }
  private static q(value: string) {
    return value.replace(/\\/g, "\\\\").replace(/'/g, "\\'");
  }
  async findByProperty(key: string, value: string, parent?: string) {
    const q = `appProperties has { key='${GoogleDrive.q(key)}' and value='${GoogleDrive.q(value)}' } and trashed = false${parent ? ` and '${GoogleDrive.q(parent)}' in parents` : ""}`;
    const r = await this.call<{ files: Array<{ id: string; parents?: string[] }> }>(`https://www.googleapis.com/drive/v3/files?${new URLSearchParams({ q, fields: "files(id,parents)", supportsAllDrives: "true", includeItemsFromAllDrives: "true" })}`);
    const f = r.files[0];
    return f ? { id: f.id, parents: f.parents ?? [] } : null;
  }
  async findChildFolder(name: string, parent: string) {
    const q = `name = '${GoogleDrive.q(name)}' and '${GoogleDrive.q(parent)}' in parents and mimeType = 'application/vnd.google-apps.folder' and trashed = false`;
    const r = await this.call<{ files: Array<{ id: string }> }>(`https://www.googleapis.com/drive/v3/files?${new URLSearchParams({ q, fields: "files(id)", supportsAllDrives: "true", includeItemsFromAllDrives: "true" })}`);
    return r.files[0]?.id ?? null;
  }
  async createFolder(name: string, parent: string, properties: Record<string, string>) {
    const r = await this.call<{ id: string }>("https://www.googleapis.com/drive/v3/files?supportsAllDrives=true", {
      method: "POST", headers: { "content-type": "application/json" },
      body: JSON.stringify({ name, parents: [parent], mimeType: "application/vnd.google-apps.folder", appProperties: properties }),
    });
    return r.id;
  }
  private static multipart(meta: object, mime: string, body: Uint8Array) {
    const boundary = `pdos${Math.random().toString(36).slice(2)}`;
    const head = new TextEncoder().encode(`--${boundary}\r\ncontent-type: application/json\r\n\r\n${JSON.stringify(meta)}\r\n--${boundary}\r\ncontent-type: ${mime}\r\n\r\n`);
    const tail = new TextEncoder().encode(`\r\n--${boundary}--`);
    const all = new Uint8Array(head.length + body.length + tail.length);
    all.set(head, 0); all.set(body, head.length); all.set(tail, head.length + body.length);
    return { all, type: `multipart/related; boundary=${boundary}` };
  }
  async upload(name: string, parent: string, mime: string, body: Uint8Array, properties: Record<string, string>) {
    const { all, type } = GoogleDrive.multipart({ name, parents: [parent], appProperties: properties }, mime, body);
    const r = await this.call<{ id: string }>("https://www.googleapis.com/upload/drive/v3/files?uploadType=multipart&supportsAllDrives=true", { method: "POST", headers: { "content-type": type }, body: all });
    return r.id;
  }
  async update(fileId: string, name: string, mime: string, body: Uint8Array) {
    const { all, type } = GoogleDrive.multipart({ name }, mime, body);
    await this.call(`https://www.googleapis.com/upload/drive/v3/files/${encodeURIComponent(fileId)}?uploadType=multipart&supportsAllDrives=true`, { method: "PATCH", headers: { "content-type": type }, body: all });
  }
  async move(fileId: string, fromParent: string | null, toParent: string) {
    const params = new URLSearchParams({ addParents: toParent, supportsAllDrives: "true" });
    if (fromParent) params.set("removeParents", fromParent);
    await this.call(`https://www.googleapis.com/drive/v3/files/${encodeURIComponent(fileId)}?${params}`, { method: "PATCH", headers: { "content-type": "application/json" }, body: "{}" });
  }
}
