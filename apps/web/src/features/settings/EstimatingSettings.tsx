/**
 * Settings → Estimating (Planet Ops Phase 3, 20261124000100_planet_ops_estimating.sql):
 *   settings.estimating.require_approval   a customer document can be made only from an approved
 *                                          estimate version (on unless switched off; owners and admins)
 *   estimate_rates                         the business's rates: unit, cost, from which day; a new cost
 *                                          is added from its day (earlier estimates keep theirs)
 * No rates come preset: the bid workbook's values aren't loaded. Costs show only with "See estimating
 * costs, rates and profit"; adding a rate needs it and Settings.
 */
import { ESTIMATE_SECTIONS, ESTIMATE_UNITS, SECTION_LABELS, UNIT_LABELS, type EstimateSection } from "@crewtavo/core/estimating";
import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import { useEffect, useState } from "react";
import { Button } from "@/components/ui/Button";
import { Field, FormError } from "@/components/ui/Field";
import { supabase, unwrap } from "@/lib/api";
import { formatDate, formatMoneyCents } from "@/lib/format";
import { can, hasRole, useSession } from "@/lib/session";
import { toast } from "@/lib/toast";
import { ratesKey, seesEstimateCosts, useRates, type Rate } from "../estimating/data";
import { companyToday } from "../pipeline/data";

