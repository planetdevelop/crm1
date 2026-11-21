/**
 * Planet Ops Phase 3: Estimating's data (20261124000100_planet_ops_estimating.sql). Estimates are
 * internal: their costs, rates, pricing and profit come only through estimate_version_costs and
 * estimate_rate_list, for people with "See estimating costs" (estimate_costs). Everyone with
 * "Prepare internal estimates" sees the scope, quantities and rate names.
 */
import type { EstimateLineInput, EstimateSection, OwnerPayMethod, PricingMethod } from "@crewtavo/core/estimating";
import { useQuery } from "@tanstack/react-query";
import { supabase, unwrap, unwrapOne } from "@/lib/api";
import { can, hasRole, type Session } from "@/lib/session";

export const canEstimate = (s: Session) => hasRole(s, "admin", "office", "estimator") && can(s, "estimate");
export const seesEstimateCosts = (s: Session) => canEstimate(s) && can(s, "estimate_costs");
export const approvesEstimates = (s: Session) => canEstimate(s) && can(s, "estimate_approve");

export interface EstimateRow {
  id: string;
  number: number;
  title: string;
  project_type: string | null;
  estimator_id: string | null;
  request_id: string | null;
  client_id: string | null;
  property_id: string | null;
  baseline_version_id: string | null;
  current_version_id: string | null;
  archived_at: string | null;
  created_at: string;
  updated_at: string;
  client: { display_name: string } | null;
  property: { line1: string | null; city: string | null } | null;
  request: { number: number; title: string; outcome_reason: string | null; stage: { label: string; kind: string } | null } | null;
  versions: Array<{ id: string; number: number; status: string; calc_status: string; saved_at: string | null; approved_at: string | null; locked_at: string | null }>;
}

const ESTIMATE_SELECT =
  "id, number, title, project_type, estimator_id, request_id, client_id, property_id, baseline_version_id, current_version_id, archived_at, created_at, updated_at, client:clients(display_name), property:properties(line1, city), request:requests(number, title, outcome_reason, stage:pipeline_stages(label, kind)), versions:estimate_versions!estimate_versions_company_id_estimate_id_fkey(id, number, status, calc_status, saved_at, approved_at, locked_at)";

export const estimatesKey = (companyId: string) => ["estimates", companyId];
export const useEstimates = (companyId: string, enabled = true) =>
  useQuery({
    queryKey: estimatesKey(companyId),
    enabled,
    queryFn: async () => unwrap(await supabase().from("estimates").select(ESTIMATE_SELECT).eq("company_id", companyId).order("updated_at", { ascending: false }).limit(500)) as unknown as EstimateRow[],
  });

export interface VersionRow {
  id: string;
  estimate_id: string;
  number: number;
  /** draft (editable), locked (used for a customer document without approval: kept as it was), approved (frozen). */
  status: "draft" | "locked" | "approved";
  revision: number;
  scope: Scope;
  assumptions: Array<{ text: string; source?: string }>;
  pricing_method: PricingMethod;
  owner_pay_method: OwnerPayMethod;
  calc_status: "ok" | "unresolved";
  calc_problems: Array<{ line?: number; field: string; message: string }>;
  based_on_version_id: string | null;
  revision_reason: string | null;
  saved_at: string | null;
  approved_at: string | null;
  approved_by: string | null;
  approval_note: string | null;
  locked_at: string | null;
}

/** Project and site, as the guided editor keeps them. The customer_* parts are what a proposal says. */
export interface Scope {
  project_type?: string;
  area_sqft?: string;
  structures?: Array<{ name: string; sqft?: string; stories?: string; notes?: string }>;
  materials?: string;
  foundation?: string;
  access?: string;
  utilities?: string;
  hazards?: string;
  testing?: string;
  inclusions?: string;
  exclusions?: string;
  site_notes?: string;
  files?: Array<{ label: string; url?: string; plan_file_id?: string }>;
  customer_overview?: string;
  customer_scope?: string;
  customer_inclusions?: string;
  customer_exclusions?: string;
  customer_assumptions?: string;
}

export interface LineRow extends EstimateLineInput {
  id?: string;
  sort?: number;
  section: EstimateSection;
  customer_item?: string | null;
  customer_description?: string | null;
  rate_id?: string | null;
  role?: string | null;
  overtime?: boolean;
  owned?: boolean | null;
  material_stream?: string | null;
  facility?: string | null;
  est_tons?: string | number | null;
  est_loose_cy?: string | number | null;
  container_cy?: string | number | null;
  expected_loads?: string | number | null;
  notes?: string | null;
}

export interface Costs {
  pricing_method: PricingMethod;
  pricing_pct: string | null;
  owner_pay_method: OwnerPayMethod;
  owner_pct: string | null;
  burden_pct: string | null;
  default_risk_pct: string | null;
  base_cost: number | null;
  risk_reserve: number | null;
  subtotal: number | null;
  markup_amount: number | null;
  price_before_owner_pay: number | null;
  owner_pay: number | null;
  selling_price: number | null;
  lines: Array<{ id: string; unit_cost: string | null; rate_snapshot: Record<string, unknown> | null; base: number | null; risk: number | null; subtotal: number | null; price: number | null }>;
}

