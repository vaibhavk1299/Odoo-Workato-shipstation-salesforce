# Gaps, limitations and risks

## Risks

| Risk | Impact | Mitigation |
|---|---|---|
| Workato and Odoo run on trial workspaces | Expiry stops every flow; the previous Odoo trial expired on 21 Nov 2026 and had to be rebuilt | Move both to paid environments before go-live; keep [odoo/](../odoo) and Workato exports current |
| Webhooks have no authentication (Odoo to Workato, Workato to Odoo `/web/hook`) | Anyone with a URL can post events | Treat URLs as secrets; add a shared-secret header check in Workato before production |
| The Workato Salesforce connection is shared with recipes outside this integration | Reconnecting it for this project affects those recipes | Use a separate connection and a dedicated integration user in new environments |
| Odoo ids hard-coded in two Odoo code records and one Workato step | A rebuilt Odoo database breaks the ShipStation resend, the daily snapshot and delivery closing until patched | Follow "Ids that must be patched" in [odoo/README.md](../odoo/README.md) |
| Validating a ShipStation-warehouse delivery by hand in Odoo | The shipment is reported twice | Operating rule: ShipStation deliveries are closed only by ShipStation |
| One Odoo product save can fire the product webhook many times | Extra Workato tasks; Salesforce skips repeats | Acceptable; versioned keys make repeats harmless |
| Accounting Seed validation rules in the current org were deactivated (9 rules) after its trial licence expired | In an org with an expired Accounting Seed licence, Product2 and Account saves fail | Not part of this package; check installed packages in each target org |
| Demo tooling is part of the package (simulator, demo data, reset and history batches) | `NFY_ResetBatch` deletes demo transactions if run | Restrict the `NFY_Demo_User` permission set and the Demo Simulator tab to administrators in production |
| `NFY_SimulatorController` contains four team email addresses used for demo contacts | Personal work addresses in source | Replace before sharing the repository outside the team |

## Known test failures (blocks a deployment with tests)

Test run of 24 Nov 2026 in the working org, 11 NFY test classes: 88 of 91 methods pass. Coverage of every
packaged class is 78% or higher (90.5% overall). Three methods of `NFY_Demo_Test` fail with
`System.LimitException: Too many SOQL queries: 101`:

- `b2bOrderShipsFromTwoLocations`
- `factoryLineShipsAsDropShip`
- one order fallback-and-billing scenario for another sales channel (line 56)

These failures already exist in the org; they are not caused by this repository. A production deployment with
`RunSpecifiedTests` fails until they are fixed (for example by moving `Test.startTest()` before the order is processed
so the scenario gets a fresh limit context). A check-only deployment without tests succeeds (validated 24 Nov 2026,
353 of 353 components).

## Gaps

- No Workato package exports in the repository yet (recipes are documented, not exported).
- Odoo code is reconstructed from history; compare with the live database before reuse.
- No automated end-to-end tests; the recorded 23 Nov 2026 run is manual.
- No monitoring of Workato itself (connection failures before an event reaches Salesforce are only visible in Workato).
- Not implemented: order edits, order cancellation from Odoo, returns, stock count snapshots, Odoo purchase orders,
  invoice status back to Odoo (see [implementation-inventory.md](implementation-inventory.md)).

## Limitations of the package

- The Apex package also contains handlers for another sales channel that this integration does not use (one order
  mapper class and related branches). They are kept so the repository matches the live org and compiles; nothing in
  the Odoo, Workato or ShipStation flows calls them.
- One `TC_Location__c` channel flag field and picklist values for other channels are included for the same reason.
- `NFY_Source_Link.Odoo` holds the current Odoo host; change it per environment.
