/**
 * Planet Ops Phase 1: a change order is finalized (added to its job, so it counts in the revised
 * contract and what can be invoiced) only once the customer has signed its exact current version.
 * That applies to added charges, credits and $0 scope or schedule changes alike. A staff "Mark
 * approved", a status change, an API call, an automation, a customer's note or a verbal yes never
 * stands in for it (docs/PLANET_OPS_IMPLEMENTATION_PLAN.md §3).
 *
 * The database enforces the same rule (migration 20261120000100_planet_ops_change_order_signature,
 * private.change_order_customer_signed); this copy lets the interface explain it before anyone tries.
 *
 * A customer signature is an approval the customer made themselves: on the client hub (their own
 * link, recorded with their name, the time and their address) or signed in person on the business's
 * device (method "in_person"). An approval the office kept without one has method "manual". Only the
 * server records a customer signature.
 *
 * "Exact version" is the whole document, not just its total: the database fingerprints its lines,
 * options, schedule, payment and contract terms (private.quote_version), refuses a signature from a
 * page that showed an older version, keeps the signed version with the approval, and refuses to
 * finalize a change order whose version moved on. The total check here is the part the interface can
 * see without asking the database. A finalized change order stays as signed: it can't be reopened,
 * edited or deleted; a revised agreement is a new change order, signed again.
 */

export interface ChangeOrderLike {
  change_order_for: string | null;
  status: string;
  total: number | string | null;
  approval: unknown;
}

export type ChangeOrderSignature =
  | { signed: true }
  | { signed: false; reason: "not_a_change_order" | "no_signature" | "staff_approval" | "changed_since_signed" };

export const CHANGE_ORDER_NEEDS_SIGNATURE =
  "A change order is added to the job only once the customer signs this exact version. Send it to them to sign, or have them sign it in person.";

export const CHANGE_ORDER_CHANGED_SINCE_SIGNED =
  "This change order changed after the customer signed it, so it needs their signature again before it's added to the job.";

const cents = (value: unknown): number | null => {
  const n = typeof value === "string" ? Number(value) : typeof value === "number" ? value : NaN;
  return Number.isFinite(n) ? Math.round(n * 100) : null;
};

/** Whether this change order carries the customer's own signature on the version it is now. */
export function changeOrderSignature(quote: ChangeOrderLike): ChangeOrderSignature {
  if (!quote.change_order_for) return { signed: false, reason: "not_a_change_order" };
  const a = quote.approval;
  if (!a || typeof a !== "object" || Array.isArray(a)) return { signed: false, reason: "no_signature" };
  const approval = a as Record<string, unknown>;
  if (approval.method === "manual") return { signed: false, reason: "staff_approval" };
  const name = typeof approval.name === "string" ? approval.name.trim() : "";
  if (!name || typeof approval.signed_at !== "string" || !approval.signed_at) return { signed: false, reason: "no_signature" };
  const signedTotal = cents(approval.total);
  if (signedTotal === null || signedTotal !== cents(quote.total)) return { signed: false, reason: "changed_since_signed" };
  return { signed: true };
}

/** What the office is told about finalizing this change order, or null when nothing stops it. */
export function changeOrderBlocker(quote: ChangeOrderLike): string | null {
  const s = changeOrderSignature(quote);
  if (s.signed || s.reason === "not_a_change_order") return null;
  return s.reason === "changed_since_signed" ? CHANGE_ORDER_CHANGED_SINCE_SIGNED : CHANGE_ORDER_NEEDS_SIGNATURE;
}
