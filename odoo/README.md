# Odoo configuration

Odoo is configured in the UI (Settings > Technical, developer mode). Nothing here is deployed by a tool: these files
are the reference for rebuilding the same configuration in another Odoo database.

Version in use: Odoo 20.0+e (Odoo Online). Company currency USD.

## Prerequisites

- Apps installed: Sales (`sale_management`), Inventory (`stock`, `sale_stock`), Purchase (`purchase`, `purchase_stock`), Invoicing / Accounting.
- Not installed and not needed: `delivery`, `stock_delivery` (carrier and tracking are custom fields here).
- Inventory settings: Storage Locations on.
- Products: Internal Reference (`default_code`) = Salesforce SKU; type Goods; Track Inventory on for stock sync.

## What to build, in order

| Step | What | Reference |
|---|---|---|
| 1 | Custom fields (stored first, then computed) | [fields.csv](fields.csv), [computed-fields/](computed-fields) |
| 2 | Form view extensions | [views/](views) |
| 3 | Locations: set `x_nfy_sf_code` and `x_nfy_shipstation`; activate "Inter-warehouse transit" | [../config/warehouse-mapping.csv](../config/warehouse-mapping.csv) |
| 4 | Server actions: Python code actions and one webhook action per automation | [server-actions/](server-actions), [automations.csv](automations.csv) |
| 5 | Automation rules | [automations.csv](automations.csv) |
| 6 | Scheduled action "NFY: Daily payment reconciliation snapshot" | below |
| 7 | Copy the URL of the on_webhook automation into Workato recipe 412422 | [../workato/README.md](../workato/README.md) |

### Webhook URLs

Each webhook server action posts to `<WORKATO_WEBHOOK_BASE>/<event>`, where `<WORKATO_WEBHOOK_BASE>` is the Workato
workspace webhook address (`https://webhooks.trial.workato.com/webhooks/rest/<workspace id>` on the trial workspace)
and `<event>` is the `webhook_event` column of [automations.csv](automations.csv). The workspace id is not stored in
this repository; take it from Workato (any recipe's webhook trigger shows it).

In Odoo 20 a server action belongs to one automation, so automations that post to the same event each have their own
webhook action.

### Ids that must be patched after creation

| Where | What to put |
|---|---|
| `server-actions/resend_shipstation_order_on_reservation_change.py` | The id of the webhook action "POST delivery to Workato for ShipStation" |
| Scheduled action code | The id of the webhook action "POST payment snapshot to Workato" |
| Workato 412422, step "Tell Odoo the order shipped (close delivery)" | The `/web/hook/<uuid>` URL Odoo shows on the on_webhook automation |

### Scheduled action

- Name: `NFY: Daily payment reconciliation snapshot`, model `res.company`, every 1 day at 02:00 UTC.
- Code (replace the id):

```python
env['ir.actions.server'].browse(<ID OF "POST payment snapshot to Workato">).with_context(active_model='res.company', active_id=env.company.id, active_ids=env.company.ids).run()
```

- The webhook action "POST payment snapshot to Workato" (model `res.company`, field `x_nfy_payment_payload`,
  event `odoo_payment_snapshot`) has no automation; only this scheduled action runs it.

## Current environment (reference only)

Database `twopir-consulting-trial.odoo.com`, rebuilt 20 Nov 2026. Automation ids 1 to 14, scheduled action 73.
Locations: NFM/Stock = `MAIN` (ShipStation), NFM/ShipMonk PA1 = `SM-PA1`, NFM/Stock/ShipMonk NV3 = `SM-NV3`,
NFM/Amazon FBA = `FBA-US`, Inter-warehouse transit active. Ids differ in any new database.

## Source and accuracy

The code files were reconstructed from the change history of the original database and used to rebuild the current
one. The current database passed the 23 Nov 2026 end-to-end test, but the code was not exported back from it line by
line. Before relying on these files for a new environment, compare them with the live records
(Settings > Technical > Fields / Server Actions).

Known open points:
- The order form view inherit id was never read back (assumed `sale.view_order_form`).
- The delivery form shows carrier and tracking only on outgoing transfers, although inbound flows also use them.
