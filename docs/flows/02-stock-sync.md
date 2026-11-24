# Flow 2: Stock sync (Odoo to Salesforce, recipe 411572)

Every completed Odoo stock move that changes stock at a Salesforce warehouse is sent as one `stock.adjusted` event.
Salesforce books it as TC inventory movements at the matching `TC_Warehouse__c` / `TC_Location__c`.

```mermaid
sequenceDiagram
    autonumber
    actor U as Odoo user
    participant O as Odoo
    participant W as Workato 411572<br/>Odoo to SFDC - Stock
    participant API as NFY_IntegrationApi
    participant SS as NFY_StockSyncService
    participant TC as TC Accounting
    participant BO as Backorder fill<br/>(fillBackorders)

    U->>O: Validate receipt, inventory count, scrap or internal transfer
    O->>O: stock.move state = done<br/>Automation "NFY: Send completed stock move to Workato"
    O->>O: x_nfy_stock_payload: walk each location up its parents<br/>to the first x_nfy_sf_code
    alt Skipped (payload = False)
        Note over O: not done, not storable, customer or transit move,<br/>no Salesforce code on either side, or same code both sides
    else Sent
        O->>W: POST webhook odoo_stock_move
        W->>API: POST stock.adjusted (source ODOO_SHOP)
        API->>SS: apply {moveId, reference, date, reason, sku, qty, from, to, unitCost}
        SS->>TC: Inbound / outbound inventory movement<br/>(transfer = linked non-accounting pair)
        SS->>TC: GL offset from TC GL Account Defaults<br/>(Vouchers Payable for receipts, Inventory Variance for counts and scrap)
        SS->>BO: Stock increased at a warehouse
        BO->>TC: Assign new stock to short order lines, oldest first
        API-->>W: 200 / 422
        Note over W: Monitor: retry 3x unless the error contains 422
    end
```

## Reason codes

| Odoo move | `reason` |
|---|---|
| From a supplier location | `receipt` |
| From or to a production location | `production` |
| From or to an inventory-loss location named "scrap" | `scrap` |
| From or to another inventory-loss location | `adjustment` |
| Between two internal locations with different codes | `transfer` |

## Warehouse mapping

The only mapping is the Odoo location field `x_nfy_sf_code` = `TC_Warehouse__c.NFY_Code__c`. Child locations inherit
the code of their nearest parent. See [config/warehouse-mapping.csv](../../config/warehouse-mapping.csv).

Customer deliveries are not sent here (they arrive as shipments). Moves into or out of transit are not sent here
(they arrive as inbound updates).
