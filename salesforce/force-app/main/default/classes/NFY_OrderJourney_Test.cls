/**
 * The Order Journey shows the business lifecycle in a fixed order, whatever order the integration
 * messages arrived in; resends and replays fold into their stage; the progress bar follows the stages.
 */
@IsTest
private class NFY_OrderJourney_Test {

    private static final String SKU = '840386208702';

    @TestSetup
    static void setup() {
        User u = TC_TestFactory.accountant();
        insert new PermissionSetAssignment(AssigneeId = u.Id,
            PermissionSetId = [SELECT Id FROM PermissionSet WHERE Name = 'NFY_Integration_Tracking'].Id);
        System.runAs(u) {
            TC_TestFactory.setup();
            NFY_DemoData.seedReference();
            NFY_DemoData.seedStock();
            List<NFY_Integration_System__c> sys = new List<NFY_Integration_System__c>();
            for (String c : new List<String>{ 'ODOO_SHOP', 'SHIPSTATION' }) {
                if ([SELECT COUNT() FROM NFY_Integration_System__c WHERE Code__c = :c] == 0) {
                    sys.add(new NFY_Integration_System__c(Name = c, Code__c = c, Category__c = 'Sales channel', Status__c = 'Connected', Mode__c = 'Webhook'));
                }
            }
            insert sys;
        }
    }

    private static User accountant() {
        return [SELECT Id FROM User WHERE Username LIKE 'tc.accountant.%' ORDER BY CreatedDate DESC LIMIT 1];
    }

    private static NFY_IntegrationService.Result order(String orderNo, Integer qty) {
        return NFY_IntegrationService.process('order.upsert', 'ODOO_SHOP', JSON.serialize(new Map<String, Object>{
            'orderNumber' => orderNo, 'channel' => 'Odoo', 'orderDate' => String.valueOf(Date.today()), 'shipFrom' => 'MAIN', 'allowFallback' => true,
            'tax' => 0, 'freight' => 0,
            'customer' => new Map<String, Object>{ 'externalId' => 'ODOO-951', 'name' => 'Journey Buyer', 'email' => 'jb@example.com', 'city' => 'Austin' },
            'lines' => new List<Object>{ new Map<String, Object>{ 'sku' => SKU, 'qty' => qty, 'price' => 100 } }
        }), 'j-order', 'Workato');
    }

    private static NFY_IntegrationService.Result sent(String orderNo, String modified, Integer qty, Integer total) {
        return NFY_IntegrationService.process('shipstation.order.sent', 'SHIPSTATION', JSON.serialize(new Map<String, Object>{
            'orderId' => 1027313900, 'orderNumber' => orderNo, 'orderKey' => orderNo, 'orderStatus' => 'awaiting_shipment',
            'createDate' => '2026-11-18T10:00:00', 'modifyDate' => modified,
            'items' => new List<Object>{ new Map<String, Object>{ 'sku' => SKU, 'quantity' => qty } },
            'advancedOptions' => new Map<String, Object>{ 'customField3' => qty < total ? 'Partly reserved: ' + SKU + ' ' + qty + ' of ' + total : 'Fully reserved' }
        }), 'j-sent', 'Workato');
    }

    private static NFY_IntegrationService.Result shipped(String orderNo, Integer id, Integer units) {
        Map<String, Object> shipment = new Map<String, Object>{ 'shipmentId' => id, 'orderNumber' => orderNo, 'trackingNumber' => '1ZJOURNEY' + id,
            'carrierCode' => 'ups', 'shipDate' => '2026-11-18', 'voided' => false };
        if (units != null) {
            shipment.put('shipmentItems', new List<Object>{ new Map<String, Object>{ 'sku' => SKU, 'quantity' => units } });
        }
        return NFY_IntegrationService.process('shipstation.notify', 'SHIPSTATION', JSON.serialize(new Map<String, Object>{
            'resourceType' => 'SHIP_NOTIFY', 'body' => JSON.serialize(new Map<String, Object>{ 'shipments' => new List<Object>{ shipment } }), 'jobId' => 'j-ss'
        }), 'j-ss', 'Workato');
    }

