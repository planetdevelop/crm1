/**
 * Planet Ops Phase 3: the internal demolition estimate's arithmetic, in the order the bid workbook
 * calculates (docs/planet-ops/ESTIMATING_MAPPING.md §2), with exact decimals. The database computes the
 * same (private.estimate_totals in 20261124000100_planet_ops_estimating.sql) and stores what it
 * computes; this module is the same arithmetic for the screens, and the tests hold the two together.
 *
 *   line base      = count × hours × days × unit cost (× (1 + burden %) for labor whose rate excludes burden)
 *   line risk      = base × line risk %
 *   line subtotal  = base + risk
 *   markup         = Σ subtotal × markup %                          (pricing method "markup", the sheet's)
 *                  | Σ subtotal ÷ (1 − margin %) − Σ subtotal        (pricing method "margin")
 *   price before owner pay = Σ subtotal + markup
 *   owner pay      = price before owner pay × owner %               (owner pay "percent_of_price", the sheet's) | 0
 *   selling price  = price before owner pay + owner pay
 *
 * Full precision throughout; each reported amount is rounded half up to the cent once, from its
 * unrounded value (a division, for the margin method, is carried to 10 decimal places first).
 */

/** An exact decimal: n × 10^-s. */
interface Dec {
  n: bigint;
  s: number;
}

const ZERO: Dec = { n: 0n, s: 0 };
const ONE: Dec = { n: 1n, s: 0 };

/** Reads a number or numeric string exactly (up to 12 decimal places), or null when it isn't one. */
export function parseDecimal(value: unknown): Dec | null {
  if (value === null || value === undefined || value === "") return null;
  const text = typeof value === "number" ? (Number.isFinite(value) ? value.toString() : "") : String(value).trim();
  if (/e/i.test(text)) {
    const n = Number(text);
    return Number.isFinite(n) ? parseDecimal(n.toFixed(12)) : null;
  }
  const m = /^(-)?(\d*)(?:\.(\d*))?$/.exec(text);
  if (!m || (!m[2] && !m[3])) return null;
  const frac = (m[3] ?? "").slice(0, 12);
  const n = BigInt((m[2] || "0") + frac) * (m[1] ? -1n : 1n);
  return { n, s: frac.length };
}

const align = (a: Dec, b: Dec): [bigint, bigint, number] => {
  const s = Math.max(a.s, b.s);
  return [a.n * 10n ** BigInt(s - a.s), b.n * 10n ** BigInt(s - b.s), s];
};
const add = (a: Dec, b: Dec): Dec => {
  const [x, y, s] = align(a, b);
  return { n: x + y, s };
};
const sub = (a: Dec, b: Dec): Dec => add(a, { n: -b.n, s: b.s });
const mul = (a: Dec, b: Dec): Dec => ({ n: a.n * b.n, s: a.s + b.s });
const sign = (a: Dec) => (a.n > 0n ? 1 : a.n < 0n ? -1 : 0);

/** a ÷ b rounded half up to `places` decimals. */
function div(a: Dec, b: Dec, places = 10): Dec {
  if (b.n === 0n) throw new RangeError("division by zero");
  // a/b = (a.n / 10^a.s) / (b.n / 10^b.s) = a.n × 10^(b.s) / (b.n × 10^(a.s))
  const num = a.n * 10n ** BigInt(b.s + places + 1);
  const den = b.n * 10n ** BigInt(a.s);
  const q = num / den;
  const r = q >= 0n ? (q + 5n) / 10n : (q - 5n) / 10n;
  return { n: r, s: places };
}

/** Rounded half up (away from zero) to cents, as a number of cents. */
export function toCentsExact(d: Dec): number {
  const scaled = d.s >= 2 ? d.n : d.n * 10n ** BigInt(2 - d.s);
  if (d.s <= 2) return Number(scaled);
  const unit = 10n ** BigInt(d.s - 2);
  const half = unit / 2n;
  const q = scaled >= 0n ? (scaled + half) / unit : (scaled - half) / unit;
  return Number(q);
}

const money = (d: Dec) => toCentsExact(d) / 100;

export const ESTIMATE_SECTIONS = ["labor", "travel", "equipment", "disposal", "hauling", "materials", "permits", "subcontractor", "other", "contingency"] as const;
export type EstimateSection = (typeof ESTIMATE_SECTIONS)[number];
export const SECTION_LABELS: Record<EstimateSection, string> = {
  labor: "Labor",
  travel: "Travel",
  equipment: "Equipment",
  disposal: "Disposal",
  hauling: "Hauling and fill",
  materials: "Materials and supplies",
  permits: "Permits and testing",
  subcontractor: "Subcontractors",
  other: "Other",
  contingency: "Contingency",
};

