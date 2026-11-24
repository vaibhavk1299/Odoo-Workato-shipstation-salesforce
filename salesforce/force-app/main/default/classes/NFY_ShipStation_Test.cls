/**
 * shipstation.notify: ShipStation label shipments and marked-shipped fulfillments become TC shipments on the
 * matching order, from the warehouse holding its allocation; replays, voids and unknown orders are skipped.
 */
@IsTest
private class NFY_ShipStation_Test {

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

    private static void order(String orderNo, Integer qty) {
        NFY_IntegrationService.Result r = NFY_IntegrationService.process('order.upsert', 'ODOO_SHOP', JSON.serialize(new Map<String, Object>{
            'orderNumber' => orderNo, 'channel' => 'Odoo', 'orderDate' => String.valueOf(Date.today()), 'shipFrom' => 'MAIN', 'allowFallback' => true,
            'tax' => 0, 'freight' => 0,
            'customer' => new Map<String, Object>{ 'externalId' => 'ODOO-950', 'name' => 'ShipStation Buyer', 'email' => 'ss@example.com', 'city' => 'Denver' },
            'lines' => new List<Object>{ new Map<String, Object>{ 'sku' => SKU, 'qty' => qty, 'price' => 100 } }
        }), 'j-order', 'Workato');
        System.assert(r.success, r.message);
    }

    private static NFY_IntegrationService.Result notify(String type, Map<String, Object> body) {
        return NFY_IntegrationService.process('shipstation.notify', 'SHIPSTATION', JSON.serialize(new Map<String, Object>{
            'resourceType' => type, 'body' => JSON.serialize(body), 'jobId' => 'j-ss'
        }), 'j-ss', 'Workato');
    }

    @IsTest
    static void markedShippedFulfillmentShipsAndBillsTheOrder() {
        System.runAs(accountant()) {
            order('ODOO-S9100', 2);
            Map<String, Object> body = new Map<String, Object>{ 'fulfillments' => new List<Object>{ new Map<String, Object>{
                'fulfillmentId' => 555, 'orderNumber' => 'ODOO-S9100', 'trackingNumber' => '1Z999TEST', 'carrierCode' => 'ups',
                'shipDate' => '2026-11-10T00:00:00.0000000', 'voided' => false } } };
            Test.startTest();
            NFY_IntegrationService.Result r = notify('FULFILLMENT_SHIPPED', body);
            NFY_IntegrationService.Result again = notify('FULFILLMENT_SHIPPED', body);
            Test.stopTest();

            System.assert(r.success, r.message);
            System.assert(r.message.contains('1 shipped'), r.message);
            System.assert(again.message.contains('0 shipped, 1 skipped'), again.message);
            TC_Shipment__c s = [SELECT NFY_Carrier__c, NFY_Tracking_Number__c, NFY_Label_System__c, NFY_External_Id__c, NFY_Ship_From__r.NFY_Code__c
                                FROM TC_Shipment__c WHERE Sales_Order__r.NFY_External_Order_Id__c = 'ODOO-S9100'];
            System.assertEquals('UPS', s.NFY_Carrier__c);
            System.assertEquals('1Z999TEST', s.NFY_Tracking_Number__c);
            System.assertEquals('ShipStation', s.NFY_Label_System__c);
            System.assertEquals('SS-F-555', s.NFY_External_Id__c);
            TC_Shipment__c src = [SELECT Id, NFY_Source_System__c, NFY_Source_Record_Id__c, NFY_Last_Sync_Log__c FROM TC_Shipment__c
                                  WHERE Sales_Order__r.NFY_External_Order_Id__c = 'ODOO-S9100'];
            System.assertEquals('ShipStation', src.NFY_Source_System__c, 'Reported by ShipStation');
            System.assertEquals('SS-F-555', src.NFY_Source_Record_Id__c);
            System.assertNotEquals(null, src.NFY_Last_Sync_Log__c);
            System.assertEquals(src.Id, [SELECT Shipment__c FROM NFY_Sync_Log__c WHERE Id = :src.NFY_Last_Sync_Log__c].Shipment__c);
            TC_Sales_Order__c so = [SELECT NFY_Source_System__c, NFY_Source_Record_Id__c FROM TC_Sales_Order__c WHERE NFY_External_Order_Id__c = 'ODOO-S9100'];
            System.assertEquals('Odoo', so.NFY_Source_System__c, 'The sales order keeps the order\'s origin');
            System.assertEquals('S9100', so.NFY_Source_Record_Id__c);
            System.assertEquals('Odoo', [SELECT NFY_Source_System__c FROM TC_Billing__c WHERE Sales_Order__r.NFY_External_Order_Id__c = 'ODOO-S9100' LIMIT 1].NFY_Source_System__c);
            System.assertEquals('MAIN', s.NFY_Ship_From__r.NFY_Code__c);
            System.assertEquals('Billed', [SELECT NFY_Fulfillment_Status__c FROM TC_Sales_Order__c WHERE NFY_External_Order_Id__c = 'ODOO-S9100'].NFY_Fulfillment_Status__c);
        }
    }

