/**
 * Settings → Pipeline (Planet Ops Phase 2, 20261122000100_planet_ops_pipeline.sql):
 *   settings.pipeline.default_owner   who a request nobody's zip covers goes to (owners and admins
 *                                     save it, through merge_company_settings); empty leaves it
 *                                     unassigned and flagged "No owner"
 *   settings.pipeline.reminders       whether stage cadence steps make follow-up reminders (on unless off)
 *   pipeline_stages                   labels, order, each stage's next action; custom open stages
 *   pipeline_cadence_steps            the reminders a request gets as it enters a stage
 *   pipeline_templates                call scripts and text/email drafts for staff
 * Nothing here sends a customer message: automatic sending comes with the communication
 * integrations (Phase 7), once a channel, approved wording, recipients and timing are set.
 */
import { SALES, type Role } from "@crewtavo/core/roles";
import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import { useEffect, useState } from "react";
import { Button } from "@/components/ui/Button";
import { confirm } from "@/components/ui/Confirm";
import { Field, FormError } from "@/components/ui/Field";
import { supabase, unwrap } from "@/lib/api";
import { hasRole, useSession } from "@/lib/session";
import { toast } from "@/lib/toast";
import { stagesKey, useStages, type Stage } from "../pipeline/data";
import { memberName, useTeam } from "../requests/RequestsPage";

const CHANNELS = [
  { value: "call", label: "Call" },
  { value: "sms", label: "Text" },
  { value: "email", label: "Email" },
  { value: "task", label: "Task" },
];

export function PipelineSettings() {
  return (
    <div className="stack-lg" data-planet-ops="pipeline-settings">
      <div className="callout callout-info">
        <div className="grow">
          <strong>Reminders and drafts only</strong>
          <div className="small" style={{ fontWeight: 400 }}>
            The pipeline makes follow-up reminders for your team and keeps templates for them to use. It never sends a message to a customer by itself. Automatic sending comes with the phone and email integrations, once you've approved the channel, wording, recipients and timing.
          </div>
        </div>
      </div>
      <OwnerSettings />
      <StageSettings />
      <CadenceSettings />
      <TemplateSettings />
    </div>
  );
}

