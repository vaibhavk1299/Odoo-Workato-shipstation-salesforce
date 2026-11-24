/**
 * Customer payments from the channel (payment.received / payment.reversed): one TC cash receipt per payment,
 * applied to the order's billing (or held until the order is billed), never recorded twice, and reversible.
 */
@IsTest
private class NFY_Payment_Test {

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

    private static void order(String orderNo) {
        System.assert(NFY_IntegrationService.process('order.upsert', 'ODOO_SHOP', JSON.serialize(new Map<String, Object>{
            'orderNumber' => orderNo, 'channel' => 'Odoo', 'orderDate' => String.valueOf(Date.today()), 'shipFrom' => 'MAIN', 'allowFallback' => true,
            'tax' => 0, 'freight' => 0,
            'customer' => new Map<String, Object>{ 'externalId' => 'ODOO-PAYT-1', 'name' => 'Paying Buyer', 'email' => 'payer@example.com', 'city' => 'Austin' },
            'lines' => new List<Object>{ new Map<String, Object>{ 'sku' => SKU, 'qty' => 1, 'price' => 100 } }
        }), 'pt-order', 'Workato').success, 'order accepted');
    }

    private static void ship(String orderNo, Integer id) {
        Map<String, Object> shipment = new Map<String, Object>{ 'shipmentId' => id, 'orderNumber' => orderNo, 'trackingNumber' => '1ZPAYT' + id,
            'carrierCode' => 'ups', 'shipDate' => String.valueOf(Date.today()), 'voided' => false };
        System.assert(NFY_IntegrationService.process('shipstation.notify', 'SHIPSTATION', JSON.serialize(new Map<String, Object>{
            'resourceType' => 'SHIP_NOTIFY', 'body' => JSON.serialize(new Map<String, Object>{ 'shipments' => new List<Object>{ shipment } }), 'jobId' => 'pt-ss'
        }), 'pt-ss', 'Workato').success, 'shipment accepted');
    }

    private static NFY_IntegrationService.Result pay(String extId, String orderNo, Decimal amount) {
        return NFY_IntegrationService.process('payment.received', 'ODOO_SHOP', JSON.serialize(new Map<String, Object>{
            'externalId' => extId, 'orderNumber' => orderNo, 'amount' => amount, 'date' => String.valueOf(Date.today()),
            'method' => 'Manual Payment (Bank)', 'reference' => 'PBNK1/' + extId, 'memo' => orderNo
        }), 'pt-' + extId, 'Workato');
    }

    private static TC_Billing__c billingOf(String orderNo) {
        Id soId = [SELECT Id FROM TC_Sales_Order__c WHERE NFY_External_Order_Id__c = :orderNo].Id;
        return [SELECT Id, Total__c, Balance__c, Received_Amount__c FROM TC_Billing__c WHERE Sales_Order__c = :soId AND Status__c = 'Posted' LIMIT 1];
    }

    private static TC_Cash_Receipt__c receipt(String extId) {
        return [SELECT Id, Status__c, Amount__c, Balance__c, Payment_Type__c, NFY_Sales_Order__c FROM TC_Cash_Receipt__c WHERE NFY_External_Id__c = :extId];
    }

    @IsTest
    static void prepaymentIsHeldThenAppliedWhenBilled() {
        System.runAs(accountant()) {
            Test.startTest();
            order('ODOO-S9600');
            NFY_IntegrationService.Result r = pay('ODOO-PAY-9600', 'ODOO-S9600', 100);
            System.assert(r.success, r.message);
            System.assert(r.message.contains('Not billed yet'), r.message);
            TC_Cash_Receipt__c before = receipt('ODOO-PAY-9600');
            System.assertEquals('Posted', before.Status__c);
            System.assertEquals(100, before.Balance__c, 'held unapplied until the order is billed');
            System.assertEquals('Electronic', before.Payment_Type__c);
            ship('ODOO-S9600', 9600);
            Test.stopTest();
            TC_Billing__c b = billingOf('ODOO-S9600');
            System.assertEquals(Math.min(100, b.Total__c), b.Received_Amount__c, 'applied when the billing posted');
            System.assertEquals(100 - Math.min(100, b.Total__c), receipt('ODOO-PAY-9600').Balance__c);
        }
    }

