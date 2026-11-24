# Flow 1: Product sync (Odoo to Salesforce)

Odoo is the product master. Each sellable variant becomes one `Product2` in Salesforce, matched by the Odoo
variant ID first and the SKU (Odoo Internal Reference, `default_code`) second. Names are never used to match.

```mermaid
sequenceDiagram
    autonumber
    actor U as Odoo user
    participant O as Odoo
    participant W1 as Workato 411537<br/>Odoo to SFDC - Products
    participant W2 as Workato 411534<br/>Product Sync (function)
    participant API as Salesforce<br/>NFY_IntegrationApi
    participant PS as NFY_ProductSyncService
    participant LOG as NFY_Sync_Log__c

    U->>O: Create or edit product (name, price, Internal Reference, ...)
    O->>O: Automation "NFY: Send product to Workato (template)"<br/>on_create_or_write, or "(variant)" on_write
    O->>W1: POST webhook odoo_product_changed<br/>body = x_nfy_product_payload {model, template_id, variants[]}
    loop For each variant
        alt Variant ID present
            W1->>W2: Call function with the standard product
            W2->>API: POST product.upsert (source ODOO_SHOP)
            API->>LOG: Log event (key ODOO-PRODUCT-id@write_date)
            API->>PS: upsert
            PS->>PS: Match Odoo variant ID, then SKU<br/>Odoo owns catalogue fields and corporate-currency price
            PS-->>API: Created / Updated / No change
            API-->>W2: 200, or 422 with reason
            Note over W2: Monitor: retry 3x unless the error<br/>contains 422 or 400 Bad Request
        else No variant ID
            W1->>W1: Log message to job report only
        end
    end
    Note over LOG: A newer version of the same product that succeeds<br/>closes older failures as Superseded
```

## Mapping (Odoo `x_nfy_product_payload` to Salesforce)

| Odoo (variant) | Payload key | Salesforce |
|---|---|---|
| `id` | `id` (sent as `sourceVariantId`) | Odoo product id on Product2 (`NFY_Odoo_Product_Id__c`) |
| `product_tmpl_id` | `template_id` | Source product id |
| `default_code` | `default_code` (sku) | `ProductCode` / SKU |
| name + variant values | `name` | `Name` |
| `description_sale` | `description_sale` | `Description` |
| `categ_id.name` (blank for All / Goods / Saleable) | `categ` | `Family` |
| `active` and template active | `active` | `IsActive` |
| `uom_id.name` (Units becomes Each) | `uom` | `QuantityUnitOfMeasure` |
| `lst_price` | `lst_price` | Standard price book entry (corporate currency) |
| `standard_price` | `standard_price` | Cost |
| `is_storable` | `is_storable` | `TC_Inventory_Product__c` (inventory flag) |
| `write_date` (max of variant and template) | `write_date` | Event version |

The Workato recipe 411537 maps Odoo keys to the standard product payload
(`sku, name, description, family, active, uom, price, currency, cost, storable, sourceProductId, sourceVariantId`)
before calling 411534. The exact field formulas live in the recipe; export it to keep them under version control
(see [Workato README](../../workato/README.md)).

## Business rules

- A product with no SKU fails with "The Odoo product has no SKU" (422). Saving it again with a SKU succeeds and supersedes the failure.
- A SKU already linked to another source product fails with "Mapping conflict" instead of taking it over.
- Odoo can send a half-saved product (no SKU) and then the full one under the same `write_date`; both are kept as separate events because the payloads differ.
