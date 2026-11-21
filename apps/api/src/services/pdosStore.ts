/**
 * Planet Ops Phase 4: the database and storage side of the PDOS Drive worker (services/pdos.ts), and
 * its scheduled task (tasks.ts "pdos").
 */
import type { Env } from "../env";
import { adminClient } from "../lib/supabase";
import { GoogleDrive, runPdos, type PdosConfig, type PdosStore } from "./pdos";

type Admin = ReturnType<typeof adminClient>;
// eslint-disable-next-line @typescript-eslint/no-explicit-any
type Loose = Record<string, any>;

const ENTITIES: Record<string, string> = { "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;" };
const escape = (s: unknown) => String(s ?? "").replace(/[&<>"]/g, (c) => ENTITIES[c]!);
const money = (n: unknown) => (n === null || n === undefined ? "—" : `$${Number(n).toFixed(2)}`);

/** The Estimate Summary as a standalone, private HTML file (internal: costs included). */
export function summaryHtml(s: Loose): string {
  const v: Loose = s.version ?? {};
  const rows = ((v.lines ?? []) as Loose[])
    .map((l) => `<tr><td>${escape(l.section)}</td><td>${escape(l.name)}</td><td>${escape(l.count ?? "")} ${escape(l.unit)}</td><td>${money(l.unit_cost)}</td><td>${money(l.price)}</td></tr>`)
    .join("");
  const versions = ((s.versions ?? []) as Loose[])
    .map((x) => `<li>v${escape(x.number)} ${escape(x.status)}${x.baseline ? " (original baseline)" : ""}: ${money(x.selling_price)} ${escape(x.revision_reason ?? "")}</li>`)
    .join("");
  const docs = ((s.documents ?? []) as Loose[])
    .map((d) => {
      const sent = ((d.sent ?? []) as Loose[]).map((x) => `${money(x.total)} (estimate v${escape(x.estimate_version)})`).join(", ") || "not sent";
      return `<li>${escape(d.presentation)} #${escape(d.number)} (${escape(d.status)}): sent ${sent}; accepted ${d.accepted ? money(d.accepted.total) : "no"}</li>`;
    })
    .join("");
  return [
    `<!doctype html><meta charset="utf-8"><title>${escape(s.summary?.title)}</title>`,
    `<h1>${escape(s.summary?.title)}</h1><p>INTERNAL: private estimating record. Not for customers.</p>`,
    `<p>Customer: ${escape(s.customer?.name)} · Property: ${escape(s.property?.line1)} ${escape(s.property?.city)} · Request: ${escape(s.request?.number)} ${escape(s.request?.title)} · Outcome: ${escape(s.request?.stage)} ${escape(s.request?.outcome_reason ?? "")}</p>`,
    `<h2>Version ${escape(v.number)} (${escape(v.status)})</h2><table border="1" cellpadding="4"><tr><th>Section</th><th>Line</th><th>Quantity</th><th>Unit cost</th><th>Selling share</th></tr>${rows}</table>`,
    `<p>Base cost ${money(v.totals?.base_cost)} · Calculated selling price ${money(v.totals?.selling_price)} (calculated; not a price sent)</p>`,
    `<h2>Versions</h2><ul>${versions}</ul><h2>Prices sent and accepted</h2><ul>${docs || "<li>None</li>"}</ul>`,
  ].join("\n");
}

export function supabaseStore(admin: Admin): PdosStore {
  const call = async <T>(fn: string, args: Record<string, unknown>): Promise<T> => {
    const r = await admin.rpc(fn as never, args as never);
    if (r.error) throw new Error(`${fn}: ${r.error.message}`);
    return r.data as T;
  };
  return {
    claim: (limit) => call("pdos_claim", { p_limit: limit }),
    folderProgress: (job, steps, done, error) => call("pdos_folder_progress", { p_job: job, p_steps: steps, p_done: done, p_error: error ?? null }),
    fileResult: (id, version, fileId, parent, error) => call("pdos_file_result", { p_id: id, p_version: version, p_drive_file_id: fileId, p_parent: parent, p_error: error ?? null }),
    async config(companyId) {
      const r = await admin.from("companies").select("settings").eq("id", companyId).single();
      const p = ((r.data?.settings ?? {}) as { pdos?: Partial<PdosConfig> & { enabled?: boolean } }).pdos;
      return p?.enabled && p.jobs_bid_folder_id && p.jobs_awarded_folder_id && p.media_folder_id
        ? { jobs_bid_folder_id: p.jobs_bid_folder_id, jobs_awarded_folder_id: p.jobs_awarded_folder_id, media_folder_id: p.media_folder_id }
        : null;
    },
    async content(file) {
      if (file.source_kind === "estimate_summary") {
        const s = await admin.from("estimate_summaries").select("estimate_id").eq("id", file.source_id).single();
        if (s.error) throw new Error(s.error.message);
        const body = await call<Loose>("estimate_summary", { p_estimate: s.data.estimate_id });
        return { mime: "text/html", body: new TextEncoder().encode(summaryHtml(body)) };
      }
      if (file.source_kind === "cost_document") {
        const d = await admin.from("cost_documents").select("storage_path").eq("id", file.source_id).single();
        if (d.error) throw new Error(d.error.message);
        const blob = await admin.storage.from("files").download(d.data.storage_path);
        if (blob.error) throw new Error(`storage: ${blob.error.message}`);
        return { mime: blob.data.type || "application/octet-stream", body: new Uint8Array(await blob.data.arrayBuffer()) };
      }
      throw new Error(`No copy for ${file.source_kind} yet`);
    },
  };
}

/** The scheduled task: one pass, only when the server has PDOS Drive credentials. */
export async function pdosBackup(env: Env) {
  if (!env.PDOS_GOOGLE_CLIENT_ID || !env.PDOS_GOOGLE_CLIENT_SECRET || !env.PDOS_GOOGLE_REFRESH_TOKEN) return { skipped: "PDOS Drive credentials aren't set" };
  const drive = new GoogleDrive({ clientId: env.PDOS_GOOGLE_CLIENT_ID, clientSecret: env.PDOS_GOOGLE_CLIENT_SECRET, refreshToken: env.PDOS_GOOGLE_REFRESH_TOKEN });
  return runPdos(supabaseStore(adminClient(env)), async () => drive);
}
