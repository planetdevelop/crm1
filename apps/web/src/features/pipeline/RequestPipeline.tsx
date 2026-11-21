/**
 * Planet Ops Phase 2: requests in the sales pipeline, as a board (one column per open stage and
 * Nurture) or a list, with the filters people work from: Needs first response, Follow-up due,
 * Overdue, Waiting on customer, No next action, No owner, and whose it is. Moving a card moves its
 * request (with its history); Won, Lost and Unqualified ask why. Won by hand is a sales call only (no
 * job, signature or payment); converting the signed agreement makes the job and marks it won.
 */
import { daysBetween, isActive, needsOutcomeReason, PIPELINE_FILTERS, pipelineFlags, type PipelineFilter } from "@crewtavo/core/pipeline";
import { useMutation, useQueryClient } from "@tanstack/react-query";
import { useMemo, useState, type DragEvent } from "react";
import { Link, useNavigate } from "react-router-dom";
import { Button } from "@/components/ui/Button";
import { Dialog } from "@/components/ui/Dialog";
import { Field, FormError } from "@/components/ui/Field";
import { Loading, Skeleton } from "@/components/ui/Skeleton";
import { EmptyState, ErrorState } from "@/components/ui/States";
import { supabase, unwrap } from "@/lib/api";
import { formatDate, formatMoney } from "@/lib/format";
import { useSession } from "@/lib/session";
import { toast } from "@/lib/toast";
import { memberName, useTeam } from "../requests/RequestsPage";
import { companyToday, KIND_COLOR, pipelineKey, usePipelineRequests, useStages, type PipelineCard, type Stage } from "./data";

type View = "board" | "list";
const VIEW_KEY = "planet-ops.pipeline.view";
const readView = (): View => {
  try {
    return localStorage.getItem(VIEW_KEY) === "list" ? "list" : "board";
  } catch {
    return "board";
  }
};

