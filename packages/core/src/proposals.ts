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

import { isDrawnSignature } from "./changeOrders";

export const PRESENTATIONS = ["line_items", "proposal"] as const;
export type Presentation = (typeof PRESENTATIONS)[number];

export const PRESENTATION_LABELS: Record<Presentation, string> = {
  line_items: "Line-item quote",
  proposal: "Proposal",
};

/** What each layout shows the customer, for choosing one when a document is made or edited. */
export const PRESENTATION_HINTS: Record<Presentation, string> = {
  line_items: "Priced line items: what each service is, how much, and its price, with the total.",
  proposal: "A narrative scope (overview, work in order, inclusions, exclusions) and one clear total, without priced lines.",
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

/**
 * Planet Ops: until the business supplies its approved wording, new quotes start with these clearly
 * marked placeholders (the database's quote_default_terms has the same words). The quote page warns
 * while either is still a placeholder. Saving the setting empty means none.
 */
export const CONTRACT_TERMS_PLACEHOLDER = "[PLACEHOLDER] Contract Terms: Planet Demolition will supply the approved wording. This is not approved text; don't send it to a real customer.";
export const PAYMENT_TERMS_PLACEHOLDER = "[PLACEHOLDER] Payment Terms: Planet Demolition will supply the approved wording. This is not approved text; don't send it to a real customer.";
export const isPlaceholderTerms = (text: string | null | undefined) => typeof text === "string" && text.includes("[PLACEHOLDER]");

/** The company's defaults and its countersignature rule, from companies.settings.quotes. */
export function proposalSettings(settings: unknown): { contractTerms: string; paymentTerms: string; countersignRequired: boolean } {
  const q = ((settings ?? {}) as Record<string, unknown>).quotes as Record<string, unknown> | undefined;
  return {
    contractTerms: typeof q?.contract_terms === "string" ? q.contract_terms : CONTRACT_TERMS_PLACEHOLDER,
    paymentTerms: typeof q?.payment_terms === "string" ? q.payment_terms : PAYMENT_TERMS_PLACEHOLDER,
    countersignRequired: q?.countersign_required === true,
  };
}

/**
 * A company countersignature as the database keeps one (20261120000200 is_company_countersignature):
 * who signed (name, user), how (drawn now, or their saved drawing applied on purpose), the drawing,
 * and the time and version the database stamped it with, which is the version the customer signed.
 */
export function isCompanyCountersignature(approval: unknown): boolean {
  const a = approval && typeof approval === "object" && !Array.isArray(approval) ? (approval as Record<string, unknown>) : null;
  const c = a?.company && typeof a.company === "object" && !Array.isArray(a.company) ? (a.company as Record<string, unknown>) : null;
  return Boolean(
    c &&
      typeof c.name === "string" && c.name.trim().length > 0 &&
      typeof c.user_id === "string" &&
      (c.method === "drawn" || c.method === "saved") &&
      isDrawnSignature(c.signature) &&
      typeof c.signed_at === "string" &&
      typeof c.fingerprint === "string" && c.fingerprint === a!.fingerprint,
  );
}

/**
 * Where an agreement stands on signatures. "Customer accepted" and "company countersigned" are
 * separate: one never implies the other. The customer's is a drawn signature with their printed name
 * and the signing time; the company's, when it's required, an intentional countersignature on the
 * version the customer signed (isCompanyCountersignature).
 */
export function signatureState(input: { status: string; approval: unknown; countersignRequired: boolean }): "unsigned" | "awaiting_countersign" | "signed" {
  if (input.status !== "approved" && input.status !== "converted") return "unsigned";
  const a = input.approval && typeof input.approval === "object" && !Array.isArray(input.approval) ? (input.approval as Record<string, unknown>) : null;
  if (!a || a.method === "manual" || !isDrawnSignature(a.signature)) return input.status === "converted" ? "signed" : "unsigned";
  return input.countersignRequired && !isCompanyCountersignature(a) ? "awaiting_countersign" : "signed";
}