    @IsTest
    static void labelShipmentWithItemsShipsOnlyThoseUnits() {
        System.runAs(accountant()) {
            order('ODOO-S9101', 2);
            Map<String, Object> body = new Map<String, Object>{ 'shipments' => new List<Object>{
                new Map<String, Object>{ 'shipmentId' => 777, 'orderNumber' => 'ODOO-S9101', 'trackingNumber' => '9400TEST', 'carrierCode' => 'stamps_com',
                    'serviceCode' => 'usps_ground_advantage', 'shipDate' => '2026-11-10', 'voided' => false,
                    'shipmentItems' => new List<Object>{ new Map<String, Object>{ 'sku' => SKU, 'quantity' => 1 } } },
                new Map<String, Object>{ 'shipmentId' => 778, 'orderNumber' => 'NO-SUCH-ORDER', 'voided' => false },
                new Map<String, Object>{ 'shipmentId' => 779, 'orderNumber' => 'ODOO-S9101', 'voided' => true } } };
            Test.startTest();
            NFY_IntegrationService.Result r = notify('SHIP_NOTIFY', body);
            Test.stopTest();

            System.assert(r.success, r.message);
            System.assert(r.message.contains('1 shipped, 2 skipped'), r.message);
            TC_Shipment__c s = [SELECT NFY_Carrier__c, NFY_Service__c FROM TC_Shipment__c WHERE Sales_Order__r.NFY_External_Order_Id__c = 'ODOO-S9101'];
            System.assertEquals('USPS', s.NFY_Carrier__c);
            System.assertEquals('usps_ground_advantage', s.NFY_Service__c);
            System.assertEquals('Partially Shipped', [SELECT NFY_Fulfillment_Status__c FROM TC_Sales_Order__c WHERE NFY_External_Order_Id__c = 'ODOO-S9101'].NFY_Fulfillment_Status__c);
        }
    }

    @IsTest
    static void refusesWhatItCannotRead() {
        System.runAs(accountant()) {
            Test.startTest();
            NFY_IntegrationService.Result badType = notify('ORDER_NOTIFY', new Map<String, Object>{ 'orders' => new List<Object>() });
            NFY_IntegrationService.Result noBody = NFY_IntegrationService.process('shipstation.notify', 'SHIPSTATION',
                JSON.serialize(new Map<String, Object>{ 'resourceType' => 'SHIP_NOTIFY' }), 'j-x', 'Workato');
            NFY_IntegrationService.Result badJson = NFY_IntegrationService.process('shipstation.notify', 'SHIPSTATION',
                JSON.serialize(new Map<String, Object>{ 'resourceType' => 'SHIP_NOTIFY', 'body' => 'not json' }), 'j-y', 'Workato');
            NFY_IntegrationService.Result empty = notify('SHIP_NOTIFY', new Map<String, Object>{ 'shipments' => new List<Object>() });
            Test.stopTest();
            System.assertEquals('Failed', badType.status);
            System.assertEquals('Failed', noBody.status);
            System.assertEquals('Failed', badJson.status);
            System.assert(empty.success, empty.message);
            System.assertEquals(null, NFY_ShipStationService.findOrder(null));
        }
    }

    private static NFY_IntegrationService.Result sent(String orderNo, String created, String modified, Integer qty) {
        return NFY_IntegrationService.process('shipstation.order.sent', 'SHIPSTATION', JSON.serialize(new Map<String, Object>{
            'orderId' => 1027313807, 'orderNumber' => orderNo, 'orderKey' => orderNo, 'orderStatus' => 'awaiting_shipment',
            'createDate' => created, 'modifyDate' => modified,
            'items' => new List<Object>{ new Map<String, Object>{ 'sku' => SKU, 'quantity' => qty } },
            'advancedOptions' => new Map<String, Object>{ 'customField3' => qty < 25 ? 'Partly reserved: ' + SKU + ' ' + qty + ' of 25' : '' }
        }), 'j-sent', 'Workato');
    }