    @IsTest
    static void paymentAfterBillingIsAppliedAndNeverDoubled() {
        System.runAs(accountant()) {
            order('ODOO-S9601');
            Test.startTest();
            ship('ODOO-S9601', 9601);
            NFY_IntegrationService.Result r = pay('ODOO-PAY-9601', 'ODOO-S9601', 40);
            NFY_IntegrationService.Result again = pay('ODOO-PAY-9601', 'ODOO-S9601', 40);
            Test.stopTest();
            System.assert(r.success, r.message);
            System.assert(r.message.contains('applied to'), r.message);
            TC_Billing__c b = billingOf('ODOO-S9601');
            System.assertEquals(40, b.Received_Amount__c);
            System.assertEquals(b.Total__c - 40, b.Balance__c, 'partial payment leaves a balance');
            System.assertEquals('Duplicate skipped', again.status);
            System.assertEquals(1, [SELECT COUNT() FROM TC_Cash_Receipt__c WHERE NFY_External_Id__c = 'ODOO-PAY-9601']);
        }
    }

    @IsTest
    static void reversedPaymentReopensTheBilling() {
        System.runAs(accountant()) {
            order('ODOO-S9602');
            Test.startTest();
            ship('ODOO-S9602', 9602);
            System.assert(pay('ODOO-PAY-9602', 'ODOO-S9602', 30).success);
            NFY_IntegrationService.Result rev = NFY_IntegrationService.process('payment.reversed', 'ODOO_SHOP',
                JSON.serialize(new Map<String, Object>{ 'externalId' => 'ODOO-PAY-9602', 'reason' => 'rejected' }), 'pt-rev', 'Workato');
            Test.stopTest();
            System.assert(rev.success, rev.message);
            TC_Billing__c b = billingOf('ODOO-S9602');
            System.assertEquals(0, b.Received_Amount__c == null ? 0 : b.Received_Amount__c, 'application removed');
            System.assertEquals(b.Total__c, b.Balance__c);
            System.assertNotEquals('Posted', receipt('ODOO-PAY-9602').Status__c, 'receipt unposted');
        }
    }

    @IsTest
    static void paymentForAnUnknownOrderWaitsForRetry() {
        System.runAs(accountant()) {
            NFY_IntegrationService.Result r = pay('ODOO-PAY-9603', 'ODOO-NOPE', 10);
            System.assert(!r.success);
            System.assert(r.message.contains('Sync the order first'), r.message);
            NFY_IntegrationService.Result noOrder = NFY_IntegrationService.process('payment.received', 'ODOO_SHOP',
                JSON.serialize(new Map<String, Object>{ 'externalId' => 'ODOO-PAY-9604', 'amount' => 10 }), 'pt-none', 'Workato');
            System.assert(noOrder.message.contains('no order number'), noOrder.message);
        }
    }

    @IsTest
    static void cancellingAPaymentThatNeverSyncedClosesItsFailures() {
        System.runAs(accountant()) {
            NFY_IntegrationService.Result noOrder = NFY_IntegrationService.process('payment.received', 'ODOO_SHOP',
                JSON.serialize(new Map<String, Object>{ 'externalId' => 'ODOO-PAY-9620', 'amount' => 126, 'memo' => 'SO-01420' }), 'pt-dup', 'Workato');
            System.assert(!noOrder.success, 'a payment without an order number fails');
            NFY_IntegrationService.Result rev = NFY_IntegrationService.process('payment.reversed', 'ODOO_SHOP',
                JSON.serialize(new Map<String, Object>{ 'externalId' => 'ODOO-PAY-9620', 'reason' => 'Payment canceled in Odoo' }), 'pt-dup-rev', 'Workato');
            System.assert(rev.success, rev.message);
            System.assert(rev.message.contains('Nothing to reverse'), rev.message);
            NFY_Sync_Log__c failed = [SELECT Resolved__c, Retry_Status__c FROM NFY_Sync_Log__c
                WHERE External_Id__c = 'ODOO-PAY-9620' AND Event_Type__c = 'payment.received' LIMIT 1];
            System.assert(failed.Resolved__c, 'the failure it left is closed');
            System.assertEquals('Superseded', failed.Retry_Status__c);
            System.assertEquals(0, [SELECT COUNT() FROM TC_Cash_Receipt__c WHERE NFY_External_Id__c = 'ODOO-PAY-9620'], 'no cash recorded');

            NFY_IntegrationService.Result unknown = NFY_IntegrationService.process('payment.reversed', 'ODOO_SHOP',
                JSON.serialize(new Map<String, Object>{ 'externalId' => 'ODOO-PAY-9621' }), 'pt-unknown-rev', 'Workato');
            System.assert(!unknown.success, 'a reversal with no payment and no failure on record still waits for a retry');
        }
    }

