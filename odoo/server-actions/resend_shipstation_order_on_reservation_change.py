# Odoo server action (Python code): resend shipstation order on reservation change
# Resend a ready ShipStation delivery when Odoo reserves more (or less) of it, so the ShipStation order
# always shows what is actually reserved. Same orderKey, so ShipStation updates the order, never duplicates it.
# Not while the delivery is being closed because ShipStation shipped it: that would reopen the shipped order.
if not env.context.get('nfy_shipstation_shipped'):
    send = env['ir.actions.server'].browse(<ID OF ACTION "POST delivery to Workato for ShipStation">)
    for picking in records.mapped('picking_id'):
        if picking.state == 'assigned':
            send.with_context(active_model='stock.picking', active_id=picking.id, active_ids=[picking.id]).run()