    private static Map<String, NFY_OrderJourneyController.Stage> byKey(NFY_OrderJourneyController.Journey j) {
        Map<String, NFY_OrderJourneyController.Stage> m = new Map<String, NFY_OrderJourneyController.Stage>();
        for (NFY_OrderJourneyController.Stage s : j.lifecycle) m.put(s.key, s);
        return m;
    }

    @IsTest
    static void lifecycleFollowsTheBusinessOrderNotTheMessageOrder() {
        System.runAs(accountant()) {
            Test.startTest();
            // Odoo fires the ShipStation webhook before the order reaches Salesforce.
            sent('ODOO-S9200', '2026-11-18T10:00:01', 0, 1);
            System.assert(order('ODOO-S9200', 1).success);
            sent('ODOO-S9200', '2026-11-18T10:00:05', 1, 1);
            System.assert(shipped('ODOO-S9200', 901, null).success);
            NFY_IntegrationService.Result replay = order('ODOO-S9200', 1);
            Test.stopTest();
            System.assertEquals('Duplicate skipped', replay.status);

            TC_Sales_Order__c so = [SELECT Id FROM TC_Sales_Order__c WHERE NFY_External_Order_Id__c = 'ODOO-S9200'];
            NFY_OrderJourneyController.Journey j = NFY_OrderJourneyController.getJourney(so.Id);

            List<String> keys = new List<String>();
            for (NFY_OrderJourneyController.Stage s : j.lifecycle) keys.add(s.key);
            System.assertEquals('origin,received,sales-order,allocation,shipstation,shipment,billing,origin-billing', String.join(keys, ','));
            Map<String, NFY_OrderJourneyController.Stage> st = byKey(j);
            System.assertEquals('Odoo', st.get('origin').path, 'Odoo is shown as the origin');
            System.assert(st.get('origin').detail.contains('S9200'), st.get('origin').detail);
            System.assertEquals(NFY_OrderJourneyController.COMPLETED, st.get('received').status);
            System.assert(st.get('received').detail.contains('1 repeat ignored'), st.get('received').detail);
            System.assertEquals(NFY_OrderJourneyController.COMPLETED, st.get('sales-order').status);
            System.assertEquals(NFY_OrderJourneyController.COMPLETED, st.get('allocation').status);
            System.assertEquals(NFY_OrderJourneyController.COMPLETED, st.get('shipstation').status, 'The latest send was fully reserved');
            System.assertEquals(2, st.get('shipstation').items.size(), 'Both sends are kept as history under one stage');
            System.assertEquals(NFY_OrderJourneyController.COMPLETED, st.get('shipment').status);
            System.assertEquals(NFY_OrderJourneyController.COMPLETED, st.get('billing').status);
            System.assertEquals(NFY_OrderJourneyController.NOT_AVAILABLE, st.get('origin-billing').status, 'No billing sync back to Odoo exists');
            System.assertEquals(3, j.stageIndex, 'The bar shows Billed only because billing really posted');
            System.assert(!j.steps.isEmpty(), 'The order history stays available');
            System.assertEquals('origin', j.steps[0].kind, 'The history starts with the order in Odoo');
            Integer lastRank = 0;
            List<String> titles = new List<String>();
            for (NFY_OrderJourneyController.Step s : j.steps) {
                System.assert(s.rank >= lastRank, 'History never steps back in the lifecycle: ' + s.title);
                System.assertNotEquals('Duplicate skipped', s.status, 'Replays are folded into the original');
                lastRank = s.rank;
                titles.add(s.title);
            }
            String order = String.join(titles, ' > ');
            System.assert(order.indexOf('Order received from') < order.indexOf('Sales order created in Salesforce'), order);
            System.assert(order.indexOf('Sales order created in Salesforce') < order.indexOf('Inventory allocated'), order);
            System.assert(order.indexOf('Inventory allocated') < order.indexOf('Order sent to ShipStation'), order);
            System.assert(order.indexOf('Order sent to ShipStation') < order.indexOf('Shipment dispatched'), order);
            System.assert(order.indexOf('Shipment dispatched') < order.indexOf('Invoice generated'), order);
            Boolean foldedNote = false;
            for (NFY_OrderJourneyController.Step s : j.steps) {
                if (s.title.startsWith('Order received') && s.note != null && s.note.contains('Sent again 1 time')) foldedNote = true;
            }
            System.assert(foldedNote, 'The replay is noted on the original order message');
            for (NFY_OrderJourneyController.Step s : j.steps) {
                System.assert(!s.route.isEmpty(), 'Every event names its systems: ' + s.title);
                System.assertNotEquals(null, s.statusLabel, 'Every event has a status: ' + s.title);
                if (s.kind == 'shipment') {
                    System.assert(s.refs.size() >= 2, 'The shipment carries its record and the message that reported it');
                    System.assertEquals('ShipStation', s.route[0]);
                }
            }
            System.assert(!order.contains('Shipment message received'), 'The shipment message is folded into the shipment: ' + order);
        }
    }

