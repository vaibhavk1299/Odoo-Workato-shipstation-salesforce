/**
 * shipstation.notify: one ShipStation webhook (SHIP_NOTIFY or FULFILLMENT_SHIPPED), forwarded by Workato
 * with the resource it points to:
 *
 *   { resourceType: "SHIP_NOTIFY" | "FULFILLMENT_SHIPPED", body: "<JSON returned by the resource_url>", jobId }
 *
 * SHIP_NOTIFY bodies hold label shipments ({"shipments":[…]} with shipmentItems); FULFILLMENT_SHIPPED bodies hold
 * orders marked as shipped without a ShipStation label ({"fulfillments":[…]}). Each one becomes a shipment.created
 * event of its own, so it is logged, deduplicated (by SS-<shipmentId> / SS-F-<fulfillmentId>) and retried on its own.
 *
 * Nothing is hardcoded per warehouse: the ship-from warehouse is the one where the order's open, allocated
 * lines sit in Salesforce. The ShipStation order number is the Salesforce external order number
 * (ODOO-S00024), or, for orders ShipStation imported from Shopify, SHOPIFY-<Shopify order number>.
 */
public without sharing class NFY_ShipStationService {
    public class ShipStationException extends Exception {}

    public class Outcome {
        public String message;
        public Integer created = 0;
        public Integer skipped = 0;
        public Integer failed = 0;
    }

    private static final Map<String, String> CARRIER_NAME = new Map<String, String>{
        'ups' => 'UPS', 'ups_walleted' => 'UPS', 'fedex' => 'FedEx', 'fedex_walleted' => 'FedEx', 'usps' => 'USPS', 'stamps_com' => 'USPS',
        'endicia' => 'USPS', 'dhl_express' => 'DHL Express', 'dhl_global_mail' => 'DHL eCommerce', 'dhl_ecommerce' => 'DHL eCommerce',
        'ontrac' => 'OnTrac', 'amazon_shipping' => 'Amazon Logistics'
    };

    public static Outcome notify(String source, Map<String, Object> p) {
        String type = p.get('resourceType') == null ? '' : String.valueOf(p.get('resourceType')).toUpperCase();
        Object raw = p.get('body');
        if (raw == null || String.isBlank(String.valueOf(raw))) {
            throw new ShipStationException('The ShipStation notification has no body. Workato must send the response of the resource_url.');
        }
        Map<String, Object> body;
        try {
            body = raw instanceof Map<String, Object> ? (Map<String, Object>) raw : (Map<String, Object>) JSON.deserializeUntyped(String.valueOf(raw));
        } catch (Exception e) {
            throw new ShipStationException('The ShipStation response is not valid JSON.');
        }
        String jobId = p.get('jobId') == null ? null : String.valueOf(p.get('jobId'));
        List<Object> items;
        Boolean labels;
        if (type == 'SHIP_NOTIFY' || type == 'ITEM_SHIP_NOTIFY') {
            items = (List<Object>) body.get('shipments');
            labels = true;
        } else if (type == 'FULFILLMENT_SHIPPED') {
            items = (List<Object>) body.get('fulfillments');
            labels = false;
        } else {
            throw new ShipStationException('Unsupported ShipStation event "' + type + '". Subscribe SHIP_NOTIFY and FULFILLMENT_SHIPPED only.');
        }
        Outcome o = new Outcome();
        List<String> notes = new List<String>();
        for (Object it : items == null ? new List<Object>() : items) {
            Map<String, Object> s = (Map<String, Object>) it;
            if (s.get('voided') == true) {
                o.skipped++;
                notes.add(str(s.get('orderNumber')) + ' voided, skipped');
                continue;
            }
            Map<String, Object> ev;
            try {
                ev = toShipmentEvent(s, labels);
            } catch (ShipStationException e) {
                o.failed++;
                notes.add(str(s.get('orderNumber')) + ': ' + e.getMessage());
                continue;
            }
            if (ev == null) {
                o.skipped++;
                notes.add(str(s.get('orderNumber')) + ' has no Salesforce order, skipped');
                continue;
            }
            NFY_IntegrationService.Result r = NFY_IntegrationService.process('shipment.created', source, JSON.serialize(ev), jobId, 'Workato');
            if (r.status == 'Success') {
                o.created++;
            } else if (r.status == 'Duplicate skipped') {
                o.skipped++;
            } else {
                o.failed++;
            }
            notes.add(str(ev.get('orderNumber')) + ' ' + r.status.toLowerCase() + ' (' + r.logName + ')');
        }
        o.message = type + ': ' + (items == null ? 0 : items.size()) + ' record(s); ' + o.created + ' shipped, ' + o.skipped + ' skipped, '
            + o.failed + ' failed.' + (notes.isEmpty() ? '' : ' ' + String.join(notes, '; ') + '.');
        return o;
    }

    /** One ShipStation shipment or fulfillment as a shipment.created payload; null when no Salesforce order matches. */
    @TestVisible
    private static Map<String, Object> toShipmentEvent(Map<String, Object> s, Boolean label) {
        TC_Sales_Order__c so = findOrder(str(s.get('orderNumber')));
        if (so == null) {
            return null;
        }
        List<Object> lines = new List<Object>();
        Set<String> skus = new Set<String>();
        if (s.get('shipmentItems') instanceof List<Object>) {
            for (Object x : (List<Object>) s.get('shipmentItems')) {
                Map<String, Object> li = (Map<String, Object>) x;
                if (String.isNotBlank(str(li.get('sku')))) {
                    lines.add(new Map<String, Object>{ 'sku' => str(li.get('sku')), 'qty' => li.get('quantity') });
                    skus.add(str(li.get('sku')));
                }
            }
        }
        String code = str(s.get('carrierCode'));
        String carrier = code == null ? null : (CARRIER_NAME.containsKey(code.toLowerCase()) ? CARRIER_NAME.get(code.toLowerCase()) : code.toUpperCase());
        String id = label ? 'SS-' + str(s.get('shipmentId')) : 'SS-F-' + str(s.get('fulfillmentId'));
        Map<String, Object> ev = new Map<String, Object>{
            'shipmentId' => id,
            'orderNumber' => so.NFY_External_Order_Id__c,
            'shipFrom' => shipFrom(so.Id, skus),
            'shipDate' => str(s.get('shipDate')) == null ? null : str(s.get('shipDate')).left(10),
            'carrier' => carrier,
            'tracking' => str(s.get('trackingNumber')),
            'service' => label ? str(s.get('serviceCode')) : str(s.get('fulfillmentServiceCode')),
            'labelSystem' => 'ShipStation'
        };
        if (!lines.isEmpty()) {
            ev.put('lines', lines);
        }
        return ev;
    }

    /** The Salesforce sales order for a ShipStation order number: as is (ODOO-S00024), else SHOPIFY-<number>. */
    @TestVisible
    private static TC_Sales_Order__c findOrder(String orderNumber) {
        if (String.isBlank(orderNumber)) {
            return null;
        }
        String plain = orderNumber.trim();
        Set<String> keys = new Set<String>{ plain, 'SHOPIFY-' + plain.removeStart('#') };
        for (TC_Sales_Order__c so : [SELECT Id, NFY_External_Order_Id__c FROM TC_Sales_Order__c WHERE NFY_External_Order_Id__c IN :keys ORDER BY CreatedDate DESC]) {
            return so;
        }
        return null;
    }

    /** The warehouse holding the order's open allocated units (for the shipped SKUs when known); the one with most units wins. */
    private static String shipFrom(Id salesOrderId, Set<String> skus) {
        Map<String, Decimal> open = new Map<String, Decimal>();
        for (TC_Sales_Order_Line__c l : [
            SELECT NFY_Ship_From__r.NFY_Code__c, Product__r.ProductCode, Quantity_Allocated__c, Quantity_Shipped__c
            FROM TC_Sales_Order_Line__c WHERE Sales_Order__c = :salesOrderId AND NFY_Ship_From__c != null
        ]) {
            if (!skus.isEmpty() && !skus.contains(l.Product__r.ProductCode)) {
                continue;
            }
            Decimal q = (l.Quantity_Allocated__c == null ? 0 : l.Quantity_Allocated__c) - (l.Quantity_Shipped__c == null ? 0 : l.Quantity_Shipped__c);
            String c = l.NFY_Ship_From__r.NFY_Code__c;
            open.put(c, (open.containsKey(c) ? open.get(c) : 0) + q);
        }
        String best = null;
        for (String c : open.keySet()) {
            if (best == null || open.get(c) > open.get(best)) {
                best = c;
            }
        }
        if (best == null) {
            throw new ShipStationException('Order has no warehouse with stock allocated in Salesforce, so the ShipStation shipment cannot be matched to a ship-from location.');
        }
        return best;
    }

    private static String str(Object v) {
        return v == null || String.isBlank(String.valueOf(v)) ? null : String.valueOf(v);
    }
}