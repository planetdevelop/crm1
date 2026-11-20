/**
 * Planet Ops Phase 1c: a customer document's versions and its customer's change requests, on the
 * quote page.
 *
 *   - Versions: each one issued to the customer (sent, sent again with changes, its exact price sent,
 *     or signed in person), kept as issued (public.quote_versions), in sequence: superseded, current
 *     or signed. "View" shows what was issued, from that version's own copy.
 *   - A draft revision: the document changed since the version the customer has, and nothing went
 *     out. The customer's link keeps the version they have, and it can't be signed until it's sent.
 *   - Change requests (public.quote_change_requests): the customer's note as typed, when, on which
 *     version, the office's reply, and its follow-up task. Sending the document again answers them.
 */
import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import { useState, type FormEvent } from "react";
import { Button } from "@/components/ui/Button";
import { Dialog } from "@/components/ui/Dialog";
import { FormError } from "@/components/ui/Field";
import { Icon } from "@/components/ui/Icon";
import { supabase, unwrap } from "@/lib/api";
import { formatDate, formatDateTime, formatMoneyCents } from "@/lib/format";
import { useSession } from "@/lib/session";

interface VersionRow {
  id: string;
  number: number;
  fingerprint: string;
  issued_at: string;
  issued_by: string | null;
  issued_via: string;
  superseded_at: string | null;
  signed_at: string | null;
  total: number | null;
  presentation: string | null;
  document: unknown;
}

interface RequestRow {
  id: string;
  message: string;
  created_at: string;
  version_number: number | null;
  identity: { link?: string } | null;
  signed_agreement: boolean;
  proposed_change_order_id: string | null;
  response: string | null;
  responded_at: string | null;
  responded_by: string | null;
  resolved_at: string | null;
}

interface TaskRow {
  id: string;
  source_id: string;
  assigned_to: string | null;
  title: string;
  done_at: string | null;
}

const VIA: Record<string, string> = { sent: "Sent", in_person: "Signed in person", site_price: "Priced on site", existing: "Sent (before versions were kept)" };

export const versionsKey = (quoteId: string) => ["quote-versions", quoteId] as const;

