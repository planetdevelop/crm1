/**
 * Planet Ops Phase 3: an approved internal estimate becomes an unsent proposal draft, reviewed and
 * sent from Quotes & Proposals; the customer's page shows the scope and price and nothing internal;
 * the summary keeps the price sent apart from the calculated one; a newer estimate version refreshes
 * the document only on purpose, after the differences are shown.
 */
import { expect, makeClient, must, test } from "./support/fixtures";

test("estimate → unsent proposal draft → sent; nothing internal on the customer's page; summary; explicit refresh", async ({ as, browser, data }) => {
  const client = await makeClient(data, "Handoff");
  const request = must(await data.db.from("requests").insert({ company_id: data.id, client_id: client.id, property_id: client.propertyId, title: `${client.name} shed demolition`, source: "phone" }).select("id").single(), "request");
  const estimateId = must(await data.db.rpc("create_estimate", { p_company: data.id, p_request_key: crypto.randomUUID(), p_title: `${client.name} shed demolition`, p_request: request.id }), "estimate") as unknown as string;
  const v1 = must(await data.db.from("estimates").select("current_version_id").eq("id", estimateId).single(), "v1").current_version_id!;
  const payload = (debrisTons: number) => ({
    scope: { customer_overview: "Remove the shed and its slab.", site_notes: "INTERNAL-SITE-NOTE: gate code 4242" },
    pricing_method: "markup", pricing_pct: 0.5, owner_pay_method: "none",
    lines: [
      { key: "crew", section: "labor", name: "Crew INTERNAL-WAGE-LINE", count: 2, hours: 8, days: 1, unit: "hour", unit_cost: 31.25, customer_item: "Demolition" },
      { key: "debris", section: "disposal", name: "Debris tons", count: debrisTons, unit: "ton", unit_cost: 50, customer_item: "Haul-off and disposal" },
      { key: "contingency", section: "contingency", name: "Contingency", count: 1, unit: "lump", unit_cost: 100, customer_item: "Demolition" },
    ],
  });
  must(await data.db.rpc("save_estimate_version", { p_version: v1, p_expected_revision: 0, p_payload: payload(2) as never }), "save v1");
  must(await data.db.rpc("approve_estimate_version", { p_version: v1 }), "approve v1");
  // Base 500 + 100 + 100 = 700; markup 50% → 1,050: Demolition 900, Haul-off 150.

  const page = await as("owner");
  await page.goto(`/estimates/${estimateId}`);
  await page.getByRole("button", { name: "Create quote / proposal" }).click();
  const dialog = page.getByRole("dialog", { name: "Create quote / proposal" });
  await expect(dialog.getByText(/Wages, costs, rates, markup, risk reserve, owner pay and internal notes stay in the estimate/)).toBeVisible();
  await dialog.getByRole("button", { name: "Create draft" }).click();
  await expect(page).toHaveURL(/\/quotes\/[0-9a-f-]+$/);
  const quoteId = page.url().split("/").pop()!;
  await expect(page.locator("[data-planet-ops=estimate-link]")).toContainText("version 1");
  const quote = must(await data.db.from("quotes").select("status, sent_at, presentation, estimate_version_id, request_id").eq("id", quoteId).single(), "quote");
  expect(quote).toMatchObject({ status: "draft", sent_at: null, presentation: "proposal", estimate_version_id: v1, request_id: request.id });
  const lines = must(await data.db.from("quote_line_items").select("name, unit_price, unit_cost").eq("quote_id", quoteId).order("sort"), "lines");
  expect(lines.map((l) => [l.name, Number(l.unit_price), l.unit_cost])).toEqual([["Demolition", 900, null], ["Haul-off and disposal", 150, null]]);

  // Sent from Quotes & Proposals; the customer's page has the scope and price, nothing internal.
  await page.getByRole("button", { name: "Send quote" }).click();
  await page.getByRole("dialog", { name: "Send quote" }).getByRole("button", { name: "Send email" }).click();
  const sent = page.getByRole("dialog", { name: "Sent" });
  const token = (await sent.getByRole("textbox").inputValue()).match(/\/hub\/([\w.-]+)/)?.[1];
  await sent.getByRole("button", { name: "Done" }).click();
  const portal = await (await browser.newContext()).newPage();
  const hubResponse = portal.waitForResponse((r) => /\/api\/hub\//.test(r.url()) && r.request().method() === "GET");
  await portal.goto(`/hub/${token}`);
  const body = await (await hubResponse).text();
  await expect(portal.locator("#root").getByText("Remove the shed and its slab.").first()).toBeVisible();
  await expect(portal.locator("#root").getByText("$1,050.00").first()).toBeVisible();
  for (const secret of ["INTERNAL-WAGE-LINE", "INTERNAL-SITE-NOTE", "31.25", "estimate_version", "Debris tons"]) {
    expect(body, `the customer's data has no "${secret}"`).not.toContain(secret);
    await expect(portal.locator("#root").getByText(secret)).toHaveCount(0);
  }
  await portal.context().close();

  // The summary: the price sent, apart from the calculated price; one summary, not backed up.
  await page.goto(`/estimates/${estimateId}/summary`);
  const summary = page.locator("[data-planet-ops=estimate-summary]");
  await expect(summary.getByText(/It hasn't been backed up/)).toBeVisible();
  await expect(summary.getByRole("table", { name: "Prices sent and accepted" }).getByText(/\$1,050\.00 on/)).toBeVisible();
  await expect(summary.getByText(/calculated; not a price sent/)).toBeVisible();

  // A newer estimate version: the document refreshes only on purpose, after the differences.
  const v2 = must(await data.db.rpc("revise_estimate", { p_estimate: estimateId, p_reason: "More debris" }), "v2") as unknown as string;
  must(await data.db.rpc("save_estimate_version", { p_version: v2, p_expected_revision: 0, p_payload: payload(4) as never }), "save v2");
  must(await data.db.rpc("approve_estimate_version", { p_version: v2 }), "approve v2");
  expect(must(await data.db.from("quote_line_items").select("unit_price").eq("quote_id", quoteId), "unchanged").map((l) => Number(l.unit_price)).sort()).toEqual([150, 900]);
  await page.goto(`/quotes/${quoteId}`);
  await page.locator("[data-planet-ops=estimate-link]").getByRole("button", { name: "Refresh from estimate…" }).click();
  const refresh = page.getByRole("dialog", { name: /Refresh from estimate version 2/ });
  await expect(refresh.getByText(/makes a draft revision/)).toBeVisible();
  await expect(refresh.getByRole("table", { name: "What changes" }).getByText("$1,200.00")).toBeVisible();
  await refresh.getByRole("button", { name: "Refresh prices", exact: true }).click();
  await expect.poll(async () => must(await data.db.from("quote_line_items").select("unit_price").eq("quote_id", quoteId), "refreshed").map((l) => Number(l.unit_price)).sort((a, b) => a - b)).toEqual([300, 900]);
  expect(must(await data.db.from("quotes").select("estimate_version_id, status").eq("id", quoteId).single(), "linked")).toMatchObject({ estimate_version_id: v2, status: "sent" });
  // No job or folder from any of it.
  expect(must(await data.db.from("jobs").select("id").eq("client_id", client.id), "jobs")).toHaveLength(0);
});