    @IsTest
    static void sendLoggedBeforeItsOrderIsLinkedWhenTheOrderArrives() {
        System.runAs(accountant()) {
            Test.startTest();
            NFY_IntegrationService.Result early = sent('ODOO-S9103', '2026-11-11T10:33:19', '2026-11-11T10:33:19', 1);
            System.assert(early.message.contains('No Salesforce order has this number yet'), early.message);
            order('ODOO-S9103', 1);
            Test.stopTest();

            NFY_Sync_Log__c l = [SELECT Order__c, Response__c FROM NFY_Sync_Log__c WHERE Id = :early.logId];
            System.assertEquals([SELECT Id FROM Order WHERE NFY_External_Order_Id__c = 'ODOO-S9103'].Id, l.Order__c, 'Linked once the order exists');
            System.assert(!l.Response__c.contains('No Salesforce order'), l.Response__c);
            System.assert(l.Response__c.contains('created in ShipStation'), l.Response__c);
            System.assertEquals('1027313807', [SELECT NFY_ShipStation_Order_Id__c FROM Order WHERE Id = :l.Order__c].NFY_ShipStation_Order_Id__c);
        }
    }

    @IsTest
    static void orderSentToShipStationIsLoggedWithoutTouchingTheOrder() {
        System.runAs(accountant()) {
            order('ODOO-S9102', 2);
            Order before = [SELECT Id, NFY_Source_System__c, NFY_Sync_Count__c, NFY_Last_Sync_Log__c FROM Order WHERE NFY_External_Order_Id__c = 'ODOO-S9102'];
            Test.startTest();
            NFY_IntegrationService.Result first = sent('ODOO-S9102', '2026-11-11T05:38:31', '2026-11-11T05:38:31', 18);
            NFY_IntegrationService.Result replay = sent('ODOO-S9102', '2026-11-11T05:38:31', '2026-11-11T05:38:31', 18);
            NFY_IntegrationService.Result resend = sent('ODOO-S9102', '2026-11-11T05:38:31', '2026-11-11T05:40:04', 25);
            NFY_IntegrationService.Result unknown = sent('ODOO-S9999', '2026-11-11T06:00:00', '2026-11-11T06:00:00', 1);
            Test.stopTest();

            System.assert(first.success, first.message);
            System.assert(first.message.contains('created in ShipStation') && first.message.contains('18 units') && first.message.contains('Partly reserved'), first.message);
            System.assertEquals('Duplicate skipped', replay.status);
            System.assert(resend.message.contains('updated in ShipStation') && resend.message.contains('25 units'), resend.message);
            System.assert(unknown.success && unknown.message.contains('No Salesforce order'), unknown.message);

            NFY_Sync_Log__c l = [SELECT Direction__c, Operation__c, Order__c, Flow__r.Code__c, System__r.Code__c, External_Id__c FROM NFY_Sync_Log__c WHERE Id = :first.logId];
            System.assertEquals('System to system', l.Direction__c);
            System.assertEquals('Created', l.Operation__c);
            System.assertEquals(before.Id, l.Order__c, 'The log links to the order');
            System.assertEquals('SHIPSTATION', l.System__r.Code__c);
            System.assertEquals('ODOO-S9102@2026-11-11T05:38:31', l.External_Id__c);
            System.assertEquals('Updated', [SELECT Operation__c FROM NFY_Sync_Log__c WHERE Id = :resend.logId].Operation__c);

            // The order's own origin stamp (from order.upsert) runs in the background during the test.
            Order after = [SELECT NFY_Source_System__c, NFY_Last_Sync_Log__c FROM Order WHERE Id = :before.Id];
            System.assertEquals('Odoo', after.NFY_Source_System__c, 'Origin stays Odoo');
            Set<Id> sendLogs = new Set<Id>{ first.logId, replay.logId, resend.logId, unknown.logId };
            System.assert(!sendLogs.contains(after.NFY_Last_Sync_Log__c), 'A send is not an order sync');
        }
    }
}