# Odoo computed field stock.picking.x_nfy_shipment_payload
# Settings > Technical > Fields. Dependencies: name,sale_id,location_id,location_id.x_nfy_sf_code,date_done,x_nfy_carrier,x_nfy_tracking,move_ids.quantity,move_ids.state
for rec in self:
    ship_from = False
    walk = rec.location_id
    while walk and not ship_from:
        ship_from = walk.x_nfy_sf_code or False
        walk = walk.location_id
    rec['x_nfy_shipment_payload'] = {
        'shipmentId': 'ODOO-' + (rec.name or '').replace('/', '-'),
        'orderNumber': 'ODOO-' + (rec.sale_id.name or ''),
        'shipFrom': ship_from or '',
        'shipDate': (rec.date_done or datetime.datetime.now()).strftime('%Y-%m-%d'),
        'carrier': rec.x_nfy_carrier or 'Odoo Delivery',
        'tracking': rec.x_nfy_tracking or rec.name,
        'service': 'Ground',
        'labelSystem': 'Odoo',
        'lines': [
            {'sku': m.product_id.default_code, 'qty': m.quantity}
            for m in rec.move_ids if m.quantity and m.state != 'cancel'
        ],
    }
