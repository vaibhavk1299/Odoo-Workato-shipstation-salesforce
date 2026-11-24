# Implementation inventory

Status as of 24 Nov 2026. "Verified" means run end to end through the real systems (Odoo UI, Workato, ShipStation,
Salesforce) in the recorded test of 23 Nov 2026 unless another date is given. Apex unit tests are not counted as
end-to-end verification.

## Implemented and verified

| # | Capability | Path | Evidence |
|---|---|---|---|
| 1 | New product and price change sync | Odoo product automations > 411537 > 411534 > `product.upsert` | Test 1: E2E Jacket created, price 40 to 45 updated |
| 2 | Missing-SKU product rejected, fixed, failure closed automatically | Same, 422 + `Superseded` | Test 2: "The Odoo product has no SKU", then created after adding the SKU |
| 3 | Vendor receipt increases Salesforce stock | stock.move > 411572 > `stock.adjusted` | Test 3: NFM/IN/01004, 20 available at Main |
| 4 | Transfer through transit with partial receipt and backorder | Inbound automations > 417679 > `inbound.update` | Test 4: In Transit > Receiving (4 of 5, variance -1) > Closed (5 of 5) |
| 5 | Order from Main shipped through ShipStation, billed, Odoo delivery closed | 411457 > 408639; 412419; 412422 + Odoo on_webhook | Test 5: S02009 > SO-01421 Allocated > ShipStation > SHP-00713, BIL-01966; Odoo Fully Delivered |
| 6 | Order from a 3PL warehouse shipped from Odoo | 408639; 411490 `shipment.created` | Test 6: S02010 from SM-PA1 > SHP-00714 FedEx, BIL-01967 |
| 7 | Ship-from fallback to Main when the requested warehouse has no stock | Odoo routing action + `handleOrder` | Test 7: S02011 FBA-US moved to Main in Odoo and Salesforce, sent to ShipStation |
| 8 | Partial allocation, backorder, ShipStation quantity update, backorder fill | `handleOrder`, `fillBackorders`, reservation-change automation | Test 8: 25 of 30 assigned, ShipStation 25 > receipt of 5 > 30 assigned, ShipStation 30, shipped and billed |
| 9 | Duplicate event ignored | Sync log key match | Test 9: repeated Workato job > `Duplicate skipped` |
| 10 | Customer payments: full, partial, prepayment applied at billing | Odoo payment automation > 420219 > `payment.received` | Tests 8 and 10: Paid / Partially Paid on the Order |
| 11 | Customer refund and cancelled refund | 420219 > `payment.refunded` / `payment.reversed` | Test 11: credit memo created, then withdrawn |
| 12 | Daily payment reconciliation | Odoo cron > 420315 > `payment.snapshot` | Test 12: 12 payments checked, nothing to repair |
| 13 | Monitoring: Command Center, integration map, failures list | LWC `nfyCommandCenter` | Test 13 |
| 14 | Cancelled payment reversal (`payment.reversed`) | 420219 | Verified 20 Nov 2026 (applied, then reversed) |

## Implemented but not fully verified

| Capability | What is missing |
|---|---|
| Stock reasons other than receipt (count adjustment, scrap, production, plain internal transfer between coded locations) | Code and Apex tests exist; only receipts were run end to end on 23 Nov |
| Vendor receipt statuses WORKING and IN_TRANSIT (tracking added before receipt) | Run on the previous Odoo database (17 Nov); not re-run after the 20 Nov rebuild |
| Inbound shortfall opens an inventory reconciliation (`NFY_Inventory_Recon__c`) | Run on the previous Odoo database (17 Nov) only |
| Retry of a failed event from Salesforce | Used during demos; not part of the 23 Nov script |
| Failure alerts (platform event + custom notification `NFY_Integration_Alert`) | Not checked on a device |
| Odoo "block confirm without products" rule | Built; no recorded negative test |
| Rep-entered Salesforce orders sent to fulfilment on activation (`NFY_OrderTrigger`, `NFY_FulfilmentJob`) | Apex tests only; not part of the Odoo flows |

## Partial

| Capability | State |
|---|---|
| Salesforce-driven ShipStation release (`NFY_Integration_Event__e` > 419546 > `NFY_ShipStationOrderApi`) | Built and tested once (20 Nov); recipe stopped and flow record inactive until go-live is approved |
| Order cancellation | `order.cancelled` handler exists in Salesforce (releases stock, closes the order, tells ShipStation via the release recipe); no Odoo automation sends it |
| Workato recipes under version control | Recipes documented in [workato/README.md](../workato/README.md); package exports not yet added |
| Odoo configuration under version control | Reconstructed code and settings in [odoo/](../odoo); not exported from the live database |
| Source links from Salesforce to Odoo / ShipStation records | `NFY_Source_Link__mdt` has an Odoo URL template; the ShipStation template is empty |

## Not implemented

| Capability | Note |
|---|---|
| Order changes after confirmation (edit, add line) | Odoo sends the order only when it is confirmed |
| Customer returns from Odoo | `return.received` exists in Salesforce; no Odoo automation |
| Odoo stock count snapshot / periodic stock reconciliation | `inventory.snapshot` exists in Salesforce; no Odoo job |
| Odoo purchase orders as TC purchase orders | Receipts arrive as stock and inbound events; `po.receipt` is not used by Odoo |
| Invoices or payment status back to Odoo | Odoo does not invoice; Salesforce bills |
| Workato job health / heartbeat in Salesforce | Salesforce sees events, not Workato connection state |
| Dedicated Salesforce integration user | Workato connects as an existing user |
| CI/CD pipeline | Deployments are run by hand with the scripts in [scripts/](../scripts) |

## Dependencies

- TC Accounting installed and configured in the Salesforce org (objects, classes, default ledger, GL Account Defaults).
- Odoo custom fields, views, server actions, automations and the daily scheduled action from [odoo/](../odoo).
- Odoo location codes equal to `TC_Warehouse__c.NFY_Code__c` ([config/warehouse-mapping.csv](../config/warehouse-mapping.csv)).
- Workato connections: Salesforce, ShipStation API, Odoo Webhook, Workato Webhook Forwarder.
- ShipStation API key and webhooks pointing to Workato 412422.
- `NFY_Integration_System__c` / `NFY_Integration_Flow__c` records ([config/seed](../config/seed)).

See [gaps-and-risks.md](gaps-and-risks.md) for risks.
