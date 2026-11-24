# Odoo, Workato, Salesforce and ShipStation integration (Nfinity)

Odoo runs day-to-day commerce and warehouse work. Workato carries every event. Salesforce with TC Accounting is the
system of record for orders, inventory value, shipments, billing and cash. ShipStation prints labels for the Main
warehouse.

```
Odoo  --webhooks-->  Workato  --REST /nfinity/v1/events-->  Salesforce + TC Accounting
Odoo  --webhook-->   Workato  --createorder-->  ShipStation
ShipStation --SHIP_NOTIFY--> Workato --> Salesforce, and --> Odoo (close delivery)
```

## What it does

| Flow | Direction | Workato | Salesforce event |
|---|---|---|---|
| [Products](docs/flows/01-product-sync.md) | Odoo to Salesforce | 411537, 411534 | `product.upsert` |
| [Stock](docs/flows/02-stock-sync.md) | Odoo to Salesforce | 411572 | `stock.adjusted` |
| [Sales orders](docs/flows/03-sales-order.md) | Odoo to Salesforce | 411457, 408639 | `order.upsert` |
| [Shipping](docs/flows/04-shipping.md) | Odoo to ShipStation; ShipStation to Salesforce and Odoo; Odoo to Salesforce (3PL) | 412419, 412422, 411490 | `shipstation.order.sent`, `shipstation.notify`, `shipment.created` |
| [Warehouse, transit and backorders](docs/flows/05-warehouse-backorder.md) | Odoo to Salesforce | 417679 (+ stock and order flows) | `inbound.update` |
| Payments and daily reconciliation | Odoo to Salesforce | 420219, 420315 | `payment.received` / `reversed` / `refunded`, `payment.snapshot` |

Full picture: [docs/architecture.md](docs/architecture.md). Status of every feature:
[docs/implementation-inventory.md](docs/implementation-inventory.md).

## Repository layout

```
salesforce/                 Salesforce DX project (deploy with the Salesforce CLI)
  force-app/main/default/   Apex, triggers, objects, fields, platform event, CMDT, LWC, pages, permission sets
  manifest/package.xml      Manifest of all 353 components
  sfdx-project.json
workato/                    Recipe inventory, connections, retry pattern, export instructions
  exports/                  Workato package exports (to be added)
odoo/                       Odoo fields, computed-field code, server actions, views, automations
shipstation/                ShipStation setup (API, webhooks, order keys)
config/
  environment.template.env  Per-environment values (no secrets)
  warehouse-mapping.csv     Odoo location <-> Salesforce warehouse codes
  seed/                     Integration System and Flow records
scripts/                    Prerequisite check, Salesforce deploy, config data load
docs/                       Architecture, five flow diagrams, inventories, deployment guide, checklist, gaps
```

## Quick start (new Salesforce org)

```powershell
sf org login web --alias nfinity-uat
./scripts/check-prerequisites.ps1 -OrgAlias nfinity-uat      # TC Accounting present? (read-only)
./scripts/deploy-salesforce.ps1 -OrgAlias nfinity-uat        # check-only validation with tests
./scripts/deploy-salesforce.ps1 -OrgAlias nfinity-uat -Deploy
./scripts/load-config-data.ps1 -OrgAlias nfinity-uat         # integration systems and flows
```

Then configure Odoo, Workato and ShipStation: [docs/deployment-guide.md](docs/deployment-guide.md) and
[docs/environment-checklist.md](docs/environment-checklist.md).

## What the Salesforce CLI does not deploy

- **TC Accounting**: prerequisite, installed separately.
- **Workato recipes and connections**: Workato export / import or rebuild ([workato/README.md](workato/README.md)).
- **Odoo configuration**: built in Odoo from [odoo/](odoo).
- **ShipStation settings**: [shipstation/README.md](shipstation/README.md).
- **Credentials**: entered directly in Workato and ShipStation. Nothing secret is stored in this repository.

## Documentation

| Document | Content |
|---|---|
| [docs/architecture.md](docs/architecture.md) | End-to-end architecture, event contract, keys, retry and alerts, routing, dependencies |
| [docs/flows/](docs/flows) | Five working-flow diagrams with mappings |
| [docs/implementation-inventory.md](docs/implementation-inventory.md) | Implemented and verified / not fully verified / partial / not implemented |
| [docs/salesforce-components.md](docs/salesforce-components.md) | Salesforce component inventory |
| [workato/README.md](workato/README.md) | Workato recipe inventory and connections |
| [docs/deployment-guide.md](docs/deployment-guide.md) | Ten-step deployment to another org |
| [docs/environment-checklist.md](docs/environment-checklist.md) | Per-environment checklist |
| [docs/gaps-and-risks.md](docs/gaps-and-risks.md) | Gaps, limitations, deployment risks |

## Source of truth

The Salesforce source was retrieved from the working org on 24 Nov 2026 and validated there with a check-only
deployment (353 of 353 components). Apex tests: 88 of 91 pass, 90.5% coverage; 3 known failures are listed in
[docs/gaps-and-risks.md](docs/gaps-and-risks.md). Workato recipe outlines were read from the live workspace. Odoo code was reconstructed from the build
history and matches the configuration tested end to end on 23 Nov 2026.
