/**
 * Source-system tracking: an Odoo order through the Integration Service stamps origin and
 * last-sync fields on the order, its lines, account and contact; duplicates and failures are
 * classified on the log; the Integration Origin controller reads it all back.
 */
@IsTest
private class NFY_Origin_Test {

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
            insert new NFY_Integration_Flow__c(Name = '[Odoo to SFDC] - Sales Orders', Code__c = 'ODOO_SHOP-ORDER', System__c = s.Id,
                Entity__c = 'Order', Direction__c = 'Into Salesforce', Active__c = true, Workato_Recipe_Id__c = '408639');
        }
    }

    private static User accountant() {
        return [SELECT Id FROM User WHERE Username LIKE 'tc.accountant.%' ORDER BY CreatedDate DESC LIMIT 1];
    }

    private static String odooOrder(String orderNo, String sku) {
        return JSON.serialize(new Map<String, Object>{
            'orderNumber' => orderNo, 'channel' => 'Odoo', 'orderDate' => '2026-11-05', 'shipFrom' => 'MAIN', 'allowFallback' => true,
            'tax' => 0, 'freight' => 0,
            'customer' => new Map<String, Object>{ 'externalId' => 'ODOO-901', 'name' => 'Odoo Test Buyer', 'email' => 'odoo.test@example.com', 'city' => 'Atlanta' },
            'lines' => new List<Object>{ new Map<String, Object>{ 'sku' => sku, 'qty' => 1, 'price' => 100 } }
        });
    }

    @IsTest
    static void odooOrderStampsOriginEverywhere() {
        System.runAs(accountant()) {
            Test.startTest();
            NFY_IntegrationService.Result r = NFY_IntegrationService.process('order.upsert', 'ODOO_SHOP', odooOrder('ODOO-S9001', '840386208702'), 'j-test-1', 'Workato');
            Test.stopTest();
            System.assert(r.success, r.message);

            Order o = [SELECT Id, AccountId, BillToContactId, NFY_Source_System__c, NFY_Source_Record_Id__c, NFY_Last_Sync_Status__c, NFY_Last_Sync_Operation__c,
                           NFY_Sync_Count__c, NFY_Synced_Via__c, NFY_Last_Sync_Log__c, NFY_Last_Synced_At__c FROM Order WHERE NFY_External_Order_Id__c = 'ODOO-S9001'];
            System.assertEquals('Odoo', o.NFY_Source_System__c);
            System.assertEquals('S9001', o.NFY_Source_Record_Id__c);
            System.assertEquals('Success', o.NFY_Last_Sync_Status__c);
            System.assertEquals('Created', o.NFY_Last_Sync_Operation__c);
            System.assertEquals(1, o.NFY_Sync_Count__c);
            System.assert(o.NFY_Synced_Via__c.startsWith('Workato · job j-test-1'), o.NFY_Synced_Via__c);
            System.assertEquals(r.logId, o.NFY_Last_Sync_Log__c);
            System.assertNotEquals(null, o.NFY_Last_Synced_At__c);

            Account a = [SELECT NFY_Source_System__c, NFY_Source_Record_Id__c, NFY_Odoo_Partner_Id__c, NFY_Sync_Count__c FROM Account WHERE Id = :o.AccountId];
            System.assertEquals('Odoo', a.NFY_Source_System__c);
            System.assertEquals('901', a.NFY_Source_Record_Id__c);
            System.assertEquals('901', a.NFY_Odoo_Partner_Id__c);
            System.assertEquals(1, a.NFY_Sync_Count__c);

            Contact c = [SELECT NFY_Source_System__c, NFY_Source_Key__c FROM Contact WHERE Id = :o.BillToContactId];
            System.assertEquals('Odoo', c.NFY_Source_System__c);
            System.assertEquals('ODOO-901-CONTACT', c.NFY_Source_Key__c);

            NFY_Sync_Log__c log = [SELECT Operation__c, Retry_Status__c, Account__c, Error_Category__c FROM NFY_Sync_Log__c WHERE Id = :r.logId];
            System.assertEquals('Created', log.Operation__c);
            System.assertEquals('Not needed', log.Retry_Status__c);
            System.assertEquals(o.AccountId, log.Account__c);

            List<OrderItem> items = [SELECT NFY_Source_Key__c FROM OrderItem WHERE OrderId = :o.Id AND NFY_Source_Key__c != null];
            System.assertEquals(1, items.size());
            System.assertEquals('ODOO-S9001-L1', items[0].NFY_Source_Key__c);
        }
    }

    @IsTest
    static void duplicateAndFailureAreClassified() {
        System.runAs(accountant()) {
            Test.startTest();
            NFY_IntegrationService.Result first = NFY_IntegrationService.process('order.upsert', 'ODOO_SHOP', odooOrder('ODOO-S9002', '840386208702'), 'j-test-2', 'Workato');
            System.assert(first.success, first.message);
            NFY_IntegrationService.Result dup = NFY_IntegrationService.process('order.upsert', 'ODOO_SHOP', odooOrder('ODOO-S9002', '840386208702'), 'j-test-3', 'Workato');
            NFY_IntegrationService.Result bad = NFY_IntegrationService.process('order.upsert', 'ODOO_SHOP', odooOrder('ODOO-S9003', 'NO-SUCH-SKU'), 'j-test-4', 'Workato');
            Test.stopTest();

            System.assertEquals('Duplicate skipped', dup.status);
            System.assertEquals('Duplicate', [SELECT Operation__c FROM NFY_Sync_Log__c WHERE Id = :dup.logId].Operation__c);

            System.assertEquals('Failed', bad.status);
            NFY_Sync_Log__c l = [SELECT Operation__c, Error_Category__c, Retry_Status__c FROM NFY_Sync_Log__c WHERE Id = :bad.logId];
            System.assertEquals('Rejected', l.Operation__c);
            System.assertEquals('Mapping', l.Error_Category__c);
            System.assertEquals('Waiting for fix', l.Retry_Status__c);
            System.assertEquals(0, [SELECT COUNT() FROM Order WHERE NFY_External_Order_Id__c = 'ODOO-S9003']);

            NFY_Sync_Log__c fake = new NFY_Sync_Log__c(Event_Type__c = 'order.upsert', External_Id__c = 'ODOO-S9002', Source__c = 'Workato',
                Status__c = 'Failed', Received_At__c = System.now());
            insert fake;
            NFY_OriginService.stampFailure(fake);
            System.assertEquals('Failed', [SELECT NFY_Last_Sync_Status__c FROM Order WHERE NFY_External_Order_Id__c = 'ODOO-S9002'].NFY_Last_Sync_Status__c);
        }
    }

    @IsTest
    static void controllerReadsOriginAndRetries() {
        System.runAs(accountant()) {
            Test.startTest();
            NFY_IntegrationService.Result r = NFY_IntegrationService.process('order.upsert', 'ODOO_SHOP', odooOrder('ODOO-S9004', '840386208702'), 'j-test-5', 'Workato');
            NFY_IntegrationService.Result bad = NFY_IntegrationService.process('order.upsert', 'ODOO_SHOP', odooOrder('ODOO-S9005', 'NO-SUCH-SKU'), 'j-test-6', 'Workato');
            Test.stopTest();
            Order o = [SELECT Id, AccountId FROM Order WHERE NFY_External_Order_Id__c = 'ODOO-S9004'];

            NFY_IntegrationOriginController.Origin oo = NFY_IntegrationOriginController.getOrigin(o.Id);
            NFY_IntegrationOriginController.Origin ao = NFY_IntegrationOriginController.getOrigin(o.AccountId);
            NFY_IntegrationOriginController.LogRow lr = NFY_IntegrationOriginController.getLog(bad.logId);
            NFY_IntegrationService.Result again = NFY_IntegrationOriginController.retryLog(bad.logId);
            Boolean threw = false;
            try {
                NFY_IntegrationOriginController.retryLog(r.logId);
            } catch (AuraHandledException e) {
                threw = true;
            }

            System.assert(oo.integrated);
            System.assertEquals('Odoo', oo.sourceSystem);
            // The card shows only fields the viewer can read: the test user may not see the order number.
            Boolean keyVisible = Schema.SObjectType.Order.fields.NFY_External_Order_Id__c.isAccessible();
            System.assertEquals(keyVisible ? 'ODOO-S9004' : null, oo.sourceKey);
            System.assertEquals(r.logId, oo.lastLogId);
            System.assert(!oo.logs.isEmpty());
            System.assertEquals('https://app.trial.workato.com/recipes/408639/job/j-test-5', oo.workatoJobUrl);
            System.assertEquals('Odoo', ao.sourceSystem);
            System.assertEquals(1, ao.systemIds.size());
            System.assertEquals('Mapping', lr.errorCategory);
            System.assertEquals('Failed', again.status);
            System.assertEquals(2, again.attempts);
            System.assert(threw, 'Retrying a successful log is refused');
            System.assertEquals(false, NFY_IntegrationOriginController.getOrigin(null).integrated);
        }
    }

    @IsTest
    static void helpersClassifyAndMap() {
        System.assertEquals('Odoo', NFY_OriginService.systemValue('odoo_shop'));
        System.assertEquals(null, NFY_OriginService.systemValue(null));
        System.assertEquals('S1', NFY_OriginService.nativeId('ODOO-S1'));
        System.assertEquals('#SPFY1', NFY_OriginService.nativeId('#SPFY1'));
        System.assertEquals(null, NFY_OriginService.nativeId(null));
        System.assertEquals('No change', NFY_OriginService.operationFor('Order', 'X is already in Salesforce.'));
        System.assertEquals('Updated', NFY_OriginService.operationFor('Shipment', 'shipped'));
        System.assertEquals('Dependency', NFY_OriginService.categorize('No Salesforce order matches the ShipStation order.'));
        System.assertEquals('Stock', NFY_OriginService.categorize('Only 52 of Nfinity Evolution 8 at Main; cannot move 240.'));
        System.assertEquals('Validation', NFY_OriginService.categorize('Unknown source system "X".'));
        System.assertEquals('Platform', NFY_OriginService.categorize('Apex CPU time limit exceeded'));
        System.assertEquals('Unknown', NFY_OriginService.categorize('Something odd'));
        System.assertEquals('Unknown', NFY_OriginService.categorize(null));
        System.assertEquals('Manual', NFY_OriginService.syncedVia(new NFY_Sync_Log__c()));
    }
}