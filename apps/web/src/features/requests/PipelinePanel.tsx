/**
 * Planet Ops Phase 2: a request in the sales pipeline (20261122000100_planet_ops_pipeline.sql).
 *   PipelineCard      its stage, owner and estimator, next action and date, service and campaign,
 *                     last contact and first response, outcome and reason, and whether its
 *                     follow-ups are paused
 *   RequestActivity   log a call, text, email or note (recorded, never sent), its open follow-ups,
 *                     and its history: every move, change and contact, kept as it happened
 * Everything here is the Sales area's; the database refuses the rest.
 */
import type { Database } from "@crewtavo/core/database";
import { needsOutcomeReason, PAUSE_REASONS } from "@crewtavo/core/pipeline";
import { SALES, type Role } from "@crewtavo/core/roles";
import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import { useEffect, useState } from "react";
import { Button } from "@/components/ui/Button";
import { Field, FormError } from "@/components/ui/Field";
import { EmptyState } from "@/components/ui/States";
import { supabase, unwrap, unwrapOne } from "@/lib/api";
import { formatDate, formatDateTime } from "@/lib/format";
import { useSession } from "@/lib/session";
import { toast } from "@/lib/toast";
import { companyToday, pipelineKey, useStages, type Stage } from "../pipeline/data";
import { OutcomeDialog } from "../pipeline/RequestPipeline";
import { memberName, useTeam } from "./RequestsPage";

type RequestPatch = Database["public"]["Tables"]["requests"]["Update"];

export const requestPipelineKey = (id: string) => ["request-pipeline", id];

function useRequestPipeline(id: string) {
  return useQuery({
    queryKey: requestPipelineKey(id),
    queryFn: async () =>
      unwrapOne(
        await supabase()
          .from("requests")
          .select("id, number, status, client_id, stage_id, stage_entered_at, assigned_to, estimator_id, next_action, next_action_on, last_contact_at, first_response_at, follow_up_paused_at, follow_up_paused_reason, outcome_reason, outcome_at, service, campaign")
          .eq("id", id)
          .maybeSingle(),
        "This request",
      ),
  });
}

