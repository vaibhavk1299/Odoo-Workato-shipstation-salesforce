@IsTest
private class NFY_CommandCenter_Test {

    private static NFY_Integration_System__c sys(String code, String category) {
        NFY_Integration_System__c s = new NFY_Integration_System__c(Name = code + ' test', Code__c = code, Category__c = category,
            Status__c = 'Planned', Mode__c = 'Polling');
        insert s;
        return s;
    }

    private static NFY_Integration_Flow__c flow(Id sysId, String code, Boolean active, String direction, String entity, String mode, String recipe) {
        return new NFY_Integration_Flow__c(Name = code, Code__c = code, System__c = sysId, Active__c = active,
            Direction__c = direction, Entity__c = entity, Mode__c = mode, Workato_Recipe_Id__c = recipe);
    }

    private static NFY_CommandCenterController.SystemRow row(String code) {
        for (NFY_CommandCenterController.SystemRow r : NFY_CommandCenterController.getSummary().systems) {
            if (r.code == code) return r;
        }
        return null;
    }

    @IsTest
    static void liveSystemIsDescribedFromItsFlowsAndLogsNotItsOwnFields() {
        NFY_Integration_System__c s = sys('TST_LIVE', 'Label system');
        insert new List<NFY_Integration_Flow__c>{
            flow(s.Id, 'TST_LIVE-SHIP', true, 'Into Salesforce', 'Shipment', 'Webhook', '9001'),
            flow(s.Id, 'TST_LIVE-ORDER', true, 'System to system', 'Order', 'Webhook', '9002'),
            flow(s.Id, 'TST_LIVE-INV', false, 'Into Salesforce', 'Inventory', 'Polling', null)
        };
        insert new NFY_Sync_Log__c(System__c = s.Id, Status__c = 'Success', Event_Type__c = 'shipment.created', Received_At__c = System.now().addMinutes(-5));

        Test.startTest();
        NFY_CommandCenterController.SystemRow r = row('TST_LIVE');
        Test.stopTest();

        System.assertEquals('Webhook', r.mode, 'Mode comes from the active flows, not the system record (Polling)');
        System.assertEquals('live', r.stage);
        System.assertEquals('ok', r.health);
        System.assertEquals('both', r.direction, 'Shipments come in, orders go out to the system');
        System.assertEquals('right', r.placement);
        System.assertEquals(2, r.flows);
        System.assertEquals(3, r.totalFlows);
        System.assertEquals(2, r.recipes);
        System.assertEquals(1, r.jobs24h);
        System.assertNotEquals(null, r.lastSync);
    }

    @IsTest
    static void plannedIdleAndUnmappedSystems() {
        NFY_Integration_System__c planned = sys('TST_PLAN', 'Sales channel');
        NFY_Integration_System__c idle = sys('TST_IDLE', 'Sales channel');
        sys('TST_NONE', '3PL / WMS');
        insert new List<NFY_Integration_Flow__c>{
            flow(planned.Id, 'TST_PLAN-ORDER', false, 'Into Salesforce', 'Order', 'Daily batch', null),
            flow(idle.Id, 'TST_IDLE-ORDER', true, 'Into Salesforce', 'Order', 'Webhook', '9003')
        };
        insert new NFY_Sync_Log__c(System__c = idle.Id, Status__c = 'Success', Event_Type__c = 'order.upsert', Received_At__c = System.now().addDays(-20));

        Test.startTest();
        NFY_CommandCenterController.SystemRow p = row('TST_PLAN');
        NFY_CommandCenterController.SystemRow i = row('TST_IDLE');
        NFY_CommandCenterController.SystemRow n = row('TST_NONE');
        Test.stopTest();

        System.assertEquals('planned', p.stage);
        System.assertEquals('planned', p.health);
        System.assertEquals('Daily batch', p.mode, 'A planned system shows its planned mode');
        System.assertEquals('left', p.placement);
        System.assertEquals('idle', i.stage, 'No event within the idle window');
        System.assertEquals('idle', i.health);
        System.assertEquals('unmapped', n.stage);
        System.assertEquals(null, n.mode);
    }

    @IsTest
    static void supersededFailuresDoNotCountAgainstHealth() {
        NFY_Integration_System__c s = sys('TST_SUP', 'Sales channel');
        insert flow(s.Id, 'TST_SUP-PRODUCT', true, 'Into Salesforce', 'Product', 'Webhook', '9005');
        insert new List<NFY_Sync_Log__c>{
            new NFY_Sync_Log__c(System__c = s.Id, Status__c = 'Failed', Resolved__c = true, Retry_Status__c = 'Superseded', Event_Type__c = 'product.upsert', Received_At__c = System.now()),
            new NFY_Sync_Log__c(System__c = s.Id, Status__c = 'Success', Event_Type__c = 'product.upsert', Received_At__c = System.now())
        };
        NFY_CommandCenterController.SystemRow r = row('TST_SUP');
        System.assertEquals(0, r.failed24h, 'A superseded half-saved state is not a failure');
        System.assertEquals(0, r.failureRate7d);
        System.assertEquals('ok', r.health);
        System.assertEquals(2, r.jobs24h, 'It still counts as an event received');
    }

    @IsTest
    static void openErrorsBeatFailureRate() {
        NFY_Integration_System__c s = sys('TST_ERR', 'Sales channel');
        insert flow(s.Id, 'TST_ERR-ORDER', true, 'Into Salesforce', 'Order', 'Webhook', '9004');
        insert new List<NFY_Sync_Log__c>{
            new NFY_Sync_Log__c(System__c = s.Id, Status__c = 'Failed', Resolved__c = true, Event_Type__c = 'order.upsert', Received_At__c = System.now()),
            new NFY_Sync_Log__c(System__c = s.Id, Status__c = 'Success', Event_Type__c = 'order.upsert', Received_At__c = System.now())
        };
        System.assertEquals('warning', row('TST_ERR').health, 'Resolved failures above 10% only call for watching');

        insert new NFY_Sync_Log__c(System__c = s.Id, Status__c = 'Failed', Resolved__c = false, Event_Type__c = 'order.upsert', Received_At__c = System.now());
        System.assertEquals('error', row('TST_ERR').health, 'An open failure needs action');
    }
}