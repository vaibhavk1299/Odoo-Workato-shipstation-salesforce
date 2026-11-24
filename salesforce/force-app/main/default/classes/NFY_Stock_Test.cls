/**
 * stock.adjusted: receipts, counts, scrap and transfers sent by the stock system move TC stock,
 * post to the ledger's default offset accounts, refuse what Salesforce cannot honour and skip
 * moves already applied.
 */
@IsTest
private class NFY_Stock_Test {

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
            NFY_Integration_System__c s = new NFY_Integration_System__c(Name = 'Odoo (Commerce)', Code__c = 'ODOO_SHOP',
                Category__c = 'Sales channel', Status__c = 'Connected', Mode__c = 'Webhook');
            insert s;
            insert new NFY_Integration_Flow__c(Name = '[Odoo to SFDC] - Stock', Code__c = 'ODOO_SHOP-INVENTORY', System__c = s.Id,
                Entity__c = 'Inventory', Direction__c = 'Into Salesforce', Active__c = true);
        }
    }

    private static User accountant() {
        return [SELECT Id FROM User WHERE Username LIKE 'tc.accountant.%' ORDER BY CreatedDate DESC LIMIT 1];
    }

    private static NFY_IntegrationService.Result send(Map<String, Object> move) {
        Map<String, Object> p = new Map<String, Object>{ 'sku' => SKU, 'qty' => 10, 'date' => String.valueOf(Date.today()), 'unitCost' => 40 };
        p.putAll(move);
        return NFY_IntegrationService.process('stock.adjusted', 'ODOO_SHOP', JSON.serialize(p), 'j-stock', 'Workato');
    }

    private static Decimal available(String warehouseCode) {
        Id productId = [SELECT Id FROM Product2 WHERE ProductCode = :SKU AND NFY_Demo__c = true LIMIT 1].Id;
        Id locId = NFY_Ref.location(warehouseCode, 'AVL').Id;
        List<TC_Inventory_Balance__c> b = [SELECT Available_Quantity__c FROM TC_Inventory_Balance__c WHERE Product__c = :productId AND Location__c = :locId];
        return b.isEmpty() ? 0 : b[0].Available_Quantity__c;
    }

    private static NFY_IntegrationService.Result inbound(String ref, String status, String version, Decimal shipped, Decimal received) {
        Map<String, Object> line = new Map<String, Object>{ 'sku' => SKU, 'shipped' => shipped };
        if (received != null) {
            line.put('received', received);
        }
        return NFY_IntegrationService.process('inbound.update', 'ODOO_SHOP', JSON.serialize(new Map<String, Object>{
            'inboundId' => 'ODOO-' + ref, 'eventId' => 'ODOO-' + ref + ':' + status + '@' + version, 'status' => status,
            'type' => '3PL ASN', 'from' => 'MAIN', 'to' => 'SM-PA1', 'eta' => String.valueOf(Date.today().addDays(3)),
            'date' => String.valueOf(Date.today()), 'lines' => new List<Object>{ line }
        }), 'j-inb', 'Workato');
    }

    private static Decimal inTransit(String warehouseCode) {
        Id productId = [SELECT Id FROM Product2 WHERE ProductCode = :SKU AND NFY_Demo__c = true LIMIT 1].Id;
        Id locId = NFY_Ref.location(warehouseCode, 'TRANSIT').Id;
        List<TC_Inventory_Balance__c> b = [SELECT Available_Quantity__c FROM TC_Inventory_Balance__c WHERE Product__c = :productId AND Location__c = :locId];
        return b.isEmpty() ? 0 : b[0].Available_Quantity__c;
    }

    /** Odoo: transfer Main → transit (6), receipt of 4 at PA1, then the last 2 in a backorder. */
    @IsTest
    static void odooTransferThroughTransitWithPartialReceipts() {
        System.runAs(accountant()) {
            send(new Map<String, Object>{ 'moveId' => 'ODOO-MOVE-900', 'reason' => 'receipt', 'to' => 'MAIN', 'qty' => 20 });
            Decimal main0 = available('MAIN');
            Decimal pa10 = available('SM-PA1');
            Test.startTest();
            NFY_IntegrationService.Result shipped = inbound('NFM/INT/00090', 'IN_TRANSIT', 'NFM/INT/00090 2026-11-17 14:00:00', 6, null);
            Decimal mainAfterShip = available('MAIN');
            Decimal transitAfterShip = inTransit('SM-PA1');
            NFY_IntegrationService.Result part = inbound('NFM/INT/00090', 'RECEIVING', 'NFM/INT/00091 2026-11-17 15:00:00', 6, 4);
            NFY_IntegrationService.Result repeat = inbound('NFM/INT/00090', 'RECEIVING', 'NFM/INT/00091 2026-11-17 15:00:00', 6, 4);
            NFY_IntegrationService.Result rest = inbound('NFM/INT/00090', 'RECEIVED', 'NFM/INT/00092 2026-11-17 16:00:00', 6, 6);
            Test.stopTest();

            System.assert(shipped.success, shipped.message);
            System.assertEquals(main0 - 6, mainAfterShip, 'Leaves Main when shipped');
            System.assertEquals(6, transitAfterShip, 'Sits in PA1 In Transit');
            System.assert(part.success, part.message);
            System.assertEquals('Duplicate skipped', repeat.status);
            System.assert(rest.success, rest.message);
            System.assertEquals(pa10 + 6, available('SM-PA1'));
            System.assertEquals(0, inTransit('SM-PA1'));
            NFY_Inbound_Shipment__c ib = [SELECT Status__c, Type__c, (SELECT Quantity_Shipped__c, Quantity_Received__c FROM Lines__r) FROM NFY_Inbound_Shipment__c WHERE External_Id__c = 'ODOO-NFM/INT/00090'];
            System.assertEquals('Closed', ib.Status__c);
            System.assertEquals('3PL ASN', ib.Type__c);
            System.assertEquals(6, ib.Lines__r[0].Quantity_Received__c);
            System.assertEquals(0, [SELECT COUNT() FROM NFY_Inventory_Recon__c WHERE Inbound_Shipment__c = :ib.Id]);
        }
    }

    /** A transfer closed short in Odoo leaves the gap in transit and opens a reconciliation. */
    @IsTest
    static void odooTransferClosedShortOpensReconciliation() {
        System.runAs(accountant()) {
            send(new Map<String, Object>{ 'moveId' => 'ODOO-MOVE-901', 'reason' => 'receipt', 'to' => 'MAIN', 'qty' => 10 });
            Test.startTest();
            inbound('NFM/INT/00095', 'IN_TRANSIT', 'NFM/INT/00095 v1', 3, null);
            NFY_IntegrationService.Result closed = inbound('NFM/INT/00095', 'RECEIVED', 'NFM/INT/00096 v1', 3, 2);
            Test.stopTest();
            System.assert(closed.success, closed.message);
            System.assert(closed.message.contains('reconciliation'), closed.message);
            System.assertEquals(1, inTransit('SM-PA1'), 'The missing unit stays in transit');
            System.assertEquals(1, [SELECT COUNT() FROM NFY_Inventory_Recon__c WHERE Inbound_Shipment__r.External_Id__c = 'ODOO-NFM/INT/00095']);
        }
    }

    @IsTest
    static void receiptAddsStockAndPostsToVouchersPayable() {
        System.runAs(accountant()) {
            Decimal before = available('MAIN');
            Test.startTest();
            NFY_IntegrationService.Result r = send(new Map<String, Object>{ 'moveId' => 'ODOO-MOVE-1', 'reason' => 'receipt', 'to' => 'MAIN', 'reference' => 'WH/IN/00001' });
            NFY_IntegrationService.Result again = send(new Map<String, Object>{ 'moveId' => 'ODOO-MOVE-1', 'reason' => 'receipt', 'to' => 'MAIN' });
            Test.stopTest();

            System.assert(r.success, r.message);
            System.assertEquals(before + 10, available('MAIN'));
            System.assertEquals('Duplicate skipped', again.status);
            TC_Inbound_Inventory_Movement__c m = [SELECT Type__c, Quantity__c, Unit_Cost__c, Credit_GL_Account__c,
                                                      NFY_Source_System__c, NFY_Source_Record_Id__c, NFY_Last_Sync_Log__c FROM TC_Inbound_Inventory_Movement__c
                                                  WHERE Inventory_Balance__c = :r.recordId ORDER BY CreatedDate DESC, Id DESC LIMIT 1];
            System.assertEquals('Odoo', m.NFY_Source_System__c, 'The movement records the system it came from');
            System.assertEquals('MOVE-1', m.NFY_Source_Record_Id__c);
            System.assertEquals(r.logId, m.NFY_Last_Sync_Log__c);
            System.assertEquals('Accounting', m.Type__c);
            System.assertEquals(10, m.Quantity__c);
            System.assertEquals(40, m.Unit_Cost__c);
            Id ledger = TC_AccountingContext.getDefaultLedgerId();
            System.assertEquals(TC_AccountingContext.getGLDefault(ledger, TC_AccountingContext.VOUCHERS_PAYABLE), m.Credit_GL_Account__c);
            System.assertEquals('Inventory', [SELECT Entity__c FROM NFY_Sync_Log__c WHERE Id = :r.logId].Entity__c);
        }
    }

    @IsTest
    static void countDecreaseRemovesStockAndRefusesTooMuch() {
        System.runAs(accountant()) {
            Decimal before = available('MAIN');
            Test.startTest();
            NFY_IntegrationService.Result down = send(new Map<String, Object>{ 'moveId' => 'ODOO-MOVE-2', 'reason' => 'adjustment', 'from' => 'MAIN', 'qty' => 3 });
            NFY_IntegrationService.Result tooMuch = send(new Map<String, Object>{ 'moveId' => 'ODOO-MOVE-3', 'reason' => 'scrap', 'from' => 'MAIN', 'qty' => before + 1000 });
            Test.stopTest();

            System.assert(down.success, down.message);
            System.assertEquals(before - 3, available('MAIN'));
            TC_Outbound_Inventory_Movement__c m = [SELECT Type__c, Debit_GL_Account__c FROM TC_Outbound_Inventory_Movement__c
                                                   WHERE Inventory_Balance__c = :down.recordId ORDER BY CreatedDate DESC, Id DESC LIMIT 1];
            System.assertEquals('Accounting', m.Type__c);
            System.assertEquals(TC_AccountingContext.getGLDefault(TC_AccountingContext.getDefaultLedgerId(), 'Inventory_Variance'), m.Debit_GL_Account__c);
            System.assertEquals('Failed', tooMuch.status);
            System.assertEquals('Stock', [SELECT Error_Category__c FROM NFY_Sync_Log__c WHERE Id = :tooMuch.logId].Error_Category__c);
            System.assertEquals(before - 3, available('MAIN'));
        }
    }

    @IsTest
    static void transferMovesStockBetweenWarehouses() {
        System.runAs(accountant()) {
            Decimal mainBefore = available('MAIN');
            Decimal pa1Before = available('SM-PA1');
            Test.startTest();
            NFY_IntegrationService.Result t = send(new Map<String, Object>{ 'moveId' => 'ODOO-MOVE-4', 'from' => 'MAIN', 'to' => 'SM-PA1', 'qty' => 4 });
            NFY_IntegrationService.Result same = send(new Map<String, Object>{ 'moveId' => 'ODOO-MOVE-5', 'from' => 'MAIN', 'to' => 'MAIN', 'qty' => 4 });
            Test.stopTest();

            System.assert(t.success, t.message);
            System.assertEquals(mainBefore - 4, available('MAIN'));
            System.assertEquals(pa1Before + 4, available('SM-PA1'));
            System.assert(same.success, same.message);
            System.assert(same.message.contains('No stock change'), same.message);
            System.assertEquals(mainBefore - 4, available('MAIN'));
        }
    }

    @IsTest
    static void refusesWhatSalesforceCannotKeep() {
        System.runAs(accountant()) {
            Product2 service = new Product2(Name = 'Gift wrap', ProductCode = 'NFY-WRAP-T', IsActive = true, NFY_Demo__c = true, TC_Inventory_Product__c = false);
            insert service;
            Test.startTest();
            NFY_IntegrationService.Result untracked = send(new Map<String, Object>{ 'moveId' => 'ODOO-MOVE-6', 'sku' => 'NFY-WRAP-T', 'to' => 'MAIN', 'reason' => 'receipt' });
            NFY_IntegrationService.Result noSide = send(new Map<String, Object>{ 'moveId' => 'ODOO-MOVE-7', 'reason' => 'receipt' });
            NFY_IntegrationService.Result badWh = send(new Map<String, Object>{ 'moveId' => 'ODOO-MOVE-8', 'to' => 'NOWHERE', 'reason' => 'receipt' });
            NFY_IntegrationService.Result badReason = send(new Map<String, Object>{ 'moveId' => 'ODOO-MOVE-9', 'to' => 'MAIN', 'reason' => 'gift' });
            NFY_IntegrationService.Result noQty = send(new Map<String, Object>{ 'moveId' => 'ODOO-MOVE-10', 'to' => 'MAIN', 'qty' => 0 });
            NFY_IntegrationService.Result badCost = send(new Map<String, Object>{ 'moveId' => 'ODOO-MOVE-11', 'to' => 'MAIN', 'unitCost' => 'abc' });
            NFY_IntegrationService.Result defaultCost = send(new Map<String, Object>{ 'moveId' => 'ODOO-MOVE-12', 'to' => 'MAIN', 'unitCost' => null, 'reason' => null });
            Test.stopTest();

            System.assertEquals('Failed', untracked.status);
            System.assert(untracked.message.contains('Track Inventory'), untracked.message);
            System.assertEquals('Failed', noSide.status);
            System.assertEquals('Failed', badWh.status);
            System.assertEquals('Failed', badReason.status);
            System.assertEquals('Failed', noQty.status);
            System.assertEquals('Failed', badCost.status);
            System.assert(defaultCost.success, defaultCost.message);
            System.assert(defaultCost.message.contains('adjustment'), defaultCost.message);
        }
    }
}