export function PipelineCard({ requestId, canSell }: { requestId: string; canSell: boolean }) {
  const session = useSession();
  const queryClient = useQueryClient();
  const r = useRequestPipeline(requestId);
  const stages = useStages(session.company.id);
  const team = useTeam(session.company.id);
  const [closing, setClosing] = useState<Stage | null>(null);
  const [next, setNext] = useState({ action: "", on: "", service: "", campaign: "" });
  const data = r.data;
  useEffect(() => {
    if (data) setNext({ action: data.next_action ?? "", on: data.next_action_on ?? "", service: data.service ?? "", campaign: data.campaign ?? "" });
  }, [data]);

  const refresh = () => {
    queryClient.invalidateQueries({ queryKey: requestPipelineKey(requestId) });
    queryClient.invalidateQueries({ queryKey: ["request-activity", requestId] });
    queryClient.invalidateQueries({ queryKey: ["request", requestId] });
    queryClient.invalidateQueries({ queryKey: pipelineKey(session.company.id) });
  };
  const update = useMutation({
    mutationFn: async (patch: RequestPatch) => unwrap(await supabase().from("requests").update(patch).eq("id", requestId).select("id")),
    onSuccess: () => {
      setClosing(null);
      refresh();
    },
    onError: (e) => toast.error(e instanceof Error ? e.message : "That didn't save."),
  });

  if (!data || !stages.data) return null;
  const stage = stages.data.find((s) => s.id === data.stage_id) ?? null;
  const decided = stage && (stage.kind === "won" || needsOutcomeReason(stage.kind));
  const today = companyToday(session.company.timezone);
  const late = data.next_action_on && data.next_action_on < today && !decided;
  const people = (team.data ?? []).filter((m) => m.active && SALES.includes(m.role as Role));
  const dirty = next.action !== (data.next_action ?? "") || next.on !== (data.next_action_on ?? "") || next.service !== (data.service ?? "") || next.campaign !== (data.campaign ?? "");
  const choose = (id: string) => {
    const to = stages.data!.find((s) => s.id === id);
    if (!to || to.id === data.stage_id) return;
    if (needsOutcomeReason(to.kind)) return setClosing(to);
    update.mutate({ stage_id: to.id }, { onSuccess: () => toast.success(`Moved to ${to.label}`, { tone: "request" }) });
  };

  return (
    <div className="card card-pad stack-sm" data-planet-ops="pipeline-card">
      <strong>Sales pipeline</strong>
      <dl className="kv">
        <dt>Stage</dt>
        <dd>
          {canSell ? (
            <select className="select input-sm" aria-label="Stage" value={data.stage_id ?? ""} disabled={update.isPending} onChange={(e) => choose(e.target.value)}>
              {!data.stage_id && <option value="">Not in the pipeline</option>}
              {stages.data.filter((s) => (s.active && s.kind !== "won") || s.id === data.stage_id).map((s) => <option key={s.id} value={s.id}>{s.label}</option>)}
            </select>
          ) : (stage?.label ?? "—")}
          {stage?.kind !== "won" && <span className="muted small" style={{ display: "block", marginTop: 4 }}>Won comes when its job is made.</span>}
        </dd>
        {data.outcome_reason && <><dt>Why</dt><dd>{data.outcome_reason}</dd></>}
        <dt>Owner</dt>
        <dd>{memberName(team.data?.find((m) => m.user_id === data.assigned_to)) ?? <span className="text-danger strong">No owner</span>}</dd>
        <dt>Estimator</dt>
        <dd>
          {canSell ? (
            <select className="select input-sm" aria-label="Estimator" value={data.estimator_id ?? ""} disabled={update.isPending || team.isPending} onChange={(e) => update.mutate({ estimator_id: e.target.value || null })}>
              <option value="">Nobody yet</option>
              {people.concat((team.data ?? []).filter((m) => m.user_id === data.estimator_id && !people.includes(m))).map((m) => <option key={m.user_id} value={m.user_id}>{memberName(m)}</option>)}
            </select>
          ) : (memberName(team.data?.find((m) => m.user_id === data.estimator_id)) ?? "Nobody yet")}
        </dd>
        <dt>Last contact</dt><dd>{data.last_contact_at ? formatDateTime(data.last_contact_at) : <span className="muted">None logged yet</span>}</dd>
        <dt>First response</dt><dd>{data.first_response_at ? formatDateTime(data.first_response_at) : <span className={decided ? "muted" : "text-danger strong"}>Not yet</span>}</dd>
        {data.stage_entered_at && <><dt>In this stage since</dt><dd>{formatDate(data.stage_entered_at)}</dd></>}
      </dl>
      {canSell && !decided && (
        <form
          className="stack-sm"
          onSubmit={(e) => {
            e.preventDefault();
            update.mutate(
              { next_action: next.action.trim() || null, next_action_on: next.on || null, service: next.service.trim() || null, campaign: next.campaign.trim() || null },
              { onSuccess: () => toast.success("Saved", { tone: "request" }) },
            );
          }}
        >
          <Field label="Next action" hint={late ? <span className="text-danger strong">Overdue</span> : undefined}>
            <input className="input input-sm" value={next.action} maxLength={200} onChange={(e) => setNext({ ...next, action: e.target.value })} placeholder="Call to book the site visit" />
          </Field>
          <Field label="Next action date"><input className="input input-sm" type="date" value={next.on} onChange={(e) => setNext({ ...next, on: e.target.value })} /></Field>
          <Field label="Requested service" optional><input className="input input-sm" value={next.service} maxLength={120} onChange={(e) => setNext({ ...next, service: e.target.value })} placeholder="House demolition" /></Field>
          <Field label="Campaign" optional><input className="input input-sm" value={next.campaign} maxLength={120} onChange={(e) => setNext({ ...next, campaign: e.target.value })} /></Field>
          {dirty && <Button type="submit" size="sm" variant="primary" loading={update.isPending} style={{ justifySelf: "start" }}>Save</Button>}
        </form>
      )}
      {!decided && (
        <div className="row wrap" style={{ gap: 8, alignItems: "center" }}>
          <span className="small">{data.follow_up_paused_at ? <>Follow-ups paused: {PAUSE_REASONS[data.follow_up_paused_reason ?? "staff"]}</> : "Follow-ups on"}</span>
          {canSell && (
            <Button size="sm" loading={update.isPending} onClick={() => update.mutate(data.follow_up_paused_at ? { follow_up_paused_at: null, follow_up_paused_reason: null } : { follow_up_paused_at: new Date().toISOString(), follow_up_paused_reason: "staff" })}>
              {data.follow_up_paused_at ? "Resume follow-ups" : "Pause follow-ups"}
            </Button>
          )}
        </div>
      )}
      {closing && <OutcomeDialog stage={closing} number={data.number ?? 0} saving={update.isPending} error={update.error} onClose={() => setClosing(null)} onSave={(reason) => update.mutate({ stage_id: closing.id, outcome_reason: reason })} />}
    </div>
  );
}

interface Event { id: string; kind: string; from_value: string | null; to_value: string | null; actor_id: string | null; created_at: string }
interface Contact { id: string; channel: string; direction: string; subject: string | null; body: string | null; sent_by: string | null; created_at: string }
interface FollowUp { id: string; title: string; due_on: string | null; assigned_to: string | null; source: string; body: string | null }

const CHANNEL: Record<string, string> = { call: "Call", sms: "Text", email: "Email", note: "Note" };

