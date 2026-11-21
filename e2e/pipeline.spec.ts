/**
 * Planet Ops Phase 2: the sales pipeline. Two requests for one client sit in New inquiry on the
 * board; one is worked from its page (a stage move, a logged call, its next action), then lost with
 * a reason; the other is untouched. The history keeps each step.
 */
import { expect, expectAccessible, makeClient, must, test } from "./support/fixtures";

test("pipeline: board and list, a request moved, a call logged, lost with a reason; the client's other request is independent", async ({ as, data }) => {
  const client = await makeClient(data, "Pipeline");
  const [first, second] = must(
    await data.db.from("requests").insert([
      { company_id: data.id, client_id: client.id, property_id: client.propertyId, title: `${client.name} house demolition`, source: "phone" },
      { company_id: data.id, client_id: client.id, property_id: client.propertyId, title: `${client.name} garage removal`, source: "phone" },
    ]).select("id, number").order("number"),
    "requests",
  );

  const page = await as("owner");
  await page.goto("/pipeline");
  const newInquiry = page.getByRole("region", { name: "New inquiry" });
  await expect(newInquiry.getByText(`${client.name} house demolition`)).toBeVisible();
  await expect(newInquiry.getByText(`${client.name} garage removal`)).toBeVisible();
  await expect(newInquiry.getByText("Make first contact").first()).toBeVisible();
  await expectAccessible(page, "the pipeline board");

  await page.getByRole("group", { name: "View" }).getByRole("button", { name: "List" }).click();
  await page.getByRole("group", { name: "Filter the pipeline" }).getByRole("button", { name: /Needs first response/ }).click();
  const list = page.locator("[data-planet-ops=pipeline-list]");
  await expect(list.getByRole("link", { name: `${client.name} house demolition` })).toBeVisible();
  await expectAccessible(page, "the pipeline list");

  // Worked from its page.
  await list.getByRole("link", { name: `${client.name} house demolition` }).click();
  const card = page.locator("[data-planet-ops=pipeline-card]");
  await expect(card.getByLabel("Stage")).toHaveValue(/.+/);
  await card.getByLabel("Stage").selectOption({ label: "Contacting" });
  const activity = page.locator("[data-planet-ops=request-activity]");
  await expect(activity.getByText("Moved from New inquiry to Contacting")).toBeVisible();

  await activity.getByLabel("What was said").fill("Called about the demolition. They want a site visit next week.");
  await activity.getByRole("button", { name: "Log call" }).click();
  await expect(activity.getByText("Call to the customer")).toBeVisible();
  await expect(card.getByText("None logged yet")).toHaveCount(0);

  await card.getByLabel("Next action", { exact: true }).fill("Book the site visit");
  await card.getByRole("button", { name: "Save" }).click();
  await expect(activity.getByText(/Next action: Book the site visit/)).toBeVisible();
  await expectAccessible(page, "a request in the pipeline");

  // Lost needs a reason.
  await card.getByLabel("Stage").selectOption({ label: "Lost" });
  const dialog = page.getByRole("dialog", { name: /to Lost/ });
  await expect(dialog.getByRole("button", { name: "Move to Lost" })).toBeDisabled();
  await dialog.getByLabel("Why?").fill("They chose another contractor");
  await dialog.getByRole("button", { name: "Move to Lost" }).click();
  await expect(card.getByText("They chose another contractor")).toBeVisible();
  await expect(card.getByLabel("Next action", { exact: true })).toHaveCount(0);

  const lost = must(await data.db.from("requests").select("outcome_reason, next_action, follow_up_paused_reason, last_contact_at").eq("id", first.id).single(), "lost request");
  expect(lost).toMatchObject({ outcome_reason: "They chose another contractor", next_action: null, follow_up_paused_reason: "lost" });
  expect(lost.last_contact_at).not.toBeNull();
  const other = must(await data.db.from("requests").select("next_action, outcome_reason, stage:pipeline_stages(system_key)").eq("id", second.id).single(), "other request");
  expect(other).toMatchObject({ next_action: "Make first contact", outcome_reason: null, stage: { system_key: "new_inquiry" } });
  const kinds = must(await data.db.from("request_pipeline_events").select("kind").eq("request_id", first.id), "history").map((e) => e.kind).sort();
  expect(kinds).toEqual(expect.arrayContaining(["contact", "next_action", "outcome", "paused", "stage"]));
});