const LINE_COLUMNS =
  "id, sort, key, section, name, customer_item, customer_description, count, hours, days, unit, rate_id, risk_pct, role, overtime, includes_burden, includes_fuel, owned, fuel_for, material_stream, facility, est_tons, est_loose_cy, container_cy, expected_loads, notes";
const VERSION_COLUMNS = "id, estimate_id, number, status, revision, scope, assumptions, pricing_method, owner_pay_method, calc_status, calc_problems, based_on_version_id, revision_reason, saved_at, approved_at, approved_by, approval_note, locked_at";

export const estimateKey = (id: string) => ["estimate", id];
export function useEstimate(id: string, versionId: string | null, costs: boolean) {
  return useQuery({
    queryKey: [...estimateKey(id), versionId, costs],
    queryFn: async () => {
      const estimate = unwrapOne(await supabase().from("estimates").select(ESTIMATE_SELECT).eq("id", id).maybeSingle(), "This estimate") as unknown as EstimateRow;
      const vid = versionId ?? estimate.current_version_id;
      const [version, lines, cost] = await Promise.all([
        supabase().from("estimate_versions").select(VERSION_COLUMNS).eq("id", vid!).single(),
        supabase().from("estimate_lines").select(LINE_COLUMNS).eq("version_id", vid!).order("sort"),
        costs ? supabase().rpc("estimate_version_costs", { p_version: vid! }) : Promise.resolve({ data: null, error: null }),
      ]);
      const c = (unwrap(cost) as unknown as Costs | null) ?? null;
      const byId = new Map((c?.lines ?? []).map((l) => [l.id, l]));
      const rows = (unwrap(lines) as unknown as LineRow[]).map((l) => ({ ...l, unit_cost: byId.get(l.id!)?.unit_cost ?? null, _costs: byId.get(l.id!) ?? null }));
      return { estimate, version: unwrap(version) as unknown as VersionRow, lines: rows, costs: c };
    },
  });
}

export interface Rate {
  id: string;
  code: string;
  section: EstimateSection;
  name: string;
  unit: string;
  unit_cost: number | null;
  includes_burden: boolean;
  includes_fuel: boolean;
  owned: boolean | null;
  effective_from: string;
  effective_to: string | null;
  notes: string | null;
}
export const ratesKey = (companyId: string) => ["estimate-rates", companyId];
export const useRates = (companyId: string, enabled = true) =>
  useQuery({ queryKey: ratesKey(companyId), enabled, queryFn: async () => (unwrap(await supabase().rpc("estimate_rate_list", { p_company: companyId })) as unknown as Rate[]) ?? [] });

/** A percent as typed (40) to the fraction stored (0.4), exactly; "" stays empty. */
export function fractionFromPercent(typed: string): string | null {
  const t = typed.trim();
  if (!t) return null;
  if (!/^\d*\.?\d*$/.test(t)) return t; // left as typed: the save refuses it with a message
  const [whole, frac = ""] = t.split(".");
  const digits = (whole || "0") + frac;
  const scale = frac.length + 2;
  const padded = digits.padStart(scale + 1, "0");
  const out = `${padded.slice(0, padded.length - scale)}.${padded.slice(padded.length - scale)}`.replace(/^0+(?=\d)/, "").replace(/\.?0+$/, "");
  return out === "" ? "0" : out;
}
/** A stored fraction (0.4) as a percent to show (40). */
export function percentFromFraction(stored: string | number | null | undefined): string {
  if (stored === null || stored === undefined || stored === "") return "";
  const t = String(stored);
  const [whole, frac = ""] = t.split(".");
  const f = frac.padEnd(2, "0");
  const out = `${whole}${f.slice(0, 2)}.${f.slice(2)}`.replace(/^0+(?=\d)/, "").replace(/\.?0+$/, "");
  return out === "" ? "0" : out;
}

/** The save payload for save_estimate_version from the editor's state. */
export function savePayload(state: { title: string; project_type: string; scope: Scope; assumptions: VersionRow["assumptions"]; lines: LineRow[]; pricing?: { method: PricingMethod; pct: string; owner: OwnerPayMethod; owner_pct: string; burden_pct: string; default_risk_pct: string } }, costs: boolean) {
  return {
    title: state.title,
    project_type: state.project_type,
    scope: state.scope,
    assumptions: state.assumptions.filter((a) => a.text.trim()),
    ...(costs && state.pricing
      ? {
          pricing_method: state.pricing.method,
          pricing_pct: fractionFromPercent(state.pricing.pct),
          owner_pay_method: state.pricing.owner,
          owner_pct: fractionFromPercent(state.pricing.owner_pct),
          burden_pct: fractionFromPercent(state.pricing.burden_pct),
          default_risk_pct: fractionFromPercent(state.pricing.default_risk_pct),
        }
      : {}),
    lines: state.lines.map((l) => {
      const { unit_cost, ...rest } = l as LineRow & { _costs?: unknown };
      delete (rest as { _costs?: unknown })._costs;
      return { ...rest, risk_pct: l.risk_pct === "" ? null : l.risk_pct, ...(costs && !l.rate_id ? { unit_cost } : {}) };
    }),
  };
}
