/**
 * Order payment status follows the order's posted TC billings: blank before billing, Unpaid once
 * the invoice posts, Partially Paid and Paid as cash is applied, Credited when credit memos cover it.
 */
@IsTest
private class NFY_PaymentStatus_Test {

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

    private static void orderAndShip(String orderNo) {
        System.assert(NFY_IntegrationService.process('order.upsert', 'ODOO_SHOP', JSON.serialize(new Map<String, Object>{
            'orderNumber' => orderNo, 'channel' => 'Odoo', 'orderDate' => String.valueOf(Date.today()), 'shipFrom' => 'MAIN', 'allowFallback' => true,
            'tax' => 0, 'freight' => 0,
            'customer' => new Map<String, Object>{ 'externalId' => 'ODOO-PAY-1', 'name' => 'Payment Buyer', 'email' => 'pay@example.com', 'city' => 'Austin' },
            'lines' => new List<Object>{ new Map<String, Object>{ 'sku' => SKU, 'qty' => 1, 'price' => 100 } }
        }), 'pay-order', 'Workato').success, 'order accepted');
        Map<String, Object> shipment = new Map<String, Object>{ 'shipmentId' => 7701, 'orderNumber' => orderNo, 'trackingNumber' => '1ZPAY7701',
            'carrierCode' => 'ups', 'shipDate' => String.valueOf(Date.today()), 'voided' => false };
        System.assert(NFY_IntegrationService.process('shipstation.notify', 'SHIPSTATION', JSON.serialize(new Map<String, Object>{
            'resourceType' => 'SHIP_NOTIFY', 'body' => JSON.serialize(new Map<String, Object>{ 'shipments' => new List<Object>{ shipment } }), 'jobId' => 'pay-ss'
        }), 'pay-ss', 'Workato').success, 'shipment accepted');
    }

    private static Order orderOf(String orderNo) {
        return [SELECT Id, NFY_Payment_Status__c, NFY_Balance_Due__c, NFY_TC_Sales_Order__c FROM Order WHERE NFY_External_Order_Id__c = :orderNo];
    }

    private static void pay(TC_Billing__c b, Decimal amount, String ref) {
        TC_Cash_Receipt__c r = new TC_Cash_Receipt__c(Account__c = b.Customer__c, Amount__c = amount, Payment_Reference__c = ref, NFY_External_Id__c = ref,
            Receipt_Date__c = b.Date__c, Status__c = 'Approved', Payment_Type__c = 'Electronic', Bank_Account__c = NFY_Ref.gl('1000'), Ledger__c = b.Ledger__c);
        insert r;
        if ([SELECT Status__c FROM TC_Cash_Receipt__c WHERE Id = :r.Id].Status__c != 'Posted') {
            System.assert(TC_PostingEngine.post(new List<Id>{ r.Id })[0].isSuccess, 'receipt posts');
        }
        insert new TC_Billing_Cash_Receipt__c(Billing__c = b.Id, Cash_Receipt__c = r.Id, Applied_Amount__c = amount, Applied_Date__c = b.Date__c);
    }

    /** Orders and ships; the queued refresh runs at stopTest. Returns the posted billing. */
    private static TC_Billing__c billedOrder(String orderNo) {
        NFY_PaymentStatusService.enabledInTests = true;
        Test.startTest();
        orderAndShip(orderNo);
        Test.stopTest();
        Order o = orderOf(orderNo);
        TC_Billing__c b = [SELECT Id, Customer__c, Date__c, Ledger__c, Total__c, Balance__c, Status__c FROM TC_Billing__c WHERE Sales_Order__c = :o.NFY_TC_Sales_Order__c];
        System.assertEquals('Posted', b.Status__c, 'shipment bills and posts');
        System.assertEquals(NFY_PaymentStatusService.UNPAID, o.NFY_Payment_Status__c, 'billed, nothing paid');
        System.assertEquals(b.Total__c, o.NFY_Balance_Due__c);
        NFY_PaymentStatusService.runInline = true; // one startTest per test, so later refreshes run inline
        return b;
    }

