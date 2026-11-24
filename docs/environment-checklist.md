# Environment configuration checklist

Copy this list per environment (Dev, UAT, Production). Values go in `config/environment.local.env` (git-ignored) or
in the system itself. Secrets are entered only in the system that uses them.

## Salesforce

- [ ] Org alias connected with `sf org login web`
- [ ] TC Accounting installed; `scripts/check-prerequisites.ps1` passes
- [ ] TC default ledger and GL Account Defaults configured
- [ ] `TC_Warehouse__c` records with `NFY_Code__c` MAIN, SM-PA1, SM-NV3, FBA-US and their locations
- [ ] Package validated, then deployed (`scripts/deploy-salesforce.ps1`)
- [ ] Integration user created; `NFY_Demo_User` and TC permissions assigned
- [ ] Ops users assigned `NFY_Demo_User` (alerts) or `NFY_Integration_Tracking`
- [ ] Systems and flows loaded (`scripts/load-config-data.ps1`), environment and recipe ids updated
- [ ] `TC_Warehouse__c.NFY_System__c` linked (MAIN to SHIPSTATION, SM-* to SHIPMONK, FBA-US to AMAZON)
- [ ] `NFY_Source_Link.Odoo` URL template points to this environment's Odoo host

## Odoo

- [ ] Apps: Sales, Inventory, Purchase, Invoicing; Storage Locations on
- [ ] 16 custom fields ([odoo/fields.csv](../odoo/fields.csv)) and 4 view extensions
- [ ] Location codes and ShipStation flag set ([config/warehouse-mapping.csv](../config/warehouse-mapping.csv)); Inter-warehouse transit active
- [ ] Server actions created; webhook URLs point to this environment's Workato workspace
- [ ] Action ids patched in the resend action and the snapshot cron
- [ ] 14 automations ([odoo/automations.csv](../odoo/automations.csv)) and the daily scheduled action
- [ ] Products carry Internal Reference = Salesforce SKU; Track Inventory on for stocked products

## Workato

- [ ] Project created; recipes imported or rebuilt
- [ ] Connection Salesforce (integration user, OAuth)
- [ ] Connection ShipStation API (Basic: API key / secret, base `https://ssapi.shipstation.com`)
- [ ] Connection Odoo Webhook (base = Odoo host)
- [ ] Connection Workato Webhook Forwarder (411457 forward URL = 408639 webhook)
- [ ] 412422 close-delivery step URL = Odoo on_webhook automation path
- [ ] Recipes started in the order in the deployment guide; 419546 stopped unless approved

## ShipStation

- [ ] API key and secret generated (entered only in Workato)
- [ ] Ship-from location for Nfinity Main
- [ ] Webhooks On Orders Shipped and On Fulfillment Shipped to the 412422 webhook URL

## Verification

- [ ] All checks in [deployment-guide.md step 10](deployment-guide.md#10-verify-the-complete-automation-flow) pass
- [ ] Command Center shows no open failures
