/**
 * shopify.order: a Shopify orders/create webhook body, as Shopify sends it, forwarded by Workato recipe 395642.
 * It is turned into an order.upsert payload here, so the mapping lives in one place and the Integration Log
 * shows the order exactly as Salesforce processed it.
 *
 *   orderNumber  SHOPIFY-<order_number>  (the key ShipStation's Shopify store also uses, so its shipments match)
 *   customer     SHOPIFY-<customer id>, reusing an Account with the same Shopify Customer ID
 *   lines        line_items sku / quantity / price; freight from shipping_lines; tax from total_tax
 *   shopifyId    the Shopify order id, so the Opportunity the recipe already wrote is reused, never duplicated
 *
 * Nothing here throws: a missing value surfaces as a clear order.upsert failure in the Integration Log, where it can be retried.
 */
public without sharing class NFY_ShopifyOrderMapper {

    public static Map<String, Object> toOrder(Map<String, Object> o) {
        Map<String, Object> c = asMap(o.get('customer'));
        Map<String, Object> addr = asMap(o.get('shipping_address'));
        if (addr.isEmpty()) {
            addr = asMap(c.get('default_address'));
        }
        if (addr.isEmpty()) {
            addr = asMap(o.get('billing_address'));
        }
        String customerId = str(c.get('id'));
        String email = str(o.get('email')) != null ? str(o.get('email')) : str(c.get('email'));
        String name = join(str(c.get('first_name')), str(c.get('last_name')));
        if (name == null) {
            name = join(str(addr.get('first_name')), str(addr.get('last_name')));
        }
        if (name == null) {
            name = email;
        }
        Map<String, Object> customer = new Map<String, Object>{
            'externalId' => customerId != null ? 'SHOPIFY-' + customerId : (email != null ? 'SHOPIFY-' + email.toLowerCase() : null),
            'shopifyCustomerId' => customerId,
            'name' => name,
            'email' => email,
            'phone' => str(addr.get('phone')),
            'city' => str(addr.get('city')),
            'state' => str(addr.get('province')),
            'country' => str(addr.get('country_code'))
        };

        List<Object> lines = new List<Object>();
        for (Object x : asList(o.get('line_items'))) {
            Map<String, Object> li = asMap(x);
            lines.add(new Map<String, Object>{ 'sku' => str(li.get('sku')), 'qty' => li.get('quantity'), 'price' => li.get('price') });
        }
        Decimal freight = 0;
        for (Object x : asList(o.get('shipping_lines'))) {
            Object p = asMap(x).get('price');
            freight += p == null ? 0 : Decimal.valueOf(String.valueOf(p));
        }

        String created = str(o.get('created_at'));
        return new Map<String, Object>{
            'orderNumber' => o.get('order_number') == null ? null : 'SHOPIFY-' + str(o.get('order_number')),
            'channel' => 'Shopify .com',
            'orderDate' => created == null ? null : created.left(10),
            'shipFrom' => 'MAIN',
            'allowFallback' => true,
            'shopifyId' => str(o.get('id')),
            'currency' => str(o.get('currency')),
            'tax' => o.get('total_tax'),
            'freight' => freight,
            'customer' => customer,
            'shipTo' => addr.isEmpty() ? null : new Map<String, Object>{
                'name' => join(str(addr.get('first_name')), str(addr.get('last_name'))),
                'company' => str(addr.get('company')),
                'street1' => str(addr.get('address1')),
                'street2' => str(addr.get('address2')),
                'city' => str(addr.get('city')),
                'state' => str(addr.get('province_code')) != null ? str(addr.get('province_code')) : str(addr.get('province')),
                'postalCode' => str(addr.get('zip')),
                'country' => str(addr.get('country_code')),
                'phone' => str(addr.get('phone'))
            },
            'lines' => lines
        };
    }

    private static Map<String, Object> asMap(Object v) {
        return v instanceof Map<String, Object> ? (Map<String, Object>) v : new Map<String, Object>();
    }

    private static List<Object> asList(Object v) {
        return v instanceof List<Object> ? (List<Object>) v : new List<Object>();
    }

    private static String str(Object v) {
        return v == null || String.isBlank(String.valueOf(v)) ? null : String.valueOf(v);
    }

    private static String join(String a, String b) {
        String s = ((a == null ? '' : a) + ' ' + (b == null ? '' : b)).trim();
        return String.isBlank(s) ? null : s;
    }
}