    private static NFY_IntegrationService.Result snapshot(String id, List<Object> payments) {
        return NFY_IntegrationService.process('payment.snapshot', 'ODOO_SHOP', JSON.serialize(new Map<String, Object>{
            'snapshotId' => id, 'externalIdPrefix' => 'ODOO-PAY-',
            'from' => System.now().addHours(-1).formatGmt('yyyy-MM-dd HH:mm:ss'), 'to' => System.now().addHours(1).formatGmt('yyyy-MM-dd HH:mm:ss'),
            'payments' => payments
        }), 'pt-' + id, 'Workato');
    }

    private static Map<String, Object> odooPayment(String extId, String state, Decimal amount, String orderNo) {
        return new Map<String, Object>{ 'externalId' => extId, 'state' => state, 'amount' => amount, 'orderNumber' => orderNo,
            'date' => String.valueOf(Date.today()), 'method' => 'Manual Payment (Bank)', 'reference' => 'PBNK1/' + extId };
    }

    @IsTest
    static void reconciliationRepairsMissedPaymentsAndReversals() {
        System.runAs(accountant()) {
            order('ODOO-S9610');
            Test.startTest();
            System.assert(pay('ODOO-PAY-9610B', 'ODOO-S9610', 15).success);
            NFY_IntegrationService.Result r = snapshot('SNAP-1', new List<Object>{
                odooPayment('ODOO-PAY-9610B', 'canceled', 15, 'ODOO-S9610'),   // cancelled in Odoo, cancel event lost
                odooPayment('ODOO-PAY-9610C', 'paid', 10, 'ODOO-S9610')        // paid in Odoo, payment event lost
            });
            Test.stopTest();
            System.assert(r.success, r.message);
            System.assert(r.message.contains('ODOO-PAY-9610C recorded'), r.message);
            System.assert(r.message.contains('reversed'), r.message);
            System.assert(r.message.contains('Everything matches'), r.message);
            System.assertNotEquals('Posted', receipt('ODOO-PAY-9610B').Status__c);
            System.assertEquals('Posted', receipt('ODOO-PAY-9610C').Status__c);
            System.assertEquals(10, receipt('ODOO-PAY-9610C').Balance__c, 'recorded; applied once the order is billed');
            System.assertEquals(0, [SELECT COUNT() FROM NFY_Sync_Log__c WHERE Event_Type__c = 'payment.reconcile']);
        }
    }

    @IsTest
    static void differencesAreReportedAndClearWhenMatched() {
        System.runAs(accountant()) {
            order('ODOO-S9611');
            Test.startTest();
            System.assert(pay('ODOO-PAY-9611A', 'ODOO-S9611', 20).success);
            System.assert(pay('ODOO-PAY-9611E', 'ODOO-S9611', 5).success);
            NFY_IntegrationService.Result first = snapshot('SNAP-2', new List<Object>{ odooPayment('ODOO-PAY-9611A', 'paid', 21, 'ODOO-S9611') });
            System.assert(first.success, first.message);
            System.assert(first.message.contains('2 difference(s)'), first.message);
            Map<String, NFY_Sync_Log__c> open = new Map<String, NFY_Sync_Log__c>();
            for (NFY_Sync_Log__c l : [SELECT External_Id__c, Error_Message__c, Status__c, Resolved__c FROM NFY_Sync_Log__c WHERE Event_Type__c = 'payment.reconcile']) {
                open.put(l.External_Id__c, l);
            }
            System.assert(open.get('ODOO-PAY-9611A').Error_Message__c.contains('21.00'), 'amount difference');
            System.assert(open.get('ODOO-PAY-9611E').Error_Message__c.contains('did not report'), 'only in Salesforce');
            NFY_IntegrationService.Result again = snapshot('SNAP-3', new List<Object>{ odooPayment('ODOO-PAY-9611A', 'paid', 20, 'ODOO-S9611') });
            Test.stopTest();
            System.assert(again.success, again.message);
            System.assertEquals(true, [SELECT Resolved__c FROM NFY_Sync_Log__c WHERE Event_Type__c = 'payment.reconcile' AND External_Id__c = 'ODOO-PAY-9611A'].Resolved__c,
                'cleared once the amounts match');
            System.assertEquals(1, [SELECT COUNT() FROM NFY_Sync_Log__c WHERE Event_Type__c = 'payment.reconcile' AND Resolved__c = false],
                'the Salesforce-only receipt stays open, not duplicated');
        }
    }