export function VersionsCard({ quoteId, status, canSell, onResend }: { quoteId: string; status: string; canSell: boolean; onResend: () => void }) {
  const { company } = useSession();
  const queryClient = useQueryClient();
  const data = useQuery({
    queryKey: versionsKey(quoteId),
    queryFn: async () => {
      const [versions, requests, tasks, live] = await Promise.all([
        supabase().from("quote_versions").select("id, number, fingerprint, issued_at, issued_by, issued_via, superseded_at, signed_at, total, presentation, document").eq("company_id", company.id).eq("quote_id", quoteId).order("number", { ascending: false }),
        supabase().from("quote_change_requests").select("id, message, created_at, version_number, identity, signed_agreement, proposed_change_order_id, response, responded_at, responded_by, resolved_at").eq("company_id", company.id).eq("quote_id", quoteId).order("created_at", { ascending: false }),
        supabase().from("follow_up_tasks").select("id, source_id, assigned_to, title, done_at").eq("company_id", company.id).eq("related_type", "quote").eq("related_id", quoteId),
        supabase().rpc("quote_fingerprint", { p_quote: quoteId }),
      ]);
      const v = unwrap(versions) as unknown as VersionRow[];
      const r = unwrap(requests) as unknown as RequestRow[];
      const t = unwrap(tasks) as unknown as TaskRow[];
      const ids = [...new Set([...v.map((x) => x.issued_by), ...r.map((x) => x.responded_by), ...t.map((x) => x.assigned_to)].filter((x): x is string => Boolean(x)))];
      const people = ids.length ? unwrap(await supabase().from("profiles").select("user_id, full_name").in("user_id", ids)) : [];
      return { versions: v, requests: r, tasks: t, live: typeof live.data === "string" ? live.data : null, names: new Map(people.map((p) => [p.user_id, p.full_name ?? ""])) };
    },
  });
  const [viewing, setViewing] = useState<VersionRow | null>(null);
  const refresh = () => queryClient.invalidateQueries({ queryKey: versionsKey(quoteId) });
  const done = useMutation({
    meta: { success: "Follow-up marked done" },
    mutationFn: async (taskId: string) => unwrap(await supabase().from("follow_up_tasks").update({ done_at: new Date().toISOString() }).eq("id", taskId).eq("company_id", company.id).select("id")),
    onSuccess: refresh,
  });

  const d = data.data;
  if (!d || (!d.versions.length && !d.requests.length)) return null;
  const current = d.versions.find((v) => !v.superseded_at && !v.signed_at) ?? null;
  const pending = status === "sent" || status === "changes_requested";
  const revising = pending && current && d.live && current.fingerprint !== d.live;
  const name = (id: string | null) => (id ? d.names.get(id) || "Someone" : null);

  return (
    <div className="card card-pad stack" data-planet-ops="versions">
      <strong>Versions and change requests</strong>
      {revising && (
        <div className="callout callout-warning" data-planet-ops="draft-revision">
          <Icon name="edit" size={20} />
          <div className="grow stack-xs">
            <div><strong>Draft revision, not sent.</strong> The customer still has version {current!.number}, and can't sign until you send the update.</div>
            <div className="small" style={{ fontWeight: 400 }}>Look it over with Preview, then send it: it goes out as version {d.versions[0]!.number + 1} and version {current!.number} can't be signed any more.</div>
          </div>
          {canSell && <Button size="sm" variant="primary" icon="send" onClick={onResend}>Send the update</Button>}
        </div>
      )}

      {d.requests.length > 0 && (
        <div className="stack-sm">
          <span className="muted small">Change requests</span>
          {d.requests.map((r) => (
            <ChangeRequestItem key={r.id} request={r} task={d.tasks.find((t) => t.source_id === r.id) ?? null} name={name} canSell={canSell} onDone={(id) => done.mutate(id)} onChanged={refresh} />
          ))}
          {status === "changes_requested" && canSell && !revising && (
            <div className="row wrap" style={{ gap: 8, alignItems: "center" }}>
              <span className="muted small">Signing is paused. Revise the document and send it, or send it again as it is to make it available to sign.</span>
              <Button size="sm" icon="send" onClick={onResend}>Send it again</Button>
            </div>
          )}
        </div>
      )}

      {d.versions.length > 0 && (
        <div className="stack-xs">
          <span className="muted small">Versions issued to the customer</span>
          <ul className="stack-xs" style={{ listStyle: "none", margin: 0, padding: 0 }}>
            {d.versions.map((v) => (
              <li key={v.id} className="row wrap" style={{ gap: 8, alignItems: "baseline" }}>
                <strong>Version {v.number}</strong>
                <span className="small">{VIA[v.issued_via] ?? "Issued"} {formatDate(v.issued_at)}{name(v.issued_by) ? ` by ${name(v.issued_by)}` : ""}</span>
                {v.total !== null && <span className="small">{formatMoneyCents(Number(v.total))}</span>}
                <span className={`chip ${v.signed_at ? "chip-green" : ""}`}>{v.signed_at ? `Signed ${formatDate(v.signed_at)}` : v.superseded_at ? "Superseded" : "Current"}</span>
                <Button size="sm" variant="ghost" onClick={() => setViewing(v)}>View</Button>
              </li>
            ))}
          </ul>
        </div>
      )}
      {viewing && <VersionDialog version={viewing} onClose={() => setViewing(null)} />}
    </div>
  );
}