export const ESTIMATE_UNITS = ["hour", "day", "week", "ton", "cy", "load", "haul", "trip", "mile", "gallon", "each", "sqft", "lf", "lump"] as const;
export type EstimateUnit = (typeof ESTIMATE_UNITS)[number];
export const UNIT_LABELS: Record<EstimateUnit, string> = {
  hour: "hour", day: "day", week: "week", ton: "ton", cy: "cubic yard", load: "load", haul: "haul", trip: "trip",
  mile: "mile", gallon: "gallon", each: "each", sqft: "sq ft", lf: "linear ft", lump: "lump sum",
};

export type PricingMethod = "markup" | "margin";
export type OwnerPayMethod = "none" | "percent_of_price";

export interface EstimateLineInput {
  key?: string;
  section: EstimateSection;
  name: string;
  count?: unknown;
  hours?: unknown;
  days?: unknown;
  unit: EstimateUnit | string;
  /** Null when no rate is given yet: the estimate can't be approved. */
  unit_cost: unknown;
  /** Fraction, e.g. 0.07. */
  risk_pct?: unknown;
  /** Labor: the rate already includes burden (never burdened again). */
  includes_burden?: boolean;
  /** Equipment: the rate already includes fuel. */
  includes_fuel?: boolean;
  /** A fuel line: the key of the equipment line it fuels. */
  fuel_for?: string | null;
}

export interface EstimatePricingInput {
  method: PricingMethod;
  /** Fraction: markup % on the subtotal, or the target margin. */
  pct: unknown;
  owner_pay: OwnerPayMethod;
  owner_pct?: unknown;
  /** Fraction; applied to labor lines whose rate excludes burden. */
  burden_pct?: unknown;
}

export interface LineResult {
  key?: string;
  base: number;
  risk: number;
  subtotal: number;
  /** The line's share of the selling price (markup and owner pay spread by subtotal), for the customer document. */
  price: number;
}

export interface EstimateResult {
  lines: LineResult[];
  base: number;
  risk: number;
  subtotal: number;
  markup: number;
  price_before_owner_pay: number;
  owner_pay: number;
  selling_price: number;
  /** The sheet's "profit margin": markup ÷ price before owner pay. Null when the price is 0. */
  sheet_margin: number | null;
  /** Markup + risk reserve: what's left if the reserve isn't needed (owner pay apart). */
  profit_if_reserve_unused: number;
  /** "ok" when every line and setting has what it needs; "unresolved" otherwise (can't be approved). */
  status: "ok" | "unresolved";
  problems: EstimateProblem[];
  warnings: EstimateProblem[];
}

export interface EstimateProblem {
  line?: number;
  field: string;
  message: string;
}

