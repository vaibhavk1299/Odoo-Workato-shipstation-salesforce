# Odoo computed field stock.picking.x_nfy_inbound_payload
# Settings > Technical > Fields. Dependencies: state,name,origin,scheduled_date,date_done,write_date,x_nfy_tracking,x_nfy_carrier,x_nfy_inbound_ref,x_nfy_final_location_id,location_id,location_dest_id,picking_type_code,move_ids.quantity,move_ids.product_uom_qty,move_ids.state,move_ids.product_id
# NFY: inbound shipment payload for Workato [Odoo to SFDC] - Inbound (vendor receipts and in-transit transfers)
# ship    = transfer into a transit location with a Final Destination  -> IN_TRANSIT when validated
# receive = transfer out of transit carrying the shipment's Inbound Ref -> RECEIVING / RECEIVED (running totals over all receipts)
# vendor  = receipt from a supplier                                      -> WORKING / IN_TRANSIT / RECEIVED
for rec in self:
    src = rec.location_id
    dst = rec.location_dest_id
    src_wh = False
    walk = src
    while walk and not src_wh:
        src_wh = walk.x_nfy_sf_code or False
        walk = walk.location_id
    dst_wh = False
    walk = dst
    while walk and not dst_wh:
        dst_wh = walk.x_nfy_sf_code or False
        walk = walk.location_id
    fin_wh = False
    walk = rec.x_nfy_final_location_id
    while walk and not fin_wh:
        fin_wh = walk.x_nfy_sf_code or False
        walk = walk.location_id
    kind = False
    if rec.picking_type_code == 'incoming' and src.usage == 'supplier' and dst_wh:
        kind = 'vendor'
    elif dst.usage == 'transit' and rec.x_nfy_final_location_id and src_wh and fin_wh:
        kind = 'ship'
    elif src.usage == 'transit' and rec.x_nfy_inbound_ref and dst_wh:
        kind = 'receive'
    if not kind:
        rec['x_nfy_inbound_payload'] = False
        continue
    ship = rec
    from_wh = src_wh if kind == 'ship' else False
    to_wh = fin_wh if kind == 'ship' else dst_wh
    receipts = rec
    if kind == 'receive':
        ship = rec.env['stock.picking'].search([('name', '=', rec.x_nfy_inbound_ref)], limit=1)
        receipts = rec.env['stock.picking'].search([('x_nfy_inbound_ref', '=', rec.x_nfy_inbound_ref), ('location_id.usage', '=', 'transit')])
        walk = ship.location_id
        while walk and not from_wh:
            from_wh = walk.x_nfy_sf_code or False
            walk = walk.location_id
    status = False
    if kind == 'vendor':
        status = 'RECEIVED' if rec.state == 'done' else ('CANCELLED' if rec.state == 'cancel' else ('IN_TRANSIT' if rec.x_nfy_tracking else ('WORKING' if rec.state in ('waiting', 'confirmed', 'assigned') else False)))
    elif kind == 'ship':
        status = 'IN_TRANSIT' if rec.state == 'done' else ('CANCELLED' if rec.state == 'cancel' else False)
    else:
        open_left = [r for r in receipts if r.state not in ('done', 'cancel')]
        done_any = [r for r in receipts if r.state == 'done']
        status = (('RECEIVING' if open_left else 'RECEIVED') if done_any else False)
    shipped = {}
    names = {}
    src_moves = ship.move_ids if kind != 'vendor' else rec.move_ids
    for m in src_moves:
        if m.state == 'cancel' or not m.product_id.default_code:
            continue
        sku = m.product_id.default_code
        names[sku] = m.product_id.display_name
        qty = m.quantity if (kind != 'vendor' and ship.state == 'done') else m.product_uom_qty
        shipped[sku] = shipped.get(sku, 0) + qty
    received = {}
    if status in ('RECEIVING', 'RECEIVED'):
        for r in (receipts if kind == 'receive' else rec):
            if r.state != 'done':
                continue
            for m in r.move_ids:
                if m.state == 'done' and m.product_id.default_code:
                    received[m.product_id.default_code] = received.get(m.product_id.default_code, 0) + m.quantity
    if not status or not shipped:
        rec['x_nfy_inbound_payload'] = False
        continue
    lines = []
    for sku in shipped:
        line = {'sku': sku, 'name': names[sku], 'shipped': shipped[sku]}
        if status in ('RECEIVING', 'RECEIVED'):
            line['received'] = received.get(sku, 0)
        lines.append(line)
    inbound_id = 'ODOO-' + (rec.x_nfy_inbound_ref if kind == 'receive' else rec.name)
    to_type = 'Vendor receipt' if kind == 'vendor' else ('Amazon FBA inbound' if (to_wh or '').startswith('FBA') else ('3PL ASN' if (to_wh or '').startswith('SM-') else 'Stock transfer'))
    when = rec.date_done or rec.scheduled_date
    p = {
        'inboundId': inbound_id,
        'eventId': inbound_id + ':' + status + '@' + rec.name + ' ' + str(rec.write_date),
        'status': status,
        'type': to_type,
        'to': to_wh,
        'eta': rec.scheduled_date.strftime('%Y-%m-%d') if rec.scheduled_date else False,
        'date': when.strftime('%Y-%m-%d') if when else False,
        'carrier': dict(rec._fields['x_nfy_carrier'].selection).get(rec.x_nfy_carrier) if rec.x_nfy_carrier else False,
        'tracking': rec.x_nfy_tracking or ship.x_nfy_tracking or False,
        'reference': rec.name,
        'origin': rec.origin or False,
        'lines': lines,
    }
    if from_wh:
        p['from'] = from_wh
    rec['x_nfy_inbound_payload'] = p