export function EstimatingSettings() {
  const session = useSession();
  const { company } = session;
  const queryClient = useQueryClient();
  const costs = seesEstimateCosts(session);
  const canSetRates = costs && can(session, "settings");
  const isAdmin = hasRole(session, "admin");
  const rates = useRates(company.id);
  const settings = useQuery({ queryKey: ["company", company.id, "estimating"], queryFn: async () => unwrap(await supabase().from("companies").select("settings").eq("id", company.id).single()) });
  const requireApproval = ((settings.data?.settings ?? {}) as { estimating?: { require_approval?: boolean } }).estimating?.require_approval !== false;
  const setApproval = useMutation({
    mutationFn: async (on: boolean) => unwrap(await supabase().rpc("merge_company_settings", { p_company: company.id, p_settings: { estimating: { require_approval: on } } as never })),
    onSuccess: () => {
      queryClient.invalidateQueries({ queryKey: ["company", company.id] });
      session.refresh();
    },
  });
  const today = companyToday(company.timezone);
  const empty = { code: "", section: "labor" as EstimateSection, name: "", unit: "hour", cost: "", from: today, burden: false, fuel: false, owned: "", notes: "" };
  const [f, setF] = useState(empty);
  const [editing, setEditing] = useState<Rate | null>(null);
  useEffect(() => {
    if (editing) setF({ code: editing.code, section: editing.section, name: editing.name, unit: editing.unit, cost: "", from: today, burden: editing.includes_burden, fuel: editing.includes_fuel, owned: editing.owned === null ? "" : editing.owned ? "owned" : "rented", notes: editing.notes ?? "" });
  }, [editing, today]);
  const add = useMutation({
    mutationFn: async () =>
      unwrap(await supabase().rpc("set_estimate_rate", {
        p_company: company.id,
        p_code: f.code.trim() || f.name.trim().toLowerCase().replace(/[^a-z0-9]+/g, "-").replace(/^-|-$/g, "").slice(0, 60),
        p_section: f.section,
        p_name: f.name.trim(),
        p_unit: f.unit,
        p_unit_cost: Number(f.cost),
        p_effective_from: f.from,
        p_includes_burden: f.burden,
        p_includes_fuel: f.fuel,
        p_owned: f.owned === "" ? undefined : f.owned === "owned",
        p_notes: f.notes.trim() || undefined,
      })),
    onSuccess: () => {
      toast.success(editing ? `New cost for ${f.name} from ${formatDate(f.from)}` : "Rate added");
      setF(empty);
      setEditing(null);
      queryClient.invalidateQueries({ queryKey: ratesKey(company.id) });
    },
  });
  const list = (rates.data ?? []) as Rate[];

  return (
    <div className="stack-lg" data-planet-ops="estimating-settings">
      <section className="card card-pad stack">
        <strong>Approval</strong>
        <label className="switch-row" style={{ fontWeight: 400 }}>
          <input type="checkbox" className="switch" checked={requireApproval} disabled={!isAdmin || setApproval.isPending} onChange={(e) => setApproval.mutate(e.target.checked)} />
          A quote or proposal is made only from an approved estimate
        </label>
        <span className="muted small">Approving needs the Approve estimates area. Approved versions are frozen: the first is the estimate's original baseline, and later changes are revisions. {isAdmin ? "Saved as you switch it." : "Owners and admins change this."}</span>
        <FormError error={setApproval.error} />
      </section>
      <section className="card card-pad stack">
        <strong>Rates</strong>
        <span className="muted small">
          Your own labor, equipment, disposal and other rates, each from the day it takes effect. Changing a cost adds a new one from its day: estimates already saved keep the rate they took. None come preset.
        </span>
        {list.length === 0 ? (
          <span className="muted small">No rates yet. Lines can still be priced by typing a cost on the estimate.</span>
        ) : (
          <table className="table table-stack" aria-label="Estimating rates">
            <thead><tr><th>Rate</th><th>Section</th><th>Unit</th>{costs && <th className="num">Cost</th>}<th>From</th><th>Includes</th><th /></tr></thead>
            <tbody>
              {list.map((r) => (
                <tr key={r.id}>
                  <td><strong>{r.name}</strong><div className="muted small">{r.code}{r.notes ? ` · ${r.notes}` : ""}</div></td>
                  <td>{SECTION_LABELS[r.section]}</td>
                  <td>{UNIT_LABELS[r.unit as keyof typeof UNIT_LABELS] ?? r.unit}</td>
                  {costs && <td className="num tabular">{r.unit_cost === null ? "—" : formatMoneyCents(Number(r.unit_cost))}</td>}
                  <td>{formatDate(r.effective_from)}</td>
                  <td className="small">{[r.includes_burden && "burden", r.includes_fuel && "fuel", r.owned === true && "owned", r.owned === false && "rented"].filter(Boolean).join(", ") || "—"}</td>
                  <td>{canSetRates && <Button size="sm" onClick={() => setEditing(r)}>New cost</Button>}</td>
                </tr>
              ))}
            </tbody>
          </table>
        )}
        {canSetRates ? (
          <form className="stack-sm" onSubmit={(e) => { e.preventDefault(); if (f.name.trim() && f.cost !== "" && f.from) add.mutate(); }}>
            <strong className="small">{editing ? `New cost for ${editing.name}` : "Add a rate"}</strong>
            <div className="row wrap" style={{ gap: 8, alignItems: "end" }}>
              <Field label="Name" className="grow"><input className="input input-sm" maxLength={120} value={f.name} disabled={Boolean(editing)} onChange={(e) => setF({ ...f, name: e.target.value })} placeholder="Crew laborer" /></Field>
              <Field label="Section">
                <select className="select input-sm" value={f.section} disabled={Boolean(editing)} onChange={(e) => setF({ ...f, section: e.target.value as EstimateSection })}>{ESTIMATE_SECTIONS.map((s) => <option key={s} value={s}>{SECTION_LABELS[s]}</option>)}</select>
              </Field>
              <Field label="Unit">
                <select className="select input-sm" value={f.unit} disabled={Boolean(editing)} onChange={(e) => setF({ ...f, unit: e.target.value })}>{ESTIMATE_UNITS.map((u) => <option key={u} value={u}>{UNIT_LABELS[u]}</option>)}</select>
              </Field>
              <Field label="Cost ($ per unit)"><input className="input input-sm" inputMode="decimal" style={{ width: 120 }} value={f.cost} onChange={(e) => setF({ ...f, cost: e.target.value.replace(/[^0-9.]/g, "") })} /></Field>
              <Field label="From"><input className="input input-sm" type="date" value={f.from} onChange={(e) => setF({ ...f, from: e.target.value })} /></Field>
            </div>
            <div className="row wrap" style={{ gap: 12, alignItems: "center" }}>
              {f.section === "labor" && <label className="row small" style={{ gap: 6 }}><input type="checkbox" checked={f.burden} disabled={Boolean(editing)} onChange={(e) => setF({ ...f, burden: e.target.checked })} />Already includes payroll burden</label>}
              {f.section === "equipment" && (
                <>
                  <label className="row small" style={{ gap: 6 }}><input type="checkbox" checked={f.fuel} disabled={Boolean(editing)} onChange={(e) => setF({ ...f, fuel: e.target.checked })} />Already includes fuel</label>
                  <select className="select input-sm" aria-label="Owned or rented" value={f.owned} onChange={(e) => setF({ ...f, owned: e.target.value })}><option value="">Owned or rented?</option><option value="owned">Owned</option><option value="rented">Rented</option></select>
                </>
              )}
              <Field label="Notes" optional className="grow"><input className="input input-sm" maxLength={1000} value={f.notes} onChange={(e) => setF({ ...f, notes: e.target.value })} placeholder="Where the rate comes from" /></Field>
            </div>
            <FormError error={add.error} />
            <div className="row" style={{ gap: 8 }}>
              <Button type="submit" size="sm" variant="primary" loading={add.isPending} disabled={!f.name.trim() || f.cost === "" || !f.from}>{editing ? "Add the new cost" : "Add rate"}</Button>
              {editing && <Button size="sm" onClick={() => { setEditing(null); setF(empty); }}>Cancel</Button>}
            </div>
          </form>
        ) : (
          <span className="muted small">Adding rates needs "See estimating costs, rates and profit" and Settings.</span>
        )}
      </section>
    </div>
  );
}