    @IsTest
    static void partialShipmentIsNotShownAsShipped() {
        System.runAs(accountant()) {
            Test.startTest();
            System.assert(order('ODOO-S9201', 2).success);
            System.assert(shipped('ODOO-S9201', 902, 1).success);
            Test.stopTest();

            TC_Sales_Order__c so = [SELECT Id FROM TC_Sales_Order__c WHERE NFY_External_Order_Id__c = 'ODOO-S9201'];
            NFY_OrderJourneyController.Journey j = NFY_OrderJourneyController.getJourney(so.Id);
            Map<String, NFY_OrderJourneyController.Stage> st = byKey(j);
            System.assertEquals(NFY_OrderJourneyController.PARTIAL, st.get('shipment').status, st.get('shipment').detail);
            System.assert(st.get('shipment').detail.contains('1 of 2'), st.get('shipment').detail);
            System.assertNotEquals(NFY_OrderJourneyController.COMPLETED, st.get('billing').status);
            System.assertEquals(2, j.stageIndex);
            System.assertEquals('Partially shipped', j.stages[2]);
            System.assertEquals(NFY_OrderJourneyController.PENDING, st.get('shipstation').status, 'Nothing was sent to ShipStation for this order');
        }
    }

    @IsTest
    static void shortStockWaitsAndNothingAfterIsMarkedDone() {
        System.runAs(accountant()) {
            Test.startTest();
            System.assert(order('ODOO-S9202', 100000).success);
            Test.stopTest();

            TC_Sales_Order__c so = [SELECT Id FROM TC_Sales_Order__c WHERE NFY_External_Order_Id__c = 'ODOO-S9202'];
            NFY_OrderJourneyController.Journey j = NFY_OrderJourneyController.getJourney(so.Id);
            Map<String, NFY_OrderJourneyController.Stage> st = byKey(j);
            String alloc = st.get('allocation').status;
            System.assert(alloc == NFY_OrderJourneyController.PARTIAL || alloc == NFY_OrderJourneyController.PENDING, alloc);
            System.assertEquals(NFY_OrderJourneyController.PENDING, st.get('shipment').status);
            System.assertEquals(NFY_OrderJourneyController.PENDING, st.get('billing').status);
            System.assert(j.stageIndex <= 1, 'Never ahead of what happened');
        }
    }

    @IsTest
    static void unlinkedRecordHasNoJourney() {
        System.runAs(accountant()) {
            NFY_OrderJourneyController.Journey j = NFY_OrderJourneyController.getJourney(UserInfo.getUserId());
            System.assertEquals(null, j.orderNumber);
            System.assert(j.lifecycle.isEmpty());
        }
    }
}