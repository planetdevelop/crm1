/** Planet Ops Phase 0: branding in one place, and the shared cost codes. */
import { describe, expect, it } from "vitest";
import { brandText, PRODUCT_NAME } from "../src/brand";
import { COST_CODES, COST_GROUPS, costCodeForExpenseCategory, EXPENSE_CATEGORY_COST_CODE, isCostCode } from "../src/costCodes";
import { addCatalog, translator } from "../src/i18n";
import { EXPENSE_CATEGORIES } from "../src/receipts";

describe("brandText", () => {
  it("shows Planet Ops in place of the upstream name", () => {
    expect(PRODUCT_NAME).toBe("Planet Ops");
    expect(brandText("Crewtavo is restarting.")).toBe("Planet Ops is restarting.");
    expect(brandText("Connect Crewtavo to Railway first")).toBe("Connect Planet Ops to Railway first");
  });

  it("keeps the upstream legal terms, docs and attribution as written", () => {
    expect(brandText("Agree to the Crewtavo Terms to continue.")).toBe("Agree to the Crewtavo Terms to continue.");
    expect(brandText("Crewtavo docs")).toBe("Crewtavo docs");
    expect(brandText("Crewtavo is based on Crewtavo")).toBe("Planet Ops is based on Crewtavo");
  });

  it("leaves lowercase technical names alone (the crewtavo Railway service, crewtavo.local)", () => {
    expect(brandText("Open the crewtavo service's Deployments")).toBe("Open the crewtavo service's Deployments");
    expect(brandText("no change")).toBe("no change");
  });

  it("is applied by the translation layer, before placeholders are filled", () => {
    const en = translator("en");
    expect(en("This Crewtavo isn't set up to send email yet")).toBe("This Planet Ops isn't set up to send email yet");
    // A value (a company's own name) is never rewritten.
    expect(en("{name} uses Crewtavo", { name: "Crewtavo Fans LLC" })).toBe("Crewtavo Fans LLC uses Planet Ops");
    addCatalog("es", { "Crewtavo was updated": "Crewtavo se actualizó" });
    expect(translator("es")("Crewtavo was updated")).toBe("Planet Ops se actualizó");
    expect(en.plural(2, { one: "{count} Crewtavo update", other: "{count} Crewtavo updates" })).toBe("2 Planet Ops updates");
  });
});

describe("cost codes", () => {
  it("has the plan's thirteen common codes, each unique", () => {
    const codes = COST_CODES.map((c) => c.code);
    expect(codes).toHaveLength(13);
    expect(new Set(codes).size).toBe(13);
    for (const c of ["labor", "equipment_rental", "equipment_owned", "equipment_upkeep", "fuel", "hauling", "disposal", "materials_fill", "tools_supplies_ppe", "permits_testing", "subcontractors", "travel_per_diem", "other"]) {
      expect(isCostCode(c)).toBe(true);
    }
    expect(isCostCode("materials")).toBe(false);
    expect(COST_GROUPS[0]).toBe("Labor");
  });

  it("maps every existing expense category to a code", () => {
    for (const category of EXPENSE_CATEGORIES) expect(isCostCode(EXPENSE_CATEGORY_COST_CODE[category])).toBe(true);
    expect(costCodeForExpenseCategory("Dump fees")).toBe("disposal");
    expect(costCodeForExpenseCategory(" fuel ")).toBe("fuel");
  });

  it("files unknown or empty categories under other instead of guessing", () => {
    expect(costCodeForExpenseCategory(null)).toBe("other");
    expect(costCodeForExpenseCategory("")).toBe("other");
    expect(costCodeForExpenseCategory("Diesel for the excavator")).toBe("other");
  });
});