    private static NFY_IntegrationService.Result refund(String extId, String orderNo, Decimal amount) {
        return NFY_IntegrationService.process('payment.refunded', 'ODOO_SHOP', JSON.serialize(new Map<String, Object>{
            'externalId' => extId, 'orderNumber' => orderNo, 'amount' => amount, 'date' => String.valueOf(Date.today()),
            'method' => 'Manual Payment (Bank)', 'reference' => 'PBNK1/' + extId, 'memo' => orderNo, 'direction' => 'outbound'
        }), 'pt-' + extId, 'Workato');
    }

    @IsTest
    static void refundOfABilledOrderCreditsTheInvoiceAndTakesCashOut() {
        System.runAs(accountant()) {
            order('ODOO-S9620');
            Test.startTest();
            ship('ODOO-S9620', 9620);
            Decimal total = billingOf('ODOO-S9620').Total__c;
            System.assert(pay('ODOO-PAY-9620', 'ODOO-S9620', total).success);
            NFY_IntegrationService.Result r = refund('ODOO-PAY-9621', 'ODOO-S9620', 30);
            NFY_IntegrationService.Result again = refund('ODOO-PAY-9621', 'ODOO-S9620', 30);
            Test.stopTest();
            System.assert(r.success, r.message);
            System.assert(r.message.contains('30.00 refunded'), r.message);
            TC_Cash_Receipt__c out = receipt('ODOO-PAY-9621');
            System.assertEquals('Posted', out.Status__c);
            System.assertEquals(-30, out.Amount__c, 'money out is a negative receipt');
            TC_Billing__c cm = [SELECT Total__c, Balance__c, Status__c FROM TC_Billing__c WHERE PO_Number__c = 'ODOO-PAY-9621'];
            System.assertEquals(-30, cm.Total__c);
            System.assertEquals(0, cm.Balance__c, 'credit memo fully applied to the invoice');
            TC_Billing__c inv = billingOf('ODOO-S9620');
            System.assertEquals(0, inv.Balance__c, 'invoice stays settled: cash plus credit');
            System.assertEquals(total - 30, inv.Received_Amount__c, '30 of cash taken back off the invoice');
            System.assertEquals(30, receipt('ODOO-PAY-9620').Balance__c, 'that cash is what left the bank');
            System.assertEquals('Duplicate skipped', again.status);
            System.assertEquals(1, [SELECT COUNT() FROM TC_Cash_Receipt__c WHERE NFY_External_Id__c = 'ODOO-PAY-9621']);
        }
    }

    @IsTest
    static void refundBeforeShippingUsesTheUnappliedCash() {
        System.runAs(accountant()) {
            order('ODOO-S9622');
            Test.startTest();
            System.assert(pay('ODOO-PAY-9622', 'ODOO-S9622', 100).success);
            NFY_IntegrationService.Result r = refund('ODOO-PAY-9623', 'ODOO-S9622', 100);
            System.assert(r.success, r.message);
            System.assert(r.message.contains('from unapplied cash'), r.message);
            System.assertEquals(0, [SELECT COUNT() FROM TC_Billing__c WHERE PO_Number__c = 'ODOO-PAY-9623'], 'no credit memo without an invoice');
            ship('ODOO-S9622', 9622);
            Test.stopTest();
            TC_Billing__c inv = billingOf('ODOO-S9622');
            System.assertEquals(0, inv.Received_Amount__c == null ? 0 : inv.Received_Amount__c, 'refunded cash is not applied when the order is billed');
            System.assertEquals(inv.Total__c, inv.Balance__c);
        }
    }

