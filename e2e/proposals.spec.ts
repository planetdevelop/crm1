/**
 * Planet Ops Phase 1b: a customer document starts with its type. The office makes a proposal from
 * "New Quote / Proposal", fills its sections, and previews it; the customer's page (phone-sized here)
 * shows the narrative scope and the agreed total without the priced line table. Switching the draft
 * to a line-item quote and back keeps the price, the sections and both terms.
 */
import { PHONE, expect, expectAccessible, makeClient, must, test } from "./support/fixtures";

test("New Quote / Proposal starts with the document type; a proposal shows its scope and total, not priced lines", async ({ as, browser, data }) => {
  const client = await makeClient(data, "Proposal");
  const page = await as("owner");
  await page.goto("/quotes");
  await page.getByRole("button", { name: "New Quote / Proposal" }).first().click();
  const dialog = page.getByRole("dialog", { name: "New Quote / Proposal" });
  const type = dialog.getByRole("group", { name: "Document type" });
  await expect(type.getByRole("radio", { name: /Line-item quote/ })).toBeChecked();
  await type.getByRole("radio", { name: /Proposal/ }).check();
  await dialog.getByLabel("Search clients").fill(client.name);
  await dialog.getByRole("option", { name: new RegExp(client.name) }).click();
  await dialog.getByLabel("Title").fill("Garage demolition");
  await dialog.getByRole("button", { name: "Create proposal" }).click();
  await expect(page).toHaveURL(/\/quotes\/[0-9a-f-]{36}$/);
  const quoteId = page.url().split("/quotes/")[1]!;

  // The type is at the top of the draft, apart from how it's looked at (Edit / Preview).
  const docType = page.getByRole("group", { name: "Document type" });
  await expect(docType.getByRole("radio", { name: /Proposal/ })).toBeChecked();
  await expect(page.getByRole("group", { name: "View" }).getByRole("button", { name: "Edit" })).toHaveAttribute("aria-pressed", "true");

  // The price comes from line items the office keeps; the customer sees the sections and the total.
  await page.getByRole("button", { name: "Custom item" }).click();
  const line = page.getByRole("row").filter({ has: page.getByLabel("Item name") }).last();
  await line.getByLabel("Item name").fill("Demolish detached garage");
  await line.getByLabel("Quantity").fill("1");
  await line.getByLabel("Unit price").fill("6400");
  await line.getByLabel("Unit price").press("Enter");
  await expect(page.getByText("$6,400.00").first()).toBeVisible();
  const overview = page.getByLabel(/Project overview/);
  await overview.fill("Remove the detached garage and its slab.");
  await overview.blur();
  const scope = page.getByLabel(/Scope of work/);
  await scope.fill("1. Disconnect utilities\n2. Demolish\n3. Haul debris");
  await scope.blur();
  await expect.poll(async () => must(await data.db.from("quotes").select("narrative").eq("id", quoteId).single(), "quote").narrative).toMatchObject({ scope: expect.stringContaining("Haul debris") });
  await expectAccessible(page, "a draft proposal");

  // Preview: the proposal as it prints, with its scope and total and no priced line table.
  await page.getByRole("group", { name: "View" }).getByRole("button", { name: "Preview" }).click();
  await expect(page.getByText("Remove the detached garage and its slab.").first()).toBeVisible();
  await expect(page.getByText("$6,400.00").first()).toBeVisible();

  // Switching to a line-item quote and back keeps the price, the sections and both terms.
  const before = must(await data.db.from("quotes").select("total, narrative, contract_terms, payment_terms").eq("id", quoteId).single(), "quote");
  await page.getByRole("group", { name: "View" }).getByRole("button", { name: "Edit" }).click();
  await docType.getByRole("radio", { name: /Line-item quote/ }).check();
  await expect.poll(async () => must(await data.db.from("quotes").select("presentation").eq("id", quoteId).single(), "quote").presentation).toBe("line_items");
  await docType.getByRole("radio", { name: /Proposal/ }).check();
  await expect.poll(async () => must(await data.db.from("quotes").select("presentation").eq("id", quoteId).single(), "quote").presentation).toBe("proposal");
  const after = must(await data.db.from("quotes").select("total, narrative, contract_terms, payment_terms").eq("id", quoteId).single(), "quote");
  expect(after).toEqual(before);

  // The customer's page, on a phone: the scope and the total, not the priced lines.
  await page.getByRole("button", { name: "Send quote" }).click();
  const send = page.getByRole("dialog", { name: "Send quote" });
  await send.getByRole("button", { name: "Send email" }).click();
  const sent = page.getByRole("dialog", { name: "Sent" });
  const token = (await sent.getByRole("textbox").inputValue()).match(/\/hub\/([\w.-]+)/)?.[1];
  expect(token, "the client link").toBeTruthy();
  await sent.getByRole("button", { name: "Done" }).click();
  const portal = await (await browser.newContext({ ...PHONE })).newPage();
  await portal.goto(`/hub/${token}`);
  const hub = portal.locator("#root");
  await expect(hub.getByText("Remove the detached garage and its slab.").first()).toBeVisible();
  await expect(hub.getByText("$6,400.00").first()).toBeVisible();
  await expect(hub.getByText("Demolish detached garage")).toHaveCount(0);
  await expectAccessible(portal, "a proposal in the customer portal, on a phone");
  await portal.context().close();
});
