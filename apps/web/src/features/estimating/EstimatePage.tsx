/**
 * Planet Ops Phase 3: one internal estimate, as a guided editor. Its steps follow the bid workbook and
 * the Future Bid Checklist: Project and site → Labor → Equipment → Disposal and hauling → Other costs
 * → Pricing review → Versions and documents. The arithmetic shown while editing is
 * packages/core/src/estimating.ts; what's saved is the database's own calculation of the same.
 * Saving never sends anything. Costs, rates and profit show only with "See estimating costs".
 */
import { calculateEstimate, ESTIMATE_UNITS, METRIC_DEFINITIONS, SECTION_LABELS, UNIT_LABELS, type EstimateSection, type OwnerPayMethod, type PricingMethod } from "@crewtavo/core/estimating";
import { useMutation, useQueryClient } from "@tanstack/react-query";
import { useEffect, useMemo, useState } from "react";
import { Link, useNavigate, useParams, useSearchParams } from "react-router-dom";
import { Button } from "@/components/ui/Button";
import { confirm } from "@/components/ui/Confirm";
import { Field, FormError } from "@/components/ui/Field";
import { Icon } from "@/components/ui/Icon";
import { BackLink, PageHeader } from "@/components/ui/PageHeader";
import { DetailSkeleton } from "@/components/ui/Skeleton";
import { PageError } from "@/components/ui/States";
import { supabase, unwrap } from "@/lib/api";
import { formatDate, formatDateTime, formatMoney } from "@/lib/format";
import { useSession } from "@/lib/session";
import { toast } from "@/lib/toast";
import { ClientPicker, PropertySelect, type PickedClient } from "../clients/ClientForm";
import { memberName, useTeam } from "../requests/RequestsPage";
import { approvesEstimates, estimateKey, estimatesKey, percentFromFraction, savePayload, seesEstimateCosts, useEstimate, useRates, type LineRow, type Scope, type VersionRow } from "./data";
import { estimateStatus } from "./EstimatesPage";
import { CreateDocumentDialog, EstimateDocuments } from "./Handoff";

const STEPS = [
  { key: "site", label: "Project and site" },
  { key: "labor", label: "Labor", sections: ["labor"] as EstimateSection[] },
  { key: "equipment", label: "Equipment", sections: ["equipment", "travel"] as EstimateSection[] },
  { key: "disposal", label: "Disposal and hauling", sections: ["disposal", "hauling"] as EstimateSection[] },
  { key: "other", label: "Other costs", sections: ["materials", "permits", "subcontractor", "other", "contingency"] as EstimateSection[] },
  { key: "pricing", label: "Pricing review" },
  { key: "versions", label: "Versions and documents" },
] as const;
type StepKey = (typeof STEPS)[number]["key"];

interface Pricing { method: PricingMethod; pct: string; owner: OwnerPayMethod; owner_pct: string; burden_pct: string; default_risk_pct: string }
interface Draft { title: string; project_type: string; scope: Scope; assumptions: VersionRow["assumptions"]; lines: LineRow[]; pricing: Pricing; client: PickedClient; property_id: string | null; estimator_id: string | null }

let keySeq = 0;
const newKey = () => `l${Date.now().toString(36)}${(keySeq++).toString(36)}`;