/** The estimate, calculated. Never throws for bad input: problems say what's missing or wrong. */
export function calculateEstimate(lines: readonly EstimateLineInput[], pricing: EstimatePricingInput): EstimateResult {
  const problems: EstimateProblem[] = [];
  const warnings: EstimateProblem[] = [];
  const factor = (v: unknown, i: number, field: string): Dec => {
    if (v === null || v === undefined || v === "") return ONE;
    const d = parseDecimal(v);
    if (!d) {
      problems.push({ line: i, field, message: `${field} isn't a number` });
      return ZERO;
    }
    if (sign(d) < 0) {
      problems.push({ line: i, field, message: `${field} can't be negative` });
      return ZERO;
    }
    return d;
  };
  const pct = (v: unknown, field: string, { max, line }: { max?: number; line?: number } = {}): Dec => {
    if (v === null || v === undefined || v === "") return ZERO;
    const d = parseDecimal(v);
    if (!d) {
      problems.push({ line, field, message: `${field} isn't a number` });
      return ZERO;
    }
    if (sign(d) < 0 || (max !== undefined && Number(d.n) / 10 ** d.s >= max)) {
      problems.push({ line, field, message: max === 1 ? `${field} must be at least 0% and under 100%` : `${field} can't be negative` });
      return ZERO;
    }
    return d;
  };

  const burden = pct(pricing.burden_pct, "Labor burden");
  const bases: Dec[] = [];
  const risks: Dec[] = [];
  lines.forEach((l, i) => {
    const count = factor(l.count, i, "Count");
    const hours = factor(l.hours, i, "Hours");
    const days = factor(l.days, i, "Days");
    let cost = parseDecimal(l.unit_cost);
    if (l.unit_cost === null || l.unit_cost === undefined || l.unit_cost === "") {
      problems.push({ line: i, field: "Unit cost", message: `${l.name || "A line"} has no rate yet` });
      cost = ZERO;
    } else if (!cost) {
      problems.push({ line: i, field: "Unit cost", message: "Unit cost isn't a number" });
      cost = ZERO;
    } else if (sign(cost) < 0 && l.section !== "other") {
      problems.push({ line: i, field: "Unit cost", message: "Unit cost can't be negative (use an Other line for a credit)" });
      cost = ZERO;
    }
    if (!(ESTIMATE_UNITS as readonly string[]).includes(l.unit)) problems.push({ line: i, field: "Unit", message: `"${l.unit}" isn't a unit the estimate knows` });
    let base = mul(mul(mul(count, hours), days), cost);
    if (l.section === "labor" && !l.includes_burden && sign(burden) > 0) base = mul(base, add(ONE, burden));
    bases.push(base);
    risks.push(mul(base, pct(l.risk_pct, "Risk %", { line: i })));
    if (l.fuel_for) {
      const target = lines.find((x) => x.key && x.key === l.fuel_for);
      if (target?.includes_fuel) warnings.push({ line: i, field: "Fuel", message: `Fuel may be counted twice: ${target.name || "that equipment"}'s rate already includes fuel, and "${l.name || "this line"}" adds fuel for it. Remove this line, or untick "Rate already includes fuel" if the rate doesn't. (A warning only: the estimate can still be saved and approved.)` });
    }
  });
  if (!lines.some((l) => l.section === "contingency")) warnings.push({ field: "Contingency", message: "No contingency line (the bid workbook says to always include one)" });

  const base = bases.reduce(add, ZERO);
  const risk = risks.reduce(add, ZERO);
  const subtotal = add(base, risk);
  let markup = ZERO;
  if (pricing.method === "markup") {
    markup = mul(subtotal, pct(pricing.pct, "Markup"));
  } else if (pricing.method === "margin") {
    const m = pct(pricing.pct, "Target margin", { max: 1 });
    markup = sign(subtotal) === 0 ? ZERO : sub(div(subtotal, sub(ONE, m)), subtotal);
  } else {
    problems.push({ field: "Pricing method", message: "Choose markup or target margin" });
  }
  const before = add(subtotal, markup);
  let owner = ZERO;
  if (pricing.owner_pay === "percent_of_price") {
    if (pricing.owner_pct === null || pricing.owner_pct === undefined || pricing.owner_pct === "") problems.push({ field: "Owner pay", message: "Owner pay is on: say its percentage (0% is allowed)" });
    owner = mul(before, pct(pricing.owner_pct, "Owner pay"));
  } else if (pricing.owner_pay !== "none") {
    problems.push({ field: "Owner pay", message: "Choose how owner pay is treated" });
  }
  const selling = add(before, owner);

  // Each line's share of the selling price (its subtotal's share), the remainder on the largest line.
  const sellingCents = toCentsExact(selling);
  const shares = lines.map((_, i) => (sign(subtotal) === 0 ? 0 : toCentsExact(div(mul(add(bases[i], risks[i]), selling), subtotal, 6))));
  const drift = sellingCents - shares.reduce((a, b) => a + b, 0);
  if (drift !== 0 && shares.length) {
    let big = 0;
    shares.forEach((v, i) => { if (Math.abs(v) > Math.abs(shares[big])) big = i; });
    shares[big] += drift;
  }

  return {
    lines: lines.map((l, i) => ({ key: l.key, base: money(bases[i]), risk: money(risks[i]), subtotal: money(add(bases[i], risks[i])), price: shares[i] / 100 })),
    base: money(base),
    risk: money(risk),
    subtotal: money(subtotal),
    markup: money(markup),
    price_before_owner_pay: money(before),
    owner_pay: money(owner),
    selling_price: sellingCents / 100,
    sheet_margin: sign(before) === 0 ? null : Number(div(markup, before, 6).n) / 1e6,
    profit_if_reserve_unused: money(add(markup, risk)),
    status: problems.length ? "unresolved" : "ok",
    problems,
    warnings,
  };
}

/** The metrics' plain-language definitions, for the pricing review. */
export const METRIC_DEFINITIONS = {
  base: "Every line's count × hours × days × unit cost (labor burden added where its rate excludes it).",
  risk: "Each line's base × its risk %.",
  subtotal: "Base cost + risk reserve.",
  markup: "Markup on the subtotal, or what the target margin adds: the business's fee.",
  price_before_owner_pay: "Subtotal + markup.",
  owner_pay: "Price before owner pay × owner pay %, added on top (or none).",
  selling_price: "Price before owner pay + owner pay: the calculated price, before anyone negotiates it.",
  sheet_margin: "Markup ÷ price before owner pay (the bid workbook's \"profit margin\"): risk reserve counted as cost, owner pay left out.",
  profit_if_reserve_unused: "Markup + risk reserve: what's left if the reserve isn't needed. Owner pay is apart.",
} as const;
