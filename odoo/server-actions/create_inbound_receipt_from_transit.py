# Odoo server action (Python code): create inbound receipt from transit
# NFY: when a shipment leaves for transit, create the receipt that will bring it into its final destination
for rec in records:
    if not rec.x_nfy_final_location_id or rec.location_dest_id.usage != 'transit':
        continue
    if env['stock.picking'].search_count([('x_nfy_inbound_ref', '=', rec.name), ('location_id.usage', '=', 'transit')]):
        continue
    moves = [m for m in rec.move_ids if m.state == 'done' and m.quantity > 0]
    if not moves:
        continue
    ptype = env['stock.picking.type'].search([('code', '=', 'internal'), ('warehouse_id', '=', rec.picking_type_id.warehouse_id.id)], limit=1) or rec.picking_type_id
    receipt = env['stock.picking'].create({
        'picking_type_id': ptype.id,
        'location_id': rec.location_dest_id.id,
        'location_dest_id': rec.x_nfy_final_location_id.id,
        'origin': rec.name,
        'x_nfy_inbound_ref': rec.name,
        'x_nfy_carrier': rec.x_nfy_carrier,
        'x_nfy_tracking': rec.x_nfy_tracking,
        'move_ids': [(0, 0, {'product_id': m.product_id.id, 'product_uom_qty': m.quantity, 'uom_id': m.uom_id.id, 'location_id': rec.location_dest_id.id, 'location_dest_id': rec.x_nfy_final_location_id.id}) for m in moves],
    })
    receipt.action_confirm()
    receipt.action_assign()
    rec.message_post(body='Inbound receipt %s created for %s.' % (receipt.name, rec.x_nfy_final_location_id.display_name))
