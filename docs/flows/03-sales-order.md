# Flow 3: Sales order (Odoo to Salesforce, recipes 411457 and 408639)

Confirming a quotation in Odoo creates the customer, Order and TC Sales Order in Salesforce and reserves
stock at the ship-from warehouse. Odoo does not invoice: Salesforce bills the order when it ships.

```mermaid
sequenceDiagram
    autonumber
    actor U as Odoo user
    participant O as Odoo
    participant B as Workato 411457<br/>Odoo Bridge
    participant W as Workato 408639<br/>Odoo to SFDC - Sales Orders
    participant API as NFY_IntegrationApi
    participant S as NFY_IntegrationService.handleOrder
    participant TC as TC Accounting

    U->>O: Quotation with Ship From (MAIN / SM-PA1 / FBA-US), products picked from the list
    U->>O: Confirm
    O->>O: Automation "NFY: Send confirmed order to Workato" (state = sale)
    O->>O: 1. Block confirm without products (UserError if a line has no product)
    O->>B: 2. POST webhook odoo_sale_order_bridge<br/>body = x_nfy_payload
    B->>W: Forward payload (HTTP, webhook odoo_sale_order_confirmed)
    W->>API: POST order.upsert (source ODOO_SHOP)
    API->>S: process
    S->>S: Account (ODOO-partner id), Contact, Order (ODOO-S0xxxx,<br/>channel Odoo), standard price book entries
    S->>S: Routing: keep Ship From where stock allows,<br/>else fall back to MAIN; short units are backordered
    S->>TC: TC Sales Order + lines, SO inventory movements (allocation)
    S-->>API: Allocated / Partially allocated
    API-->>W: 200 / 422
    Note over W: Monitor: retry 3x unless the error contains 422
    par In Odoo, at the same time
        O->>O: Automation "NFY: Route delivery to Ship From location"<br/>sets the delivery source location (same MAIN fallback)
    end
```

## Mapping (Odoo `x_nfy_payload` to `order.upsert`)

| Odoo | Payload | Salesforce |
|---|---|---|
| `sale.order.name` | `name` | `Order.NFY_External_Order_Id__c` = `ODOO-<name>` |
| `date_order` | `date_order` | Order effective date |
| `x_nfy_ship_from` | `warehouse_code` | Requested `TC_Warehouse__c` (by `NFY_Code__c`) |
| `amount_tax` | `amount_tax` | Tax |
| constant 0 | `freight` | Freight |
| `partner_id` id, name, email, phone, city, state, country | `partner.*` | Account (`ODOO-<id>`) and Contact |
| line `product_id.default_code` | `order_line[].default_code` | Product2 by SKU |
| line `product_uom_qty` | `order_line[].product_uom_qty` | Quantity |
| line `price_reduce_taxexcl` (after discount) | `order_line[].price_unit` | Unit price |

The field formulas that turn this into the `order.upsert` body are in recipe 408639 (export it to version them).

Also sent by the recipe: `channel` = `Odoo` (required by the API; stored on `Order.NFY_Channel__c`,
`TC_Sales_Order__c.NFY_Channel__c` and the billing), and `source` = `ODOO_SHOP`, which links the sync log to the
`NFY_Integration_System__c` record `ODOO_SHOP` and the flow `ODOO_SHOP-ORDER`.

## Records created

| Salesforce record | Link |
|---|---|
| Account, Contact | Customer `ODOO-<partner id>` |
| Order + OrderItems | `NFY_External_Order_Id__c`, `NFY_Ship_From__c` (requested warehouse), `NFY_Routing_Decision__c` |
| `TC_Sales_Order__c` + lines | `NFY_Order__c` = the Order; `Opportunity__c` stays blank |
| SO inventory movements | One per assigned line at the ship-from location |
| `NFY_Sync_Log__c` | `Order__c`, `Sales_Order__c`, `Account__c`, `Flow__c`, Workato job id |

No Opportunity is created for Odoo orders (`Order.OpportunityId` is blank on all 56 Odoo orders in the org).

## Business rules

- An unknown SKU fails the event (422) and nothing is created; fix the product and retry from Salesforce.
- Products that are not inventory products are billed with the order and never reserved or shipped.
- Orders with every stocked line assigned publish a `Release` event on `NFY_Integration_Event__e`. No active recipe
  consumes it today: Odoo sends ShipStation orders itself (see [Flow 4](04-shipping.md)).
- Order cancellation from Odoo is not wired (`order.cancelled` exists in Salesforce, no Odoo automation sends it).
