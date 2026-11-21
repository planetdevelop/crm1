# First staging test of Estimating: a 30-minute walkthrough for the owner

For after PRs #4 → #15 are merged into `planet-ops-staging` and staging is deployed. Use **fictional
records only** (a test customer such as "TEST – Walkthrough", 1 Test Road). Customer sends from
staging must stay non-live: use your own address as the test customer's email, and don't take a
payment. The full checklist is in [../PLANET_OPS_PROGRESS.md](../PLANET_OPS_PROGRESS.md) (Phase 3
staging acceptance checklist); this is the short path through it.

Before you start: the app applies migrations when it starts, so confirm the staging service points
at the **staging** database, not production (see [RAILWAY_STAGING.md](RAILWAY_STAGING.md)).

1. **Settings → Estimating.** Add three made-up rates: a crew hour ($25, excludes burden), a
   skid steer day ($300, includes fuel), a disposal ton ($85). Leave *approval required* on.
2. **New request** for the test customer ("Garage demolition"). On the request, **Start estimate**.
   Press it twice: one estimate.
3. **Project and site**: area 480 sq ft, a structure, access notes, an assumption ("4 tons: from the
   photos"), and the customer overview.
4. **Lines**: crew 2 × 8 h × 1 day (pick the rate), skid steer 1 day, disposal 3.4 tons with 12
   loose CY and a 20 CY container, a $150 contingency. Add a fuel line for the skid steer: see the
   warning, then delete the line.
5. **Pricing review**: 25% markup, 20% burden. Check each figure's definition. **Save.**
6. **Approve** (Versions and documents). Version 1 is the original baseline.
7. **Create quote / proposal → Proposal.** In Quotes & Proposals: an unsent draft, scope and total
   only. Open the customer preview: no costs, rates or internal notes.
8. **Send** it to your own address (non-live), open the link on your phone, **request changes**.
9. Back in Estimating, **Revise** ("Customer added the shed"), add a line, save, approve. On the
   proposal, **Refresh from estimate…**: review the differences, confirm. Send again.
10. Sign on the phone with a drawn signature (and countersign, if your settings require it).
    **Convert to job**: the job says which estimate version it came from (version 2).
11. Open the estimate's **Summary**: versions, the calculated price apart from the prices sent and
    accepted, the job, "not backed up" (Phase 4 does Drive). Print it.
12. **Two-browser check**: open the estimate in two browsers, save in one, then the other: it asks
    you to reload.
13. **Roles**: sign in as a test person with *Prepare internal estimates* only: no costs anywhere;
    change a quantity and save: the costs stay as you set them.

Write down anything that looks wrong, with the estimate number. Physical iPad, finger and stylus
signing are for you to try on the device: the automated tests only emulate screen sizes.
