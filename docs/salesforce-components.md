# Salesforce component inventory

Source: [salesforce/force-app](../salesforce/force-app), retrieved from the working org on 24 Nov 2026.
353 components; manifest in [salesforce/manifest/package.xml](../salesforce/manifest/package.xml).
Deployable with the Salesforce CLI. TC Accounting is a prerequisite and is **not** in this package.

## Apex: integration core

| Class | Role |
|---|---|
| `NFY_IntegrationApi` | REST `POST /nfinity/v1/events`. Validates the envelope, returns 200 / 422 / 400 |
| `NFY_IntegrationService` | Logs, de-duplicates and processes every event; orders, shipments, inbound, payments, refunds, reconciliation, cancellation, backorder fill, release events, alerts, retry |
| `NFY_ProductSyncService` | `product.upsert`: Product2 per variant, matching and field ownership |
| `NFY_StockSyncService` | `stock.adjusted`: TC inventory movements and GL offsets |
| `NFY_ShipStationService` | `shipstation.notify`: splits ShipStation webhooks into `shipment.created` events |
| `NFY_ShipStationOrderApi` | REST `GET /nfinity/v1/shipstation/order/{id}?kind=`: ShipStation order body for the release recipe |
| `NFY_PaymentStatusService` | Order payment status and balance due from TC billings |
| `NFY_OriginService` | Stamps source system, source id and last sync on every record an event touches |
| `NFY_Ref` | Cached reference data: systems, flows, warehouses, locations, GL accounts, price book |

## Apex: user interface controllers

| Class | Used by |
|---|---|
| `NFY_CommandCenterController` | `nfyCommandCenter` (KPIs, integration map, failures, `retryLog`) |
| `NFY_OrderJourneyController` | `nfyOrderJourney` (Order History) |
| `NFY_IntegrationOriginController` | `nfyIntegrationOrigin` (origin card, Retry on a log, links to Workato jobs) |
| `NFY_OrderFulfilmentController` | `nfySendToFulfilment` (orders entered by reps) |

## Apex: jobs, triggers and tooling

| Component | Role |
|---|---|
| Trigger `NFY_OrderTrigger` (Order, after update) + `NFY_FulfilmentJob` | Sends an activated rep-entered order through the Integration API |
| Trigger `NFY_BillingPaymentTrigger` (TC_Billing__c) | Calls `NFY_PaymentStatusService` |
| `NFY_ThreePLTemplate` | Creates the system, warehouse, locations and flows for a new 3PL in one call |
| `NFY_SimulatorController`, `NFY_DemoData`, `NFY_HistoryBatch`, `NFY_ResetBatch` | Demo simulator, demo data seed, history replay and demo reset. Kept because other classes and tests depend on them; restrict access in production |
| One channel order mapper class | Shared dependency of `NFY_IntegrationService`; not used by this integration |

## Apex tests (11 classes)

`NFY_CommandCenter_Test`, `NFY_Demo_Test`, `NFY_OrderJourney_Test`, `NFY_Origin_Test`, `NFY_PaymentStatus_Test`,
`NFY_Payment_Test`, `NFY_ProductSync_Test`, `NFY_Release_Test`, `NFY_ShipStationOrderApi_Test`,
`NFY_ShipStation_Test`, `NFY_Stock_Test`.

## Objects

| Object | Purpose |
|---|---|
| `NFY_Sync_Log__c` | Integration Log: one record per event (status, key, payload, response, error, retry status, links to Order, Product, Shipment, Sales Order, Account, Flow, Workato job). Change Data Capture enabled (`ChangeEvents_NFY_Sync_Log_ChangeEvent`) for live refresh |
| `NFY_Integration_System__c` | Catalogue of connected systems (code, category, status) |
| `NFY_Integration_Flow__c` | Catalogue of flows (code, direction, entity, mode, Workato recipe id, active) |
| `NFY_Inbound_Shipment__c`, `NFY_Inbound_Shipment_Line__c` | Inbound / in-transit shipments with shipped, received and variance |
| `NFY_Inventory_Recon__c` | Inventory reconciliation opened by inbound shortfalls and snapshots |
| `NFY_Return__c`, `NFY_Settlement__c` | Returns and payout settlements (API handlers exist; not used by Odoo today) |
| `NFY_Integration_Event__e` (platform event) | Fulfilment instructions (`Release`, `Cancel`) and failure alerts (`Error`) |
| `NFY_Source_Link__mdt` (custom metadata) | URL template per source system ("Open in source"); records `Odoo`, `ShipStation` |

## Fields on standard and TC objects

124 NFY fields on Account, Contact, Opportunity, Order, OrderItem, Product2 and on the TC objects
`TC_Billing__c`, `TC_Cash_Receipt__c`, `TC_Inbound_Inventory_Movement__c`, `TC_Journal_Entry__c`, `TC_Location__c`,
`TC_Outbound_Inventory_Movement__c`, `TC_Purchase_Order__c`, `TC_Sales_Order__c`, `TC_Sales_Order_Line__c`,
`TC_Shipment__c`, `TC_Warehouse__c`. Key ones:

| Field | Meaning |
|---|---|
| `Order.NFY_External_Order_Id__c` | `ODOO-<sale order>` |
| `Order.NFY_Channel__c`, `TC_Sales_Order__c.NFY_Channel__c`, `TC_Billing__c.NFY_Channel__c` | Sales channel (value `Odoo`) |
| `Order.NFY_Payment_Status__c`, `Order.NFY_Balance_Due__c` | From TC billings |
| `Product2.NFY_Odoo_Product_Id__c` | Odoo variant id |
| `TC_Warehouse__c.NFY_Code__c` | Warehouse code shared with Odoo (`x_nfy_sf_code`) |
| `TC_Warehouse__c.NFY_System__c` | Operator system (for example `SHIPSTATION` for Main) |
| `TC_Cash_Receipt__c.NFY_External_Id__c` | `ODOO-PAY-<id>`, unique |
| `TC_Shipment__c.NFY_Label_System__c` | Who produced the label |

Source tracking fields (Source System, Source Record ID, Last Sync Log) use the global value set
`NFY_Integration_Systems`.

## User interface and access

| Type | Components |
|---|---|
| Lightning app | `Nfinity` |
| Tabs | Command Center, Demo Simulator, Integration System, Integration Flow, Sync Log, Inbound Shipment, Inventory Reconciliation, Return, Settlement |
| Lightning pages | `NFY_Command_Center`, `NFY_Simulator`, record pages for Account, Contact, Opportunity, Order, Product, Sales Order, Shipment, Billing, Sync Log |
| LWC | `nfyCommandCenter`, `nfyIntegrationMap`, `nfySystemCard`, `nfyFlowConnector`, `nfyStatus`, `nfyStatusBadge`, `nfyIntegrationOrigin`, `nfyOrderJourney`, `nfySendToFulfilment`, `nfySimulator` |
| Layouts, list views | Layouts for the NFY objects; list views such as Open Failures, Odoo Orders, Integrated Products |
| Permission sets | `NFY_Demo_User` (full access to the app, objects, fields and API classes; its users receive failure alerts), `NFY_Integration_Tracking` (read origin and sync tracking) |
| Notification type | `NFY_Integration_Alert` |

## Excluded from this repository

Components in the org that are not needed for this integration and that nothing in the package depends on:
two one-off source backfill classes (`NFY_SourceBackfill`, its test), a test class for another sales channel,
one `NFY_Source_Link__mdt` record for another channel, and two record-triggered flows for another channel.
