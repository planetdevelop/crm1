/**
 * Planet Ops Phase 1b: Quotes & Proposals (docs/PLANET_OPS_IMPLEMENTATION_PLAN.md §3).
 *
 * One customer-document record, two layouts:
 *   - a line-item quote: priced lines and their totals;
 *   - a proposal: project overview, scope in work order, inclusions, exclusions, assumptions,
 *     optional alternates, and a clear total.
 * Both use the quote's one total, and both carry two separate sections, Contract Terms and Payment
 * Terms, filled from the company's defaults and edited for the job. Internal estimating (costs,
 * markup, owner pay) is never part of either: that's the separate Estimating area (Phase 3).
 *
 * The database (20261120000200_planet_ops_quotes_and_proposals.sql) keeps the same shape: quotes.
 * presentation, quotes.narrative (only these section keys), quotes.contract_terms and payment_terms.
 */

export const PRESENTATIONS = ["line_items", "proposal"] as const;
export type Presentation = (typeof PRESENTATIONS)[number];

export const PRESENTATION_LABELS: Record<Presentation, string> = {
  line_items: "Line-item quote",
  proposal: "Proposal",
};

export const isPresentation = (value: unknown): value is Presentation => value === "line_items" || value === "proposal";

/** The proposal's sections, in the order they print. */
export const NARRATIVE_SECTIONS = [
  { key: "overview", label: "Project overview", hint: "What the project is and where." },
  { key: "scope", label: "Scope of work", hint: "The work, in the order it will be done." },
  { key: "inclusions", label: "Included", hint: "What the price includes." },
  { key: "exclusions", label: "Not included", hint: "What the price doesn't include." },
  { key: "assumptions", label: "Assumptions", hint: "Site conditions and access the price assumes." },
  { key: "alternates", label: "Optional alternates", hint: "Options the customer can choose, priced separately." },
] as const;
export type NarrativeKey = (typeof NARRATIVE_SECTIONS)[number]["key"];
export type Narrative = Partial<Record<NarrativeKey, string>>;

/** The most each section holds (the database checks the whole narrative's size). */
export const NARRATIVE_MAX = 8000;
/** The most each of the Contract Terms and the Payment Terms holds. */
export const TERMS_MAX = 20000;

/** A stored narrative, keeping only its known sections as trimmed text. */
export function readNarrative(raw: unknown): Narrative {
  if (!raw || typeof raw !== "object" || Array.isArray(raw)) return {};
  const out: Narrative = {};
  for (const { key } of NARRATIVE_SECTIONS) {
    const value = (raw as Record<string, unknown>)[key];
    if (typeof value === "string" && value.trim()) out[key] = value.trim().slice(0, NARRATIVE_MAX);
  }
  return out;
}

/** The sections with something in them, in print order, with their headings. */
export function narrativeSections(raw: unknown): Array<{ key: NarrativeKey; title: string; text: string }> {
  const n = readNarrative(raw);
  return NARRATIVE_SECTIONS.flatMap(({ key, label }) => (n[key] ? [{ key, title: label, text: n[key]! }] : []));
}

/** The two terms sections as they print, each only when it has words. */
export function termsSections(quote: { contract_terms?: string | null; payment_terms?: string | null }): Array<{ key: "contract" | "payment"; title: string; text: string }> {
  const out: Array<{ key: "contract" | "payment"; title: string; text: string }> = [];
  const contract = quote.contract_terms?.trim();
  const payment = quote.payment_terms?.trim();
  if (contract) out.push({ key: "contract", title: "Contract Terms", text: contract });
  if (payment) out.push({ key: "payment", title: "Payment Terms", text: payment });
  return out;
}

/** The company's defaults and its countersignature rule, from companies.settings.quotes. */
export function proposalSettings(settings: unknown): { contractTerms: string; paymentTerms: string; countersignRequired: boolean } {
  const q = ((settings ?? {}) as Record<string, unknown>).quotes as Record<string, unknown> | undefined;
  return {
    contractTerms: typeof q?.contract_terms === "string" ? q.contract_terms : "",
    paymentTerms: typeof q?.payment_terms === "string" ? q.payment_terms : "",
    countersignRequired: q?.countersign_required === true,
  };
}

/**
 * Where an agreement stands on signatures. "Customer accepted" and "company countersigned" are
 * separate: one never implies the other.
 */
export function signatureState(input: { status: string; approval: unknown; countersignRequired: boolean }): "unsigned" | "awaiting_countersign" | "signed" {
  if (input.status !== "approved" && input.status !== "converted") return "unsigned";
  const a = input.approval && typeof input.approval === "object" && !Array.isArray(input.approval) ? (input.approval as Record<string, unknown>) : null;
  if (!a || a.method === "manual") return input.status === "converted" ? "signed" : "unsigned";
  const company = a.company && typeof a.company === "object" && !Array.isArray(a.company);
  return input.countersignRequired && !company ? "awaiting_countersign" : "signed";
}
