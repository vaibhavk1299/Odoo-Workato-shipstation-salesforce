# Odoo server action (Python code): route delivery to ship from
# Route each sales delivery to the order's Ship From location.
# If Ship From cannot cover every line and Nfinity Main can, fall back to Main,
# matching the Salesforce Integration API routing (allowFallback).
# Locations are found by their Salesforce Warehouse Code (x_nfy_sf_code), not by ID.
Location = env['stock.location']
main_loc = Location.search([('x_nfy_sf_code', '=', 'MAIN'), ('usage', '=', 'internal')], limit=1)
MAIN_ID = main_loc.id
for rec in records:
    if rec.state in ('done', 'cancel', 'assigned'):
        continue
    code = rec.sale_id.x_nfy_ship_from or 'MAIN'
    target_loc = Location.search([('x_nfy_sf_code', '=', code), ('usage', '=', 'internal')], limit=1)
    target = target_loc.id
    if not target:
        continue
    note = 'Source location set from order ship-from code %s.' % code
    if target != MAIN_ID and rec.move_ids:
        short = [m for m in rec.move_ids if m.product_id.with_context(location=target, compute_child=False).free_qty < m.product_uom_qty]
        if short:
            main_ok = all(m.product_id.with_context(location=MAIN_ID, compute_child=False).free_qty >= m.product_uom_qty for m in rec.move_ids)
            if main_ok:
                skus = ', '.join([m.product_id.default_code or m.product_id.name for m in short])
                note = 'Ship-from %s has no stock for %s; delivery falls back to Nfinity Main (MAIN), as in Salesforce routing.' % (code, skus)
                target = MAIN_ID
    if rec.location_id.id != target:
        rec.do_unreserve()
        rec.write({'location_id': target})
        rec.move_ids.write({'location_id': target})
        rec.message_post(body=note)
        rec.action_assign()
    elif target == MAIN_ID and code != 'MAIN':
        rec.message_post(body=note)
