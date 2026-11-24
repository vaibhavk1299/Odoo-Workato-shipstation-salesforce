# Odoo computed field product.template.x_nfy_product_payload
# Settings > Technical > Fields. Dependencies: name,default_code,list_price,standard_price,active,sale_ok,description_sale,categ_id,uom_id,type,is_storable,product_variant_ids,write_date
# NFY: standard product payload for Workato [Odoo to SFDC] - Products (all variants of the template, archived included)
for record in self:
    record['x_nfy_product_payload'] = {'model': 'product.template', 'template_id': record.id, 'variants': [{
            'id': v.id,
            'template_id': v.product_tmpl_id.id,
            'default_code': v.default_code or '',
            'name': v.name + ((' - ' + ', '.join(v.product_template_variant_value_ids.mapped('name'))) if v.product_template_variant_value_ids else ''),
            'description_sale': v.description_sale or '',
            'categ': '' if (v.categ_id.name or '') in ('All', 'Goods', 'Saleable') else (v.categ_id.name or ''),
            'active': bool(v.active and v.product_tmpl_id.active),
            'sale_ok': bool(v.sale_ok),
            'type': v.type or '',
            'is_storable': bool(v.is_storable),
            'uom': 'Each' if (v.uom_id.name or '') in ('Units', 'Unit', 'Unit(s)') else (v.uom_id.name or ''),
            'lst_price': v.lst_price,
            'standard_price': v.standard_price,
            'currency': v.currency_id.name or 'USD',
            'write_date': max(v.write_date, v.product_tmpl_id.write_date).strftime('%Y-%m-%d %H:%M:%S') if v.write_date and v.product_tmpl_id.write_date else '',
        } for v in record.with_context(active_test=False).product_variant_ids]}
