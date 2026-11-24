# Odoo computed field stock.picking.x_nfy_shipstation_payload
# Settings > Technical > Fields. Dependencies: name,state,sale_id,partner_id,location_id,location_id.x_nfy_sf_code,location_id.x_nfy_shipstation,move_ids.product_uom_qty,move_ids.quantity,move_ids.state
for rec in self:
    wh = False
    walk = rec.location_id
    while walk and not wh:
        if walk.x_nfy_sf_code:
            wh = walk
        walk = walk.location_id
    eligible = rec.picking_type_code == 'outgoing' and rec.sale_id and wh and wh.x_nfy_shipstation
    if not eligible:
        rec['x_nfy_shipstation_payload'] = False
        continue
    p = rec.partner_id
    addr = {
        'name': p.name or '',
        'company': (p.parent_id.name if p.parent_id else '') or '',
        'street1': p.street or '',
        'street2': p.street2 or '',
        'city': p.city or '',
        'state': p.state_id.code or '',
        'postalCode': p.zip or '',
        'country': p.country_id.code or 'US',
        'phone': p.phone or '',
        'residential': True,
    }
    so = rec.sale_id
    rec['x_nfy_shipstation_payload'] = {
        'orderNumber': 'ODOO-' + (so.name or ''),
        'orderKey': 'ODOO-' + (rec.name or '').replace('/', '-'),
        'orderDate': (so.date_order or datetime.datetime.now()).strftime('%Y-%m-%dT%H:%M:%S'),
        'orderStatus': 'awaiting_shipment',
        'customerUsername': p.email or p.name or '',
        'customerEmail': p.email or '',
        'billTo': addr,
        'shipTo': addr,
        'amountPaid': so.amount_total,
        # Only what Odoo has reserved is sent, so ShipStation never ships more than is in stock. When more is
        # reserved later, automation 8 resends and ShipStation updates the same order (same orderKey).
        'items': [
            {'lineItemKey': str(m.id), 'sku': m.product_id.default_code or '', 'name': m.product_id.name or '',
             'quantity': int(m.quantity), 'unitPrice': (m.sale_line_id.price_reduce_taxexcl if m.sale_line_id else m.product_id.lst_price)}
            for m in rec.move_ids if m.state != 'cancel' and m.quantity > 0
        ],
        'advancedOptions': {'customField1': wh.x_nfy_sf_code, 'customField2': str(rec.id), 'source': 'Odoo',
                            'customField3': ('Partly reserved: ' + ', '.join('%s %d of %d' % (m.product_id.default_code or m.product_id.name, int(m.quantity), int(m.product_uom_qty)) for m in rec.move_ids if m.state != 'cancel' and m.quantity < m.product_uom_qty)) if any(m.state != 'cancel' and m.quantity < m.product_uom_qty for m in rec.move_ids) else 'Fully reserved'},
    }
