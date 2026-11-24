/**
 * Demo simulator: builds the payloads Shopify, Amazon, ShipMonk, ShipStation, Odoo and Global-e
 * would send and pushes them through NFY_IntegrationService, the same path Workato uses.
 * Every scene button in the Nfinity app calls one of these methods. The seed history uses the
 * same builders, so seeded and live records look alike.
 */
public with sharing class NFY_SimulatorController {

    // ------------------------------------------------------------------ deterministic randomness
    private static Long seed = 20261103;
    public static void reseed(Long s) {
        seed = s;
    }
    public static Integer rand(Integer bound) {
        seed = Math.mod(seed * 1103515245L + 12345L, 2147483648L);
        return Math.mod(seed / 65536L, (Long) bound).intValue();
    }
    private static String pickStr(List<String> values) {
        return values[rand(values.size())];
    }
    private static String digits(Integer n) {
        String s = '';
        for (Integer i = 0; i < n; i++) {
            s += String.valueOf(rand(10));
        }
        return s;
    }
    private static String alnum(Integer n) {
        String chars = 'ABCDEFGHJKLMNPQRSTUVWXYZ0123456789';
        String s = '';
        for (Integer i = 0; i < n; i++) {
            Integer k = rand(chars.length());
            s += chars.substring(k, k + 1);
        }
        return s;
    }

    // ------------------------------------------------------------------ reference pools (all invented)
    private static final List<String> FIRST = new List<String>{ 'Avery', 'Brooke', 'Kaylee', 'Madison', 'Harper', 'Reagan', 'Peyton', 'Addison', 'Jordan',
        'Lauryn', 'Emery', 'Skylar', 'Tatum', 'Hadley', 'Sloane', 'Kennedy', 'Ainsley', 'Riley', 'Camryn', 'Brynlee', 'Marley', 'Delaney', 'Jada', 'Paige' };
    private static final List<String> LAST = new List<String>{ 'Whitfield', 'Okafor', 'Delgado', 'Brennan', 'Castellano', 'Pruitt', 'Haldane', 'Moreno',
        'Ashby', 'Kowalski', 'Thibodeaux', 'Nakamura', 'Ellison', 'Barrow', 'Quintero', 'Lindqvist', 'Fairbanks', 'Ruiz', 'Sutton', 'Holloway' };
    // city, state, ranked ShipMonk site for that region
    private static final List<List<String>> PLACES = new List<List<String>>{
        new List<String>{ 'Charlotte', 'NC', 'SM-PA1' }, new List<String>{ 'Columbus', 'OH', 'SM-PA1' }, new List<String>{ 'Philadelphia', 'PA', 'SM-PA1' },
        new List<String>{ 'Orlando', 'FL', 'SM-PA1' }, new List<String>{ 'Nashville', 'TN', 'SM-PA1' }, new List<String>{ 'Richmond', 'VA', 'SM-PA1' },
        new List<String>{ 'Dallas', 'TX', 'SM-NV3' }, new List<String>{ 'Phoenix', 'AZ', 'SM-NV3' }, new List<String>{ 'San Diego', 'CA', 'SM-NV3' },
        new List<String>{ 'Denver', 'CO', 'SM-NV3' }, new List<String>{ 'Salt Lake City', 'UT', 'SM-NV3' }, new List<String>{ 'Atlanta', 'GA', 'MAIN' },
        new List<String>{ 'Savannah', 'GA', 'MAIN' }, new List<String>{ 'Birmingham', 'AL', 'MAIN' } };
    private static final List<String> GYMS = new List<String>{ 'Peachtree Elite Cheer', 'Lone Star Allstars', 'Summit Spirit Athletics', 'Carolina Thunder Cheer',
        'Blue Ridge Tumbling', 'Westlake High School Cheer', 'Magnolia Prep Spirit', 'Desert Storm Allstars' };
    private static final List<String> REPS = new List<String>{ 'Jamie Calloway', 'Morgan Pierce', 'Taylor Rhodes', 'Casey Lin', 'Drew Hammond', 'Alexis Wren', 'Quinn Barlow', 'Rowan Ellis' };

    public static final List<String> SHOE_SKUS = new List<String>{ '840386208701', '840386208702', '840386208703', '840386208704', '840386211201', '840386211202',
        '840386211203', '840386215465', '840386215475', '840386215485', '840386215403', '840386215404', '840386219108', '840386219109' };
    public static final List<String> ACCESSORY_SKUS = new List<String>{ '840386230011', '840386230022', '840386230033', '840386230034', '840386230045' };

    // ------------------------------------------------------------------ payload builders

    /** Sample contact details: Twopir team inboxes and one placeholder phone number. */
    public static final List<String> EMAILS = new List<String>{ 'nikitak@twopirconsulting.com', 'harshp@twopirconsulting.com',
        'sumitk@twopirconsulting.com', 'nikhilp@twopirconsulting.com' };
    public static final String PHONE = '123457890';

    /** Same customer, same inbox: the email is picked from the external ID. */
    public static String emailFor(String externalId) {
        return EMAILS[Math.mod(Math.abs(externalId.hashCode()), EMAILS.size())];
    }

    private static Map<String, Object> withContact(Map<String, Object> c) {
        c.put('email', emailFor((String) c.get('externalId')));
        c.put('phone', PHONE);
        return c;
    }

    public static Map<String, Object> customer(String channel) {
        if (channel == 'Wholesale / Team') {
            String gym = pickStr(GYMS);
            List<String> place = PLACES[rand(PLACES.size())];
            return withContact(new Map<String, Object>{ 'externalId' => 'B2B-' + gym.replace(' ', '-').toUpperCase(), 'name' => gym, 'type' => gym.contains('School') || gym.contains('Prep') ? 'School' : 'Cheer gym / team',
                'city' => place[0], 'state' => place[1], 'country' => 'US', 'address' => place[0] + ', ' + place[1],
                'contactName' => pickStr(FIRST) + ' ' + pickStr(LAST), 'title' => gym.contains('School') || gym.contains('Prep') ? 'Cheer Coach' : 'Gym Owner' });
        }
        String first = pickStr(FIRST);
        String last = pickStr(LAST);
        List<String> place = PLACES[rand(PLACES.size())];
        String prefix = channel.startsWith('Amazon') || channel == 'Buy with Prime' ? 'AMZ-' : (channel == 'Global-e' ? 'GE-' : (channel == 'EU Webstore' ? 'EU-' : 'SHOP-'));
        Map<String, Object> c = new Map<String, Object>{ 'externalId' => prefix + (first + '.' + last).toLowerCase(), 'name' => first + ' ' + last, 'type' => prefix == 'AMZ-' ? 'Marketplace buyer' : 'Consumer',
            'city' => place[0], 'state' => place[1], 'country' => 'US', 'address' => place[0] + ', ' + place[1], 'region' => place[2] };
        if (channel == 'Global-e') {
            List<List<String>> intl = new List<List<String>>{ new List<String>{ 'Toronto', 'ON', 'CA' }, new List<String>{ 'London', '', 'GB' }, new List<String>{ 'Sydney', 'NSW', 'AU' } };
            List<String> p = intl[rand(intl.size())];
            c.putAll(new Map<String, Object>{ 'city' => p[0], 'state' => p[1], 'country' => p[2], 'address' => p[0] + ', ' + p[2] });
        }
        if (channel == 'EU Webstore') {
            List<List<String>> eu = new List<List<String>>{ new List<String>{ 'Amsterdam', 'NL' }, new List<String>{ 'Rotterdam', 'NL' }, new List<String>{ 'Antwerp', 'BE' }, new List<String>{ 'Manchester', 'GB' } };
            List<String> p = eu[rand(eu.size())];
            c.putAll(new Map<String, Object>{ 'city' => p[0], 'state' => '', 'country' => p[1], 'address' => p[0] + ', ' + p[1] });
        }
        return withContact(c);
    }

    public static Map<String, Object> line(String sku, Integer qty) {
        Product2 p = NFY_Ref.product(sku);
        PricebookEntry e = [SELECT UnitPrice FROM PricebookEntry WHERE Id = :NFY_Ref.priceEntry(p.Id)];
        return new Map<String, Object>{ 'sku' => sku, 'qty' => qty, 'price' => e.UnitPrice };
    }

    public static Map<String, Object> order(String orderNo, String channel, Map<String, Object> cust, String shipFrom, List<Object> lines, Date orderDate) {
        Decimal sub = 0;
        for (Object o : lines) {
            Map<String, Object> l = (Map<String, Object>) o;
            sub += (Decimal) l.get('price') * (Integer) l.get('qty');
        }
        Decimal freight = channel == 'Wholesale / Team' ? 25.00 : (sub >= 100 || channel.startsWith('Amazon') ? 0 : 15.00);
        Map<String, Object> p = new Map<String, Object>{
            'orderNumber' => orderNo, 'channel' => channel, 'orderDate' => String.valueOf(orderDate), 'customer' => cust, 'shipFrom' => shipFrom,
            'lines' => lines, 'freight' => freight, 'tax' => (sub * 0.0875).setScale(2),
            'shopifyId' => orderNo.startsWith('#SPFY') ? '70' + digits(11) : null,
            'customerStatus' => rand(3) == 0 ? 'Existing' : 'New',
            'category' => channel == 'Wholesale / Team' ? (cust.get('type') == 'School' ? '5 - Scholastic' : '1 - Team') : (channel.startsWith('Amazon') ? '4 - Amazon' : '3 - Ecom .com')
        };
        if (channel == 'Wholesale / Team') {
            p.put('salesRep', pickStr(REPS));
        }
        return p;
    }

    /** Carrier, service, tracking and label system as each ship-from would report them. */
    public static Map<String, Object> shipment(String shipmentId, String orderNo, String shipFrom, Date shipDate) {
        String carrier;
        String service;
        String tracking;
        String label;
        if (shipFrom.startsWith('SM-')) {
            carrier = pickStr(new List<String>{ 'OnTrac', 'DHL eCom', 'USPS', 'UPS' });
            label = 'ShipMonk WMS';
        } else if (shipFrom == 'FBA-US') {
            carrier = 'Amazon';
            label = 'Amazon';
        } else if (shipFrom == 'CUSTOMWEAR') {
            carrier = 'UPS';
            label = 'Decorator';
        } else if (shipFrom == 'FACTORY') {
            carrier = 'DHL Express';
            label = 'Factory (direct)';
        } else if (shipFrom == 'NL-ODOO') {
            carrier = pickStr(new List<String>{ 'PostNL', 'DHL Parcel' });
            label = 'Odoo';
        } else {
            carrier = pickStr(new List<String>{ 'UPS', 'USPS', 'FedEx' });
            label = 'ShipStation';
        }
        switch on carrier {
            when 'UPS' { tracking = '1Z' + alnum(6) + '03' + digits(8); service = 'UPS Ground'; }
            when 'USPS' { tracking = '9400' + digits(18); service = 'USPS Ground Advantage'; }
            when 'FedEx' { tracking = digits(12); service = 'FedEx Home Delivery'; }
            when 'OnTrac' { tracking = 'D1000' + digits(10); service = 'OnTrac Ground'; }
            when 'DHL eCom' { tracking = 'GM' + digits(16); service = 'DHL SmartMail Parcel'; }
            when 'Amazon' { tracking = 'TBA' + digits(12); service = 'Amazon Shipping'; }
            when 'PostNL' { tracking = '3S' + alnum(4) + digits(9); service = 'PostNL Standard'; }
            when 'DHL Express' { tracking = digits(10); service = 'DHL Express Worldwide'; }
            when else { tracking = 'JVGL' + digits(16); service = 'DHL Parcel Connect'; }
        }
        return new Map<String, Object>{ 'shipmentId' => shipmentId, 'orderNumber' => orderNo, 'shipFrom' => shipFrom, 'carrier' => carrier,
            'service' => service, 'tracking' => tracking, 'labelSystem' => label, 'shipDate' => String.valueOf(shipDate) };
    }

    public static NFY_IntegrationService.Result send(String eventType, String source, Map<String, Object> payload) {
        return NFY_IntegrationService.process(eventType, source, JSON.serialize(payload), 'sim-' + String.valueOf(System.now().getTime()).right(8), 'Simulator');
    }

    public static String nextShopifyNumber() {
        Integer max = 385900;
        for (Order o : [SELECT NFY_External_Order_Id__c FROM Order WHERE NFY_External_Order_Id__c LIKE '#SPFY%' ORDER BY NFY_External_Order_Id__c DESC LIMIT 1]) {
            max = Math.max(max, Integer.valueOf(o.NFY_External_Order_Id__c.substring(5)));
        }
        return '#SPFY' + String.valueOf(max + 1);
    }

    private static String amazonOrderNumber() {
        return pickStr(new List<String>{ '111', '112', '113', '114' }) + '-' + digits(7) + '-' + digits(7);
    }

    /** Ship-from for each of the order's lines, as the channel would report them. */
    public static Set<String> shipFroms(String orderNo) {
        Set<String> result = new Set<String>();
        for (TC_Sales_Order_Line__c l : [
            SELECT NFY_Ship_From__r.NFY_Code__c FROM TC_Sales_Order_Line__c
            WHERE Sales_Order__r.NFY_External_Order_Id__c = :orderNo AND NFY_Ship_From__c != null AND Product__r.TC_Inventory_Product__c = true
        ]) {
            result.add(l.NFY_Ship_From__r.NFY_Code__c);
        }
        return result;
    }

    public static String sourceFor(String shipFrom) {
        if (shipFrom.startsWith('SM-')) return 'SHIPMONK';
        if (shipFrom == 'FBA-US') return 'AMAZON';
        if (shipFrom == 'NL-ODOO') return 'ODOO';
        if (shipFrom == 'CUSTOMWEAR' || shipFrom == 'FACTORY' || shipFrom == 'PRINTFUL') return 'SALESFORCE';
        return 'SHIPSTATION';
    }

    /** Ships every open ship-from on the order, one shipment each. */
    public static List<NFY_IntegrationService.Result> shipAll(String orderNo, Date shipDate) {
        List<NFY_IntegrationService.Result> out = new List<NFY_IntegrationService.Result>();
        Integer n = 1;
        for (String sf : shipFroms(orderNo)) {
            String id = sourceFor(sf).left(2) + '-' + digits(7);
            out.add(send('shipment.created', sourceFor(sf), shipment(id, orderNo, sf, shipDate)));
            n++;
        }
        return out;
    }

    // ------------------------------------------------------------------ scene actions (Simulator tab)

    public class SceneResult {
        @AuraEnabled public List<NFY_IntegrationService.Result> results = new List<NFY_IntegrationService.Result>();
        @AuraEnabled public String reference;
        @AuraEnabled public Id recordId;
        SceneResult add(NFY_IntegrationService.Result r) {
            results.add(r);
            if (recordId == null && r.recordId != null) {
                recordId = r.recordId;
            }
            return this;
        }
    }

    private static void live() {
        reseed(System.now().getTime());
    }

    /** S2: Shopify order routed to ShipMonk PA1. withStockout adds a SKU PA1 does not stock, so that line falls back to Main. */
    @AuraEnabled
    public static SceneResult shopifyOrder(Boolean withStockout) {
        live();
        SceneResult s = new SceneResult();
        String no = nextShopifyNumber();
        Map<String, Object> c = customer('Shopify .com');
        c.put('city', 'Charlotte');
        c.put('state', 'NC');
        List<Object> lines = new List<Object>{ line('840386208702', 1), line('840386230011', 1) };
        if (withStockout == true) {
            lines.add(line('840386215403', 1));
        }
        Map<String, Object> p = order(no, 'Shopify .com', c, 'SM-PA1', lines, Date.today());
        p.put('routingReason', 'Shopify ranked ShipMonk PA1 (east coast, fewest splits)');
        s.reference = no;
        return s.add(send('order.upsert', 'SHOPIFY', p));
    }

    /** T06: re-send the last Shopify order exactly as before. */
    @AuraEnabled
    public static SceneResult resendLastOrder() {
        SceneResult s = new SceneResult();
        List<NFY_Sync_Log__c> last = [SELECT Payload__c FROM NFY_Sync_Log__c WHERE Event_Type__c = 'order.upsert' AND System__r.Code__c = 'SHOPIFY' AND Status__c = 'Success' ORDER BY CreatedDate DESC LIMIT 1];
        if (last.isEmpty()) {
            throw new AuraHandledException('Create a Shopify order first.');
        }
        Map<String, Object> p = (Map<String, Object>) JSON.deserializeUntyped(last[0].Payload__c);
        s.reference = (String) p.get('orderNumber');
        return s.add(send('order.upsert', 'SHOPIFY', p));
    }

    /** S2/S4/S6/S7: the 3PL, ShipStation, decorator or Odoo reports a shipment for one ship-from. */
    @AuraEnabled
    public static SceneResult shipFrom(String orderNumber, String shipFromCode) {
        live();
        SceneResult s = new SceneResult();
        String src = sourceFor(shipFromCode);
        s.reference = orderNumber;
        return s.add(send('shipment.created', src, shipment(src.left(2) + '-' + digits(7), orderNumber, shipFromCode, Date.today())));
    }

    /** S3: Amazon creates an inbound shipment plan from Main to FBA. */
    @AuraEnabled
    public static SceneResult fbaInboundPlan(String sku, Integer qty) {
        live();
        SceneResult s = new SceneResult();
        String id = 'FBA19' + alnum(6);
        s.reference = id;
        return s.add(send('inbound.update', 'AMAZON', new Map<String, Object>{ 'inboundId' => id, 'status' => 'WORKING', 'type' => 'Amazon FBA inbound',
            'from' => 'MAIN', 'to' => 'FBA-US', 'lines' => new List<Object>{ new Map<String, Object>{ 'sku' => sku == null ? '840386208702' : sku, 'shipped' => qty == null ? 240 : qty } } }));
    }

    @AuraEnabled
    public static SceneResult fbaInboundShipped(String inboundId) {
        live();
        SceneResult s = new SceneResult();
        s.reference = inboundId;
        return s.add(send('inbound.update', 'AMAZON', new Map<String, Object>{ 'inboundId' => inboundId, 'status' => 'SHIPPED', 'carrier' => 'UPS',
            'tracking' => '1Z' + alnum(6) + '03' + digits(8) }));
    }

    /** S3: Amazon reports the receipt, shortBy units under what was sent. */
    @AuraEnabled
    public static SceneResult fbaInboundReceived(String inboundId, Integer shortBy) {
        SceneResult s = new SceneResult();
        s.reference = inboundId;
        List<Object> lines = new List<Object>();
        for (NFY_Inbound_Shipment_Line__c l : [SELECT Product__r.ProductCode, Quantity_Shipped__c FROM NFY_Inbound_Shipment_Line__c WHERE Inbound_Shipment__r.External_Id__c = :inboundId]) {
            lines.add(new Map<String, Object>{ 'sku' => l.Product__r.ProductCode, 'received' => l.Quantity_Shipped__c - (shortBy == null ? 0 : shortBy) });
        }
        return s.add(send('inbound.update', 'AMAZON', new Map<String, Object>{ 'inboundId' => inboundId, 'status' => 'RECEIVED', 'lines' => lines }));
    }

    /** S3: an FBA marketplace order. mcf = a Shopify .com order fulfilled by Amazon MCF. Amazon's shipment follows as its own event (shipFrom FBA-US). */
    @AuraEnabled
    public static SceneResult amazonOrder(Boolean mcf) {
        live();
        SceneResult s = new SceneResult();
        String channel = mcf == true ? 'Amazon MCF' : 'Amazon FBA';
        String no = mcf == true ? nextShopifyNumber() : amazonOrderNumber();
        Map<String, Object> p = order(no, channel, customer(channel), 'FBA-US', new List<Object>{ line('840386208702', 1) }, Date.today());
        p.put('routingReason', mcf == true ? 'Shopify ranked Amazon MCF for this order' : 'Fulfilled by Amazon');
        s.reference = no;
        return s.add(send('order.upsert', mcf == true ? 'SHOPIFY' : 'AMAZON', p));
    }

    /** S3: a return for the most recent Amazon order. */
    @AuraEnabled
    public static SceneResult amazonReturn(String condition) {
        live();
        SceneResult s = new SceneResult();
        List<TC_Sales_Order__c> last = [SELECT NFY_External_Order_Id__c FROM TC_Sales_Order__c WHERE NFY_Channel__c = 'Amazon FBA' AND NFY_Fulfillment_Status__c = 'Billed' ORDER BY CreatedDate DESC LIMIT 1];
        if (last.isEmpty()) {
            throw new AuraHandledException('Create and ship an Amazon FBA order first.');
        }
        String rma = 'RMA-' + digits(7);
        s.reference = rma;
        return s.add(send('return.received', 'AMAZON', new Map<String, Object>{ 'rma' => rma, 'orderNumber' => last[0].NFY_External_Order_Id__c, 'sku' => '840386208702',
            'qty' => 1, 'condition' => condition == null ? 'Sellable' : condition, 'warehouse' => 'FBA-US', 'refund' => 99.99,
            'reason' => condition == 'Unfulfillable' ? 'Damaged by carrier' : 'Size too small' }));
    }

    /** S4: a rep's team order: shoes from Main, decorated jackets from Customwear, one style direct from the factory. */
    @AuraEnabled
    public static SceneResult b2bOrder() {
        live();
        SceneResult s = new SceneResult();
        String no = 'B2B-' + digits(5);
        Map<String, Object> jacket = line('840386230033', 12);
        jacket.put('shipFrom', 'CUSTOMWEAR');
        Map<String, Object> direct = line('840386219109', 24);
        direct.put('shipFrom', 'FACTORY');
        Map<String, Object> p = order(no, 'Wholesale / Team', customer('Wholesale / Team'), 'MAIN', new List<Object>{ line('840386211202', 12), jacket, direct }, Date.today());
        p.put('routingReason', 'Default warehouse on the sales order: Nfinity Main; decorated jackets from Customwear; Rival 9 direct from factory');
        s.reference = no;
        return s.add(send('order.upsert', 'SALESFORCE', p));
    }

    /** S5: a factory PO plus its container on the water. */
    @AuraEnabled
    public static SceneResult factoryPo() {
        live();
        SceneResult s = new SceneResult();
        Account vendor = [SELECT Id FROM Account WHERE NFY_External_Customer_Id__c = 'VENDOR-FACTORY' LIMIT 1];
        String poNo = 'PO-NFY-' + digits(4);
        TC_Purchase_Order__c po = new TC_Purchase_Order__c(Vendor__c = vendor.Id, Order_Date__c = Date.today(), Status__c = 'Open', Type__c = 'Standard',
            NFY_External_Id__c = poNo, NFY_Demo__c = true, Comment__c = 'Spring restock, FOB Xiamen');
        insert po;
        insert new TC_Purchase_Order_Line__c(Purchase_Order__c = po.Id, Product__c = NFY_Ref.product('840386208702').Id, Quantity__c = 1000);
        String ib = 'CNT-' + alnum(4) + digits(7);
        s.reference = poNo;
        s.recordId = po.Id;
        return s.add(send('inbound.update', 'SALESFORCE', new Map<String, Object>{ 'inboundId' => ib, 'status' => 'IN_TRANSIT', 'type' => 'Factory container',
            'to' => 'MAIN', 'poNumber' => poNo, 'containerNo' => ib.substring(4), 'vessel' => 'MSC Aurora', 'eta' => String.valueOf(Date.today().addDays(9)),
            'lines' => new List<Object>{ new Map<String, Object>{ 'sku' => '840386208702', 'shipped' => 1000 } } }));
    }

    /** S5: the container is split: 600 into Main, 400 into ShipMonk NV3. */
    @AuraEnabled
    public static SceneResult receivePo(String poNumber) {
        live();
        SceneResult s = new SceneResult();
        List<NFY_Inbound_Shipment__c> ib = [SELECT External_Id__c FROM NFY_Inbound_Shipment__c WHERE Purchase_Order__r.NFY_External_Id__c = :poNumber LIMIT 1];
        String ibId = ib.isEmpty() ? null : ib[0].External_Id__c;
        s.reference = poNumber;
        s.add(send('po.receipt', 'SALESFORCE', new Map<String, Object>{ 'receiptId' => poNumber + '-MAIN', 'poNumber' => poNumber, 'warehouse' => 'MAIN', 'inboundId' => ibId,
            'lines' => new List<Object>{ new Map<String, Object>{ 'sku' => '840386208702', 'qty' => 600 } } }));
        s.add(send('po.receipt', 'SHIPMONK', new Map<String, Object>{ 'receiptId' => poNumber + '-NV3', 'poNumber' => poNumber, 'warehouse' => 'SM-NV3', 'inboundId' => ibId,
            'lines' => new List<Object>{ new Map<String, Object>{ 'sku' => '840386208702', 'qty' => 400 } } }));
        return s;
    }

    /** S6: onboard the Netherlands 3PL from the template. */
    @AuraEnabled
    public static SceneResult onboardNetherlands() {
        SceneResult s = new SceneResult();
        s.recordId = NFY_ThreePLTemplate.onboard('NL 3PL · Odoo', 'NL-ODOO', 'Venlo', 'EU', 'EUR', 'ODOO');
        s.reference = 'NL-ODOO';
        // Opening stock for the new site arrives as a transfer from Main, the way the first container would be split.
        NFY_IntegrationService.transfer(NFY_Ref.product('840386208702').Id, 'MAIN', 'AVL', 'NL-ODOO', 'AVL', 60, Date.today());
        NFY_IntegrationService.transfer(NFY_Ref.product('840386230011').Id, 'MAIN', 'AVL', 'NL-ODOO', 'AVL', 40, Date.today());
        return s;
    }

    /** S6: an EU webstore order routed to the NL 3PL. */
    @AuraEnabled
    public static SceneResult euOrder() {
        live();
        SceneResult s = new SceneResult();
        if (!NFY_Ref.hasWarehouse('NL-ODOO')) {
            throw new AuraHandledException('Onboard the Netherlands 3PL first.');
        }
        String no = 'EU-' + digits(6);
        Map<String, Object> p = order(no, 'EU Webstore', customer('EU Webstore'), 'NL-ODOO', new List<Object>{ line('840386208702', 1), line('840386230011', 1) }, Date.today());
        p.put('routingReason', 'EU address routed to NL 3PL (Odoo)');
        p.put('allowFallback', false);
        s.reference = no;
        return s.add(send('order.upsert', 'SHOPIFY', p));
    }

    /** S7: ShipStation reports a label for an order the daily Shopify sync has not delivered yet. */
    @AuraEnabled
    public static SceneResult shipStationFailure() {
        live();
        SceneResult s = new SceneResult();
        String no = nextShopifyNumber();
        s.reference = no;
        Map<String, Object> p = shipment('SS-' + digits(7), no, 'MAIN', Date.today());
        p.put('sfdcId', '006' + alnum(12));
        p.put('lines', new List<Object>{ new Map<String, Object>{ 'sku' => '840386211201', 'qty' => 1 } });
        return s.add(send('shipment.created', 'SHIPSTATION', p));
    }

    /** S7: the late Shopify order sync arrives for the order the failed shipment points at. */
    @AuraEnabled
    public static SceneResult runOrderSyncFor(String orderNumber) {
        live();
        SceneResult s = new SceneResult();
        Map<String, Object> p = order(orderNumber, 'Shopify .com', customer('Shopify .com'), 'MAIN', new List<Object>{ line('840386211201', 1) }, Date.today());
        p.put('routingReason', 'Shopify ranked Nfinity Main (Atlanta pickup region)');
        s.reference = orderNumber;
        return s.add(send('order.upsert', 'SHOPIFY', p));
    }

    @AuraEnabled
    public static SceneResult retry(Id logId) {
        SceneResult s = new SceneResult();
        return s.add(NFY_IntegrationService.retry(logId));
    }

    /**
     * S9: a team order for 40 more Flyte - Adult 8.5 than ShipMonk NV3 holds, with the ship-from fixed to NV3,
     * so NV3 assigns what it has and 40 are backordered.
     */
    @AuraEnabled
    public static SceneResult shortfallOrder() {
        live();
        SceneResult s = new SceneResult();
        String sku = '840386215485';
        Id productId = NFY_Ref.product(sku).Id;
        Decimal atNv3 = 0;
        for (TC_Inventory_Balance__c b : [
            SELECT Available_Quantity__c FROM TC_Inventory_Balance__c WHERE Product__c = :productId AND Location__r.NFY_Code__c = 'SM-NV3-AVL'
        ]) {
            atNv3 = b.Available_Quantity__c == null ? 0 : b.Available_Quantity__c;
        }
        String no = 'B2B-' + digits(5);
        Map<String, Object> p = order(no, 'Wholesale / Team', customer('Wholesale / Team'), 'SM-NV3',
            new List<Object>{ line(sku, atNv3.intValue() + 40) }, Date.today());
        // The team's shoes must come from the west coast site, so no fallback to Main: the 40 extra are backordered.
        p.put('allowFallback', false);
        p.put('routingReason', 'Rep fixed the ship-from to ShipMonk NV3 (west coast team, no fallback)');
        s.reference = no;
        return s.add(send('order.upsert', 'SALESFORCE', p));
    }

    /** S9: a PO for the order's shortfall is received at the ship-from; the backorder is assigned automatically. */
    @AuraEnabled
    public static SceneResult stockArrives(String orderNumber) {
        live();
        SceneResult s = new SceneResult();
        List<TC_Sales_Order_Line__c> shortLines = [
            SELECT Product__c, Product__r.ProductCode, NFY_Short_Qty__c, NFY_Ship_From__r.NFY_Code__c FROM TC_Sales_Order_Line__c
            WHERE Sales_Order__r.NFY_External_Order_Id__c = :orderNumber AND NFY_Short_Qty__c > 0
        ];
        if (shortLines.isEmpty()) {
            throw new AuraHandledException(orderNumber + ' has nothing short.');
        }
        Account vendor = [SELECT Id FROM Account WHERE NFY_External_Customer_Id__c = 'VENDOR-FACTORY' LIMIT 1];
        String poNo = 'PO-NFY-' + digits(4);
        TC_Purchase_Order__c po = new TC_Purchase_Order__c(Vendor__c = vendor.Id, Order_Date__c = Date.today(), Status__c = 'Open', Type__c = 'Standard',
            NFY_External_Id__c = poNo, NFY_Demo__c = true, Comment__c = 'Restock for backorder ' + orderNumber);
        insert po;
        TC_Sales_Order_Line__c l = shortLines[0];
        insert new TC_Purchase_Order_Line__c(Purchase_Order__c = po.Id, Product__c = l.Product__c, Quantity__c = l.NFY_Short_Qty__c);
        s.reference = poNo;
        return s.add(send('po.receipt', sourceFor(l.NFY_Ship_From__r.NFY_Code__c), new Map<String, Object>{ 'receiptId' => poNo + '-1', 'poNumber' => poNo,
            'warehouse' => l.NFY_Ship_From__r.NFY_Code__c, 'lines' => new List<Object>{ new Map<String, Object>{ 'sku' => l.Product__r.ProductCode, 'qty' => l.NFY_Short_Qty__c } } }));
    }

    /** S7: a stock count from the 3PL, with two deliberate mismatches. */
    @AuraEnabled
    public static SceneResult stockSnapshot(String warehouseCode) {
        SceneResult s = new SceneResult();
        String code = warehouseCode == null ? 'SM-PA1' : warehouseCode;
        List<Object> items = new List<Object>();
        Integer i = 0;
        for (TC_Inventory_Balance__c b : [
            SELECT Product__r.ProductCode, Available_Quantity__c FROM TC_Inventory_Balance__c
            WHERE Location__r.NFY_Code__c = :(code + '-AVL') AND Product__r.NFY_Demo__c = true ORDER BY Product__r.ProductCode
        ]) {
            Decimal q = b.Available_Quantity__c;
            if (i == 1) q = q - 4;
            if (i == 5) q = q + 2;
            items.add(new Map<String, Object>{ 'sku' => b.Product__r.ProductCode, 'qty' => Math.max(q, 0) });
            i++;
        }
        s.reference = code;
        return s.add(send('inventory.snapshot', sourceFor(code), new Map<String, Object>{ 'snapshotId' => code + '-' + System.now().format('yyyyMMddHHmmss'),
            'warehouse' => code, 'asOf' => String.valueOf(Date.today()), 'items' => items }));
    }

    /** S8: settlement or payout covering the last 14 days of billings for that payer, plus one sale missing from Salesforce. */
    @AuraEnabled
    public static SceneResult settlement(String source) {
        SceneResult s = new SceneResult();
        Boolean amazon = source != 'SHOPIFY';
        String payerCode = amazon ? 'PAYER-AMAZON' : 'PAYER-SHOPIFY';
        Date endD = Date.today();
        Date startD = endD.addDays(-14);
        Decimal gross = 0;
        for (AggregateResult ar : [
            SELECT SUM(Balance__c) total FROM TC_Billing__c WHERE Customer__r.NFY_External_Customer_Id__c = :payerCode AND Status__c = 'Posted'
            AND Balance__c > 0 AND NFY_Settlement__c = null AND Date__c >= :startD AND Date__c <= :endD
        ]) {
            gross = ar.get('total') == null ? 0 : (Decimal) ar.get('total');
        }
        Decimal extra = 129.99;
        String id = amazon ? 'AMZ-STL-' + endD.format().replace('/', '') + '-' + String.valueOf(System.now().getTime()).right(4) : 'SHP-PO-' + String.valueOf(System.now().getTime()).right(8);
        s.reference = id;
        Decimal total = gross + extra;
        return s.add(send('settlement.posted', amazon ? 'AMAZON' : 'SHOPIFY', new Map<String, Object>{ 'settlementId' => id,
            'periodStart' => String.valueOf(startD), 'periodEnd' => String.valueOf(endD), 'grossSales' => total, 'refunds' => 0,
            'marketplaceFees' => amazon ? (total * 0.15).setScale(2) : 0, 'fulfillmentFees' => amazon ? (total * 0.11).setScale(2) : 0,
            'paymentFees' => amazon ? 0 : (total * 0.029).setScale(2) }));
    }
}