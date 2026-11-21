/**
 * Planet Ops Phase 2: Settings → Sales pipeline (stages, cadence, templates; reminders and drafts
 * only), and the pipeline's Report and Pricing history. A template written here is offered when
 * logging a contact on a request; a custom stage can be added and removed again.
 */
import { expect, expectAccessible, makeClient, must, test, unique } from "./support/fixtures";

test("pipeline settings: a template is offered in the contact log; a custom stage comes and goes; report and pricing history", async ({ as, data }) => {
  const page = await as("owner");
  await page.goto("/settings?tab=pipeline");
  const settings = page.locator("[data-planet-ops=pipeline-settings]");
  await expect(settings.getByText("Reminders and drafts only")).toBeVisible();
  await expect(settings.getByRole("table", { name: "Pipeline stages" }).getByRole("textbox", { name: "New inquiry: name" })).toHaveValue("New inquiry");
  await expect(settings.getByRole("table", { name: "Follow-up cadence" }).getByText("First response")).toBeVisible();
  await expectAccessible(page, "pipeline settings");

  // A template, in the business's own words.
  const name = unique("Check-in");
  await settings.getByLabel("Name", { exact: true }).fill(name);
  await settings.getByLabel("Script", { exact: true }).fill("Ask whether they have questions about the proposal, and when they'd like to start.");
  await settings.getByRole("button", { name: "Add template" }).click();
  await expect(settings.getByRole("table", { name: "Templates" }).getByText(name)).toBeVisible();

  // A custom stage, then removed.
  const stage = unique("Permit check");
  await settings.getByLabel("Add a stage").fill(stage);
  await settings.getByRole("button", { name: "Add", exact: true }).click();
  await expect(settings.getByRole("textbox", { name: `${stage}: name` })).toHaveValue(stage);
  await settings.getByRole("button", { name: `Delete ${stage}` }).click();
  await page.getByRole("dialog").getByRole("button", { name: "Delete" }).click();
  await expect(settings.getByRole("textbox", { name: `${stage}: name` })).toHaveCount(0);

  // The template is there to start a logged call from; nothing is sent.
  const client = await makeClient(data, "Template");
  const request = must(await data.db.from("requests").insert({ company_id: data.id, client_id: client.id, title: `${client.name} demolition`, source: "phone" }).select("id").single(), "request");
  await page.goto(`/requests/${request.id}`);
  const activity = page.locator("[data-planet-ops=request-activity]");
  await activity.getByLabel(/^Template/).selectOption({ label: name });
  await expect(activity.getByLabel("What was said")).toHaveValue(/questions about the proposal/);

  // Report and pricing history.
  await page.goto("/pipeline?view=report");
  const report = page.locator("[data-planet-ops=pipeline-report]");
  await expect(report.getByText("Requests in", { exact: true })).toBeVisible();
  await expect(report.getByText(/won ÷ \(won \+ lost\)/)).toBeVisible();
  await expectAccessible(page, "the pipeline report");
  await page.goto("/pipeline?view=pricing");
  await expect(page.locator("[data-planet-ops=pricing-history]").getByText(/sales evidence, not what a job actually cost/)).toBeVisible();
  await expectAccessible(page, "pricing history");

  const tpl = must(await data.db.from("pipeline_templates").select("id").eq("company_id", data.id).eq("name", name), "template");
  expect(tpl).toHaveLength(1);
  must(await data.db.from("pipeline_templates").delete().eq("id", tpl[0].id).select("id"), "clean up the template");
});
