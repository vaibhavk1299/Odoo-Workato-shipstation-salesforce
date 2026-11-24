# Odoo computed field res.company.x_nfy_payment_payload
# Settings > Technical > Fields. Dependencies: 
for rec in self:
    to_ts = datetime.datetime.now()
    from_ts = to_ts - datetime.timedelta(days=7)
    payments = self.env['account.payment'].search([('partner_type', '=', 'customer'), ('payment_type', '=', 'inbound'), ('company_id', '=', rec.id), ('write_date', '>=', from_ts)], limit=500, order='id')
    rows = []
    for pay in payments:
        rows.append(pay.x_nfy_payment_payload)
    rec['x_nfy_payment_payload'] = {
        'event': 'payment.snapshot',
        'snapshotId': 'ODOO-PAYSNAP-' + to_ts.strftime('%Y%m%d%H%M%S'),
        'from': from_ts.strftime('%Y-%m-%d %H:%M:%S'),
        'to': to_ts.strftime('%Y-%m-%d %H:%M:%S'),
        'externalIdPrefix': 'ODOO-PAY-',
        'payments': rows,
    }
