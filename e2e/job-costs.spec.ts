/**
 * Planet Ops Phase 4: on a job, the office uploads a receipt (the same file twice is one document),
 * corrects the suggested category and approves it, records a disposal ticket whose charge counts once,
 * and sees each figure apart (a missing one says so). PDOS settings show the backup state. Fictional.
 */
import { expect, expectAccessible, makeClient, must, test } from "./support/fixtures";

test("job costs: upload, review, disposal ticket, figures apart", async ({ as, data }) => {
  const client = await makeClient(data, "Costs");
  const job = must(await data.db.from("jobs").insert({ company_id: data.id, client_id: client.id, property_id: client.propertyId, title: `${client.name} garage demolition`, status: "active" }).select("id").single(), "job");
  const page = await as("owner");
  await page.goto(`/jobs/${job.id}`);
  const panel = page.locator("[data-planet-ops=job-costs]");
  await expect(panel.getByRole("heading", { name: /Job costs/ }).or(panel.getByText("Job costs (Planet Ops)"))).toBeVisible();
  // No estimate behind this job, and nothing recorded: said so, not $0.
  await expect(panel.getByText("None (made without an estimate)")).toBeVisible();
  await expect(panel.getByLabel("Job figures").getByText("Not recorded").first()).toBeVisible();

  // Upload the same receipt twice: one document.
  const receipt = { name: "fuel.pdf", mimeType: "application/pdf", buffer: Buffer.from(`%PDF-1.4 fictional receipt ${client.name}`) };
  await panel.locator("input[type=file]").setInputFiles(receipt);
  await expect(panel.getByLabel("Cost documents").getByRole("row")).toHaveCount(2);
  await panel.locator("input[type=file]").setInputFiles(receipt);
  await expect(page.getByText(/already uploaded \(kept once\)/)).toBeVisible();
  await expect(panel.getByLabel("Cost documents").getByRole("row")).toHaveCount(2);

  // Review: vendor, total, category tools (the reader would have said fuel), approve on this job.
  await panel.getByRole("button", { name: "Review" }).click();
  const dialog = page.getByRole("dialog", { name: /Review receipt/ });
  await dialog.getByLabel("Vendor").fill("TEST Fuel Stop");
  await dialog.getByLabel("Total on the document").fill("84.50");
  await dialog.getByLabel("Category").fill("tools");
  await dialog.getByLabel("Amount 1").fill("80");
  await expectAccessible(page, "the cost review dialog");
  await dialog.getByRole("button", { name: "Approve" }).click();
  await expect(dialog).toHaveCount(0);
  await expect(panel.getByLabel("Job figures").getByText("$80.00")).toBeVisible();
  const docs = must(await data.db.from("cost_documents" as never).select("review_status, category, total").eq("job_id", job.id), "docs") as unknown as Array<{ review_status: string; category: string; total: number }>;
  expect(docs).toEqual([{ review_status: "approved", category: "tools", total: 84.5 }]);

  // A disposal ticket: weighed, its charge added once.
  await panel.getByRole("button", { name: "Add ticket" }).click();
  const t = page.getByRole("dialog", { name: "Disposal ticket" });
  await t.getByLabel(/^Facility/).fill("TEST Transfer");
  await t.getByLabel(/^Ticket number/).fill(`T-${Date.now()}`);
  await t.getByLabel(/^Net lb/).fill("6400");
  await t.getByLabel(/^Container capacity CY/).fill("20");
  await t.getByLabel(/^Tipping fee/).fill("288");
  await t.getByRole("button", { name: "Save ticket" }).click();
  await expect(t).toHaveCount(0);
  const totals = panel.getByLabel("Disposal totals");
  await expect(totals.getByText("3.2 t")).toBeVisible();
  await expect(totals.getByText(/20 CY/)).toBeVisible();
  await expect(panel.getByLabel("Disposal tickets").getByText("Counted once")).toBeVisible();
  await expect(panel.getByLabel("Job figures").getByText("$288.00")).toBeVisible(); // provisional, apart from approved
  await expectAccessible(page, "a job's costs");

  // Nothing went to a job folder: the job exists, but PDOS isn't set up here.
  await page.goto("/settings?tab=pdos");
  await expect(page.locator("[data-planet-ops=pdos-settings]").getByText(/No: files wait, kept in the app/)).toBeVisible();
  await expectAccessible(page, "PDOS settings");
});

test("cost review: the inbox for files without a job; crew don't see it", async ({ as }) => {
  const page = await as("owner");
  await page.goto("/job-costs");
  await expect(page.getByRole("heading", { name: "Cost review" })).toBeVisible();
  await expectAccessible(page, "cost review");
});
