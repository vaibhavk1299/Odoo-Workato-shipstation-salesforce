# Odoo server action (Python code): close delivery shipped in shipstation
# ShipStation shipped an order (Workato forwards ShipStation's SHIP_NOTIFY / FULFILLMENT_SHIPPED body).
# Close the matching Odoo delivery at a ShipStation warehouse: carrier, tracking, validate. Each delivery is
# its own ShipStation order (orderKey ODOO-<delivery name with - for />), so the key finds the exact
# delivery; without a key, the order number is used only when it matches one open delivery. A partly
# shipped delivery keeps the rest as a backorder. Shipments for orders that are not Odoo's are ignored.
CARRIERS = {'ups': 'UPS', 'ups_walleted': 'UPS', 'usps': 'USPS', 'stamps_com': 'USPS', 'fedex': 'FedEx',
            'fedex_walleted': 'FedEx', 'dhl_ecommerce': 'DHL eCommerce', 'ontrac': 'OnTrac', 'amazon_shipping': 'Amazon Logistics'}
body = payload or {}
items = body.get('shipments') or body.get('fulfillments') or []
Picking = env['stock.picking'].with_context(nfy_shipstation_shipped=True, skip_sms=True, skip_backorder=True)
open_at_shipstation = [('picking_type_code', '=', 'outgoing'), ('state', '=', 'assigned'), ('location_id.x_nfy_shipstation', '=', True)]
closed = []
skipped = []
for s in items:
    num = s.get('orderNumber') or ''
    key = s.get('orderKey') or ''
    picks = Picking.browse()
    if not s.get('voided'):
        if key.startswith('ODOO-'):
            picks = Picking.search([('name', '=', key[5:].replace('-', '/'))] + open_at_shipstation)
        elif num.startswith('ODOO-'):
            picks = Picking.search([('origin', '=', num[5:])] + open_at_shipstation)
            if len(picks) > 1:
                picks = Picking.browse()
    if not picks:
        skipped.append(key or num or '?')
    for p in picks:
        p.write({'x_nfy_carrier': CARRIERS.get((s.get('carrierCode') or '').lower(), False),
                 'x_nfy_tracking': s.get('trackingNumber') or False})
        p.move_ids.filtered(lambda m: m.state not in ('done', 'cancel')).write({'picked': True})
        p.button_validate()
        closed.append(p.name + ' (' + num + ')')
log('ShipStation shipped. Closed: ' + (', '.join(closed) or 'none') + '. Skipped: ' + (', '.join(skipped) or 'none'))
