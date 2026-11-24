# Deployment guide: a new Salesforce org

## What is deployed how

| Part | How | Automated by this repository |
|---|---|---|
| Salesforce metadata and Apex (353 components) | Salesforce CLI (`sf project deploy`) | Yes: [scripts/deploy-salesforce.ps1](../scripts/deploy-salesforce.ps1) |
| Integration catalogue records (systems, flows) | Salesforce CLI data upsert | Yes: [scripts/load-config-data.ps1](../scripts/load-config-data.ps1) |
| TC Accounting | Separate installation (prerequisite) | Checked only: [scripts/check-prerequisites.ps1](../scripts/check-prerequisites.ps1) |
| Warehouse codes on `TC_Warehouse__c` | Manual (TC owns the records) | No |
| Workato recipes | Workato package export / import, or rebuild from [workato/README.md](../workato/README.md) | No (not deployable with the Salesforce CLI) |
| Workato connections | Created and authorised in Workato | No |
| Odoo fields, views, actions, automations, cron | Manual in Odoo, from [odoo/](../odoo) | No |
| ShipStation API key, webhooks | Manual in ShipStation | No |
| Credentials and secrets | Entered directly in Workato / ShipStation by an authorised person | Never stored in Git |

## 1. Clone the repository

```powershell
git clone https://github.com/Twopir-Consulting/Odoo-Workato-shipstation-salesforce.git
```

Tools: Salesforce CLI (`sf`) 2.x, PowerShell 5.1+ (or run the `sf` commands below directly on macOS / Linux).

## 2. Connect the target Salesforce org

```powershell
sf org login web --alias nfinity-uat --instance-url https://<my-domain>.my.salesforce.com
```

### Prerequisites in the org (check before deploying)

```powershell
./scripts/check-prerequisites.ps1 -OrgAlias nfinity-uat
```

Read-only. Confirms the 21 TC objects and 7 TC classes the NFY code uses. Also confirm by hand:

- TC Accounting configured: default ledger, GL Account Defaults (Vouchers Payable, Inventory Variance), GL accounts used for revenue and refunds.
- Orders enabled; standard price book active; corporate currency set.
- `TC_Warehouse__c` records exist for each warehouse in [config/warehouse-mapping.csv](../config/warehouse-mapping.csv), each with its Available and In Transit `TC_Location__c`.
- No other installed package with active validation rules that block Product2, Account or Contact saves.

## 3. Integration user and permissions

1. Create (or choose) the user the Workato Salesforce connection will sign in as. A dedicated integration user is recommended.
2. After step 4, assign permission set `NFY_Demo_User` (objects, fields, `NFY_IntegrationApi`, `NFY_ShipStationOrderApi`) plus the TC Accounting permissions the TC package requires.
3. Assign `NFY_Demo_User` to the operations users who should see the Nfinity app and receive failure alerts; `NFY_Integration_Tracking` for read-only users.

## 4. Deploy Salesforce metadata and Apex

```powershell
./scripts/deploy-salesforce.ps1 -OrgAlias nfinity-uat           # check-only validation with the 11 NFY test classes
./scripts/deploy-salesforce.ps1 -OrgAlias nfinity-uat -Deploy   # deploy
```

