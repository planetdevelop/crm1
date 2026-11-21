/**
 * Planet Ops Phase 4: Settings → PDOS Drive backup. The Drive folder ids the backup writes to (Jobs
 * Bid, Jobs Awarded, PDOS / Media), switching it on (owners and admins), and what's backed up, waiting
 * or failed, with a retry. The server also needs its Drive credentials (docs/planet-ops/PDOS_DRIVE_RUNBOOK.md).
 */
import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import { useEffect, useState } from "react";
import { Button } from "@/components/ui/Button";
import { Field, FormError } from "@/components/ui/Field";
import { supabase, unwrap } from "@/lib/api";
import { formatDateTime } from "@/lib/format";
import { useSession } from "@/lib/session";
import { toast } from "@/lib/toast";

interface Pdos { enabled?: boolean; jobs_bid_folder_id?: string; jobs_awarded_folder_id?: string; media_folder_id?: string }
interface Status { configured: boolean; files: Record<string, number> | null; held: number; folders: Record<string, number> | null; last_backed_up_at: string | null; failures: Array<{ kind: string; id: string; name: string; error: string; attempts: number; next: string }> }

export function PdosSettings() {
  const { company, role } = useSession();
  const isAdmin = role === "owner" || role === "admin";
  const queryClient = useQueryClient();
  const settings = useQuery({ queryKey: ["company", company.id, "pdos"], queryFn: async () => unwrap(await supabase().from("companies").select("settings").eq("id", company.id).single()) });
  const status = useQuery({ queryKey: ["pdos-status", company.id], queryFn: async () => unwrap(await supabase().rpc("pdos_status" as never, { p_company: company.id } as never)) as unknown as Status });
  const [f, setF] = useState<Pdos>({});
  useEffect(() => setF(((settings.data?.settings ?? {}) as { pdos?: Pdos }).pdos ?? {}), [settings.data]);
  const save = useMutation({
    mutationFn: async () => unwrap(await supabase().rpc("merge_company_settings", { p_company: company.id, p_settings: { pdos: f } as never })),
    onSuccess: () => { toast.success("Saved"); queryClient.invalidateQueries({ queryKey: ["company", company.id, "pdos"] }); queryClient.invalidateQueries({ queryKey: ["pdos-status"] }); },
  });
  const retry = useMutation({
    mutationFn: async () => unwrap(await supabase().rpc("pdos_retry" as never, { p_company: company.id } as never)) as unknown as number,
    onSuccess: (n) => { toast.success(`${n} queued to try again now`); queryClient.invalidateQueries({ queryKey: ["pdos-status"] }); },
  });
  const s = status.data;
  const ready = f.jobs_bid_folder_id && f.jobs_awarded_folder_id && f.media_folder_id;
  return (
    <div className="stack-lg" data-planet-ops="pdos-settings">
      <section className="card card-pad stack">
        <strong>PDOS Drive folders</strong>
        <span className="muted small">
          Google Drive is the official PDOS record; the app keeps its own copy first and copies to Drive in the background. Before a job exists, an estimate's summary goes into Jobs Bid as one
          file (no folder). Only Create Job or converting a signed agreement makes a job's folder in Jobs Awarded, named "{"{Project address} - {Project type} - {Year}"}", with Documents & Permits,
          Reciepts and Dump Tickets, and its folder in PDOS / Media. Paste each folder's id from its Drive address (the part after /folders/).
        </span>
        <Field label="Jobs Bid folder id"><input className="input" value={f.jobs_bid_folder_id ?? ""} disabled={!isAdmin} onChange={(e) => setF({ ...f, jobs_bid_folder_id: e.target.value.trim() })} /></Field>
        <Field label="Jobs Awarded folder id"><input className="input" value={f.jobs_awarded_folder_id ?? ""} disabled={!isAdmin} onChange={(e) => setF({ ...f, jobs_awarded_folder_id: e.target.value.trim() })} /></Field>
        <Field label="PDOS / Media folder id"><input className="input" value={f.media_folder_id ?? ""} disabled={!isAdmin} onChange={(e) => setF({ ...f, media_folder_id: e.target.value.trim() })} /></Field>
        <label className="switch-row" style={{ fontWeight: 400 }}>
          <input type="checkbox" className="switch" checked={Boolean(f.enabled)} disabled={!isAdmin || !ready} onChange={(e) => setF({ ...f, enabled: e.target.checked })} />
          Back up to Drive (needs the three folders, and the server's Drive credentials)
        </label>
        <FormError error={save.error} />
        {isAdmin && <Button variant="primary" loading={save.isPending} onClick={() => save.mutate()} style={{ justifySelf: "start" }}>Save</Button>}
      </section>
      <section className="card card-pad stack" aria-label="Backup status">
        <strong>Backup status</strong>
        {s && (
          <dl className="kv">
            <dt>Switched on</dt><dd>{s.configured ? "Yes" : "No: files wait, kept in the app"}</dd>
            <dt>Files</dt><dd>{Object.entries(s.files ?? {}).map(([k, v]) => `${v} ${k.replace("_", " ")}`).join(", ") || "None yet"}{s.held ? `; ${s.held} waiting for a job` : ""}</dd>
            <dt>Job folders</dt><dd>{Object.entries(s.folders ?? {}).map(([k, v]) => `${v} ${k.replace("_", " ")}`).join(", ") || "None yet"}</dd>
            <dt>Last backed up</dt><dd>{s.last_backed_up_at ? formatDateTime(s.last_backed_up_at) : "Never"}</dd>
          </dl>
        )}
        {s && s.failures.length > 0 && (
          <table className="table table-stack" aria-label="Failed backups">
            <thead><tr><th>What</th><th>Error</th><th>Tries</th><th>Next try</th></tr></thead>
            <tbody>{s.failures.map((x) => <tr key={x.kind + x.id}><td>{x.kind === "folder" ? "Folder " : ""}{x.name}</td><td className="small">{x.error}</td><td>{x.attempts}</td><td>{formatDateTime(x.next)}</td></tr>)}</tbody>
          </table>
        )}
        <FormError error={retry.error} />
        {isAdmin && <Button loading={retry.isPending} onClick={() => retry.mutate()} style={{ justifySelf: "start" }}>Retry failed and waiting now</Button>}
      </section>
    </div>
  );
}