function OwnerSettings() {
  const session = useSession();
  const { company } = session;
  const queryClient = useQueryClient();
  const team = useTeam(company.id);
  const isAdmin = hasRole(session, "admin");
  const settings = useQuery({
    queryKey: ["company", company.id, "pipeline"],
    queryFn: async () => unwrap(await supabase().from("companies").select("settings").eq("id", company.id).single()),
  });
  const p = ((settings.data?.settings ?? {}) as { pipeline?: { default_owner?: string | null; reminders?: boolean } }).pipeline ?? {};
  const [owner, setOwner] = useState<string>("");
  const [reminders, setReminders] = useState(true);
  useEffect(() => {
    if (settings.data) {
      setOwner(p.default_owner ?? "");
      setReminders(p.reminders !== false);
    }
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [settings.data]);
  const save = useMutation({
    mutationFn: async () => unwrap(await supabase().rpc("merge_company_settings", { p_company: company.id, p_settings: { pipeline: { default_owner: owner || null, reminders } } as never })),
    onSuccess: () => {
      toast.success("Pipeline settings saved");
      queryClient.invalidateQueries({ queryKey: ["company", company.id] });
      session.refresh();
    },
  });
  const sellers = (team.data ?? []).filter((m) => m.active && SALES.includes(m.role as Role));
  return (
    <form className="card card-pad stack" onSubmit={(e) => { e.preventDefault(); save.mutate(); }}>
      <strong>Owners and reminders</strong>
      <Field label="Default owner" hint="A new request goes to the salesperson whose sales area covers its zip code. When nobody does, it goes to this person. With nobody chosen, it stays unassigned and shows as No owner.">
        <select className="select" value={owner} disabled={!isAdmin} onChange={(e) => setOwner(e.target.value)} style={{ maxWidth: 320 }}>
          <option value="">Nobody (leave unassigned)</option>
          {sellers.map((m) => <option key={m.user_id} value={m.user_id}>{memberName(m)}</option>)}
        </select>
      </Field>
      <label className="switch-row" style={{ fontWeight: 400 }}>
        <input type="checkbox" className="switch" checked={reminders} disabled={!isAdmin} onChange={(e) => setReminders(e.target.checked)} />
        Make follow-up reminders from each stage's cadence
      </label>
      {!isAdmin && <span className="muted small">Owners and admins change these.</span>}
      <FormError error={save.error} />
      {isAdmin && <Button type="submit" variant="primary" loading={save.isPending} style={{ justifySelf: "start" }}>Save</Button>}
    </form>
  );
}

function StageSettings() {
  const { company } = useSession();
  const queryClient = useQueryClient();
  const stages = useStages(company.id);
  const [adding, setAdding] = useState("");
  const refresh = () => queryClient.invalidateQueries({ queryKey: stagesKey(company.id) });
  const update = useMutation({
    mutationFn: async ({ id, patch }: { id: string; patch: Partial<Pick<Stage, "label" | "sort" | "default_next_action" | "default_due_days" | "active">> }) =>
      unwrap(await supabase().from("pipeline_stages").update(patch).eq("id", id).select("id")),
    onSuccess: refresh,
    onError: (e) => toast.error(e instanceof Error ? e.message : "That didn't save."),
  });
  const add = useMutation({
    mutationFn: async () => {
      const open = (stages.data ?? []).filter((s) => s.kind === "open");
      const after = open[open.length - 1]?.sort ?? 0;
      unwrap(await supabase().from("pipeline_stages").insert({ company_id: company.id, label: adding.trim(), kind: "open", sort: after + 1 }).select("id"));
    },
    onSuccess: () => {
      setAdding("");
      refresh();
    },
  });
  const remove = useMutation({
    mutationFn: async (id: string) => unwrap(await supabase().from("pipeline_stages").delete().eq("id", id).select("id")),
    onSuccess: refresh,
    onError: (e) => toast.error(e instanceof Error && /foreign key/.test(e.message) ? "Move the requests in this stage first." : e instanceof Error ? e.message : "That didn't delete."),
  });
  const list = stages.data ?? [];
  const swap = (i: number, j: number) => {
    const a = list[i], b = list[j];
    if (!a || !b) return;
    update.mutate({ id: a.id, patch: { sort: b.sort } });
    update.mutate({ id: b.id, patch: { sort: a.sort } });
  };
  return (
    <section className="card card-pad stack">
      <strong>Stages</strong>
      <span className="muted small">Rename them, put them in your order and set what a request does next on entering each. Won, Nurture, Lost and Unqualified are outcomes: Lost and Unqualified ask why, and Won comes when the job is made.</span>
      <table className="table table-stack" aria-label="Pipeline stages">
        <thead><tr><th>Stage</th><th>Next action on entry</th><th className="num">Due in (days)</th><th>On</th><th /></tr></thead>
        <tbody>
          {list.map((s, i) => (
            <StageRow key={s.id} stage={s} first={i === 0} last={i === list.length - 1} onSave={(patch) => update.mutate({ id: s.id, patch })} onUp={() => swap(i, i - 1)} onDown={() => swap(i, i + 1)} onDelete={async () => { if (await confirm({ title: `Delete ${s.label}?`, body: "Its requests' history keeps the name.", confirmLabel: "Delete", danger: true })) remove.mutate(s.id); }} />
          ))}
        </tbody>
      </table>
      <form className="row wrap" style={{ gap: 8, alignItems: "end" }} onSubmit={(e) => { e.preventDefault(); if (adding.trim()) add.mutate(); }}>
        <Field label="Add a stage" className="grow"><input className="input" maxLength={60} value={adding} onChange={(e) => setAdding(e.target.value)} placeholder="Permitting check" /></Field>
        <Button type="submit" loading={add.isPending} disabled={!adding.trim()}>Add</Button>
      </form>
      <FormError error={add.error} />
    </section>
  );
}

function StageRow({ stage, first, last, onSave, onUp, onDown, onDelete }: { stage: Stage; first: boolean; last: boolean; onSave: (patch: Partial<Stage>) => void; onUp: () => void; onDown: () => void; onDelete: () => void }) {
  const [label, setLabel] = useState(stage.label);
  const [action, setAction] = useState(stage.default_next_action ?? "");
  const [days, setDays] = useState(stage.default_due_days == null ? "" : String(stage.default_due_days));
  const takesAction = stage.kind === "open" || stage.kind === "nurture";
  const locked = ["new_inquiry", "won", "nurture", "lost", "unqualified"].includes(stage.system_key ?? "");
  const changed = label.trim() !== stage.label || action.trim() !== (stage.default_next_action ?? "") || days !== (stage.default_due_days == null ? "" : String(stage.default_due_days));
  return (
    <tr>
      <td><input className="input input-sm" aria-label={`${stage.label}: name`} maxLength={60} value={label} onChange={(e) => setLabel(e.target.value)} /></td>
      <td>{takesAction ? <input className="input input-sm" aria-label={`${stage.label}: next action`} maxLength={200} value={action} onChange={(e) => setAction(e.target.value)} /> : <span className="muted small">{stage.kind === "won" ? "Done in sales" : "Asks why"}</span>}</td>
      <td className="num">{takesAction ? <input className="input input-sm" aria-label={`${stage.label}: due in days`} inputMode="numeric" style={{ width: 72 }} value={days} onChange={(e) => setDays(e.target.value.replace(/\D/g, "").slice(0, 3))} /> : null}</td>
      <td><input type="checkbox" className="switch" aria-label={`${stage.label}: on`} checked={stage.active} disabled={locked} onChange={(e) => onSave({ active: e.target.checked })} /></td>
      <td>
        <span className="row" style={{ gap: 4, justifyContent: "flex-end" }}>
          {changed && <Button size="sm" variant="primary" disabled={!label.trim()} onClick={() => onSave({ label: label.trim(), ...(takesAction ? { default_next_action: action.trim() || null, default_due_days: days === "" ? null : Math.min(365, Number(days)) } : {}) })}>Save</Button>}
          <Button size="sm" icon="chevronUp" aria-label={`Move ${stage.label} up`} disabled={first} onClick={onUp} />
          <Button size="sm" icon="chevronDown" aria-label={`Move ${stage.label} down`} disabled={last} onClick={onDown} />
          {!stage.system_key && <Button size="sm" icon="trash" aria-label={`Delete ${stage.label}`} onClick={onDelete} />}
        </span>
      </td>
    </tr>
  );
}

interface Step { id: string; stage_id: string; after_days: number; title: string; channel: string; template_id: string | null; sort: number; active: boolean }
interface Template { id: string; name: string; channel: string; subject: string | null; body: string; active: boolean }

const useTemplates = (companyId: string) =>
  useQuery({ queryKey: ["pipeline-templates", companyId], queryFn: async () => unwrap(await supabase().from("pipeline_templates").select("id, name, channel, subject, body, active").eq("company_id", companyId).order("name")) as Template[] });

function CadenceSettings() {
  const { company } = useSession();
  const queryClient = useQueryClient();
  const stages = useStages(company.id);
  const templates = useTemplates(company.id);
  const steps = useQuery({
    queryKey: ["pipeline-cadence", company.id],
    queryFn: async () => unwrap(await supabase().from("pipeline_cadence_steps").select("id, stage_id, after_days, title, channel, template_id, sort, active").eq("company_id", company.id).order("sort")) as Step[],
  });
  const [draft, setDraft] = useState({ stage_id: "", after_days: "0", title: "", channel: "call", template_id: "" });
  const refresh = () => queryClient.invalidateQueries({ queryKey: ["pipeline-cadence", company.id] });
  const add = useMutation({
    mutationFn: async () =>
      unwrap(await supabase().from("pipeline_cadence_steps").insert({ company_id: company.id, stage_id: draft.stage_id, after_days: Math.min(365, Number(draft.after_days) || 0), title: draft.title.trim(), channel: draft.channel, template_id: draft.template_id || null, sort: (steps.data?.length ?? 0) * 10 + 10 }).select("id")),
    onSuccess: () => {
      setDraft({ ...draft, title: "", after_days: "0", template_id: "" });
      refresh();
    },
  });
  const update = useMutation({
    mutationFn: async ({ id, patch }: { id: string; patch: Partial<Step> }) => unwrap(await supabase().from("pipeline_cadence_steps").update(patch).eq("id", id).select("id")),
    onSuccess: refresh,
  });
  const remove = useMutation({
    mutationFn: async (id: string) => unwrap(await supabase().from("pipeline_cadence_steps").delete().eq("id", id).select("id")),
    onSuccess: refresh,
  });
  const open = (stages.data ?? []).filter((s) => s.active && (s.kind === "open" || s.kind === "nurture"));
  const label = (id: string) => stages.data?.find((s) => s.id === id)?.label ?? "—";
  return (
    <section className="card card-pad stack">
      <strong>Follow-up cadence</strong>
      <span className="muted small">As a request enters a stage, each step here becomes a reminder for its owner, due that many days later. A request whose follow-ups are paused (the customer replied, opted out, or someone paused them) gets none.</span>
      <table className="table table-stack" aria-label="Follow-up cadence">
        <thead><tr><th>Stage</th><th>Reminder</th><th className="num">After (days)</th><th>Template</th><th>On</th><th /></tr></thead>
        <tbody>
          {(steps.data ?? []).map((s) => (
            <tr key={s.id}>
              <td>{label(s.stage_id)}</td>
              <td>{s.title} <span className="muted small">({CHANNELS.find((c) => c.value === s.channel)?.label})</span></td>
              <td className="num tabular">{s.after_days}</td>
              <td>
                <select className="select input-sm" aria-label={`${s.title}: template`} value={s.template_id ?? ""} onChange={(e) => update.mutate({ id: s.id, patch: { template_id: e.target.value || null } })}>
                  <option value="">None</option>
                  {(templates.data ?? []).filter((t) => t.active).map((t) => <option key={t.id} value={t.id}>{t.name}</option>)}
                </select>
              </td>
              <td><input type="checkbox" className="switch" aria-label={`${s.title}: on`} checked={s.active} onChange={(e) => update.mutate({ id: s.id, patch: { active: e.target.checked } })} /></td>
              <td><Button size="sm" icon="trash" aria-label={`Remove ${s.title}`} onClick={() => remove.mutate(s.id)} /></td>
            </tr>
          ))}
        </tbody>
      </table>
      <form className="row wrap" style={{ gap: 8, alignItems: "end" }} onSubmit={(e) => { e.preventDefault(); if (draft.stage_id && draft.title.trim()) add.mutate(); }}>
        <Field label="Stage">
          <select className="select input-sm" value={draft.stage_id} onChange={(e) => setDraft({ ...draft, stage_id: e.target.value })}>
            <option value="">Pick a stage</option>
            {open.map((s) => <option key={s.id} value={s.id}>{s.label}</option>)}
          </select>
        </Field>
        <Field label="Reminder" className="grow"><input className="input input-sm" maxLength={200} value={draft.title} onChange={(e) => setDraft({ ...draft, title: e.target.value })} placeholder="Check in after the site visit" /></Field>
        <Field label="After (days)"><input className="input input-sm" inputMode="numeric" style={{ width: 72 }} value={draft.after_days} onChange={(e) => setDraft({ ...draft, after_days: e.target.value.replace(/\D/g, "").slice(0, 3) })} /></Field>
        <Field label="How">
          <select className="select input-sm" value={draft.channel} onChange={(e) => setDraft({ ...draft, channel: e.target.value })}>{CHANNELS.map((c) => <option key={c.value} value={c.value}>{c.label}</option>)}</select>
        </Field>
        <Button type="submit" size="sm" loading={add.isPending} disabled={!draft.stage_id || !draft.title.trim()}>Add step</Button>
      </form>
      <FormError error={add.error ?? update.error ?? remove.error} />
    </section>
  );
}

function TemplateSettings() {
  const { company } = useSession();
  const queryClient = useQueryClient();
  const templates = useTemplates(company.id);
  const empty = { id: "", name: "", channel: "call", subject: "", body: "" };
  const [editing, setEditing] = useState(empty);
  const refresh = () => queryClient.invalidateQueries({ queryKey: ["pipeline-templates", company.id] });
  const save = useMutation({
    mutationFn: async () => {
      const row = { name: editing.name.trim(), channel: editing.channel, subject: editing.channel === "email" ? editing.subject.trim() || null : null, body: editing.body.trim() };
      if (editing.id) unwrap(await supabase().from("pipeline_templates").update(row).eq("id", editing.id).select("id"));
      else unwrap(await supabase().from("pipeline_templates").insert({ ...row, company_id: company.id }).select("id"));
    },
    onSuccess: () => {
      toast.success("Template saved");
      setEditing(empty);
      refresh();
    },
  });
  const toggle = useMutation({
    mutationFn: async (t: Template) => unwrap(await supabase().from("pipeline_templates").update({ active: !t.active }).eq("id", t.id).select("id")),
    onSuccess: refresh,
  });
  return (
    <section className="card card-pad stack">
      <strong>Templates</strong>
      <span className="muted small">Call scripts and text or email drafts your team starts from when they log a contact. Write them in your own words; none come preset. They're never sent by themselves.</span>
      {(templates.data ?? []).length > 0 && (
        <table className="table table-stack" aria-label="Templates">
          <thead><tr><th>Name</th><th>For</th><th>On</th><th /></tr></thead>
          <tbody>
            {(templates.data ?? []).map((t) => (
              <tr key={t.id}>
                <td><strong>{t.name}</strong><div className="muted small ellipsis" style={{ maxWidth: 420 }}>{t.body}</div></td>
                <td>{CHANNELS.find((c) => c.value === t.channel)?.label}</td>
                <td><input type="checkbox" className="switch" aria-label={`${t.name}: on`} checked={t.active} onChange={() => toggle.mutate(t)} /></td>
                <td><Button size="sm" onClick={() => setEditing({ id: t.id, name: t.name, channel: t.channel, subject: t.subject ?? "", body: t.body })}>Edit</Button></td>
              </tr>
            ))}
          </tbody>
        </table>
      )}
      <form className="stack-sm" onSubmit={(e) => { e.preventDefault(); if (editing.name.trim() && editing.body.trim()) save.mutate(); }}>
        <strong className="small">{editing.id ? "Edit template" : "New template"}</strong>
        <div className="row wrap" style={{ gap: 8 }}>
          <Field label="Name" className="grow"><input className="input input-sm" maxLength={80} value={editing.name} onChange={(e) => setEditing({ ...editing, name: e.target.value })} /></Field>
          <Field label="For">
            <select className="select input-sm" value={editing.channel} onChange={(e) => setEditing({ ...editing, channel: e.target.value })}>{CHANNELS.filter((c) => c.value !== "task").map((c) => <option key={c.value} value={c.value}>{c.label}</option>)}</select>
          </Field>
        </div>
        {editing.channel === "email" && <Field label="Subject" optional><input className="input input-sm" maxLength={200} value={editing.subject} onChange={(e) => setEditing({ ...editing, subject: e.target.value })} /></Field>}
        <Field label={editing.channel === "call" ? "Script" : "Message"}><textarea className="textarea" rows={4} maxLength={4000} value={editing.body} onChange={(e) => setEditing({ ...editing, body: e.target.value })} /></Field>
        <FormError error={save.error} />
        <div className="row" style={{ gap: 8 }}>
          <Button type="submit" size="sm" variant="primary" loading={save.isPending} disabled={!editing.name.trim() || !editing.body.trim()}>{editing.id ? "Save template" : "Add template"}</Button>
          {editing.id && <Button size="sm" onClick={() => setEditing(empty)}>Cancel</Button>}
        </div>
      </form>
    </section>
  );
}