export function RequestActivity({ requestId, canSell }: { requestId: string; canSell: boolean }) {
  const session = useSession();
  const queryClient = useQueryClient();
  const team = useTeam(session.company.id);
  const activity = useQuery({
    queryKey: ["request-activity", requestId],
    enabled: canSell,
    queryFn: async () => {
      const [events, contacts, tasks, templates] = await Promise.all([
        supabase().from("request_pipeline_events").select("id, kind, from_value, to_value, actor_id, created_at").eq("request_id", requestId).order("created_at", { ascending: false }).limit(200),
        supabase().from("messages").select("id, channel, direction, subject, body, sent_by, created_at").eq("related_type", "request").eq("related_id", requestId).order("created_at", { ascending: false }).limit(200),
        supabase().from("follow_up_tasks").select("id, title, due_on, assigned_to, source, body").eq("related_type", "request").eq("related_id", requestId).is("done_at", null).order("due_on", { nullsFirst: false }),
        supabase().from("pipeline_templates").select("id, name, channel, subject, body").eq("company_id", session.company.id).eq("active", true).order("name"),
      ]);
      return { events: unwrap(events) as Event[], contacts: unwrap(contacts) as Contact[], tasks: unwrap(tasks) as FollowUp[], templates: unwrap(templates) };
    },
  });
  const [log, setLog] = useState({ channel: "call", direction: "out", body: "", subject: "" });
  const [task, setTask] = useState({ title: "", due: "" });
  const refresh = () => {
    queryClient.invalidateQueries({ queryKey: ["request-activity", requestId] });
    queryClient.invalidateQueries({ queryKey: requestPipelineKey(requestId) });
    queryClient.invalidateQueries({ queryKey: pipelineKey(session.company.id) });
  };
  const logContact = useMutation({
    mutationFn: async () =>
      unwrap(await supabase().rpc("log_request_contact", { p_request: requestId, p_channel: log.channel, p_direction: log.channel === "note" ? "internal" : log.direction, p_body: log.body, p_subject: log.subject || undefined })),
    onSuccess: () => {
      toast.success(`${CHANNEL[log.channel]} logged`, { tone: "request" });
      setLog({ ...log, body: "", subject: "" });
      refresh();
    },
  });
  const addTask = useMutation({
    mutationFn: async () => unwrap(await supabase().rpc("add_request_follow_up", { p_request: requestId, p_title: task.title, p_due_on: task.due || undefined })),
    onSuccess: () => {
      setTask({ title: "", due: "" });
      refresh();
    },
  });
  const done = useMutation({
    mutationFn: async (id: string) => unwrap(await supabase().from("follow_up_tasks").update({ done_at: new Date().toISOString(), done_by: session.userId }).eq("id", id).select("id")),
    onSuccess: refresh,
  });
  if (!canSell) return null;
  const name = (id: string | null) => (id ? memberName(team.data?.find((m) => m.user_id === id)) ?? "Someone" : "The app");
  const templates = (activity.data?.templates ?? []).filter((t) => t.channel === log.channel);
  const timeline = [
    ...(activity.data?.events ?? []).filter((e) => e.kind !== "contact").map((e) => ({ at: e.created_at, key: `e${e.id}`, node: <span><strong>{describe(e, name)}</strong> <span className="muted">· {name(e.actor_id)}</span></span> })),
    ...(activity.data?.contacts ?? []).map((c) => ({
      at: c.created_at,
      key: `c${c.id}`,
      node: (
        <span>
          <strong>{CHANNEL[c.channel] ?? c.channel}{c.direction === "in" ? " from the customer" : c.direction === "out" ? " to the customer" : ""}</strong> <span className="muted">· {name(c.sent_by)}</span>
          {c.subject && <span style={{ display: "block" }}>{c.subject}</span>}
          {c.body && <span className="pre-wrap" style={{ display: "block" }}>{c.body}</span>}
        </span>
      ),
    })),
  ].sort((a, b) => b.at.localeCompare(a.at));
  const today = companyToday(session.company.timezone);

  return (
    <section className="stack" data-planet-ops="request-activity">
      <h2 className="section-title">Follow-ups and contact history</h2>
      <div className="card card-pad stack-sm">
        <strong>Open follow-ups</strong>
        {(activity.data?.tasks ?? []).length === 0 && <span className="muted small">None open.</span>}
        {(activity.data?.tasks ?? []).map((t) => (
          <div key={t.id} className="row" style={{ gap: 8, alignItems: "center" }}>
            <span className="grow">
              {t.title}
              <span className={`small${t.due_on && t.due_on < today ? " text-danger strong" : " muted"}`} style={{ display: "block" }}>
                {t.due_on ? `Due ${formatDate(t.due_on)}` : "No date"} · {t.assigned_to ? name(t.assigned_to) : "The office"}{t.source === "cadence" ? " · from the stage's cadence" : ""}
              </span>
              {t.body && <span className="muted small" style={{ display: "block" }}>{t.body}</span>}
            </span>
            <Button size="sm" loading={done.isPending && done.variables === t.id} onClick={() => done.mutate(t.id)}>Done</Button>
          </div>
        ))}
        <form className="row wrap" style={{ gap: 8, alignItems: "end" }} onSubmit={(e) => { e.preventDefault(); if (task.title.trim()) addTask.mutate(); }}>
          <Field label="Add a follow-up" className="grow"><input className="input input-sm" value={task.title} maxLength={300} onChange={(e) => setTask({ ...task, title: e.target.value })} placeholder="Call back about the start date" /></Field>
          <Field label="Due" optional><input className="input input-sm" type="date" value={task.due} onChange={(e) => setTask({ ...task, due: e.target.value })} /></Field>
          <Button type="submit" size="sm" loading={addTask.isPending} disabled={!task.title.trim()}>Add</Button>
        </form>
        <FormError error={addTask.error ?? done.error} />
      </div>

      <form className="card card-pad stack-sm" onSubmit={(e) => { e.preventDefault(); if (log.body.trim()) logContact.mutate(); }}>
        <strong>Log a contact</strong>
        <span className="muted small">Records what happened with the customer on this request and their client record. Nothing is sent from here.</span>
        <div className="row wrap" style={{ gap: 8 }}>
          <Field label="What">
            <select className="select input-sm" value={log.channel} onChange={(e) => setLog({ ...log, channel: e.target.value })}>
              <option value="call">Call</option>
              <option value="sms">Text</option>
              <option value="email">Email</option>
              <option value="note">Internal note</option>
            </select>
          </Field>
          {log.channel !== "note" && (
            <Field label="Direction">
              <select className="select input-sm" value={log.direction} onChange={(e) => setLog({ ...log, direction: e.target.value })}>
                <option value="out">We contacted them</option>
                <option value="in">They contacted us</option>
              </select>
            </Field>
          )}
          {templates.length > 0 && (
            <Field label="Template" optional>
              <select className="select input-sm" value="" onChange={(e) => { const t = templates.find((x) => x.id === e.target.value); if (t) setLog({ ...log, body: t.body, subject: t.subject ?? log.subject }); }}>
                <option value="">Start from a template…</option>
                {templates.map((t) => <option key={t.id} value={t.id}>{t.name}</option>)}
              </select>
            </Field>
          )}
        </div>
        {log.channel === "email" && <Field label="Subject" optional><input className="input input-sm" value={log.subject} maxLength={200} onChange={(e) => setLog({ ...log, subject: e.target.value })} /></Field>}
        <Field label={log.channel === "note" ? "Note" : "What was said"}>
          <textarea className="textarea" rows={3} maxLength={4000} value={log.body} onChange={(e) => setLog({ ...log, body: e.target.value })} />
        </Field>
        {log.direction === "in" && log.channel !== "note" && <span className="muted small">A reply from the customer pauses this request's follow-ups.</span>}
        <FormError error={logContact.error} />
        <Button type="submit" size="sm" variant="primary" loading={logContact.isPending} disabled={!log.body.trim()} style={{ justifySelf: "start" }}>Log {CHANNEL[log.channel].toLowerCase()}</Button>
      </form>

      <div className="card">
        {timeline.length === 0 ? (
          <EmptyState inline title="No history yet" />
        ) : (
          <ol className="stack-sm" style={{ listStyle: "none", margin: 0, padding: 16 }} aria-label="Pipeline history">
            {timeline.map((t) => (
              <li key={t.key} className="row" style={{ gap: 12, alignItems: "baseline" }}>
                <span className="muted small tabular" style={{ minWidth: 140 }}>{formatDateTime(t.at)}</span>
                {t.node}
              </li>
            ))}
          </ol>
        )}
      </div>
    </section>
  );
}

/** A history line, in words. */
export function describe(e: Pick<Event, "kind" | "from_value" | "to_value">, name: (id: string | null) => string): string {
  switch (e.kind) {
    case "stage": return e.from_value ? `Moved from ${e.from_value} to ${e.to_value}` : `Came in at ${e.to_value}`;
    case "owner": return e.to_value ? `Owner: ${name(e.to_value)}` : "Owner removed";
    case "estimator": return e.to_value ? `Estimator: ${name(e.to_value)}` : "Estimator removed";
    case "next_action": return e.to_value ? `Next action: ${e.to_value}` : "Next action cleared";
    case "outcome": return `Reason: ${e.to_value}`;
    case "paused": return `Follow-ups paused: ${PAUSE_REASONS[e.to_value ?? "staff"] ?? e.to_value}`;
    case "resumed": return "Follow-ups resumed";
    default: return e.kind;
  }
}
