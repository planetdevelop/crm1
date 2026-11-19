/**
 * Planet Ops common cost codes (Phase 0 shared records, docs/PLANET_OPS_IMPLEMENTATION_PLAN.md §2).
 *
 * One vocabulary for estimates (Phase 3), job costs and receipts (Phase 4) and benchmarks (Phase 8),
 * so a cost is never forced into a generic "materials" bucket. Phase 0 defines the codes and how the
 * existing expense categories (receipts.ts EXPENSE_CATEGORIES, stored as free text in
 * public.expenses.category) map onto them. Nothing is stored yet: the column that records a code on
 * estimate lines and expenses arrives with the phase that first writes it (see the migration
 * outline in docs/planet-ops/DATA_MAP.md).
 */
import type { ExpenseCategory } from "./receipts";

export const COST_CODES = [
  { code: "labor", label: "Labor and burden", group: "Labor" },
  { code: "equipment_rental", label: "Equipment rental", group: "Equipment" },
  { code: "equipment_owned", label: "Owned equipment", group: "Equipment" },
  { code: "equipment_upkeep", label: "Equipment upkeep", group: "Equipment" },
  { code: "fuel", label: "Fuel", group: "Equipment" },
  { code: "hauling", label: "Hauling", group: "Hauling and disposal" },
  { code: "disposal", label: "Disposal and tipping fees", group: "Hauling and disposal" },
  { code: "materials_fill", label: "Materials and fill", group: "Materials and other" },
  { code: "tools_supplies_ppe", label: "Tools, supplies and PPE", group: "Materials and other" },
  { code: "permits_testing", label: "Permits and testing", group: "Materials and other" },
  { code: "subcontractors", label: "Subcontractors", group: "Subcontractors" },
  { code: "travel_per_diem", label: "Travel and per diem", group: "Labor" },
  { code: "other", label: "Other", group: "Materials and other" },
] as const;

export type CostCode = (typeof COST_CODES)[number]["code"];
export type CostGroup = (typeof COST_CODES)[number]["group"];

const CODES = new Set<string>(COST_CODES.map((c) => c.code));
export const isCostCode = (value: unknown): value is CostCode => typeof value === "string" && CODES.has(value);

export const costCodeLabel = (code: CostCode): string => COST_CODES.find((c) => c.code === code)!.label;
export const costCodeGroup = (code: CostCode): CostGroup => COST_CODES.find((c) => c.code === code)!.group;

/** The display groups, in the order the estimating sheet shows them. */
export const COST_GROUPS: readonly CostGroup[] = [...new Set(COST_CODES.map((c) => c.group))];

/**
 * Where each existing expense category lands. "Dump fees" is disposal (tipping), not hauling; a
 * hauler's bill is coded `hauling` once costs record codes directly.
 */
export const EXPENSE_CATEGORY_COST_CODE: Record<ExpenseCategory, CostCode> = {
  Materials: "materials_fill",
  "Equipment rental": "equipment_rental",
  "Equipment upkeep": "equipment_upkeep",
  Fuel: "fuel",
  "Dump fees": "disposal",
  Subcontractor: "subcontractors",
  Permits: "permits_testing",
  Supplies: "tools_supplies_ppe",
  Other: "other",
};

/**
 * The cost code for an expense's stored category (free text, so anything an older row holds).
 * Unknown or empty categories are `other`, never guessed from the wording.
 */
export function costCodeForExpenseCategory(category: string | null | undefined): CostCode {
  if (!category) return "other";
  const known = (Object.keys(EXPENSE_CATEGORY_COST_CODE) as ExpenseCategory[]).find((c) => c.toLowerCase() === category.trim().toLowerCase());
  return known ? EXPENSE_CATEGORY_COST_CODE[known] : "other";
}