export function EstimatePage() {
  const { id = "" } = useParams();
  const session = useSession();
  const navigate = useNavigate();
  const queryClient = useQueryClient();
  const [params, setParams] = useSearchParams();
  const [making, setMaking] = useState(false);
  const costs = seesEstimateCosts(session);
  const approver = approvesEstimates(session);
  const versionParam = params.get("version");
  const data = useEstimate(id, versionParam, costs);
  const rates = useRates(session.company.id);
  const team = useTeam(session.company.id);
  const step = (STEPS.find((s) => s.key === params.get("step"))?.key ?? "site") as StepKey;
  const [draft, setDraft] = useState<Draft | null>(null);
  const [dirty, setDirty] = useState(false);

  const d = data.data;
  useEffect(() => {
    if (!d) return;
    setDraft({
      title: d.estimate.title,
      project_type: d.estimate.project_type ?? "",
      scope: d.version.scope ?? {},
      assumptions: d.version.assumptions ?? [],
      lines: d.lines.map((l) => ({ ...l, key: l.key ?? newKey() })),
      pricing: {
        method: d.costs?.pricing_method ?? d.version.pricing_method,
        pct: percentFromFraction(d.costs?.pricing_pct),
        owner: d.costs?.owner_pay_method ?? d.version.owner_pay_method,
        owner_pct: percentFromFraction(d.costs?.owner_pct),
        burden_pct: percentFromFraction(d.costs?.burden_pct),
        default_risk_pct: percentFromFraction(d.costs?.default_risk_pct),
      },
      client: d.estimate.client_id ? { id: d.estimate.client_id, display_name: d.estimate.client?.display_name ?? "" } : null,
      property_id: d.estimate.property_id,
      estimator_id: d.estimate.estimator_id,
    });
    setDirty(false);
  }, [d]);

  const editable = d?.version.status === "draft";
  const live = useMemo(() => {
    if (!draft) return null;
    const frac = (t: string) => (t.trim() === "" ? null : String(Number(t) / 100));
    return calculateEstimate(draft.lines.map((l) => ({ ...l, risk_pct: l.risk_pct ?? 0 })), {
      method: draft.pricing.method,
      pct: frac(draft.pricing.pct),
      owner_pay: draft.pricing.owner,
      owner_pct: draft.pricing.owner === "percent_of_price" ? frac(draft.pricing.owner_pct) : undefined,
      burden_pct: frac(draft.pricing.burden_pct),
    });
  }, [draft]);

  const refresh = () => {
    queryClient.invalidateQueries({ queryKey: estimateKey(id) });
    queryClient.invalidateQueries({ queryKey: estimatesKey(session.company.id) });
  };
  const save = useMutation({
    mutationFn: async () => {
      const payload = { ...savePayload(draft!, costs), client_id: draft!.client?.id ?? null, property_id: draft!.property_id, estimator_id: draft!.estimator_id };
      return unwrap(await supabase().rpc("save_estimate_version", { p_version: d!.version.id, p_expected_revision: d!.version.revision, p_payload: payload as never })) as unknown as { revision: number; calc_status: string };
    },
    onSuccess: (r) => {
      toast.success(r.calc_status === "ok" ? "Estimate saved" : "Saved. It isn't complete yet: see what's missing", { tone: "quote" });
      refresh();
    },
  });
  const approve = useMutation({
    mutationFn: async (note: string) => unwrap(await supabase().rpc("approve_estimate_version", { p_version: d!.version.id, p_note: note || undefined })) as unknown as { baseline: boolean },
    onSuccess: (r) => {
      toast.success(r.baseline ? "Approved: this is the estimate's original baseline" : "Revision approved", { tone: "job" });
      refresh();
    },
  });
  const revise = useMutation({
    mutationFn: async (reason: string) => unwrap(await supabase().rpc("revise_estimate", { p_estimate: id, p_reason: reason || undefined })) as unknown as string,
    onSuccess: (vid) => {
      refresh();
      setParams({ version: vid, step: "site" });
    },
  });

  if (data.isPending || !draft) return data.error ? <PageError error={data.error} onRetry={() => data.refetch()} back={<BackLink to="/estimates">Estimating</BackLink>} /> : <DetailSkeleton />;
  if (!d) return null;
  const set = (patch: Partial<Draft>) => {
    setDraft({ ...draft, ...patch });
    setDirty(true);
  };
  const status = estimateStatus(d.estimate);
  const problems = live?.problems ?? [];
  const goTo = (s: StepKey) => setParams({ ...(versionParam ? { version: versionParam } : {}), step: s }, { replace: true });

  return (
    <>
      <BackLink to="/estimates">Estimating</BackLink>
      <PageHeader
        title={draft.title}
        actions={
          <>
            <Link className="btn" to={`/estimates/${id}/summary`}><Icon name="file" size={16} />Summary</Link>
            {editable && <Button variant="primary" icon="check" loading={save.isPending} disabled={!dirty} onClick={() => save.mutate()}>Save</Button>}
            {!editable && <Button icon="edit" loading={revise.isPending} onClick={async () => { const reason = window.prompt("Why is it being revised? (kept with the revision)") ?? null; if (reason !== null) revise.mutate(reason); }}>Revise</Button>}
            <Button icon="quote" disabled={dirty || d.version.calc_status !== "ok" || !d.version.saved_at} onClick={() => setMaking(true)}>Create quote / proposal</Button>
          </>
        }
      />
      <div className="page-meta">
        <span className="muted">Estimate #{d.estimate.number} · version {d.version.number}</span>
        <span className="pill pill-quiet">{status.label}</span>
        {d.estimate.request_id && d.estimate.request && <Link to={`/requests/${d.estimate.request_id}`} className="strong">Request #{d.estimate.request.number}{d.estimate.request.stage ? ` · ${d.estimate.request.stage.label}` : ""}</Link>}
        {draft.client && <Link to={`/clients/${draft.client.id}`}>{draft.client.display_name}</Link>}
        {!editable && <span className="muted small">Version {d.version.number} is approved and frozen. Revise to change it.</span>}
        {dirty && <span className="text-danger small strong">Unsaved changes</span>}
      </div>
      <FormError error={save.error ?? approve.error ?? revise.error} />

      <div className="tabs" role="group" aria-label="Estimate steps" style={{ flexWrap: "wrap", marginBottom: 16 }}>
        {STEPS.map((s, i) => (
          <button key={s.key} type="button" className="tab" aria-pressed={step === s.key} onClick={() => goTo(s.key)}>{i + 1}. {s.label}</button>
        ))}
      </div>

      <div className="two-col" data-planet-ops="estimate-editor">
        <div className="wide stack-lg">
          {step === "site" && <SiteStep draft={draft} set={set} editable={editable} requestId={d.estimate.request_id} />}
          {STEPS.filter((s): s is Extract<(typeof STEPS)[number], { sections: EstimateSection[] }> => "sections" in s).map((s) =>
            step === s.key ? <LinesStep key={s.key} sections={s.sections} draft={draft} set={set} editable={editable} costs={costs} rates={rates.data ?? []} live={live} /> : null,
          )}
          {step === "pricing" && <PricingStep draft={draft} set={set} editable={editable} costs={costs} live={live} />}
          {step === "versions" && (
            <VersionsStep data={d} approver={approver} onApprove={(note) => approve.mutate(note)} approving={approve.isPending} dirty={dirty} name={(u) => memberName(team.data?.find((m) => m.user_id === u)) ?? "Someone"} onOpen={(vid) => setParams({ version: vid, step: "versions" })} />
          )}
        </div>
        <aside className="narrow stack" style={{ position: "sticky", top: 16, alignSelf: "start" }}>
          <div className="card card-pad stack-sm" data-planet-ops="estimate-totals">
            <strong>{costs ? "Calculated price" : "Estimate"}</strong>
            {costs && live ? (
              <dl className="kv">
                <dt>Base cost</dt><dd className="tabular">{formatMoney(live.base)}</dd>
                <dt>Risk reserve</dt><dd className="tabular">{formatMoney(live.risk)}</dd>
                <dt>Markup</dt><dd className="tabular">{formatMoney(live.markup)}</dd>
                <dt>Owner pay</dt><dd className="tabular">{formatMoney(live.owner_pay)}</dd>
                <dt><strong>Calculated selling price</strong></dt><dd className="tabular strong">{formatMoney(live.selling_price)}</dd>
              </dl>
            ) : (
              <span className="muted small">Costs, pricing and profit are shown to people with "See estimating costs, rates and profit".</span>
            )}
            {problems.length > 0 ? (
              <div className="small" role="status">
                <strong className="text-danger">Not complete: it can't be approved or sent on yet</strong>
                <ul style={{ margin: "4px 0 0", paddingLeft: 18 }}>{problems.slice(0, 6).map((p, i) => <li key={i}>{p.message}</li>)}</ul>
              </div>
            ) : (
              <span className="small text-success strong">Complete</span>
            )}
            {(live?.warnings ?? []).map((w, i) => <span key={i} className="small" style={{ color: "var(--warning)" }}>⚠ {w.message}</span>)}
            <span className="muted small">Saving or calculating never sends anything to the customer.</span>
          </div>
        </aside>
      </div>
      {making && <CreateDocumentDialog version={d.version} estimateTitle={draft.title} onClose={() => setMaking(false)} onCreated={(qid) => navigate(`/quotes/${qid}`)} />}
    </>
  );
}

function SiteStep({ draft, set, editable, requestId }: { draft: Draft; set: (p: Partial<Draft>) => void; editable: boolean; requestId: string | null }) {
  const s = draft.scope;
  const team = useTeam(useSession().company.id);
  const sc = (patch: Partial<Scope>) => set({ scope: { ...s, ...patch } });
  const text = (key: keyof Scope, label: string, hint?: string, rows = 2) => (
    <Field label={label} optional hint={hint}>
      <textarea className="textarea" rows={rows} maxLength={4000} disabled={!editable} value={(s[key] as string) ?? ""} onChange={(e) => sc({ [key]: e.target.value } as Partial<Scope>)} />
    </Field>
  );
  return (
    <>
      <section className="card card-pad stack" aria-label="Project">
        <strong>Project</strong>
        <div className="row wrap" style={{ gap: 12 }}>
          <Field label="Title" className="grow"><input className="input" value={draft.title} maxLength={200} disabled={!editable} onChange={(e) => set({ title: e.target.value })} /></Field>
          <Field label="Project type" optional><input className="input" value={draft.project_type} maxLength={120} disabled={!editable} onChange={(e) => set({ project_type: e.target.value })} placeholder="House demolition" /></Field>
        </div>
        {!requestId && (
          <Field label="Customer" optional hint="Needed before a quote or proposal is made from this estimate.">
            {editable ? <ClientPicker value={draft.client} onChange={(c) => set({ client: c, property_id: null })} allowCreate={false} /> : <span>{draft.client?.display_name ?? "—"}</span>}
          </Field>
        )}
        {draft.client && editable && <Field label="Property" optional><PropertySelect clientId={draft.client.id} value={draft.property_id} onChange={(p) => set({ property_id: p })} /></Field>}
        <Field label="Estimator">
          <select className="select" value={draft.estimator_id ?? ""} disabled={!editable} onChange={(e) => set({ estimator_id: e.target.value || null })} style={{ maxWidth: 320 }}>
            <option value="">Nobody yet</option>
            {(team.data ?? []).filter((m) => m.active).map((m) => <option key={m.user_id} value={m.user_id}>{memberName(m)}</option>)}
          </select>
        </Field>
      </section>
      <section className="card card-pad stack" aria-label="Structures and measurements">
        <strong>Structures and measurements</strong>
        <Field label="Total area (sq ft)" optional hint="Used for price per square foot. Measure, don't guess: the checklist's lesson.">
          <input className="input" inputMode="decimal" style={{ maxWidth: 160 }} disabled={!editable} value={s.area_sqft ?? ""} onChange={(e) => sc({ area_sqft: e.target.value.replace(/[^0-9.]/g, "") })} />
        </Field>
        {(s.structures ?? []).map((st, i) => (
          <div key={i} className="row wrap" style={{ gap: 8, alignItems: "end" }}>
            <Field label="Structure" className="grow"><input className="input input-sm" value={st.name} disabled={!editable} onChange={(e) => sc({ structures: (s.structures ?? []).map((x, j) => (j === i ? { ...x, name: e.target.value } : x)) })} /></Field>
            <Field label="Sq ft" optional><input className="input input-sm" inputMode="decimal" style={{ width: 100 }} value={st.sqft ?? ""} disabled={!editable} onChange={(e) => sc({ structures: (s.structures ?? []).map((x, j) => (j === i ? { ...x, sqft: e.target.value.replace(/[^0-9.]/g, "") } : x)) })} /></Field>
            <Field label="Stories" optional><input className="input input-sm" inputMode="numeric" style={{ width: 80 }} value={st.stories ?? ""} disabled={!editable} onChange={(e) => sc({ structures: (s.structures ?? []).map((x, j) => (j === i ? { ...x, stories: e.target.value.replace(/\D/g, "") } : x)) })} /></Field>
            {editable && <Button size="sm" icon="trash" aria-label={`Remove ${st.name || "structure"}`} onClick={() => sc({ structures: (s.structures ?? []).filter((_, j) => j !== i) })} />}
          </div>
        ))}
        {editable && <Button size="sm" icon="plus" style={{ justifySelf: "start" }} onClick={() => sc({ structures: [...(s.structures ?? []), { name: "" }] })}>Add a structure</Button>}
        {text("materials", "Materials and layers", "Siding, roofing layers, framing, masonry, chimneys…")}
        {text("foundation", "Foundation", "Slab, stem wall, piers, basement; depth and reinforcement")}
      </section>
      <section className="card card-pad stack" aria-label="Site conditions">
        <strong>Site conditions</strong>
        {text("access", "Access constraints", "Gates, driveway width, slopes, overhead lines, neighbors")}
        {text("utilities", "Utilities", "Disconnects and caps: who, when, and what's assumed")}
        {text("hazards", "Hazards", "Asbestos, lead, fire debris, septic, pools…")}
        {text("testing", "Testing assumptions", "What testing is assumed, and what happens if it finds something")}
        {text("site_notes", "Site notes", undefined, 3)}
      </section>
      <section className="card card-pad stack" aria-label="Scope boundaries">
        <strong>Inclusions and exclusions (internal)</strong>
        {text("inclusions", "Included", "The finished condition, in words: what's removed and what remains")}
        {text("exclusions", "Not included")}
      </section>
      <section className="card card-pad stack" aria-label="Customer scope">
        <strong>For the customer's document</strong>
        <span className="muted small">What a proposal made from this estimate says. Write it for the customer: no costs or internal notes.</span>
        {text("customer_overview", "Project overview", undefined, 2)}
        {text("customer_scope", "Scope of work", undefined, 3)}
        {text("customer_inclusions", "Included", undefined, 2)}
        {text("customer_exclusions", "Not included", undefined, 2)}
        {text("customer_assumptions", "Assumptions", undefined, 2)}
      </section>
      <section className="card card-pad stack" aria-label="Supporting files">
        <strong>Supporting files and evidence</strong>
        {(s.files ?? []).map((f, i) => (
          <div key={i} className="row wrap" style={{ gap: 8, alignItems: "end" }}>
            <Field label="Label" className="grow"><input className="input input-sm" value={f.label} disabled={!editable} onChange={(e) => sc({ files: (s.files ?? []).map((x, j) => (j === i ? { ...x, label: e.target.value } : x)) })} /></Field>
            <Field label="Link" optional className="grow"><input className="input input-sm" value={f.url ?? ""} disabled={!editable} onChange={(e) => sc({ files: (s.files ?? []).map((x, j) => (j === i ? { ...x, url: e.target.value } : x)) })} placeholder="Photos, plans, quotes from subs (a link within your business)" /></Field>
            {editable && <Button size="sm" icon="trash" aria-label={`Remove ${f.label || "file"}`} onClick={() => sc({ files: (s.files ?? []).filter((_, j) => j !== i) })} />}
          </div>
        ))}
        {editable && <Button size="sm" icon="plus" style={{ justifySelf: "start" }} onClick={() => sc({ files: [...(s.files ?? []), { label: "" }] })}>Add a file link</Button>}
        {requestId && <span className="muted small">Plans and photos on the request stay on the request: <Link to={`/requests/${requestId}`} style={{ textDecoration: "underline" }}>open it</Link>.</span>}
      </section>
      <AssumptionLog draft={draft} set={set} editable={editable} />
    </>
  );
}

function AssumptionLog({ draft, set, editable }: { draft: Draft; set: (p: Partial<Draft>) => void; editable: boolean }) {
  return (
    <section className="card card-pad stack" aria-label="Assumption log">
      <strong>Assumption log</strong>
      <span className="muted small">Every assumption the price rests on, and where it came from, so whoever reads the estimate later can follow it.</span>
      {draft.assumptions.map((a, i) => (
        <div key={i} className="row wrap" style={{ gap: 8, alignItems: "end" }}>
          <Field label="Assumption" className="grow"><input className="input input-sm" maxLength={500} value={a.text} disabled={!editable} onChange={(e) => set({ assumptions: draft.assumptions.map((x, j) => (j === i ? { ...x, text: e.target.value } : x)) })} /></Field>
          <Field label="Source" optional><input className="input input-sm" maxLength={200} value={a.source ?? ""} disabled={!editable} onChange={(e) => set({ assumptions: draft.assumptions.map((x, j) => (j === i ? { ...x, source: e.target.value } : x)) })} placeholder="Site visit, owner, photo" /></Field>
          {editable && <Button size="sm" icon="trash" aria-label="Remove assumption" onClick={() => set({ assumptions: draft.assumptions.filter((_, j) => j !== i) })} />}
        </div>
      ))}
      {editable && <Button size="sm" icon="plus" style={{ justifySelf: "start" }} onClick={() => set({ assumptions: [...draft.assumptions, { text: "" }] })}>Add an assumption</Button>}
    </section>
  );
}

/** Which columns each kind of line uses. */
const SECTION_HINTS: Record<EstimateSection, string> = {
  labor: "Count = people, Hours = per day, Days = working days. Rates are per hour; mark a rate that already includes payroll burden so it isn't burdened twice.",
  travel: "Truck fuel: gallons × $/gallon. Mileage: miles × $/mile. Lodging / per diem: people × nights × rate.",
  equipment: "Count = machines, Days or Hours, at the rental or owned rate. Mark a rate that already includes fuel; a separate fuel line for it is flagged.",
  disposal: "Price by what's billed (tons, hauls or loads). Keep the estimated weight, loose volume and container size apart: a 20-yard container isn't 20 measured yards.",
  hauling: "Trucking, fill and base deliveries: loads or tons at the delivered rate, separate from disposal.",
  materials: "Fill, gravel, shoring, tools, supplies and PPE.",
  permits: "Permits, inspections, air-quality reports and testing.",
  subcontractor: "Subcontracted work at their quote (ask for one: high variance).",
  other: "Anything else, explained. A credit can be a negative unit cost here.",
  contingency: "The bid workbook says always include one.",
};

function LinesStep({ sections, draft, set, editable, costs, rates, live }: { sections: EstimateSection[]; draft: Draft; set: (p: Partial<Draft>) => void; editable: boolean; costs: boolean; rates: ReturnType<typeof useRates>["data"] & object; live: ReturnType<typeof calculateEstimate> | null }) {
  const update = (key: string, patch: Partial<LineRow>) => set({ lines: draft.lines.map((l) => (l.key === key ? { ...l, ...patch } : l)) });
  const remove = (key: string) => set({ lines: draft.lines.filter((l) => l.key !== key) });
  const add = (section: EstimateSection) =>
    set({ lines: [...draft.lines, { key: newKey(), section, name: "", unit: section === "labor" ? "hour" : section === "disposal" ? "ton" : section === "equipment" ? "day" : "each", unit_cost: null, count: 1, hours: section === "labor" ? 8 : null, days: section === "labor" || section === "equipment" ? 1 : null, risk_pct: draft.pricing.default_risk_pct ? String(Number(draft.pricing.default_risk_pct) / 100) : 0 }] });
  const index = new Map(draft.lines.map((l, i) => [l.key, i]));
  return (
    <>
      {sections.map((section) => {
        const lines = draft.lines.filter((l) => l.section === section);
        const sectionRates = rates.filter((r) => r.section === section);
        return (
          <section key={section} className="card card-pad stack" aria-label={SECTION_LABELS[section]}>
            <strong>{SECTION_LABELS[section]}</strong>
            <span className="muted small">{SECTION_HINTS[section]}</span>
            {lines.length === 0 && <span className="muted small">No {SECTION_LABELS[section].toLowerCase()} lines.</span>}
            {lines.map((l) => {
              const i = index.get(l.key)!;
              const result = live?.lines[i];
              const missing = live?.problems.some((p) => p.line === i);
              return (
                <div key={l.key} className="card card-pad stack-sm" style={{ borderStyle: missing ? "dashed" : undefined }} data-line={l.name}>
                  <div className="row wrap" style={{ gap: 8, alignItems: "end" }}>
                    <Field label="Line" className="grow"><input className="input input-sm" value={l.name} maxLength={200} disabled={!editable} onChange={(e) => update(l.key!, { name: e.target.value })} placeholder={section === "labor" ? "Crew" : "Item"} /></Field>
                    {sectionRates.length > 0 && (
                      <Field label="Rate" optional>
                        <select className="select input-sm" value={l.rate_id ?? ""} disabled={!editable} onChange={(e) => { const r = sectionRates.find((x) => x.id === e.target.value); update(l.key!, r ? { rate_id: r.id, unit: r.unit, unit_cost: r.unit_cost === null ? l.unit_cost : String(r.unit_cost), includes_burden: r.includes_burden, includes_fuel: r.includes_fuel, owned: r.owned, name: l.name || r.name } : { rate_id: null }); }}>
                          <option value="">Typed here</option>
                          {sectionRates.map((r) => <option key={r.id} value={r.id}>{r.name} ({UNIT_LABELS[r.unit as keyof typeof UNIT_LABELS] ?? r.unit})</option>)}
                        </select>
                      </Field>
                    )}
                    {editable && <Button size="sm" icon="trash" aria-label={`Remove ${l.name || "line"}`} onClick={() => remove(l.key!)} />}
                  </div>
                  <div className="row wrap" style={{ gap: 8, alignItems: "end" }}>
                    <Num label={section === "labor" ? "People" : "Count"} value={l.count} disabled={!editable} onChange={(v) => update(l.key!, { count: v })} />
                    <Num label="Hours" value={l.hours} disabled={!editable} onChange={(v) => update(l.key!, { hours: v })} />
                    <Num label="Days" value={l.days} disabled={!editable} onChange={(v) => update(l.key!, { days: v })} />
                    <Field label="Unit">
                      <select className="select input-sm" value={l.unit} disabled={!editable || Boolean(l.rate_id)} onChange={(e) => update(l.key!, { unit: e.target.value })}>
                        {ESTIMATE_UNITS.map((u) => <option key={u} value={u}>{UNIT_LABELS[u]}</option>)}
                      </select>
                    </Field>
                    {costs && <Num label={`Unit cost ($/${UNIT_LABELS[l.unit as keyof typeof UNIT_LABELS] ?? l.unit})`} value={l.unit_cost} disabled={!editable || Boolean(l.rate_id)} onChange={(v) => update(l.key!, { unit_cost: v })} allowNegative={section === "other"} />}
                    {costs && <Num label="Risk %" value={l.risk_pct === null || l.risk_pct === undefined ? "" : String(Math.round(Number(l.risk_pct) * 1e6) / 1e4)} disabled={!editable} onChange={(v) => update(l.key!, { risk_pct: v === "" ? 0 : String(Number(v) / 100) })} />}
                  </div>
                  {section === "labor" && (
                    <div className="row wrap" style={{ gap: 12, alignItems: "center" }}>
                      <Field label="Role" optional><input className="input input-sm" value={l.role ?? ""} maxLength={80} disabled={!editable} onChange={(e) => update(l.key!, { role: e.target.value })} placeholder="Foreman, laborer, operator" /></Field>
                      <label className="row small" style={{ gap: 6 }}><input type="checkbox" checked={Boolean(l.overtime)} disabled={!editable} onChange={(e) => update(l.key!, { overtime: e.target.checked })} />Overtime hours</label>
                      <label className="row small" style={{ gap: 6 }}><input type="checkbox" checked={Boolean(l.includes_burden)} disabled={!editable || Boolean(l.rate_id)} onChange={(e) => update(l.key!, { includes_burden: e.target.checked })} />Rate already includes burden</label>
                    </div>
                  )}
                  {section === "equipment" && (
                    <div className="row wrap" style={{ gap: 12, alignItems: "center" }}>
                      <Field label="Owned or rented">
                        <select className="select input-sm" value={l.owned === true ? "owned" : l.owned === false ? "rented" : ""} disabled={!editable} onChange={(e) => update(l.key!, { owned: e.target.value === "" ? null : e.target.value === "owned" })}>
                          <option value="">Not said</option><option value="owned">Owned</option><option value="rented">Rented</option>
                        </select>
                      </Field>
                      <label className="row small" style={{ gap: 6 }}><input type="checkbox" checked={Boolean(l.includes_fuel)} disabled={!editable || Boolean(l.rate_id)} onChange={(e) => update(l.key!, { includes_fuel: e.target.checked })} />Rate already includes fuel</label>
                      <Field label="Fuel for" optional>
                        <select className="select input-sm" value={l.fuel_for ?? ""} disabled={!editable} onChange={(e) => update(l.key!, { fuel_for: e.target.value || null })}>
                          <option value="">Not a fuel line</option>
                          {draft.lines.filter((x) => x.section === "equipment" && x.key !== l.key).map((x) => <option key={x.key} value={x.key}>{x.name || "Unnamed"}</option>)}
                        </select>
                      </Field>
                    </div>
                  )}
                  {section === "disposal" && (
                    <div className="row wrap" style={{ gap: 8, alignItems: "end" }}>
                      <Field label="Material stream" optional><input className="input input-sm" value={l.material_stream ?? ""} disabled={!editable} onChange={(e) => update(l.key!, { material_stream: e.target.value })} placeholder="C&D, concrete, metal, green…" /></Field>
                      <Field label="Facility" optional><input className="input input-sm" value={l.facility ?? ""} disabled={!editable} onChange={(e) => update(l.key!, { facility: e.target.value })} /></Field>
                      <Num label="Est. tons" value={l.est_tons} disabled={!editable} onChange={(v) => update(l.key!, { est_tons: v })} />
                      <Num label="Est. loose CY" value={l.est_loose_cy} disabled={!editable} onChange={(v) => update(l.key!, { est_loose_cy: v })} />
                      <Num label="Container CY" value={l.container_cy} disabled={!editable} onChange={(v) => update(l.key!, { container_cy: v })} />
                      <Num label="Expected loads" value={l.expected_loads} disabled={!editable} onChange={(v) => update(l.key!, { expected_loads: v })} />
                    </div>
                  )}
                  <div className="row wrap" style={{ gap: 8, alignItems: "end" }}>
                    <Field label="On the customer's document as" optional hint="Lines with the same name are one customer line, at their selling price. Costs never show."><input className="input input-sm" value={l.customer_item ?? ""} maxLength={200} disabled={!editable} onChange={(e) => update(l.key!, { customer_item: e.target.value })} placeholder={SECTION_LABELS[section]} /></Field>
                    <Field label="Notes (internal)" optional className="grow"><input className="input input-sm" value={l.notes ?? ""} maxLength={2000} disabled={!editable} onChange={(e) => update(l.key!, { notes: e.target.value })} /></Field>
                  </div>
                  {costs && result && <span className="small muted tabular">Base {formatMoney(result.base)} · risk {formatMoney(result.risk)} · subtotal {formatMoney(result.subtotal)} · selling share {formatMoney(result.price)}</span>}
                  {!costs && l.rate_id && <span className="small muted">Priced from the {rates.find((r) => r.id === l.rate_id)?.name ?? "selected"} rate.</span>}
                </div>
              );
            })}
            {editable && <Button size="sm" icon="plus" style={{ justifySelf: "start" }} onClick={() => add(section)}>Add {SECTION_LABELS[section].toLowerCase()} line</Button>}
          </section>
        );
      })}
    </>
  );
}

function Num({ label, value, onChange, disabled, allowNegative }: { label: string; value: unknown; onChange: (v: string) => void; disabled?: boolean; allowNegative?: boolean }) {
  return (
    <Field label={label} optional>
      <input className="input input-sm" inputMode="decimal" style={{ width: 110 }} disabled={disabled} value={value === null || value === undefined ? "" : String(value)} onChange={(e) => onChange(e.target.value.replace(allowNegative ? /[^0-9.-]/g : /[^0-9.]/g, ""))} />
    </Field>
  );
}

function PricingStep({ draft, set, editable, costs, live }: { draft: Draft; set: (p: Partial<Draft>) => void; editable: boolean; costs: boolean; live: ReturnType<typeof calculateEstimate> | null }) {
  if (!costs) return <div className="card card-pad muted">Pricing and profit are shown to people with "See estimating costs, rates and profit".</div>;
  const p = draft.pricing;
  const pr = (patch: Partial<Pricing>) => set({ pricing: { ...p, ...patch } });
  const area = Number(draft.scope.area_sqft);
  return (
    <>
      <section className="card card-pad stack" aria-label="Pricing method">
        <strong>Pricing method</strong>
        <span className="muted small">Choose one. Markup is the bid workbook's method (a % of the subtotal, so the risk reserve is marked up too). A target margin sets the price so the fee is that % of the price. They never both apply.</span>
        <div className="row wrap" style={{ gap: 16 }}>
          <label className="row" style={{ gap: 6 }}><input type="radio" name="method" checked={p.method === "markup"} disabled={!editable} onChange={() => pr({ method: "markup" })} />Markup on cost</label>
          <label className="row" style={{ gap: 6 }}><input type="radio" name="method" checked={p.method === "margin"} disabled={!editable} onChange={() => pr({ method: "margin" })} />Target margin</label>
        </div>
        <Field label={p.method === "markup" ? "Markup %" : "Target margin % (under 100)"}><input className="input" inputMode="decimal" style={{ maxWidth: 120 }} value={p.pct} disabled={!editable} onChange={(e) => pr({ pct: e.target.value.replace(/[^0-9.]/g, "") })} /></Field>
      </section>
      <section className="card card-pad stack" aria-label="Owner pay">
        <strong>Owner pay</strong>
        <span className="muted small">The bid workbook adds owner pay as a % of the price after markup. Whether it applies, and its %, is this estimate's to say: there's no default.</span>
        <div className="row wrap" style={{ gap: 16 }}>
          <label className="row" style={{ gap: 6 }}><input type="radio" name="owner" checked={p.owner === "none"} disabled={!editable} onChange={() => pr({ owner: "none" })} />No owner pay</label>
          <label className="row" style={{ gap: 6 }}><input type="radio" name="owner" checked={p.owner === "percent_of_price"} disabled={!editable} onChange={() => pr({ owner: "percent_of_price" })} />% of the price before owner pay, added on top</label>
        </div>
        {p.owner === "percent_of_price" && <Field label="Owner pay %"><input className="input" inputMode="decimal" style={{ maxWidth: 120 }} value={p.owner_pct} disabled={!editable} onChange={(e) => pr({ owner_pct: e.target.value.replace(/[^0-9.]/g, "") })} /></Field>}
      </section>
      <section className="card card-pad stack" aria-label="Labor burden and risk">
        <strong>Labor burden and risk</strong>
        <Field label="Labor burden %" optional hint="Payroll taxes, workers' comp and the like, added to labor lines whose rate doesn't already include it. Not in the bid workbook: leave empty for none.">
          <input className="input" inputMode="decimal" style={{ maxWidth: 120 }} value={p.burden_pct} disabled={!editable} onChange={(e) => pr({ burden_pct: e.target.value.replace(/[^0-9.]/g, "") })} />
        </Field>
        <Field label="Default risk % for new lines" optional hint="Only fills in new lines; each line's own risk % is what counts.">
          <input className="input" inputMode="decimal" style={{ maxWidth: 120 }} value={p.default_risk_pct} disabled={!editable} onChange={(e) => pr({ default_risk_pct: e.target.value.replace(/[^0-9.]/g, "") })} />
        </Field>
      </section>
      {live && (
        <section className="card card-pad stack" aria-label="Price and profit">
          <strong>Price and profit</strong>
          <table className="table" aria-label="Price and profit">
            <tbody>
              {([
                ["Base cost", live.base, METRIC_DEFINITIONS.base],
                ["Risk reserve", live.risk, METRIC_DEFINITIONS.risk],
                ["Subtotal", live.subtotal, METRIC_DEFINITIONS.subtotal],
                [p.method === "markup" ? "Markup" : "Margin fee", live.markup, METRIC_DEFINITIONS.markup],
                ["Price before owner pay", live.price_before_owner_pay, METRIC_DEFINITIONS.price_before_owner_pay],
                ["Owner pay", live.owner_pay, METRIC_DEFINITIONS.owner_pay],
                ["Calculated selling price", live.selling_price, METRIC_DEFINITIONS.selling_price],
                ["Profit if the reserve isn't used", live.profit_if_reserve_unused, METRIC_DEFINITIONS.profit_if_reserve_unused],
              ] as const).map(([label, amount, hint]) => (
                <tr key={label}><td><strong>{label}</strong><div className="muted small">{hint}</div></td><td className="num tabular">{formatMoney(amount)}</td></tr>
              ))}
              <tr><td><strong>Sheet margin</strong><div className="muted small">{METRIC_DEFINITIONS.sheet_margin}</div></td><td className="num tabular">{live.sheet_margin === null ? "—" : `${(live.sheet_margin * 100).toFixed(1)}%`}</td></tr>
              <tr><td><strong>Price per sq ft</strong><div className="muted small">Calculated selling price ÷ the total area on Project and site.</div></td><td className="num tabular">{area > 0 ? formatMoney(live.selling_price / area) : "—"}</td></tr>
            </tbody>
          </table>
          <span className="muted small">This is the calculated price. What the customer is sent, and what they sign, are kept on the quote or proposal and never change these figures.</span>
        </section>
      )}
    </>
  );
}

function VersionsStep({ data, approver, onApprove, approving, dirty, name, onOpen }: { data: NonNullable<ReturnType<typeof useEstimate>["data"]>; approver: boolean; onApprove: (note: string) => void; approving: boolean; dirty: boolean; name: (u: string | null) => string; onOpen: (versionId: string) => void }) {
  const [note, setNote] = useState("");
  const [asking, setAsking] = useState(false);
  const v = data.version;
  const versions = [...data.estimate.versions].sort((a, b) => b.number - a.number);
  return (
    <>
      <section className="card card-pad stack" aria-label="Approval">
        <strong>Approval</strong>
        {v.status === "approved" ? (
          <span>Version {v.number} was approved {v.approved_at ? formatDateTime(v.approved_at) : ""} by {name(v.approved_by)}{v.approval_note ? `: ${v.approval_note}` : ""}. {data.estimate.baseline_version_id === v.id ? "It's the estimate's original baseline." : "It's an approved revision; the original baseline stays as it was."}</span>
        ) : approver ? (
          <>
            <span className="muted small">Approving freezes this version. The first approved version is the estimate's original baseline; later changes are revisions.</span>
            <Field label="Approval note" optional><input className="input" value={note} maxLength={1000} onChange={(e) => setNote(e.target.value)} /></Field>
            <Button variant="primary" icon="check" style={{ justifySelf: "start" }} loading={approving} disabled={dirty || v.calc_status !== "ok" || !v.saved_at} onClick={async () => { if (await confirm({ title: `Approve version ${v.number}?`, body: "It's frozen from now on: changes become a revision.", confirmLabel: "Approve" })) onApprove(note); }}>Approve version {v.number}</Button>
            {(dirty || v.calc_status !== "ok") && <span className="small text-danger">Save a complete estimate first.</span>}
          </>
        ) : (
          <span className="muted">Waiting for someone with Approve estimates.</span>
        )}
        {asking && <span />}
      </section>
      <section className="card card-pad stack" aria-label="Versions">
        <strong>Versions</strong>
        <table className="table table-stack">
          <thead><tr><th>Version</th><th>Status</th><th>Saved</th><th>Approved</th><th /></tr></thead>
          <tbody>
            {versions.map((x) => (
              <tr key={x.id}>
                <td>v{x.number}{x.id === data.estimate.baseline_version_id ? " · original baseline" : ""}</td>
                <td>{x.status === "approved" ? "Approved" : x.calc_status === "ok" ? "Draft" : "Draft, incomplete"}</td>
                <td>{x.saved_at ? formatDate(x.saved_at) : "—"}</td>
                <td>{x.approved_at ? formatDate(x.approved_at) : "—"}</td>
                <td>{x.id !== v.id && <Button size="sm" onClick={() => { setAsking(false); onOpen(x.id); }}>Open</Button>}</td>
              </tr>
            ))}
          </tbody>
        </table>
        {v.revision_reason && <span className="muted small">Version {v.number}: {v.revision_reason}</span>}
      </section>
      <EstimateDocuments estimateId={data.estimate.id} />
    </>
  );
}