> Known issue: 3 methods of `NFY_Demo_Test` currently fail with "Too many SOQL queries: 101" (also in the source
> org). Fix them before a deployment that runs tests; see [gaps-and-risks.md](gaps-and-risks.md#known-test-failures-blocks-a-deployment-with-tests).

Equivalent CLI command (run from `salesforce/`):

```powershell
sf project deploy start --target-org nfinity-uat --source-dir force-app --test-level RunSpecifiedTests --tests NFY_CommandCenter_Test --tests NFY_Demo_Test --tests NFY_OrderJourney_Test --tests NFY_Origin_Test --tests NFY_PaymentStatus_Test --tests NFY_Payment_Test --tests NFY_ProductSync_Test --tests NFY_Release_Test --tests NFY_ShipStationOrderApi_Test --tests NFY_ShipStation_Test --tests NFY_Stock_Test --wait 60
```

## 5. Environment-specific values in Salesforce

1. Edit [config/seed](../config/seed) for the environment (`Environment__c`; `Workato_Recipe_Id__c` once the recipes exist in the target workspace), then:
   ```powershell
   ./scripts/load-config-data.ps1 -OrgAlias nfinity-uat
   ```
2. Set `TC_Warehouse__c.NFY_Code__c`, `NFY_System__c` and the other NFY fields as in [config/warehouse-mapping.csv](../config/warehouse-mapping.csv).
3. Setup > Custom Metadata Types > NFY Source Link > `Odoo`: set the URL template to the new Odoo host.
4. Check the picklist value `Odoo` is active on `Order.NFY_Channel__c`, `TC_Sales_Order__c.NFY_Channel__c`, `TC_Billing__c.NFY_Channel__c` (deployed with the package).

## 6. Configure Odoo, Workato and ShipStation connections

| System | Steps |
|---|---|
| Odoo | Build the configuration in [odoo/README.md](../odoo/README.md) steps 1 to 6. Leave the automations **inactive** until step 9. |
| Workato | Create the four connections in [workato/README.md](../workato/README.md#connections). Salesforce connection: sign in as the integration user from step 3. |
| ShipStation | API key and secret into the Workato "ShipStation API" connection. Ship-from location for Main. See [shipstation/README.md](../shipstation/README.md). |

## 7. Import or recreate the Workato recipes

- With exports: import the package from [workato/exports](../workato/exports) into the target project and map each
  connection to the ones created in step 6.
- Without exports: rebuild each recipe from the step outlines in [workato/README.md](../workato/README.md) and the
  payload definitions in [docs/flows](flows). Recipe ids change in a new workspace.

## 8. Update mappings and credentials

| Value | Where |
|---|---|
| Workato webhook URL for each `odoo_*` event | Each Odoo webhook server action |
| Webhook URL of 408639 | Forward step of 411457 |
| Odoo `/web/hook/...` URL of the close-delivery automation | 412422 step "Tell Odoo the order shipped (close delivery)" |
| Webhook URL of 412422 (`shipstation_notify`) | ShipStation webhooks On Orders Shipped and On Fulfillment Shipped |
| New recipe ids | `NFY_Integration_Flow__c.Workato_Recipe_Id__c` |
| Odoo action ids | Resend action and snapshot cron code (see [odoo/README.md](../odoo/README.md#ids-that-must-be-patched-after-creation)) |
| Location codes | Odoo `stock.location.x_nfy_sf_code` / `x_nfy_shipstation` |

## 9. Activate the integrations

Order matters: receivers first, senders last.

1. Salesforce flow records active (already, from the seed).
2. Workato: 411534 (function), then 408639, 411537, 411572, 411490, 417679, 420219, 420315, 412419, 412422, then 411457.
   Leave 419546 stopped unless Salesforce-driven ShipStation release is approved.
3. ShipStation webhooks on.
4. Odoo automations active; scheduled action active.

## 10. Verify the complete automation flow

Run each flow once with a test product and test customer:

| Check | Expected result in Salesforce |
|---|---|
| Create a product with a SKU in Odoo | Product2 created; Sync Log `product.upsert` Success |
| Validate a vendor receipt into Main | Sync Log `stock.adjusted`; TC inventory balance increased |
| Confirm an order with Ship From = MAIN | Order + TC Sales Order allocated; ShipStation order `ODOO-<SO>` awaiting shipment |
| Mark it shipped in ShipStation | TC Shipment and posted billing; Odoo delivery Done |
| Confirm an order from SM-PA1, validate the delivery with carrier and tracking | TC Shipment from PA1; billing posted |
| Register a customer payment in Odoo with the order number in the memo | Cash receipt applied; Order Paid |
| Transfer to transit with a Final Destination, receive it | Inbound shipment In Transit, then Closed |
| Command Center | No open failures; each system Healthy |

Rollback: deactivate the Odoo automations first (stops new events), then stop the Workato recipes. Failed events stay
in `NFY_Sync_Log__c` and can be retried after a fix.
