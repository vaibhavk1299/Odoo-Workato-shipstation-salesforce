/**
 * Read-only endpoint the "[SFDC to ShipStation] - Released Orders" Workato recipe calls for each fulfilment
 * instruction (NFY_Integration_Event__e, Severity__c = Release or Cancel):
 *
 *   GET /services/apexrest/nfinity/v1/shipstation/order/{orderId or channel order number}?kind=Release|Cancel
 *
 * Returns { send, reason, orderNumber, warnings, payload } where payload is the ShipStation v1 createorder body.
 * Workato posts the payload only when send is true. All decisions are made here from Salesforce data:
 *   - the order must have a TC sales order in the right state (fully assigned for Release, Cancelled for Cancel);
 *   - only lines assigned at warehouses operated by ShipStation (TC_Warehouse__c.NFY_System__c) are sent;
 *   - an order whose source system already reaches ShipStation through another active "System to system" order
 *     flow (for example "[Odoo to ShipStation] - Orders") is skipped, so the two never overwrite each other.
 *     Deactivating that flow record at cutover hands those orders to Salesforce, with no code change.
 * orderKey = orderNumber = the channel order number, so a resend updates the ShipStation order instead of adding one.
 */
@RestResource(urlMapping='/nfinity/v1/shipstation/order/*')
global with sharing class NFY_ShipStationOrderApi {

    public static final String SHIPSTATION = 'SHIPSTATION';

    global class Reply {
        public Boolean send = false;
        public String reason;
        public String orderNumber;
        public String orderId;
        public List<String> warnings = new List<String>();
        public Map<String, Object> payload;
        /** The same body as a JSON string, so Workato can post it unchanged without a schema for every nested field. */
        public String payloadJson;
    }

    @HttpGet
    global static void get() {
        RestRequest req = RestContext.request;
        RestResponse res = RestContext.response;
        res.addHeader('Content-Type', 'application/json');
        String ref = EncodingUtil.urlDecode(req.requestURI.substringAfterLast('/'), 'UTF-8');
        String kind = req.params.get('kind');
        Reply r = build(ref, String.isBlank(kind) ? NFY_IntegrationService.RELEASE : kind);
        res.statusCode = r.orderId == null ? 404 : 200;
        res.responseBody = Blob.valueOf(JSON.serialize(r));
    }

    public static Reply build(String ref, String kind) {
        Reply r = new Reply();
        Id asId = null;
        try {
            asId = String.isBlank(ref) ? null : Id.valueOf(ref);
        } catch (Exception e) {
            asId = null;
        }
        List<Order> found = [
            SELECT Id, OrderNumber, EffectiveDate, NFY_External_Order_Id__c, NFY_Source_System__c, NFY_Channel__c, Shipping__c,
                ShippingStreet, ShippingCity, ShippingState, ShippingPostalCode, ShippingCountry,
                Account.Name, Account.Phone, Account.ShippingStreet, Account.ShippingCity, Account.ShippingState, Account.ShippingPostalCode, Account.ShippingCountry,
                ShipToContact.Name, ShipToContact.Email, ShipToContact.Phone, ShipToContact.MailingStreet, ShipToContact.MailingCity,
                ShipToContact.MailingState, ShipToContact.MailingPostalCode, ShipToContact.MailingCountry,
                BillToContact.Email,
                NFY_TC_Sales_Order__c, NFY_TC_Sales_Order__r.Name, NFY_TC_Sales_Order__r.Status__c, NFY_TC_Sales_Order__r.NFY_Fulfillment_Status__c
            FROM Order
            WHERE (Id = :asId) OR (NFY_External_Order_Id__c != null AND NFY_External_Order_Id__c = :ref)
            LIMIT 1
        ];
        if (found.isEmpty()) {
            r.reason = 'No Salesforce order matches ' + ref + '.';
            return r;
        }
        Order o = found[0];
        r.orderId = o.Id;
        r.orderNumber = String.isBlank(o.NFY_External_Order_Id__c) ? o.OrderNumber : o.NFY_External_Order_Id__c;
        Boolean cancel = kind == NFY_IntegrationService.CANCEL;

        if (o.NFY_TC_Sales_Order__c == null) {
            r.reason = r.orderNumber + ' has no TC sales order yet.';
            return r;
        }
        String state = o.NFY_TC_Sales_Order__r.NFY_Fulfillment_Status__c;
        if (!cancel && state != 'Awaiting Shipment') {
            r.reason = r.orderNumber + ' is ' + state + ', not ready to ship.';
            return r;
        }
        if (cancel && o.NFY_TC_Sales_Order__r.Status__c != 'Cancelled') {
            r.reason = r.orderNumber + ' is not cancelled in Salesforce.';
            return r;
        }

        String other = otherSender(o.NFY_Source_System__c);
        if (other != null) {
            r.reason = r.orderNumber + ' reaches ShipStation through ' + other + '; Salesforce does not send it.';
            return r;
        }

        // Lines to ship from ShipStation-operated warehouses. For a cancellation the assignments are already gone,
        // so every stocked line at those warehouses is listed with its ordered quantity.
        List<Map<String, Object>> items = new List<Map<String, Object>>();
        Set<String> shipFrom = new Set<String>();
        Set<String> elsewhere = new Set<String>();
        for (TC_Sales_Order_Line__c l : [
            SELECT Id, Product__r.ProductCode, Product__r.Name, Quantity_Ordered__c, Quantity_Allocated__c, Quantity_Shipped__c, Unit_Price__c,
                NFY_Ship_From__r.Name, NFY_Ship_From__r.NFY_Code__c, NFY_Ship_From__r.NFY_System__r.Code__c
            FROM TC_Sales_Order_Line__c
            WHERE Sales_Order__c = :o.NFY_TC_Sales_Order__c AND Product__r.TC_Inventory_Product__c = true
            ORDER BY Name
        ]) {
            if (l.NFY_Ship_From__r == null || l.NFY_Ship_From__r.NFY_System__r == null || l.NFY_Ship_From__r.NFY_System__r.Code__c != SHIPSTATION) {
                if (l.NFY_Ship_From__r != null) {
                    elsewhere.add(l.NFY_Ship_From__r.Name);
                }
                continue;
            }
            Decimal qty = cancel ? nz(l.Quantity_Ordered__c) : nz(l.Quantity_Allocated__c) - nz(l.Quantity_Shipped__c);
            if (qty <= 0) {
                continue;
            }
            shipFrom.add(l.NFY_Ship_From__r.NFY_Code__c);
            items.add(new Map<String, Object>{
                'lineItemKey' => String.valueOf(l.Id),
                'sku' => l.Product__r.ProductCode,
                'name' => l.Product__r.Name,
                'quantity' => qty.intValue(),
                'unitPrice' => nz(l.Unit_Price__c)
            });
        }
        if (items.isEmpty()) {
            r.reason = r.orderNumber + ' has nothing to ship from a ShipStation warehouse'
                + (elsewhere.isEmpty() ? '.' : ' (ships from ' + String.join(new List<String>(elsewhere), ', ') + ').');
            return r;
        }
        if (!elsewhere.isEmpty()) {
            r.warnings.add('Lines shipping from ' + String.join(new List<String>(elsewhere), ', ') + ' are not sent to ShipStation.');
        }

        Map<String, Object> address = address(o, r.warnings);
        r.payload = new Map<String, Object>{
            'orderNumber' => r.orderNumber,
            'orderKey' => r.orderNumber,
            'orderDate' => o.EffectiveDate == null ? null : String.valueOf(o.EffectiveDate) + 'T00:00:00.0000000',
            'orderStatus' => cancel ? 'cancelled' : 'awaiting_shipment',
            'customerUsername' => o.ShipToContact.Email != null ? o.ShipToContact.Email : o.BillToContact.Email,
            'customerEmail' => o.ShipToContact.Email != null ? o.ShipToContact.Email : o.BillToContact.Email,
            'billTo' => address,
            'shipTo' => address,
            'items' => items,
            'shippingAmount' => nz(o.Shipping__c),
            'advancedOptions' => new Map<String, Object>{
                'customField1' => 'SF ' + o.OrderNumber,
                'customField2' => o.NFY_TC_Sales_Order__r.Name,
                'customField3' => cancel ? 'Cancelled in Salesforce' : 'Fully reserved',
                'source' => 'Salesforce'
            }
        };
        r.payloadJson = JSON.serialize(compact(r.payload));
        r.send = true;
        r.reason = r.orderNumber + (cancel ? ' cancellation' : ' release') + ': ' + items.size() + ' line(s) from ' + String.join(new List<String>(shipFrom), ', ') + '.';
        return r;
    }

    /**
     * The active "System to system" order flow that already delivers this source's orders to ShipStation, or null.
     * Flow names follow "[Source to ShipStation] - …"; the source is the Order's NFY_Source_System__c value.
     */
    @TestVisible
    private static String otherSender(String sourceSystem) {
        if (String.isBlank(sourceSystem)) {
            return null;
        }
        String prefix = '[' + sourceSystem + ' to ';
        for (NFY_Integration_Flow__c f : [
            SELECT Name, Workato_Recipe_Id__c FROM NFY_Integration_Flow__c
            WHERE Active__c = true AND System__r.Code__c = :SHIPSTATION AND Direction__c = 'System to system' AND Entity__c = 'Order'
        ]) {
            if (f.Name != null && f.Name.startsWithIgnoreCase(prefix)) {
                return '"' + f.Name + '"' + (String.isBlank(f.Workato_Recipe_Id__c) ? '' : ' (recipe ' + f.Workato_Recipe_Id__c + ')');
            }
        }
        return null;
    }

    /** Best address on file: the Order's shipping address, then the ship-to contact, then the account. */
    private static Map<String, Object> address(Order o, List<String> warnings) {
        String street = o.ShippingStreet, city = o.ShippingCity, state = o.ShippingState, zip = o.ShippingPostalCode, country = o.ShippingCountry;
        if (String.isBlank(street) && String.isBlank(city) && o.ShipToContact != null) {
            street = o.ShipToContact.MailingStreet; city = o.ShipToContact.MailingCity; state = o.ShipToContact.MailingState;
            zip = o.ShipToContact.MailingPostalCode; country = o.ShipToContact.MailingCountry;
        }
        if (String.isBlank(street) && String.isBlank(city) && o.Account != null) {
            street = o.Account.ShippingStreet; city = o.Account.ShippingCity; state = o.Account.ShippingState;
            zip = o.Account.ShippingPostalCode; country = o.Account.ShippingCountry;
        }
        if (String.isBlank(street) || String.isBlank(zip)) {
            warnings.add('Ship-to address has no ' + (String.isBlank(street) ? 'street' : 'postal code') + '; ShipStation will hold the order for address review.');
        }
        if (String.isNotBlank(country) && country.trim().length() != 2) {
            warnings.add('Country "' + country + '" is not a 2-letter code and was left out.');
            country = null;
        }
        String phone = o.ShipToContact != null && o.ShipToContact.Phone != null ? o.ShipToContact.Phone : (o.Account == null ? null : o.Account.Phone);
        List<String> lines = String.isBlank(street) ? new List<String>() : street.split('\n');
        return new Map<String, Object>{
            'name' => o.ShipToContact != null && o.ShipToContact.Name != null ? o.ShipToContact.Name : (o.Account == null ? r(o) : o.Account.Name),
            'company' => o.Account == null ? null : o.Account.Name,
            'street1' => lines.size() > 0 ? lines[0].trim() : null,
            'street2' => lines.size() > 1 ? lines[1].trim() : null,
            'city' => city,
            'state' => state,
            'postalCode' => zip,
            'country' => country == null ? null : country.trim().toUpperCase(),
            'phone' => phone
        };
    }

    /** Drops blank values at every level, so ShipStation keeps what it already has instead of receiving nulls. */
    @TestVisible
    private static Object compact(Object value) {
        if (value instanceof Map<String, Object>) {
            Map<String, Object> out = new Map<String, Object>();
            Map<String, Object> m = (Map<String, Object>) value;
            for (String k : m.keySet()) {
                Object v = compact(m.get(k));
                if (v != null) {
                    out.put(k, v);
                }
            }
            return out;
        }
        if (value instanceof List<Object>) {
            List<Object> out = new List<Object>();
            for (Object v : (List<Object>) value) {
                out.add(compact(v));
            }
            return out;
        }
        if (value instanceof String && String.isBlank((String) value)) {
            return null;
        }
        return value;
    }

    private static String r(Order o) {
        return o.OrderNumber;
    }

    private static Decimal nz(Decimal d) {
        return d == null ? 0 : d;
    }
}