function ChangeRequestItem({ request: r, task, name, canSell, onDone, onChanged }: { request: RequestRow; task: TaskRow | null; name: (id: string | null) => string | null; canSell: boolean; onDone: (taskId: string) => void; onChanged: () => void }) {
  const [reply, setReply] = useState("");
  const respond = useMutation({
    meta: { inline: true, success: "Reply saved" },
    mutationFn: async () => unwrap(await supabase().rpc("respond_to_change_request", { p_request: r.id, p_response: reply.trim() })),
    onSuccess: () => {
      setReply("");
      onChanged();
    },
  });
  return (
    <div className="card card-pad stack-xs" style={{ boxShadow: "none" }} data-planet-ops="change-request">
      <div className="row wrap" style={{ gap: 8, alignItems: "baseline" }}>
        <strong className="small">{formatDateTime(r.created_at)}</strong>
        <span className="muted small">{r.signed_agreement ? "on the signed agreement" : r.version_number ? `on version ${r.version_number}` : ""}{r.identity?.link === "office" ? " · from the office's copy of the link" : ""}</span>
        <span className={`chip ${r.resolved_at ? "" : "chip-amber"}`}>{r.resolved_at ? "Answered" : "Open"}</span>
      </div>
      <p className="pre-wrap" style={{ margin: 0 }}>“{r.message}”</p>
      {r.proposed_change_order_id && <a className="small" href={`/quotes/${r.proposed_change_order_id}`}>Open the proposed change order</a>}
      {r.response ? (
        <p className="small" style={{ margin: 0 }}><strong>Reply</strong>{name(r.responded_by) ? ` from ${name(r.responded_by)}` : ""}: <span className="pre-wrap">{r.response}</span></p>
      ) : (
        canSell && (
          <form className="stack-xs" onSubmit={(e: FormEvent) => { e.preventDefault(); if (reply.trim()) respond.mutate(); }}>
            <label className="small" htmlFor={`reply-${r.id}`}>Your reply (kept with the request)</label>
            <textarea id={`reply-${r.id}`} className="textarea" rows={2} value={reply} maxLength={4000} onChange={(e) => setReply(e.target.value)} />
            <FormError error={respond.error} />
            <div><Button size="sm" type="submit" loading={respond.isPending} disabled={!reply.trim()}>Save reply</Button></div>
          </form>
        )
      )}
      {task && (
        <div className="row wrap small" style={{ gap: 8, alignItems: "center" }}>
          <Icon name="check" size={14} />
          <span>Follow-up for {name(task.assigned_to) ?? "the office"}: {task.done_at ? `done ${formatDate(task.done_at)}` : "open"}</span>
          {!task.done_at && canSell && <Button size="sm" variant="ghost" onClick={() => onDone(task.id)}>Mark done</Button>}
        </div>
      )}
    </div>
  );
}

/** What a version issued: its own copy, never today's document. */
function VersionDialog({ version, onClose }: { version: VersionRow; onClose: () => void }) {
  const doc = (version.document ?? {}) as { quote?: Record<string, unknown>; lines?: Array<Record<string, unknown>>; options?: Array<Record<string, unknown>> };
  const q = doc.quote ?? {};
  const narrative = (q.narrative ?? {}) as Record<string, string | null>;
  const text = (v: unknown) => (typeof v === "string" && v.trim() ? v : null);
  return (
    <Dialog open onClose={onClose} title={`Version ${version.number}`} description={`${VIA[version.issued_via] ?? "Issued"} ${formatDateTime(version.issued_at)} · ${version.presentation === "proposal" ? "Proposal" : "Line-item quote"}`} size="lg">
      <div className="stack">
        {text(q.title) && <strong>{String(q.title)}</strong>}
        {version.presentation === "proposal" &&
          Object.entries(narrative).filter(([, v]) => text(v)).map(([k, v]) => (
            <div key={k} className="stack-xs"><span className="muted small">{k}</span><p className="pre-wrap" style={{ margin: 0 }}>{v}</p></div>
          ))}
        <table className="table">
          <thead><tr><th>Line</th><th>Qty</th><th>Price</th></tr></thead>
          <tbody>
            {(doc.lines ?? []).map((l) => (
              <tr key={String(l.id)}>
                <td>{String(l.name ?? "")}{text(l.description) ? <div className="muted small pre-wrap">{String(l.description)}</div> : null}{l.optional ? <span className="muted small"> (optional)</span> : null}</td>
                <td>{String(l.quantity ?? "")} {String(l.unit ?? "")}</td>
                <td>{formatMoneyCents(Number(l.unit_price ?? 0))}</td>
              </tr>
            ))}
          </tbody>
        </table>
        {version.total !== null && <div><strong>Total {formatMoneyCents(Number(version.total))}</strong></div>}
        {text(q.contract_terms) && <div className="stack-xs"><strong className="small">Contract Terms</strong><p className="pre-wrap" style={{ margin: 0 }}>{String(q.contract_terms)}</p></div>}
        {text(q.payment_terms) && <div className="stack-xs"><strong className="small">Payment Terms</strong><p className="pre-wrap" style={{ margin: 0 }}>{String(q.payment_terms)}</p></div>}
        <div className="form-actions"><Button onClick={onClose}>Close</Button></div>
      </div>
    </Dialog>
  );
}
