# Odoo computed field account.payment.x_nfy_payment_payload
# Settings > Technical > Fields. Dependencies: state,amount,date,memo,name,currency_id,partner_id,journal_id,payment_method_line_id,payment_transaction_id
for rec in self:
    order = rec.payment_transaction_id.sale_order_ids[:1]
    if not order and rec.memo:
        words = rec.memo.replace(',', ' ').replace(';', ' ').replace('/', ' ').split()
        if words:
            order = self.env['sale.order'].search([('name', 'in', words)], limit=1)
    if rec.state in ('paid', 'reconciled'):
        event = 'payment.received'
    elif rec.state in ('canceled', 'rejected'):
        event = 'payment.reversed'
    else:
        event = None
    method = rec.payment_method_line_id.name or ''
    if rec.payment_transaction_id.provider_id:
        method = rec.payment_transaction_id.provider_id.name
    elif rec.journal_id:
        method = (method + ' (' + rec.journal_id.name + ')').strip()
    rec['x_nfy_payment_payload'] = {
        'event': event,
        'externalId': 'ODOO-PAY-%s' % rec.id,
        'odooPaymentId': rec.id,
        'orderNumber': ('ODOO-' + order.name) if order else None,
        'amount': rec.amount,
        'currency': rec.currency_id.name,
        'date': str(rec.date) if rec.date else None,
        'method': method,
        'reference': rec.name or None,
        'providerReference': rec.payment_transaction_id.provider_reference or None,
        'memo': rec.memo or None,
        'customer': rec.partner_id.name or None,
        'state': rec.state,
        'reason': ('Payment ' + rec.state + ' in Odoo') if event == 'payment.reversed' else None,
    }