    @IsTest
    static void refundLargerThanThePaymentWaitsForRetry() {
        System.runAs(accountant()) {
            order('ODOO-S9624');
            Test.startTest();
            System.assert(pay('ODOO-PAY-9624', 'ODOO-S9624', 10).success);
            NFY_IntegrationService.Result r = refund('ODOO-PAY-9625', 'ODOO-S9624', 50);
            Test.stopTest();
            System.assert(!r.success);
            System.assert(r.message.contains('more than the 10.00 received'), r.message);
            System.assertEquals(0, [SELECT COUNT() FROM TC_Cash_Receipt__c WHERE NFY_External_Id__c = 'ODOO-PAY-9625']);
        }
    }

    @IsTest
    static void cancelledRefundPutsThePaymentBack() {
        System.runAs(accountant()) {
            order('ODOO-S9626');
            Test.startTest();
            ship('ODOO-S9626', 9626);
            Decimal total = billingOf('ODOO-S9626').Total__c;
            System.assert(pay('ODOO-PAY-9626', 'ODOO-S9626', total).success);
            System.assert(refund('ODOO-PAY-9627', 'ODOO-S9626', 20).success);
            // The cancellation arrives later as its own event (own transaction), as from Workato.
            System.enqueueJob(new ReverseJob('ODOO-PAY-9627'));
            Test.stopTest();
            NFY_Sync_Log__c rev = [SELECT Status__c, Response__c, Error_Message__c FROM NFY_Sync_Log__c WHERE Event_Type__c = 'payment.reversed' AND External_Id__c = 'ODOO-PAY-9627'];
            System.assertEquals('Success', rev.Status__c, 'reversal log: ' + rev.Error_Message__c);
            System.assert(rev.Response__c.contains('(refund) reversed'), rev.Response__c);
            System.assertNotEquals('Posted', receipt('ODOO-PAY-9627').Status__c);
            System.assertNotEquals('Posted', [SELECT Status__c FROM TC_Billing__c WHERE PO_Number__c = 'ODOO-PAY-9627'].Status__c, 'credit memo withdrawn');
            TC_Billing__c inv = billingOf('ODOO-S9626');
            System.assertEquals(total, inv.Received_Amount__c, 'the payment is applied in full again');
            System.assertEquals(0, inv.Balance__c);
            System.assertEquals(0, receipt('ODOO-PAY-9626').Balance__c);
        }
    }

    public class ReverseJob implements Queueable {
        private final String extId;
        public ReverseJob(String extId) {
            this.extId = extId;
        }
        public void execute(QueueableContext ctx) {
            NFY_IntegrationService.process('payment.reversed', 'ODOO_SHOP',
                JSON.serialize(new Map<String, Object>{ 'externalId' => extId, 'reason' => 'Payment canceled in Odoo' }), 'pt-rev-' + extId, 'Workato');
        }
    }

    @IsTest
    static void reconciliationRecordsAMissedRefund() {
        System.runAs(accountant()) {
            order('ODOO-S9628');
            Test.startTest();
            System.assert(pay('ODOO-PAY-9628', 'ODOO-S9628', 40).success);
            Map<String, Object> lost = odooPayment('ODOO-PAY-9629', 'paid', 15, 'ODOO-S9628');
            lost.put('direction', 'outbound');
            Map<String, Object> inbound = odooPayment('ODOO-PAY-9628', 'paid', 40, 'ODOO-S9628');
            inbound.put('direction', 'inbound');
            NFY_IntegrationService.Result r = snapshot('SNAP-9', new List<Object>{ inbound, lost });
            NFY_IntegrationService.Result again = snapshot('SNAP-10', new List<Object>{ inbound, lost });
            Test.stopTest();
            System.assert(r.success, r.message);
            System.assert(r.message.contains('ODOO-PAY-9629 recorded'), r.message);
            System.assertEquals(-15, receipt('ODOO-PAY-9629').Amount__c);
            System.assert(again.message.contains('Everything matches'), 'the refund matches as a negative amount: ' + again.message);
        }
    }

    @IsTest
    static void paymentTypeFollowsTheMethod() {
        System.assertEquals('Check', NFY_IntegrationService.paymentType('Check', null));
        System.assertEquals('Electronic', NFY_IntegrationService.paymentType('Stripe', null));
        System.assertEquals('Electronic', NFY_IntegrationService.paymentType(null, 'pi_123'));
        System.assertEquals('Other', NFY_IntegrationService.paymentType('Cash', null));
    }
}