    @IsTest
    static void partPaymentLeavesABalance() {
        System.runAs(accountant()) {
            TC_Billing__c b = billedOrder('ODOO-S9300');
            pay(b, 40, 'PAY-9300-1');
            Order o = orderOf('ODOO-S9300');
            System.assertEquals(NFY_PaymentStatusService.PARTIAL, o.NFY_Payment_Status__c, 'cash applied re-saves the billing');
            System.assertEquals(b.Total__c - 40, o.NFY_Balance_Due__c);
        }
    }

    @IsTest
    static void fullPaymentMarksPaid() {
        System.runAs(accountant()) {
            TC_Billing__c b = billedOrder('ODOO-S9301');
            pay(b, b.Total__c, 'PAY-9301-1');
            Order o = orderOf('ODOO-S9301');
            System.assertEquals(NFY_PaymentStatusService.PAID, o.NFY_Payment_Status__c);
            System.assertEquals(0, o.NFY_Balance_Due__c);
        }
    }

    @IsTest
    static void samePaymentCannotBeRecordedTwice() {
        System.runAs(accountant()) {
            Account a = new Account(Name = 'Dup Payer');
            insert a;
            insert new TC_Cash_Receipt__c(Account__c = a.Id, Amount__c = 10, Payment_Reference__c = 'P1', NFY_External_Id__c = 'STRIPE-ch_1',
                Receipt_Date__c = Date.today(), Status__c = 'Approved', Payment_Type__c = 'Electronic', Bank_Account__c = NFY_Ref.gl('1000'));
            Boolean blocked = false;
            try {
                insert new TC_Cash_Receipt__c(Account__c = a.Id, Amount__c = 10, Payment_Reference__c = 'P1', NFY_External_Id__c = 'stripe-CH_1',
                    Receipt_Date__c = Date.today(), Status__c = 'Approved', Payment_Type__c = 'Electronic', Bank_Account__c = NFY_Ref.gl('1000'));
            } catch (DmlException e) {
                blocked = e.getDmlType(0) == StatusCode.DUPLICATE_VALUE;
            }
            System.assert(blocked, 'External payment ID is unique, case-insensitive');
        }
    }

    @IsTest
    static void evaluateCoversEveryState() {
        System.assertEquals(null, NFY_PaymentStatusService.evaluate(new List<TC_Billing__c>()).status, 'not billed');
        System.assertEquals(null, NFY_PaymentStatusService.evaluate(new List<TC_Billing__c>()).balanceDue);
        // Total__c and Balance__c are formula and roll-up fields, so build the rows from JSON.
        List<TC_Billing__c> partly = (List<TC_Billing__c>) JSON.deserialize('[{"Total__c":100,"Balance__c":30}]', List<TC_Billing__c>.class);
        System.assertEquals(NFY_PaymentStatusService.PARTIAL, NFY_PaymentStatusService.evaluate(partly).status);
        System.assertEquals(30, NFY_PaymentStatusService.evaluate(partly).balanceDue);
        List<TC_Billing__c> unpaid = (List<TC_Billing__c>) JSON.deserialize('[{"Total__c":100,"Balance__c":100}]', List<TC_Billing__c>.class);
        System.assertEquals(NFY_PaymentStatusService.UNPAID, NFY_PaymentStatusService.evaluate(unpaid).status);
        List<TC_Billing__c> paid = (List<TC_Billing__c>) JSON.deserialize('[{"Total__c":100,"Balance__c":0},{"Total__c":50,"Balance__c":0}]', List<TC_Billing__c>.class);
        System.assertEquals(NFY_PaymentStatusService.PAID, NFY_PaymentStatusService.evaluate(paid).status);
        List<TC_Billing__c> credited = (List<TC_Billing__c>) JSON.deserialize('[{"Total__c":100,"Balance__c":0},{"Total__c":-100,"Balance__c":0}]', List<TC_Billing__c>.class);
        System.assertEquals(NFY_PaymentStatusService.CREDITED, NFY_PaymentStatusService.evaluate(credited).status);
    }
}