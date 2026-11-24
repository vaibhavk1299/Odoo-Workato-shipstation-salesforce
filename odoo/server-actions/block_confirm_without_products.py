# Odoo server action (Python code): block confirm without products
# NFY: an order can only go to Salesforce when every line is a real product.
missing = [l.name for l in record.order_line if not l.display_type and not l.is_downpayment and not l.product_id]
products = [l for l in record.order_line if not l.display_type and l.product_id]
if missing or not products:
    detail = ("Lines without a product: " + ", ".join(missing) + ". ") if missing else "The order has no product lines. "
    raise UserError(detail + "Select each product from the list (the entry with its [code]) before confirming, so the order can sync to Salesforce.")
