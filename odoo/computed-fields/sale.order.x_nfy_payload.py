# Odoo computed field sale.order.x_nfy_payload
# Settings > Technical > Fields. Dependencies: name,state,date_order,amount_tax,x_nfy_ship_from,partner_id,order_line,order_line.product_uom_qty,order_line.price_unit,order_line.discount
for record in self:
    p = record.partner_id
    record['x_nfy_payload'] = {
        'id': record.id,
        'name': record.name,
        'state': record.state,
        'date_order': record.date_order and record.date_order.strftime('%Y-%m-%d') or False,
        'warehouse_code': record.x_nfy_ship_from or 'MAIN',
        'amount_tax': record.amount_tax,
        'freight': 0,
        'partner': {
            'id': p.id,
            'name': p.name,
            'email': p.email or '',
            'phone': p.phone or '',
            'city': p.city or '',
            'state': p.state_id.code or '',
            'country': p.country_id.code or '',
        },
        'order_line': [
            {'default_code': l.product_id.default_code, 'product_uom_qty': l.product_uom_qty, 'price_unit': l.price_reduce_taxexcl}
            for l in record.order_line if not l.display_type and l.product_id
        ],
    }