export function RequestPipeline() {
  const session = useSession();
  const { company } = session;
  const navigate = useNavigate();
  const queryClient = useQueryClient();
  const stages = useStages(company.id);
  const requests = usePipelineRequests(company.id);
  const team = useTeam(company.id);
  const [view, setView] = useState<View>(readView);
  const [filter, setFilter] = useState<PipelineFilter | "all" | "decided">("all");
  const [owner, setOwner] = useState<string>("");
  const [dragging, setDragging] = useState<PipelineCard | null>(null);
  const [over, setOver] = useState<string | null>(null);
  const [closing, setClosing] = useState<{ card: PipelineCard; stage: Stage } | null>(null);
  const today = companyToday(company.timezone);

  const byId = useMemo(() => new Map((stages.data ?? []).map((s) => [s.id, s])), [stages.data]);
  const cards = useMemo(
    () =>
      (requests.data ?? []).map((r) => {
        const stage = r.stage_id ? byId.get(r.stage_id) ?? null : null;
        return { ...r, stage, flags: pipelineFlags({ ...r, stage }, today), active: isActive({ status: r.status, stage }) };
      }),
    [requests.data, byId, today],
  );
  type Row = (typeof cards)[number];
  const counts = useMemo(() => {
    const c: Record<string, number> = { all: 0, decided: 0 };
    for (const r of cards) {
      if (owner && (owner === "none" ? r.assigned_to : r.assigned_to !== owner)) continue;
      if (r.active) c.all++;
      else c.decided++;
      for (const f of r.flags) c[f] = (c[f] ?? 0) + 1;
    }
    return c;
  }, [cards, owner]);
  const shown = cards.filter((r) =>
    (!owner || (owner === "none" ? !r.assigned_to : r.assigned_to === owner))
    && (filter === "decided" ? !r.active : r.active && (filter === "all" || r.flags.has(filter))),
  );

  const refresh = () => {
    queryClient.invalidateQueries({ queryKey: pipelineKey(company.id) });
    queryClient.invalidateQueries({ queryKey: ["requests", company.id] });
  };
  const move = useMutation({
    mutationFn: async ({ card, stage, reason }: { card: PipelineCard; stage: Stage; reason?: string }) =>
      unwrap(await supabase().from("requests").update({ stage_id: stage.id, ...(reason ? { outcome_reason: reason } : {}) }).eq("id", card.id).select("id")),
    onSuccess: (_, { card, stage }) => {
      toast.success(`#${card.number} moved to ${stage.label}`, { tone: "request" });
      setClosing(null);
      refresh();
    },
    onError: (e) => toast.error(e instanceof Error ? e.message : "That move didn't save."),
  });
  const setView_ = (v: View) => {
    setView(v);
    try {
      localStorage.setItem(VIEW_KEY, v);
    } catch {
      /* the choice just isn't remembered */
    }
  };

  const columns = (stages.data ?? []).filter((s) => s.active && (s.kind === "open" || s.kind === "nurture"));
  // Won (a sales call, with a note), Lost and Unqualified: each asks why.
  const outcomes = (stages.data ?? []).filter((s) => s.active && (needsOutcomeReason(s.kind) || s.kind === "won"));
  const drop = (stage: Stage) => {
    const card = dragging;
    setDragging(null);
    setOver(null);
    if (!card || card.stage_id === stage.id) return;
    if (needsOutcomeReason(stage.kind) || stage.kind === "won") return setClosing({ card, stage });
    move.mutate({ card, stage });
  };
  const zone = (stage: Stage) => ({
    onDragOver: (e: DragEvent) => {
      if (dragging && dragging.stage_id !== stage.id) {
        e.preventDefault();
        if (over !== stage.id) setOver(stage.id);
      }
    },
    onDragLeave: (e: DragEvent) => !(e.currentTarget as HTMLElement).contains(e.relatedTarget as Node) && setOver(null),
    onDrop: (e: DragEvent) => {
      e.preventDefault();
      drop(stage);
    },
    "data-drop": over === stage.id || undefined,
  });
  const name = (id: string | null) => (id ? memberName(team.data?.find((m) => m.user_id === id)) : null);

  if (stages.error || requests.error) return <div className="card"><ErrorState error={stages.error ?? requests.error} onRetry={() => { stages.refetch(); requests.refetch(); }} /></div>;

  return (
    <div className="stack">
      <div className="toolbar" style={{ flexWrap: "wrap" }}>
        <div className="tabs" role="group" aria-label="Filter the pipeline" style={{ flexWrap: "wrap" }}>
          <button type="button" className="tab" aria-pressed={filter === "all"} onClick={() => setFilter("all")}>Active <span className="badge">{counts.all ?? 0}</span></button>
          {PIPELINE_FILTERS.map((f) => (
            <button key={f.key} type="button" className="tab" aria-pressed={filter === f.key} onClick={() => setFilter(f.key)}>
              {f.label} <span className="badge">{counts[f.key] ?? 0}</span>
            </button>
          ))}
          <button type="button" className="tab" aria-pressed={filter === "decided"} onClick={() => setFilter("decided")}>Decided (30 days) <span className="badge">{counts.decided ?? 0}</span></button>
        </div>
        <select className="select input-sm" aria-label="Whose requests" value={owner} onChange={(e) => setOwner(e.target.value)} style={{ maxWidth: 220 }}>
          <option value="">Everyone's</option>
          <option value={session.userId}>Mine</option>
          <option value="none">No owner</option>
          {(team.data ?? []).filter((m) => m.active && m.user_id !== session.userId).map((m) => <option key={m.user_id} value={m.user_id}>{memberName(m)}</option>)}
        </select>
        <div className="segmented" role="group" aria-label="View">
          <button type="button" aria-pressed={view === "board"} onClick={() => setView_("board")}>Board</button>
          <button type="button" aria-pressed={view === "list"} onClick={() => setView_("list")}>List</button>
        </div>
      </div>

      {stages.isPending || requests.isPending ? (
        <Loading><div className="board">{[0, 1, 2, 3].map((c) => <div key={c} className="board-col"><Skeleton width="60%" height={14} />{[0, 1].map((i) => <Skeleton key={i} height={70} radius={8} />)}</div>)}</div></Loading>
      ) : shown.length === 0 && view === "list" ? (
        <div className="card"><EmptyState icon="requests" title={filter === "all" ? "No active requests" : "Nothing matches"}>{filter === "all" ? "New requests from forms, the Client Hub, the phone and referrals land in New inquiry." : "Try another filter."}</EmptyState></div>
      ) : view === "board" && filter !== "decided" ? (
        <>
          <div className="board" data-planet-ops="pipeline-board">
            {columns.map((col) => {
              const items = shown.filter((r) => r.stage_id === col.id).sort((a, b) => (a.next_action_on ?? "9999").localeCompare(b.next_action_on ?? "9999"));
              const total = items.reduce((s, r) => s + (r.value ?? 0), 0);
              return (
                <section key={col.id} className="board-col" style={{ ["--stage" as string]: KIND_COLOR[col.kind] }} aria-label={col.label} {...zone(col)}>
                  <div className="board-col-head">
                    <strong>{col.label}</strong>
                    <span className="badge">{items.length}</span>
                    {total > 0 && <span className="muted">{formatMoney(total)}</span>}
                  </div>
                  {items.map((r) => <Deal key={r.id} r={r} today={today} owner={name(r.assigned_to)} dragging={dragging?.id === r.id} onDrag={setDragging} />)}
                  {items.length === 0 && <span className="muted small" style={{ padding: "4px 2px" }}>Nothing here</span>}
                </section>
              );
            })}
          </div>
          {dragging && (
            <div className="row" style={{ gap: 12, position: "sticky", bottom: 16 }}>
              {outcomes.map((s) => (
                <div key={s.id} className="card row grow" style={{ justifyContent: "center", padding: 16, borderStyle: "dashed", borderColor: over === s.id ? KIND_COLOR[s.kind] : undefined, color: s.kind === "won" ? "var(--job)" : "var(--danger)", fontWeight: 600 }} {...zone(s)}>
                  Drop here: {s.label}
                </div>
              ))}
            </div>
          )}
        </>
      ) : (
        <div className="card" data-planet-ops="pipeline-list">
          <table className="table table-stack">
            <thead><tr><th>#</th><th>Request</th><th>Stage</th><th>Owner</th><th>Next action</th><th>Last contact</th><th className="num">Quoted</th></tr></thead>
            <tbody>
              {shown.sort((a, b) => (a.next_action_on ?? "9999").localeCompare(b.next_action_on ?? "9999")).map((r: Row) => (
                <tr key={r.id} className="row-link" onClick={() => navigate(`/requests/${r.id}`)}>
                  <td className="muted tabular" style={{ width: 56 }}>#{r.number}</td>
                  <td>
                    <Link className="cell-link" to={`/requests/${r.id}`} onClick={(e) => e.stopPropagation()}>{r.title}</Link>
                    <div className="muted small">{r.client?.display_name ?? ""}{r.service ? ` · ${r.service}` : ""}</div>
                    <Badges r={r} />
                  </td>
                  <td>
                    {r.stage?.label ?? (r.status === "archived" ? "Archived" : "—")}
                    {r.stage_entered_at && r.active && <div className="muted small">{daysBetween(r.stage_entered_at, new Date().toISOString())} days</div>}
                    {r.outcome_reason && <div className="muted small">{r.outcome_reason}</div>}
                  </td>
                  <td>{name(r.assigned_to) ?? <span className="text-danger strong">No owner</span>}{r.estimator_id && <div className="muted small">Estimator: {name(r.estimator_id)}</div>}</td>
                  <td>{r.next_action ? <>{r.next_action}{r.next_action_on && <div className={`small${r.next_action_on < today ? " text-danger strong" : " muted"}`}>{formatDate(r.next_action_on)}</div>}</> : <span className="muted">—</span>}</td>
                  <td>{r.last_contact_at ? formatDate(r.last_contact_at) : <span className="muted">None yet</span>}</td>
                  <td className="num tabular">{r.value != null ? formatMoney(r.value) : "—"}</td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      )}

      {closing && (
        <OutcomeDialog
          stage={closing.stage}
          number={closing.card.number}
          saving={move.isPending}
          error={move.error}
          onClose={() => setClosing(null)}
          onSave={(reason) => move.mutate({ card: closing.card, stage: closing.stage, reason })}
        />
      )}
    </div>
  );
}

function Badges({ r }: { r: { flags: Set<PipelineFilter> } }) {
  if (!r.flags.size) return null;
  return (
    <span className="row wrap" style={{ gap: 4, marginTop: 4 }}>
      {PIPELINE_FILTERS.filter((f) => r.flags.has(f.key)).map((f) => (
        <span key={f.key} className={`pill pill-quiet${f.key === "overdue" || f.key === "no_owner" ? " text-danger" : ""}`} style={{ fontSize: 12 }}>{f.label}</span>
      ))}
    </span>
  );
}

function Deal({ r, today, owner, dragging, onDrag }: { r: PipelineCard & { flags: Set<PipelineFilter> }; today: string; owner: string | null; dragging: boolean; onDrag: (c: PipelineCard | null) => void }) {
  const late = r.next_action_on && r.next_action_on < today;
  return (
    <Link
      to={`/requests/${r.id}`}
      className="deal"
      draggable
      data-dragging={dragging || undefined}
      data-stale={late || undefined}
      onDragStart={(e) => {
        e.dataTransfer.effectAllowed = "move";
        e.dataTransfer.setData("text/plain", r.id);
        onDrag(r);
      }}
      onDragEnd={() => onDrag(null)}
    >
      <span className="d-title">{r.title}</span>
      <span className="muted small ellipsis">{r.client?.display_name ?? ""}</span>
      <span className="small">{r.next_action ?? "No next action"}{r.next_action_on && <span className={late ? "text-danger strong" : "muted"}> · {formatDate(r.next_action_on)}</span>}</span>
      <span className="d-meta">
        <span>#{r.number}</span>
        <span className={owner ? undefined : "text-danger strong"}>{owner ?? "No owner"}</span>
      </span>
      {r.value != null && <span className="d-value">{formatMoney(r.value)}</span>}
      <Badges r={r} />
    </Link>
  );
}

/** Lost or Unqualified: why. The request keeps it, and its history keeps it too. */
export function OutcomeDialog({ stage, number, saving, error, onClose, onSave }: { stage: Stage; number: number; saving: boolean; error: unknown; onClose: () => void; onSave: (reason: string) => void }) {
  const [reason, setReason] = useState("");
  return (
    <Dialog open onClose={onClose} title={`Move #${number} to ${stage.label}`} description={stage.kind === "won" ? "A sales call only: it makes no job, signature, deposit or payment, and the agreement stays as it is. Converting the signed quote or proposal makes the job. Say why it's won; it stays in the history." : "Say why. It stays with the request and in its history, and its follow-ups stop."}>
      <form
        className="stack"
        onSubmit={(e) => {
          e.preventDefault();
          if (reason.trim()) onSave(reason.trim());
        }}
      >
        <Field label={stage.kind === "won" ? "Why is it won?" : "Why?"}>
          <textarea className="textarea" required maxLength={500} rows={3} value={reason} onChange={(e) => setReason(e.target.value)} />
        </Field>
        <FormError error={error} />
        <div className="form-actions">
          <Button onClick={onClose}>Cancel</Button>
          <Button type="submit" variant="primary" loading={saving} disabled={!reason.trim()}>Move to {stage.label}</Button>
        </div>
      </form>
    </Dialog>
  );
}
