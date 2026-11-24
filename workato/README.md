# Workato

Workspace: Workato trial (`app.trial.workato.com`), project **NFinity Commerce**.
Workato recipes and connections are **not** deployable with the Salesforce CLI. Move them with a Workato
package export / import (or Recipe Lifecycle Management on paid plans), then reconnect and edit the environment values
listed below. Connection credentials are never part of an export and are never stored in this repository.

## Recipe inventory

| Id | Name | Status | Trigger | Steps (as built) | Calls | Retry |
|---|---|---|---|---|---|---|
| 411457 | [Odoo Bridge] - Sale Order Confirmed Webhook | Active | HTTP webhook `odoo_sale_order_bridge` | Forward the Odoo payload to the Sales Orders recipe via HTTP | Webhook of 408639 | none |
| 408639 | [Odoo to SFDC] - Sales Orders | Active | HTTP webhook `odoo_sale_order_confirmed` | Monitor: Post `order.upsert` to the Integration API; on error retry 3x unless 422, else stop with error | Salesforce custom action | 3x unless 422 |
| 411537 | [Odoo to SFDC] - Products | Active | HTTP webhook `odoo_product_changed` | For each variant: if Variant ID present, monitor: call 411534; on error do not retry, log; else log to job report | 411534 | none (function retries) |
| 411534 | [Product Sync] - Upsert Product to Salesforce | Active | Function call | Monitor: Post `product.upsert`, return result; on error retry 3x unless 422 or 400 Bad Request, else stop | Salesforce custom action | 3x unless 422 / 400 |
| 411572 | [Odoo to SFDC] - Stock | Active | HTTP webhook `odoo_stock_move` | Monitor: Post `stock.adjusted` | Salesforce custom action | 3x unless 422 |
| 411490 | [Odoo to SFDC] - Shipments | Active | HTTP webhook `odoo_shipment_done` | Monitor: Post `shipment.created` | Salesforce custom action | 3x unless 422 |
| 417679 | [Odoo to SFDC] - Inbound & In-Transit | Active | HTTP webhook `odoo_inbound_update` | Monitor: Post `inbound.update` | Salesforce custom action | 3x unless 422 |
| 420219 | [Odoo to SFDC] - Payments | Active | HTTP webhook `odoo_payment_update` | Monitor: Post payment event (`payment.received` / `reversed` / `refunded`) | Salesforce custom action | 3x unless 422 |
| 420315 | [Odoo to SFDC] - Payment Reconciliation | Active | HTTP webhook `odoo_payment_snapshot` | Monitor: Post `payment.snapshot` | Salesforce custom action | 3x unless 422 |
| 412419 | [Odoo to ShipStation] - Orders | Active | HTTP webhook `odoo_order_to_shipstation` | Create or update ShipStation order via HTTP; log `shipstation.order.sent` to Salesforce | ShipStation API, Salesforce | none |
| 412422 | [ShipStation to SFDC] - Shipments | Active | HTTP webhook `shipstation_notify` | Monitor: GET ShipStation resource, Post `shipstation.notify`; then "Tell Odoo the order shipped (close delivery)" via HTTP | ShipStation API, Salesforce, Odoo on_webhook | 3x unless 422 |
| 419546 | [SFDC to ShipStation] - Released Orders | **Inactive** | Salesforce platform event `NFY_Integration_Event__e` | GET ShipStation order from the Integration API; stop unless `send`; create or update ShipStation order; log the send | Salesforce, ShipStation API | none |
| 412413 | [ShipStation] - Setup and connection check | Inactive | Manual | Utility: GET `/stores` to check the ShipStation connection | ShipStation API | none |

Every "Post ... to Nfinity Integration API" step is a Salesforce **custom action**:
`POST /services/apexrest/nfinity/v1/events` with body `{event, source, jobId, payload}`; `source` is `ODOO_SHOP` for
Odoo events and `SHIPSTATION` for ShipStation events; `jobId` is the Workato job id (it links the sync log back to the job).

Monitor pattern used by the Salesforce-posting recipes:

```
MONITOR
    Post <event> to Nfinity Integration API in Salesforce (Custom)
ON ERROR
    IF error message does not contain "422"      (411534 also: does not contain "400 Bad Request")
        RETRY all actions in monitor block up to 3 times
    IF CONDITION NOT MET, OR ERROR PERSISTS
        STOP job with error
```

## Connections

| Connection | Type | Used by | Configure in a new workspace |
|---|---|---|---|
| Salesforce | Salesforce connector (OAuth) | All recipes that post to the Integration API, 419546 | Connect as an integration user that has the `NFY_Demo_User` permission set. In the current workspace this connection is shared with recipes outside this integration: do not reconnect or edit it there. |
| ShipStation API | HTTP, Basic auth (API key / secret), base URL `https://ssapi.shipstation.com` | 412419, 412422, 419546, 412413 | Enter the ShipStation API key and secret in Workato |
| Odoo Webhook (no auth) | HTTP, no auth, base URL = Odoo host | 412422 | Set the base URL to the new Odoo host; the step URL is the on_webhook automation path |
| Workato Webhook Forwarder (no auth) | HTTP, no auth | 411457 | Point the forward step at the webhook URL of 408639 in the new workspace |

There is no Odoo API connection: Odoo pushes every event by webhook. There is no ShipStation or Odoo connector on the
current plan, so both use HTTP connections.

## Environment values to change after import

| Recipe / connection | Value |
|---|---|
| Odoo automations (all webhook actions) | New workspace webhook base for every `odoo_*` event |
| ShipStation webhooks (On Orders Shipped, On Fulfillment Shipped) | New webhook URL of 412422 (`shipstation_notify`) |
| 411457 forward step | New webhook URL of 408639 |
| 412422 step "Tell Odoo the order shipped" | The new Odoo on_webhook automation URL |
| Odoo Webhook (no auth) | New Odoo host |
| Salesforce flow records | `NFY_Integration_Flow__c.Workato_Recipe_Id__c` = the new recipe ids (used for job links in Salesforce) |

## Exports

Recipe exports are not yet in this repository. To add them:

1. Workato > Tools > Recipe lifecycle management (or the project's **Export** action on the trial plan) > select the
   recipes in the table above, without connections' secrets.
2. Save the downloaded package `.zip` to [exports/](exports) and commit it.
3. Check the export does not contain webhook URLs with workspace ids or any credentials before committing
   (`git diff --cached`); replace them with placeholders if it does.

Field-level mappings (Workato formulas) are only visible in the recipe editor or in an export; this repository
documents the payloads on the Odoo and Salesforce sides instead (see [docs/flows](../docs/flows)).
