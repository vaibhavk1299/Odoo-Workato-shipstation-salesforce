# Odoo computed field stock.move.x_nfy_stock_payload
# Settings > Technical > Fields. Dependencies: state,quantity,location_id,location_dest_id,product_id,price_unit,date,reference,location_id.x_nfy_sf_code,location_dest_id.x_nfy_sf_code
for rec in self:
    codes = []
    for loc in (rec.location_id, rec.location_dest_id):
        found = False
        if loc.usage == 'internal':
            walk = loc
            while walk and not found:
                found = walk.x_nfy_sf_code or False
                walk = walk.location_id
        codes.append(found)
    src = codes[0]
    dst = codes[1]
    usages = [rec.location_id.usage, rec.location_dest_id.usage]
    skip = rec.state != 'done' or not rec.product_id.is_storable or 'customer' in usages or 'transit' in usages or not (src or dst) or src == dst
    if skip:
        rec['x_nfy_stock_payload'] = False
        continue
    if 'supplier' in usages:
        reason = 'receipt'
    elif 'production' in usages:
        reason = 'production'
    elif 'inventory' in usages:
        other = rec.location_dest_id if rec.location_dest_id.usage == 'inventory' else rec.location_id
        reason = 'scrap' if 'scrap' in (other.name or '').lower() else 'adjustment'
    else:
        reason = 'transfer'
    rec['x_nfy_stock_payload'] = {
        'moveId': 'ODOO-MOVE-' + str(rec.id),
        'reference': rec.reference or rec.picking_id.name or '',
        'date': (rec.date or datetime.datetime.now()).strftime('%Y-%m-%d'),
        'reason': reason,
        'sku': rec.product_id.default_code or '',
        'qty': rec.quantity,
        'from': src or None,
        'to': dst or None,
        'unitCost': rec.price_unit or rec.product_id.standard_price,
    }
