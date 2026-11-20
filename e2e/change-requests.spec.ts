/**
 * Planet Ops Phase 1c: a proposal goes out as version 1; the customer asks for changes in the portal
 * (signing pauses); the office reads the note, replies, prepares a revision (the customer's link shows
 * only that an update is coming) and sends it as version 2; the customer signs version 2, and both
 * versions are kept.
 */
import { expect, expectAccessible, makeClient, must, test } from "./support/fixtures";

test("Request changes → signing paused → a revision sent as version 2 → signed; both versions kept", async ({ as, browser, data }) => {
  const client = await makeClient(data, "Changes");
  const quote = must(
    await data.db.from("quotes").insert({ company_id: data.id, client_id: client.id, property_id: client.propertyId, title: "Shed demolition", tax_rate: 0, presentation: "proposal", narrative: { overview: "Remove the shed and its slab." } }).select("id").single(),
    "quote",
  );
  must(await data.db.from("quote_line_items").insert({ company_id: data.id, quote_id: quote.id, name: "Demolish shed", quantity: 1, unit: "job", unit_price: 2400, taxable: false, sort: 0 }).select("id"), "line");

  const page = await as("owner");
  await page.goto(`/quotes/${quote.id}`);
  await page.getByRole("button", { name: "Send quote" }).click();
  await page.getByRole("dialog", { name: "Send quote" }).getByRole("button", { name: "Send email" }).click();
  const sent = page.getByRole("dialog", { name: "Sent" });
  const token = (await sent.getByRole("textbox").inputValue()).match(/\/hub\/([\w.-]+)/)?.[1];
  expect(token, "the client link").toBeTruthy();
  await sent.getByRole("button", { name: "Done" }).click();
  await expect.poll(async () => must(await data.db.from("quote_versions").select("number").eq("quote_id", quote.id), "versions").length).toBe(1);

  // The customer asks for a change instead of signing.
  const portal = await (await browser.newContext()).newPage();
  await portal.goto(`/hub/${token}`);
  const hub = portal.locator("#root");
  await expect(hub.getByText("Remove the shed and its slab.").first()).toBeVisible();
  await hub.getByRole("button", { name: "Request changes" }).first().click();
  const note = "Please keep the slab; we'll pour a new pad on it.";
  await hub.getByLabel("What would you like changed?").fill(note);
  await hub.getByRole("button", { name: "Send request" }).click();
  await expect(hub.getByRole("heading", { name: "Request sent" })).toBeVisible();
  await portal.reload();
  await expect(hub.getByText(/You asked for changes/)).toBeVisible();
  await expect(hub.getByText(note)).toBeVisible();
  await expect(hub.getByRole("button", { name: /Approve/ })).toHaveCount(0);
  await expectAccessible(portal, "a document with changes requested, in the customer portal");

  // The office sees the note on the version it was about, with its follow-up, and replies.
  await page.reload();
  const versions = page.locator("[data-planet-ops=versions]");
  await expect(versions.getByText(note)).toBeVisible();
  await expect(versions.getByText("on version 1")).toBeVisible();
  await expect(versions.getByText(/Follow-up for/)).toBeVisible();
  await versions.getByLabel("Your reply (kept with the request)").fill("Yes, the slab stays. Updated proposal on its way.");
  await versions.getByRole("button", { name: "Save reply" }).click();
  await expect(versions.getByText(/the slab stays/)).toBeVisible();

  // A revision: the price drops. Nothing goes out, and the customer's link shows only that an update is coming.
  const line = page.getByRole("row").filter({ has: page.getByLabel("Item name") }).first();
  await line.getByLabel("Unit price").fill("1900");
  await line.getByLabel("Unit price").press("Enter");
  await expect(page.getByText("$1,900.00").first()).toBeVisible();
  await page.reload();
  await expect(page.locator("[data-planet-ops=draft-revision]")).toBeVisible();
  await portal.reload();
  await expect(hub.getByRole("heading", { name: /An updated proposal is on its way/ })).toBeVisible();
  await expect(hub.getByText("$1,900.00")).toHaveCount(0);

  // The office sends the update: version 2.
  await page.locator("[data-planet-ops=draft-revision]").getByRole("button", { name: "Send the update" }).click();
  await page.getByRole("dialog", { name: /Send|Resend/ }).getByRole("button", { name: "Send email" }).click();
  await page.getByRole("dialog", { name: "Sent" }).getByRole("button", { name: "Done" }).click();
  await expect.poll(async () => must(await data.db.from("quote_versions").select("number, superseded_at").eq("quote_id", quote.id).order("number"), "versions").map((v) => [v.number, v.superseded_at !== null])).toEqual([[1, true], [2, false]]);

  // The customer signs version 2.
  await portal.reload();
  await expect(hub.getByText("$1,900.00").first()).toBeVisible();
  await hub.getByRole("button", { name: "Continue to sign" }).click();
  await hub.getByLabel("Your full name").fill("Pat Client");
  const signaturePad = hub.getByRole("img", { name: /Draw your signature with your finger, mouse or stylus/ });
  await signaturePad.scrollIntoViewIfNeeded();
  const pad = await signaturePad.boundingBox();
  await portal.mouse.move(pad!.x + 30, pad!.y + 80);
  await portal.mouse.down();
  await portal.mouse.move(pad!.x + 90, pad!.y + 50, { steps: 5 });
  await portal.mouse.move(pad!.x + 160, pad!.y + 90, { steps: 5 });
  await portal.mouse.up();
  await hub.getByRole("checkbox", { name: /I approve this/ }).check();
  await hub.getByRole("button", { name: /Approve/ }).click();
  await expect(hub.getByText(/^Signed on/)).toBeVisible();
  await portal.context().close();

  const signed = must(await data.db.from("quotes").select("status, total, approval").eq("id", quote.id).single(), "signed quote");
  expect(signed.status).toBe("approved");
  expect(Number(signed.total)).toBe(1900);
  expect(signed.approval).toMatchObject({ version_number: 2 });
  const kept = must(await data.db.from("quote_versions").select("number, total, signed_at").eq("quote_id", quote.id).order("number"), "versions");
  expect(kept.map((v) => [v.number, Number(v.total), v.signed_at !== null])).toEqual([[1, 2400, false], [2, 1900, true]]);
  const requests = must(await data.db.from("quote_change_requests").select("message, version_number, resolved_at").eq("quote_id", quote.id), "requests");
  expect(requests).toEqual([{ message: note, version_number: 1, resolved_at: expect.any(String) }]);
});
