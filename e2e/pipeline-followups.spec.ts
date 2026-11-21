/**
 * Planet Ops Phase 2 follow-ups: pausing cancels the stage's reminder and resuming brings that same
 * reminder back; a follow-up made the next action moves it when snoozed; Won by hand is a sales call
 * with a note and makes no job.
 */
import { expect, makeClient, must, test } from "./support/fixtures";

test("follow-ups: pause and resume restore the same reminder; snoozing moves the next action; Won with a note makes no job", async ({ as, data }) => {
  const client = await makeClient(data, "Follow-ups");
  const request = must(await data.db.from("requests").insert({ company_id: data.id, client_id: client.id, property_id: client.propertyId, title: `${client.name} shed removal`, source: "phone" }).select("id").single(), "request");
  const page = await as("owner");
  await page.goto(`/requests/${request.id}`);
  const card = page.locator("[data-planet-ops=pipeline-card]");
  const activity = page.locator("[data-planet-ops=request-activity]");
  await expect(activity.getByText(/^First response:/)).toBeVisible();

  await card.getByRole("button", { name: "Pause follow-ups" }).click();
  await expect(activity.getByText(/^First response:/)).toHaveCount(0);
  await card.getByRole("button", { name: "Resume follow-ups" }).click();
  await expect(activity.getByText(/^First response:/)).toBeVisible();
  await expect(activity.getByText(/Follow-up restored: First response/)).toBeVisible();
  const reminders = must(await data.db.from("follow_up_tasks").select("id, done_at").eq("related_id", request.id).eq("source", "cadence"), "reminders");
  expect(reminders).toHaveLength(1);
  expect(reminders[0].done_at).toBeNull();

  // A follow-up that is the next action; snoozed a week, the next action moves with it.
  await activity.getByLabel("Add a follow-up").fill("Call about the slab");
  await activity.getByLabel("Make it the next action").check();
  await activity.getByRole("button", { name: "Add", exact: true }).click();
  await expect(card.getByLabel("Next action", { exact: true })).toHaveValue("Call about the slab");
  await activity.getByRole("button", { name: 'Snooze "Call about the slab" a week' }).click();
  await expect(activity.getByText(/Follow-up moved: Call about the slab/)).toBeVisible();
  const [linked, task] = await Promise.all([
    data.db.from("requests").select("next_action_on, next_action_task_id").eq("id", request.id).single(),
    data.db.from("follow_up_tasks").select("id, due_on").eq("related_id", request.id).eq("title", "Call about the slab").single(),
  ]);
  expect(must(linked, "request").next_action_task_id).toBe(must(task, "task").id);
  expect(must(linked, "request").next_action_on).toBe(must(task, "task").due_on);

  // Won by hand: a note, and no job.
  await card.getByLabel("Stage").selectOption({ label: "Won" });
  const dialog = page.getByRole("dialog", { name: /to Won/ });
  await expect(dialog.getByText(/makes no job, signature, deposit or payment/)).toBeVisible();
  await dialog.getByLabel("Why is it won?").fill("Verbal yes on site; contract to follow");
  await dialog.getByRole("button", { name: "Move to Won" }).click();
  await expect(card.getByText("Verbal yes on site; contract to follow")).toBeVisible();
  const jobs = must(await data.db.from("jobs").select("id").eq("client_id", client.id), "jobs");
  expect(jobs).toHaveLength(0);
});
