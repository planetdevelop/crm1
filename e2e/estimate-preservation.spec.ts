/**
 * Planet Ops Phase 3 hardening: with approval switched off, a line-item quote made from a saved
 * draft locks that estimate version exactly as it was (no approval is recorded); later changes are a
 * revision and leave the document alone. Two people editing the same estimate: the second save is
 * refused with a reload message instead of overwriting the first. Fictional records only.
 */
import { expect, expectAccessible, makeClient, must, test } from "./support/fixtures";

test("approval off: the document's estimate version is locked, not approved; a stale save is refused", async ({ as, data }) => {
  const client = await makeClient(data, "Preserve");
  const request = must(await data.db.from("requests").insert({ company_id: data.id, client_id: client.id, property_id: client.propertyId, title: `${client.name} carport removal`, source: "phone" }).select("id").single(), "request");
  const estimateId = must(await data.db.rpc("create_estimate", { p_company: data.id, p_request_key: crypto.randomUUID(), p_title: `${client.name} carport removal`, p_request: request.id }), "estimate") as unknown as string;
  const v1 = must(await data.db.from("estimates").select("current_version_id").eq("id", estimateId).single(), "v1").current_version_id!;
  must(await data.db.rpc("save_estimate_version", { p_version: v1, p_expected_revision: 0, p_payload: {
    scope: { customer_overview: "Remove the carport and haul it away." },
    pricing_method: "markup", pricing_pct: 0.2, owner_pay_method: "none",
    lines: [
      { key: "crew", section: "labor", name: "Crew", count: 2, hours: 4, days: 1, unit: "hour", unit_cost: 30, customer_item: "Removal" },
      { key: "dump", section: "disposal", name: "Dump fee", count: 1, unit: "load", unit_cost: 160, customer_item: "Disposal" },
    ],
  } as never }), "save v1");
  // 240 + 160 = 400; 20% → $480.00 (Removal $288, Disposal $192).

  const before = must(await data.db.from("companies").select("settings").eq("id", data.id).single(), "settings").settings as { estimating?: { require_approval?: boolean } } | null;
  must(await data.db.rpc("merge_company_settings", { p_company: data.id, p_settings: { estimating: { require_approval: false } } as never }), "approval off");
  try {
    const page = await as("owner");
    await page.goto(`/estimates/${estimateId}`);
    await page.getByRole("button", { name: "Create quote / proposal" }).click();
    const dialog = page.getByRole("dialog", { name: "Create quote / proposal" });
    await expect(dialog.getByText(/making the document locks\s+version 1 exactly as it is now/)).toBeVisible();
    await dialog.getByLabel(/Line-item quote/).check();
    await dialog.getByRole("button", { name: "Create draft" }).click();
    await expect(page).toHaveURL(/\/quotes\/[0-9a-f-]+$/);
    const quoteId = page.url().split("/").pop()!;
    const lines = must(await data.db.from("quote_line_items").select("name, unit_price").eq("quote_id", quoteId).order("sort"), "lines");
    expect(lines.map((l) => [l.name, Number(l.unit_price)])).toEqual([["Removal", 288], ["Disposal", 192]]);
    expect(must(await data.db.from("quotes").select("status, sent_at, presentation").eq("id", quoteId).single(), "quote")).toMatchObject({ status: "draft", sent_at: null, presentation: "line_items" });

    // The version is kept as it was, and nothing says it was approved.
    const locked = must(await data.db.from("estimate_versions").select("status, locked_at, approved_at, approved_by").eq("id", v1).single(), "locked");
    expect(locked).toMatchObject({ status: "locked", approved_at: null, approved_by: null });
    expect(locked.locked_at).not.toBeNull();
    await page.goto(`/estimates/${estimateId}`);
    await expect(page.getByText(/was used for a customer document.*kept exactly as it was \(it isn't approved\)/)).toBeVisible();
    await expect(page.getByRole("button", { name: "Save" })).toHaveCount(0);
    await expectAccessible(page, "a locked estimate version");

    // A revision is where later changes go; the document keeps version 1's prices.
    page.once("dialog", (d) => d.accept("Customer wants the slab out too"));
    await page.getByRole("button", { name: "Revise" }).click();
    await expect(page.getByText(/version 2/).first()).toBeVisible();
    const v2 = must(await data.db.from("estimates").select("current_version_id").eq("id", estimateId).single(), "v2").current_version_id!;
    expect(v2).not.toBe(v1);

    // Two people on version 2: the first save lands, the second is refused (reload, nothing lost).
    const other = await as("owner");
    await other.goto(`/estimates/${estimateId}?step=labor`);
    await page.goto(`/estimates/${estimateId}?step=labor`);
    const mine = page.locator("[data-planet-ops=estimate-editor]").getByRole("region", { name: "Labor" }).locator("[data-line]").first();
    await mine.getByLabel(/^Hours/).fill("6");
    await page.getByRole("button", { name: "Save" }).click();
    await expect(page.getByText("Unsaved changes")).toHaveCount(0);
    const theirs = other.locator("[data-planet-ops=estimate-editor]").getByRole("region", { name: "Labor" }).locator("[data-line]").first();
    await theirs.getByLabel(/^Hours/).fill("9");
    await other.getByRole("button", { name: "Save" }).click();
    await expect(other.getByRole("alert").filter({ hasText: /Someone else saved this estimate since you opened it/ })).toBeVisible();
    const saved = must(await data.db.from("estimate_lines").select("hours").eq("version_id", v2).eq("key", "crew").single(), "saved line");
    expect(Number(saved.hours)).toBe(6);
    expect(must(await data.db.from("quote_line_items").select("unit_price").eq("quote_id", quoteId), "unchanged").map((l) => Number(l.unit_price)).sort((a, b) => a - b)).toEqual([192, 288]);
    expect(must(await data.db.from("estimate_versions").select("status").eq("id", v1).single(), "v1 kept").status).toBe("locked");
  } finally {
    must(await data.db.rpc("merge_company_settings", { p_company: data.id, p_settings: { estimating: { require_approval: before?.estimating?.require_approval ?? true } } as never }), "approval restored");
  }
});
