/**
 * Keeps Order.NFY_Payment_Status__c and Order.NFY_Balance_Due__c in step with the order's TC billings.
 *
 * The TC model owns every money figure. TC_Billing__c.Received_Amount__c is a roll-up of the cash applied
 * to it and Balance__c is a formula (Total - received - adjustments - credit memos applied - write-offs), so
 * every payment, credit memo or posting re-saves the billing. NFY_BillingPaymentTrigger hands the touched
 * sales orders to this class, which reads the posted billings fresh and copies the result to the Order.
 *
 *   no posted invoice                        blank (not billed yet)
 *   posted credit memos cover the invoices   Credited
 *   open balance 0                           Paid
 *   open balance below the invoiced total    Partially Paid
 *   otherwise                                Unpaid
 */
public without sharing class NFY_PaymentStatusService {

    public static final String UNPAID = 'Unpaid';
    public static final String PARTIAL = 'Partially Paid';
    public static final String PAID = 'Paid';
    public static final String CREDITED = 'Credited';

    /** Fields whose change can move an order's payment status or balance. */
    private static final List<String> MONEY_FIELDS = new List<String>{
        'Status__c', 'Total__c', 'Received_Amount__c', 'Adjustment_Amount__c', 'Credit_Memo_Applied_Amount__c', 'Written_Off_Amount__c', 'Sales_Order__c'
    };

    /**
     * Sales orders of the billings that matter, for the trigger: posted billings inserted or restored,
     * deleted billings, and updates that change status, totals or applied amounts. Other saves
     * (lines being added to a draft, comments) cost nothing.
     */
    public static void refreshForBillings(List<TC_Billing__c> recs, Map<Id, TC_Billing__c> oldMap) {
        Set<Id> soIds = new Set<Id>();
        if (recs == null) {
            for (TC_Billing__c b : oldMap.values()) {
                soIds.add(b.Sales_Order__c);
            }
        } else {
            for (TC_Billing__c b : recs) {
                TC_Billing__c old = oldMap == null ? null : oldMap.get(b.Id);
                if (old == null) {
                    if (b.Status__c == 'Posted') {
                        soIds.add(b.Sales_Order__c);
                    }
                    continue;
                }
                for (String f : MONEY_FIELDS) {
                    if (b.get(f) != old.get(f)) {
                        soIds.add(b.Sales_Order__c);
                        soIds.add(old.Sales_Order__c);
                        break;
                    }
                }
            }
        }
        schedule(soIds);
    }

    /** Sales orders already queued in this transaction; the job reads fresh data when it runs, so one is enough. */
    private static Set<Id> queued = new Set<Id>();
    /** Tests set this to refresh in the same transaction. */
    @TestVisible
    private static Boolean runInline = false;
    /**
     * In tests the queued job runs inside the test's own limits, on top of the Order automation it triggers.
     * Tests of other features don't need payment status, so only tests that opt in run it.
     */
    @TestVisible
    private static Boolean enabledInTests = false;

    /**
     * Refreshes after the billing transaction commits, so posting, cash application and their Order
     * automation never share one set of limits. Falls back to an inline refresh when no queueable slot is left.
     */
    public static void schedule(Set<Id> salesOrderIds) {
        salesOrderIds.remove(null);
        if (Test.isRunningTest() && !enabledInTests) {
            return;
        }
        if (runInline) {
            refresh(salesOrderIds);
            return;
        }
        salesOrderIds.removeAll(queued);
        if (salesOrderIds.isEmpty()) {
            return;
        }
        if (Limits.getQueueableJobs() < Limits.getLimitQueueableJobs()) {
            queued.addAll(salesOrderIds);
            System.enqueueJob(new RefreshJob(salesOrderIds));
        } else {
            refresh(salesOrderIds);
        }
    }

    public class RefreshJob implements Queueable {
        private final Set<Id> salesOrderIds;
        public RefreshJob(Set<Id> salesOrderIds) {
            this.salesOrderIds = salesOrderIds;
        }
        public void execute(QueueableContext ctx) {
            refresh(salesOrderIds);
        }
    }

    /** Recalculates the payment fields of the Orders behind these TC sales orders. */
    public static void refresh(Set<Id> salesOrderIds) {
        salesOrderIds.remove(null);
        if (salesOrderIds.isEmpty()) {
            return;
        }
        Set<Id> orderIds = new Set<Id>();
        for (TC_Sales_Order__c so : [SELECT NFY_Order__c FROM TC_Sales_Order__c WHERE Id IN :salesOrderIds AND NFY_Order__c != null]) {
            orderIds.add(so.NFY_Order__c);
        }
        if (orderIds.isEmpty()) {
            return;
        }
        // An Order normally has one TC sales order; sum across all of them in case there are more.
        Map<Id, Set<Id>> soByOrder = new Map<Id, Set<Id>>();
        for (TC_Sales_Order__c so : [SELECT Id, NFY_Order__c FROM TC_Sales_Order__c WHERE NFY_Order__c IN :orderIds]) {
            if (!soByOrder.containsKey(so.NFY_Order__c)) {
                soByOrder.put(so.NFY_Order__c, new Set<Id>());
            }
            soByOrder.get(so.NFY_Order__c).add(so.Id);
        }
        Set<Id> allSo = new Set<Id>();
        for (Set<Id> s : soByOrder.values()) {
            allSo.addAll(s);
        }
        Map<Id, List<TC_Billing__c>> billsBySo = new Map<Id, List<TC_Billing__c>>();
        for (TC_Billing__c b : [
            SELECT Id, Sales_Order__c, Total__c, Balance__c FROM TC_Billing__c
            WHERE Sales_Order__c IN :allSo AND Status__c = 'Posted'
        ]) {
            if (!billsBySo.containsKey(b.Sales_Order__c)) {
                billsBySo.put(b.Sales_Order__c, new List<TC_Billing__c>());
            }
            billsBySo.get(b.Sales_Order__c).add(b);
        }

        Map<Id, Order> current = new Map<Id, Order>([
            SELECT Id, NFY_Payment_Status__c, NFY_Balance_Due__c FROM Order WHERE Id IN :soByOrder.keySet()
        ]);
        List<Order> updates = new List<Order>();
        for (Id orderId : soByOrder.keySet()) {
            List<TC_Billing__c> bills = new List<TC_Billing__c>();
            for (Id soId : soByOrder.get(orderId)) {
                if (billsBySo.containsKey(soId)) {
                    bills.addAll(billsBySo.get(soId));
                }
            }
            Result r = evaluate(bills);
            Order o = current.get(orderId);
            if (o != null && (o.NFY_Payment_Status__c != r.status || o.NFY_Balance_Due__c != r.balanceDue)) {
                updates.add(new Order(Id = orderId, NFY_Payment_Status__c = r.status, NFY_Balance_Due__c = r.balanceDue));
            }
        }
        if (!updates.isEmpty()) {
            update updates;
        }
    }

    public class Result {
        public String status;
        public Decimal balanceDue;
    }

    /** Status and open balance from an order's posted billings. */
    @TestVisible
    static Result evaluate(List<TC_Billing__c> postedBills) {
        Decimal invoiced = 0;
        Decimal open = 0;
        Decimal creditTotal = 0;
        Boolean hasInvoice = false;
        for (TC_Billing__c b : postedBills) {
            Decimal total = b.Total__c == null ? 0 : b.Total__c;
            Decimal balance = b.Balance__c == null ? 0 : b.Balance__c;
            if (total > 0) {
                hasInvoice = true;
                invoiced += total;
                open += Math.max(balance, 0);
            } else if (total < 0) {
                creditTotal += -total;
            }
        }
        Result r = new Result();
        if (!hasInvoice) {
            return r;
        }
        r.balanceDue = open.setScale(2);
        if (creditTotal >= invoiced) {
            r.status = CREDITED;
        } else if (open <= 0) {
            r.status = PAID;
        } else if (open < invoiced) {
            r.status = PARTIAL;
        } else {
            r.status = UNPAID;
        }
        return r;
    }
}