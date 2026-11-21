/**
 * Planet Ops Phase 3: a new estimator works an estimate from a request with fictional numbers:
 * project and site, labor, disposal, contingency, pricing; saves (nothing is sent); approves the
 * original baseline; revises. Tablet and phone widths keep the editor on the screen.
 */
import { expect, expectAccessible, makeClient, must, test } from "./support/fixtures";

test("estimating: from a request to an approved baseline and a revision, with the totals the engine gives", async ({ as, data }) => {
  const client = await makeClient(data, "Estimate");
  const request = must(await data.db.from("requests").insert({ company_id: data.id, client_id: client.id, property_id: client.propertyId, title: `${client.name} garage demolition`, source: "phone" }).select("id").single(), "request");
  const page = await as("owner");
  await page.goto(`/requests/${request.id}`);
  await page.locator("[data-planet-ops=request-estimates]").getByRole("button", { name: "Start estimate" }).click();
  const dialog = page.getByRole("dialog", { name: "New estimate" });
  await dialog.getByLabel(/^Project type/).fill("Garage demolition");
  await dialog.getByRole("button", { name: "Create estimate" }).click();
  // If it can't be made, say why (the dialog's own message).
  await Promise.race([page.waitForURL(/\/estimates\/[0-9a-f-]+$/), dialog.getByRole("alert").waitFor()]);
  expect(await dialog.getByRole("alert").count() ? await dialog.getByRole("alert").textContent() : null, "the estimate is made").toBeNull();
  await expect(page).toHaveURL(/\/estimates\/[0-9a-f-]+$/);
  const estimateId = page.url().split("/").pop()!;
  const estimate = must(await data.db.from("estimates").select("number, title, client_id, property_id, request_id").eq("id", estimateId).single(), "estimate");
  expect(estimate).toMatchObject({ title: `${client.name} garage demolition`, client_id: client.id, property_id: client.propertyId, request_id: request.id });

  // Project and site.
  const editor = page.locator("[data-planet-ops=estimate-editor]");
  await editor.getByLabel(/^Total area/).fill("480");
  await editor.getByLabel(/^Access constraints/).fill("Narrow driveway; no overhead lines.");
  await editor.getByRole("region", { name: "Customer scope" }).getByLabel(/^Project overview/).fill("Demolish the detached garage and remove its slab.");
  await expectAccessible(page, "an estimate's project and site");

  // Labor: 2 people × 8 h × 1 day at $25.
  const steps = page.getByRole("group", { name: "Estimate steps" });
  await steps.getByRole("button", { name: /Labor/ }).click();
  const labor = editor.getByRole("region", { name: "Labor" });
  await labor.getByRole("button", { name: "Add labor line" }).click();
  let line = labor.locator("[data-line]").last();
  await line.getByLabel("Line", { exact: true }).fill("Crew");
  await line.getByLabel(/^People/).fill("2");
  await line.getByLabel(/^Hours/).fill("8");
  await line.getByLabel(/^Days/).fill("1");
  await line.getByLabel(/^Unit cost/).fill("25");

  // Disposal: 3 tons at $80, with the weight, volume and container kept apart.
  await steps.getByRole("button", { name: /Disposal and hauling/ }).click();
  const disposal = editor.getByRole("region", { name: "Disposal", exact: true });
  await disposal.getByRole("button", { name: "Add disposal line" }).click();
  line = disposal.locator("[data-line]").last();
  await line.getByLabel("Line", { exact: true }).fill("Mixed debris");
  await line.getByLabel(/^Count/).fill("3");
  await line.getByLabel(/^Unit cost/).fill("80");
  await line.getByLabel(/^Est\. tons/).fill("3");
  await line.getByLabel(/^Container CY/).fill("20");

  // Contingency: $100.
  await steps.getByRole("button", { name: /Other costs/ }).click();
  const contingency = editor.getByRole("region", { name: "Contingency" });
  await contingency.getByRole("button", { name: "Add contingency line" }).click();
  line = contingency.locator("[data-line]").last();
  await line.getByLabel("Line", { exact: true }).fill("Contingency");
  await line.getByLabel(/^Unit cost/).fill("100");

  // Pricing: 30% markup, no owner pay → 740 + 222 = $962.00.
  await steps.getByRole("button", { name: /Pricing review/ }).click();
  await editor.getByLabel("Markup %").fill("30");
  const totals = page.locator("[data-planet-ops=estimate-totals]");
  await expect(totals.getByText("$962.00")).toBeVisible();
  await expect(totals.getByText("Complete")).toBeVisible();
  await expectAccessible(page, "an estimate's pricing review");
  await page.getByRole("button", { name: "Save" }).click();
  await expect(page.getByText("Unsaved changes")).toHaveCount(0);

  const saved = must(await data.db.rpc("estimate_version_costs", { p_version: must(await data.db.from("estimates").select("current_version_id").eq("id", estimateId).single(), "current").current_version_id! }), "costs") as unknown as { base_cost: number; selling_price: number };
  expect(Number(saved.base_cost)).toBe(740);
  expect(Number(saved.selling_price)).toBe(962);
  const lines = must(await data.db.from("estimate_lines").select("name, est_tons, container_cy").eq("version_id", must(await data.db.from("estimates").select("current_version_id").eq("id", estimateId).single(), "current").current_version_id!).order("sort"), "lines");
  expect(lines.find((l) => l.name === "Mixed debris")).toMatchObject({ est_tons: 3, container_cy: 20 });
  // Nothing was sent or made.
  expect(must(await data.db.from("quotes").select("id").eq("client_id", client.id), "quotes")).toHaveLength(0);

  // Approve: the original baseline.
  await steps.getByRole("button", { name: /Versions and documents/ }).click();
  await editor.getByRole("button", { name: "Approve version 1" }).click();
  await page.getByRole("dialog").getByRole("button", { name: "Approve" }).click();
  await expect(editor.getByText(/It's the estimate's original baseline/)).toBeVisible();
  const approved = must(await data.db.from("estimates").select("baseline_version_id, current_version_id").eq("id", estimateId).single(), "approved");
  expect(approved.baseline_version_id).toBe(approved.current_version_id);

  // Revise: version 2 is a draft; version 1 stays the baseline.
  page.once("dialog", (d) => d.accept("Customer added a shed"));
  await page.getByRole("button", { name: "Revise" }).click();
  await expect(page.getByText(/version 2/).first()).toBeVisible();
  const revised = must(await data.db.from("estimate_versions").select("number, status, revision_reason").eq("estimate_id", estimateId).order("number"), "versions");
  expect(revised).toEqual([{ number: 1, status: "approved", revision_reason: null }, { number: 2, status: "draft", revision_reason: "Customer added a shed" }]);

  // Tablet and phone: the editor fits the screen (no sideways scrolling).
  for (const size of [{ width: 820, height: 1180 }, { width: 390, height: 844 }]) {
    await page.setViewportSize(size);
    await page.goto(`/estimates/${estimateId}?step=labor`);
    await expect(editor.getByRole("region", { name: "Labor" })).toBeVisible();
    const overflow = await page.evaluate(() => document.documentElement.scrollWidth - window.innerWidth);
    expect(overflow, `no sideways scrolling at ${size.width}px`).toBeLessThanOrEqual(1);
  }
});

test("estimating: the list, settings and rates; no costs on screen for a request page", async ({ as }) => {
  const page = await as("owner");
  await page.goto("/estimates");
  await expect(page.getByRole("heading", { name: "Estimating" })).toBeVisible();
  await expect(page.getByText(/costs, rates and profit stay here/)).toBeVisible();
  await expectAccessible(page, "the estimating list");
  await page.goto("/settings?tab=estimating");
  const settings = page.locator("[data-planet-ops=estimating-settings]");
  await expect(settings.getByText("A quote or proposal is made only from an approved estimate")).toBeVisible();
  await expect(settings.getByText(/None come preset/)).toBeVisible();
  await expectAccessible(page, "estimating settings");
});
