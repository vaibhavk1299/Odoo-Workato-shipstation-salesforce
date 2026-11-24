# ShipStation configuration

ShipStation prints labels for deliveries from Odoo locations flagged `x_nfy_shipstation = True` (today Nfinity Main,
code `MAIN`). ShipStation is configured in its own UI; nothing here is deployed by a tool.

## Setup checklist

| Item | Setting |
|---|---|
| API access | Account > API Settings: generate the v1 API key and secret. Enter them only in the Workato connection "ShipStation API" (Basic auth). Never store them in this repository. |
| Store | Orders created through the API land in the "Manual Orders" store. No marketplace store is needed for this integration. |
| Warehouse (Ship From) | One ShipStation ship-from location for Nfinity Main. Its address is the Odoo warehouse address. |
| Webhook "On Orders Shipped" (`SHIP_NOTIFY`) | URL = Workato 412422 webhook (`<WORKATO_WEBHOOK_BASE>/shipstation_notify`) |
| Webhook "On Fulfillment Shipped" (`FULFILLMENT_SHIPPED`) | Same URL as above |
| Customer notifications | Optional. Tests mark orders shipped with notifications off. |

## How orders are identified

| ShipStation field | Value | Used for |
|---|---|---|
| `orderNumber` | `ODOO-<Odoo sale order>`, e.g. `ODOO-S02009` | Salesforce Order match (`Order.NFY_External_Order_Id__c`) |
| `orderKey` | `ODOO-<Odoo delivery name, / replaced by ->` | Upsert key; one ShipStation order per Odoo delivery; used to close that delivery |
| `advancedOptions.customField1` | Salesforce warehouse code | Reference |
| `advancedOptions.customField2` | Odoo delivery id | Reference |
| `advancedOptions.customField3` | `Fully reserved` / `Partly reserved: ...` | Warehouse sees partial reservation |

Shipments come back as `shipstation.notify`; each label shipment (`SS-<shipmentId>`) or marked-shipped fulfilment
(`SS-F-<fulfillmentId>`) becomes one `shipment.created` in Salesforce.

## Warehouse operator in Salesforce

`TC_Warehouse__c.NFY_System__c` points to the `SHIPSTATION` integration system for warehouses ShipStation ships from.
The inactive recipe 419546 and `NFY_ShipStationOrderApi` use it to decide which lines would be sent from Salesforce.
