/**
 * Release to fulfilment (Phase 2): an order is released to ShipStation once every stocked line is assigned;
 * older backorders keep their claim on stock that arrives; a cancellation returns assigned stock, passes it to
 * waiting backorders and pulls a released order back.
 */
@IsTest
private class NFY_Release_Test {

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

    private static NFY_IntegrationService.Result order(String orderNo, Decimal qty) {
        return NFY_IntegrationService.process('order.upsert', 'ODOO_SHOP', JSON.serialize(new Map<String, Object>{
            'orderNumber' => orderNo, 'channel' => 'Odoo', 'orderDate' => String.valueOf(Date.today()), 'shipFrom' => 'MAIN', 'allowFallback' => false,
            'tax' => 0, 'freight' => 0,
            'customer' => new Map<String, Object>{ 'externalId' => 'ODOO-REL-1', 'name' => 'Release Buyer', 'email' => 'rel@example.com', 'city' => 'Austin' },
            'lines' => new List<Object>{ new Map<String, Object>{ 'sku' => SKU, 'qty' => qty, 'price' => 100 } }
        }), 'rel-' + orderNo, 'Workato');
    }

    private static NFY_IntegrationService.Result cancel(String orderNo) {
        return NFY_IntegrationService.process('order.cancelled', 'ODOO_SHOP', JSON.serialize(new Map<String, Object>{
            'orderNumber' => orderNo, 'reason' => 'Customer changed mind'
        }), 'cancel-' + orderNo, 'Workato');
    }

    private static TC_Inventory_Balance__c mainBalance() {
        Id productId = NFY_Ref.product(SKU).Id;
        Id locId = NFY_Ref.location('MAIN', 'AVL').Id;
        return [SELECT Id, Available_Quantity__c FROM TC_Inventory_Balance__c WHERE Product__c = :productId AND Location__c = :locId];
    }

    private static Order orderOf(String orderNo) {
        return [SELECT Id, NFY_Fulfillment_Status__c, NFY_Stock_Status__c, NFY_Units_Short__c, NFY_TC_Sales_Order__r.Status__c
                FROM Order WHERE NFY_External_Order_Id__c = :orderNo];
    }

    private static List<NFY_Integration_Event__e> events(String kind) {
        List<NFY_Integration_Event__e> out = new List<NFY_Integration_Event__e>();
        for (NFY_Integration_Event__e e : NFY_IntegrationService.fulfilmentEvents) {
            if (e.Severity__c == kind) {
                out.add(e);
            }
        }
        return out;
    }

    @IsTest
    static void fullyAssignedOrderIsReleased() {
        System.runAs(accountant()) {
            Test.startTest();
            System.assert(order('ODOO-S9400', 1).success);
            Test.stopTest();
            Order o = orderOf('ODOO-S9400');
            System.assertEquals('Awaiting Shipment', o.NFY_Fulfillment_Status__c);
            List<NFY_Integration_Event__e> rel = events(NFY_IntegrationService.RELEASE);
            System.assertEquals(1, rel.size(), 'one release per order');
            System.assertEquals(o.Id, rel[0].Log_Id__c);
            System.assertEquals('ODOO-S9400', rel[0].Message__c);
            System.assertEquals('SHIPSTATION', rel[0].System_Code__c);
        }
    }

    @IsTest
    static void backorderKeepsItsClaimOnArrivingStock() {
        System.runAs(accountant()) {
            Decimal onHand = mainBalance().Available_Quantity__c;
            Test.startTest();
            System.assert(order('ODOO-S9401', onHand + 2).success);
            System.assertEquals('Received', orderOf('ODOO-S9401').NFY_Fulfillment_Status__c, 'two units short');
            System.assertEquals(0, events(NFY_IntegrationService.RELEASE).size(), 'not released while short');

            // Two units arrive without the backorder fill running (for example a manual adjustment).
            insert new TC_Inbound_Inventory_Movement__c(Inventory_Balance__c = mainBalance().Id, Type__c = 'Accounting', Quantity__c = 2,
                Unit_Cost__c = 19.30, Movement_Date__c = Date.today(), Credit_GL_Account__c = NFY_Ref.gl('3900'));

            System.assert(order('ODOO-S9402', 1).success);
            Order later = orderOf('ODOO-S9402');
            System.assertEquals('Received', later.NFY_Fulfillment_Status__c, 'the newer order may not take the older order\'s units');
            System.assertEquals(1, later.NFY_Units_Short__c);

            String note = NFY_IntegrationService.fillBackorders(new Set<Id>{ NFY_Ref.location('MAIN', 'AVL').Id }, Date.today());
            Test.stopTest();
            System.assert(note.contains('ODOO-S9401'), note);
            System.assertEquals('Awaiting Shipment', orderOf('ODOO-S9401').NFY_Fulfillment_Status__c, 'older order filled first');
            System.assertEquals('Received', orderOf('ODOO-S9402').NFY_Fulfillment_Status__c);
            List<NFY_Integration_Event__e> rel = events(NFY_IntegrationService.RELEASE);
            System.assertEquals(1, rel.size());
            System.assertEquals('ODOO-S9401', rel[0].Message__c, 'released when the backorder fill completes it');
        }
    }

    @IsTest
    static void cancellationReturnsStockAndPullsBackTheOrder() {
        System.runAs(accountant()) {
            Decimal before = mainBalance().Available_Quantity__c;
            // A sales order entered in TC without an Order must not be mistaken for the one being cancelled.
            insert new TC_Sales_Order__c(Customer__c = [SELECT Id FROM Account LIMIT 1].Id, Order_Date__c = Date.today(), Status__c = 'Open');
            Test.startTest();
            System.assert(order('ODOO-S9403', 2).success);
            System.assertEquals(before - 2, mainBalance().Available_Quantity__c, 'assigned at release');
            NFY_IntegrationService.Result r = cancel('ODOO-S9403');
            System.assert(r.success, r.message);
            NFY_IntegrationService.Result again = cancel('ODOO-S9403');
            Test.stopTest();
            System.assertEquals(before, mainBalance().Available_Quantity__c, 'stock returned');
            Order o = orderOf('ODOO-S9403');
            System.assertEquals('Cancelled', o.NFY_Fulfillment_Status__c);
            System.assertEquals('Cancelled', o.NFY_TC_Sales_Order__r.Status__c);
            List<NFY_Integration_Event__e> can = events(NFY_IntegrationService.CANCEL);
            System.assertEquals(1, can.size(), 'released order is pulled back from ShipStation');
            System.assertEquals(o.Id, can[0].Log_Id__c);
            System.assertEquals('Duplicate skipped', again.status, 'a repeated cancellation does nothing');
        }
    }

    @IsTest
    static void unknownOrderCannotBeCancelled() {
        System.runAs(accountant()) {
            NFY_IntegrationService.Result r = cancel('ODOO-NOPE');
            System.assert(!r.success);
            System.assert(r.message.contains('Nothing to cancel'), r.message);
        }
    }
}