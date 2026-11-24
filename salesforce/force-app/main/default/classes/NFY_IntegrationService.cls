/**
 * The one entry point for every event Nfinity's outside systems send (through Workato in
 * production, through the demo simulator on stage). Each call is logged first, checked for
 * duplicates, then processed in a single transaction that drives TC Accounting Wizard through
 * its own records and triggers. A failure rolls back everything except the log entry.
 *
 *   order.upsert        Account, Order, Opportunity (Shopify), TC Sales Order, allocation at ship-from
 *   shipment.created    TC Shipment for one ship-from; billing posted when the order is fully shipped
 *   inbound.update      FBA / 3PL / container inbound: transfers via In Transit, reconciliation on shortfall
 *   po.receipt          TC purchase order receipt at a location
 *   inventory.snapshot  external stock counts compared with TC
 *   return.received     return, restock if sellable, credit memo
 *   settlement.posted   cash receipt applied to billings, fees journal entry
 *   product.upsert      Product2 per variant from Odoo or Shopify (NFY_ProductSyncService)
 *   stock.adjusted      receipts, counts, scrap and transfers from the stock system (NFY_StockSyncService)
 *   shipstation.notify  ShipStation SHIP_NOTIFY / FULFILLMENT_SHIPPED, split into shipment.created events (NFY_ShipStationService)
 *   shopify.order       a raw Shopify orders/create body, mapped to order.upsert on arrival (NFY_ShopifyOrderMapper)
 */
public without sharing class NFY_IntegrationService {
    public class NFYException extends Exception {}

    public class Result {
        @AuraEnabled public Boolean success = false;
        @AuraEnabled public String status;
        @AuraEnabled public String message;
        @AuraEnabled public Id recordId;
        @AuraEnabled public String recordName;
        @AuraEnabled public Id logId;
        @AuraEnabled public String logName;
        @AuraEnabled public Integer attempts;
    }

    private class Outcome {
        Id recordId;
        String recordName;
        String message;
        Id orderId;
        Id salesOrderId;
        Id linkedOrderId;   // log link only: the order is not touched or re-stamped
        String operation;   // overrides the operation worked out from the message
        Outcome(Id recordId, String recordName, String message) {
            this.recordId = recordId;
            this.recordName = recordName;
            this.message = message;
        }
    }

    /** True while an event is being processed; the Order trigger ignores changes made here. */
    public static Boolean processing = false;

    /** The Integration Log entry of the event being processed, for records that link back to it as they are created. */
    public static Id currentLogId;

    public static final Map<String, String> EVENT_ENTITY = new Map<String, String>{
        'order.upsert' => 'Order', 'shipment.created' => 'Shipment', 'inbound.update' => 'Inbound', 'po.receipt' => 'PO Receipt',
        'inventory.snapshot' => 'Inventory', 'return.received' => 'Return', 'settlement.posted' => 'Settlement',
        'product.upsert' => 'Product', 'stock.adjusted' => 'Inventory', 'shipstation.notify' => 'Shipment',
        'shipstation.order.sent' => 'Order', 'order.cancelled' => 'Order',
        'payment.received' => 'Payment', 'payment.reversed' => 'Payment', 'payment.snapshot' => 'Payment', 'payment.reconcile' => 'Payment',
        'payment.refunded' => 'Payment'
    };

    private static final Map<String, String> EXTERNAL_KEY = new Map<String, String>{
        'order.upsert' => 'orderNumber', 'shipment.created' => 'shipmentId', 'inbound.update' => 'inboundId', 'po.receipt' => 'receiptId',
        'inventory.snapshot' => 'snapshotId', 'return.received' => 'rma', 'settlement.posted' => 'settlementId',
        'product.upsert' => 'eventId', 'stock.adjusted' => 'moveId', 'shipstation.order.sent' => 'orderNumber',
        'order.cancelled' => 'orderNumber', 'payment.received' => 'externalId', 'payment.reversed' => 'externalId',
        'payment.snapshot' => 'snapshotId', 'payment.reconcile' => 'externalId', 'payment.refunded' => 'externalId'
    };

    /** Events that only record a delivery between two other systems; everything else comes into Salesforce. */
    private static final Map<String, String> EVENT_DIRECTION = new Map<String, String>{
        'shipstation.order.sent' => 'System to system'
    };

    // ------------------------------------------------------------------ entry points

    public static Result process(String eventType, String source, String payloadJson, String jobId, String origin) {
        if (eventType == 'shopify.order') {
            // A raw Shopify order: mapped once here, then processed and logged as the order.upsert it becomes.
            Map<String, Object> raw = parse(payloadJson);
            if (raw != null) {
                payloadJson = JSON.serialize(NFY_ShopifyOrderMapper.toOrder(raw));
            }
            eventType = 'order.upsert';
        }
        NFY_Integration_System__c sys = NFY_Ref.system(source);
        String entity = EVENT_ENTITY.get(eventType);
        NFY_Integration_Flow__c flow = NFY_Ref.flow(source, entity);
        Map<String, Object> payload = parse(payloadJson);
        NFY_Sync_Log__c log = new NFY_Sync_Log__c(
            Event_Type__c = eventType, Entity__c = entity, Status__c = 'Received',
            Direction__c = EVENT_DIRECTION.containsKey(eventType) ? EVENT_DIRECTION.get(eventType) : 'Into Salesforce',
            Payload__c = payloadJson == null ? null : payloadJson.left(131072), Attempts__c = 0, Workato_Job_Id__c = jobId,
            Source__c = origin == null ? 'Manual' : origin, Received_At__c = System.now(),
            System__c = sys == null ? null : sys.Id, Flow__c = flow == null ? null : flow.Id
        );
        if (payload != null && EXTERNAL_KEY.containsKey(eventType)) {
            log.External_Id__c = str(payload.get(EXTERNAL_KEY.get(eventType)));
            // One inbound shipment sends several status updates; each status is its own event.
            if (eventType == 'inbound.update' && log.External_Id__c != null && payload.get('status') != null) {
                log.External_Id__c += ':' + str(payload.get('status')).toUpperCase();
            }
            // A sender that versions its updates (Odoo: "<inbound>:<STATUS>@<transfer> <write_date>") passes the
            // version as eventId, so a second partial receipt is a new event, not a repeat of the first.
            if (eventType == 'inbound.update' && payload.get('eventId') != null) {
                log.External_Id__c = str(payload.get('eventId')).left(255);
            }
            // Each version of a ShipStation order is its own event; the same version sent twice is a duplicate.
            if (eventType == 'shipstation.order.sent' && log.External_Id__c != null) {
                log.External_Id__c = (log.External_Id__c + '@' + String.valueOf(payload.get('modifyDate'))).left(255);
            }
        }
        insert log;
        return run(log, source, payload);
    }

    public static Result retry(Id logId) {
        NFY_Sync_Log__c log = [
            SELECT Id, Name, Event_Type__c, Entity__c, External_Id__c, Payload__c, Attempts__c, Status__c, System__r.Code__c,
                Source__c, Workato_Job_Id__c, Order__c, Account__c, Received_At__c, Resolved__c
            FROM NFY_Sync_Log__c WHERE Id = :logId
        ];
        if (log.Status__c == 'Success') {
            throw new NFYException(log.Name + ' already succeeded.');
        }
        return run(log, log.System__r.Code__c, parse(log.Payload__c));
    }

    private static Result run(NFY_Sync_Log__c log, String source, Map<String, Object> payload) {
        Result r = new Result();
        r.logId = log.Id;
        Long started = System.currentTimeMillis();
        log.Attempts__c = (log.Attempts__c == null ? 0 : log.Attempts__c) + 1;
        r.attempts = log.Attempts__c.intValue();
        // One query finds both kinds of earlier event: a success (replay) and an open failure (repeat).
        List<NFY_Sync_Log__c> earlier = log.Attempts__c == 1 && log.External_Id__c != null ? earlierSame(log) : new List<NFY_Sync_Log__c>();
        if (isDuplicate(log, earlier)) {
            log.Status__c = 'Duplicate skipped';
            log.Operation__c = 'Duplicate';
            log.Retry_Status__c = 'Not needed';
            log.Response__c = log.External_Id__c + ' was already processed. Nothing changed.';
            log.Processed_At__c = System.now();
            update log;
            r.success = true;
            r.status = log.Status__c;
            r.message = log.Response__c;
            return finish(r, log);
        }
        // The same event already failed and nobody has fixed it yet: keep one open failure, not one per repeat.
        NFY_Sync_Log__c open = openFailure(log, earlier);
        if (open != null) {
            log.Status__c = 'Duplicate skipped';
            log.Operation__c = 'Duplicate';
            log.Retry_Status__c = 'Not needed';
            log.Response__c = 'Same event already failed as ' + open.Name + ' and is waiting for a fix: ' + open.Error_Message__c;
            log.Processed_At__c = System.now();
            update log;
            r.success = true;
            r.status = log.Status__c;
            r.message = log.Response__c;
            return finish(r, log);
        }
        Savepoint sp = Database.setSavepoint();
        try {
            if (payload == null) {
                throw new NFYException('The payload is not valid JSON.');
            }
            if (NFY_Ref.system(source) == null) {
                throw new NFYException('Unknown source system "' + source + '". Register it under Integration Systems.');
            }
            Outcome o;
            Boolean wasProcessing = processing;
            Id outerLogId = currentLogId;
            try {
                processing = true;
                currentLogId = log.Id;
                o = dispatch(log.Event_Type__c, source.toUpperCase(), payload);
            } finally {
                processing = wasProcessing;
                currentLogId = outerLogId;
            }
            log.Status__c = 'Success';
            log.Error_Message__c = null;
            log.Resolved__c = log.Attempts__c > 1;
            log.Response__c = (log.Attempts__c > 1 ? 'Succeeded on attempt ' + log.Attempts__c.intValue() + '. ' : '') + o.message;
            log.Record_Id__c = o.recordId;
            log.Record_Name__c = o.recordName;
            log.Order__c = o.orderId != null ? o.orderId : o.linkedOrderId;
            log.Sales_Order__c = o.salesOrderId;
            log.Operation__c = o.operation != null ? o.operation : NFY_OriginService.operationFor(log.Entity__c, o.message);
            log.Error_Category__c = null;
            log.Retry_Status__c = log.Attempts__c > 1 ? 'Resolved' : 'Not needed';
            NFY_OriginService.stampSuccess(log, source, o.orderId, log.Operation__c);
            if (o.recordId != null) {
                Schema.SObjectType t = o.recordId.getSObjectType();
                if (t == Product2.SObjectType) {
                    log.Product__c = o.recordId;
                } else if (t == TC_Shipment__c.SObjectType) {
                    log.Shipment__c = o.recordId;
                }
            }
            NFY_OriginService.stampRecord(log, source, o.recordId);
            r.success = true;
            r.recordId = o.recordId;
            r.recordName = o.recordName;
        } catch (Exception e) {
            Database.rollback(sp);
            NFY_Ref.reset();
            log.Status__c = 'Failed';
            log.Error_Message__c = cleanMessage(e);
            log.Response__c = null;
            log.Operation__c = 'Rejected';
            log.Error_Category__c = NFY_OriginService.categorize(log.Error_Message__c);
            log.Retry_Status__c = 'Waiting for fix';
            NFY_OriginService.stampFailure(log);
        }
        log.Processed_At__c = System.now();
        log.Duration_ms__c = System.currentTimeMillis() - started;
        update log;
        if (log.System__c != null) {
            update new NFY_Integration_System__c(Id = log.System__c, Last_Sync__c = System.now());
        }
        r.status = log.Status__c;
        r.message = log.Status__c == 'Failed' ? log.Error_Message__c : log.Response__c;
        if (log.Status__c == 'Failed') {
            raiseAlert(log, source);
        }
        linkSendsToOrder(log);
        finish(r, log);
        supersedeOlderFailures(log, r.logName);
        return r;
    }

    private static final String NO_ORDER_YET = ' No Salesforce order has this number yet.';

    /**
     * Odoo fires the order webhook and the ShipStation webhook at the same moment, so a ShipStation
     * send can be logged a second before its order exists. Both sides close the gap: a new order
     * links the sends already logged for it, and a send that found no order checks again once its
     * own transaction has committed.
     */
    private static void linkSendsToOrder(NFY_Sync_Log__c log) {
        if (log.Status__c != 'Success' || log.External_Id__c == null) {
            return;
        }
        if (log.Event_Type__c == 'order.upsert' && log.Order__c != null) {
            linkPendingSends(log.External_Id__c, log.Order__c);
        } else if (log.Event_Type__c == 'shipstation.order.sent' && log.Order__c == null
                && !System.isQueueable() && Limits.getQueueableJobs() < Limits.getLimitQueueableJobs()) {
            System.enqueueJob(new LinkSendJob(log.External_Id__c.substringBefore('@')));
        }
    }

    @TestVisible
    private static Integer linkPendingSends(String orderNo, Id orderId) {
        List<NFY_Sync_Log__c> sends = [
            SELECT Id, Response__c, Payload__c FROM NFY_Sync_Log__c
            WHERE Event_Type__c = 'shipstation.order.sent' AND Order__c = null AND External_Id__c LIKE :(orderNo + '@%')
            ORDER BY Received_At__c
        ];
        String ssOrderId = null;
        for (NFY_Sync_Log__c s : sends) {
            s.Order__c = orderId;
            s.Response__c = s.Response__c == null ? null : s.Response__c.remove(NO_ORDER_YET);
            Map<String, Object> body = parse(s.Payload__c);
            if (body != null && body.get('orderId') != null) {
                ssOrderId = str(body.get('orderId'));
            }
        }
        update sends;
        if (ssOrderId != null) {
            Boolean was = processing;
            try {
                processing = true;
                update new Order(Id = orderId, NFY_ShipStation_Order_Id__c = ssOrderId.left(40));
            } finally {
                processing = was;
            }
        }
        return sends.size();
    }

    /** Re-checks, after commit, for the order a ShipStation send could not find. */
    public class LinkSendJob implements Queueable {
        private String orderNo;
        public LinkSendJob(String orderNo) {
            this.orderNo = orderNo;
        }
        public void execute(QueueableContext ctx) {
            List<Order> orders = [SELECT Id FROM Order WHERE NFY_External_Order_Id__c = :orderNo LIMIT 1];
            if (!orders.isEmpty()) {
                linkPendingSends(orderNo, orders[0].Id);
            }
        }
    }

    private static Result finish(Result r, NFY_Sync_Log__c log) {
        r.logName = [SELECT Name FROM NFY_Sync_Log__c WHERE Id = :log.Id].Name;
        return r;
    }

    /**
     * Versioned events carry "record@version" keys (product.upsert: ODOO-PRODUCT-46@<write_date>;
     * shipstation.order.sent: ODOO-S00040@<modifyDate>). The source can send several states under one
     * version while it is still saving (Odoo sends the product before its Internal Reference is stored,
     * then again with it, all with the same write_date), so for these a repeat means the same key AND
     * the same payload. Other events keep matching on the key alone.
     */
    private static Boolean versioned(NFY_Sync_Log__c log) {
        return log.External_Id__c != null && log.External_Id__c.contains('@');
    }

    private static List<NFY_Sync_Log__c> earlierSame(NFY_Sync_Log__c log) {
        return [
            SELECT Id, Name, Status__c, Error_Message__c, Payload__c FROM NFY_Sync_Log__c
            WHERE Event_Type__c = :log.Event_Type__c AND External_Id__c = :log.External_Id__c AND Id != :log.Id
                AND (Status__c = 'Success' OR (Status__c = 'Failed' AND Resolved__c = false))
            ORDER BY Received_At__c LIMIT 40
        ];
    }

    private static NFY_Sync_Log__c openFailure(NFY_Sync_Log__c log, List<NFY_Sync_Log__c> earlier) {
        for (NFY_Sync_Log__c f : earlier) {
            if (f.Status__c == 'Failed' && (!versioned(log) || f.Payload__c == log.Payload__c)) {
                return f;
            }
        }
        return null;
    }

    private static Boolean isDuplicate(NFY_Sync_Log__c log, List<NFY_Sync_Log__c> earlier) {
        for (NFY_Sync_Log__c e : earlier) {
            if (e.Status__c == 'Success' && (!versioned(log) || e.Payload__c == log.Payload__c)) {
                return true;
            }
        }
        return false;
    }

    /**
     * After a versioned event is processed, older open failures for the same record describe a state that
     * no longer exists (for example "no SKU" from a half-saved Odoo product). They are resolved and point to
     * the newer log, so only the record's current problem stays open.
     */
    @TestVisible
    private static Integer supersedeOlderFailures(NFY_Sync_Log__c log, String logName) {
        // Housekeeping only: never let it cost a business event its query budget.
        if (!versioned(log) || log.Status__c == 'Duplicate skipped' || Limits.getQueries() > Limits.getLimitQueries() - 10) {
            return 0;
        }
        String recordKey = log.External_Id__c.substringBefore('@') + '@%';
        List<NFY_Sync_Log__c> older = [
            SELECT Id, Response__c FROM NFY_Sync_Log__c
            WHERE Event_Type__c = :log.Event_Type__c AND External_Id__c LIKE :recordKey AND Status__c = 'Failed'
                AND Resolved__c = false AND Id != :log.Id AND Received_At__c <= :log.Received_At__c
        ];
        for (NFY_Sync_Log__c f : older) {
            f.Resolved__c = true;
            f.Retry_Status__c = 'Superseded';
            f.Response__c = ('Superseded by ' + logName + ', a newer state of the same record (' + log.Status__c + ').'
                + (String.isBlank(f.Response__c) ? '' : ' ' + f.Response__c)).left(32768);
        }
        update older;
        return older.size();
    }

    private static Outcome dispatch(String eventType, String source, Map<String, Object> p) {
        switch on eventType {
            when 'order.upsert' { return handleOrder(source, p); }
            when 'shipment.created' { return handleShipment(source, p); }
            when 'inbound.update' { return handleInbound(source, p); }
            when 'po.receipt' { return handlePoReceipt(source, p); }
            when 'inventory.snapshot' { return handleSnapshot(source, p); }
            when 'return.received' { return handleReturn(source, p); }
            when 'settlement.posted' { return handleSettlement(source, p); }
            when 'product.upsert' {
                NFY_ProductSyncService.Outcome po = NFY_ProductSyncService.upsertProduct(source, p);
                return new Outcome(po.recordId, po.recordName, po.message);
            }
            when 'shipstation.notify' {
                NFY_ShipStationService.Outcome ss = NFY_ShipStationService.notify(source, p);
                if (ss.created == 0 && ss.failed > 0) {
                    throw new NFYException(ss.message);
                }
                return new Outcome(null, 'ShipStation notification', ss.message);
            }
            when 'shipstation.order.sent' { return handleOrderSent(p); }
            when 'order.cancelled' { return handleCancel(source, p); }
            when 'payment.received' { return handlePayment(source, p); }
            when 'payment.reversed' { return handlePaymentReversed(source, p); }
            when 'payment.refunded' { return handleRefund(source, p); }
            when 'payment.snapshot' { return handlePaymentSnapshot(source, p); }
            when 'payment.reconcile' {
                // Retry of one reconciliation finding: check that payment again.
                String issue = reconcilePayment(source, p, null);
                if (issue != null) {
                    throw new NFYException(issue);
                }
                return new Outcome(null, str(p.get('externalId')), str(p.get('externalId')) + ' now matches between ' + source + ' and Salesforce.');
            }
            when 'stock.adjusted' {
                NFY_StockSyncService.Outcome so = NFY_StockSyncService.apply(source, p);
                return new Outcome(so.recordId, so.recordName, so.message);
            }
            when else { throw new NFYException('Unsupported event "' + eventType + '".'); }
        }
    }

    // ------------------------------------------------------------------ shipstation.order.sent

    /**
     * Records that Workato created or updated an order in ShipStation (the createorder response is the
     * payload). Nothing in Salesforce changes: the log links to the Salesforce order with the same
     * number so ops can see what ShipStation holds, and the dashboard counts the send.
     */
    private static Outcome handleOrderSent(Map<String, Object> p) {
        String orderNo = req(p, 'orderNumber');
        Decimal units = 0;
        Object items = p.get('items');
        if (items instanceof List<Object>) {
            for (Object it : (List<Object>) items) {
                if (it instanceof Map<String, Object>) {
                    Object q = ((Map<String, Object>) it).get('quantity');
                    if (q != null) units += Decimal.valueOf(String.valueOf(q));
                }
            }
        }
        String created = str(p.get('createDate'));
        String modified = str(p.get('modifyDate'));
        Boolean isNew = created == null || created == modified;
        String note = null;
        if (p.get('advancedOptions') instanceof Map<String, Object>) {
            note = str(((Map<String, Object>) p.get('advancedOptions')).get('customField3'));
        }
        List<Order> orders = [SELECT Id FROM Order WHERE NFY_External_Order_Id__c = :orderNo LIMIT 1];
        String msg = orderNo + (isNew ? ' created in ShipStation' : ' updated in ShipStation')
            + (p.get('orderId') == null ? '' : ' (order ' + str(p.get('orderId')) + ')')
            + ': ' + units.stripTrailingZeros().toPlainString() + ' units, status ' + str(p.get('orderStatus')) + '.'
            + (String.isBlank(note) ? '' : ' ' + note + '.')
            + (orders.isEmpty() ? NO_ORDER_YET : '');
        String ssOrderId = str(p.get('orderId'));
        if (!orders.isEmpty() && ssOrderId != null) {
            update new Order(Id = orders[0].Id, NFY_ShipStation_Order_Id__c = ssOrderId.left(40));
        }
        Outcome o = new Outcome(orders.isEmpty() ? null : orders[0].Id, orderNo, msg);
        o.linkedOrderId = orders.isEmpty() ? null : orders[0].Id;
        o.operation = isNew ? 'Created' : 'Updated';
        return o;
    }

    // ------------------------------------------------------------------ order.upsert

    private class LineSpec {
        Product2 product;
        Decimal qty;
        Decimal price;
        TC_Warehouse__c shipFrom;
    }

    private static Outcome handleOrder(String source, Map<String, Object> p) {
        String orderNo = req(p, 'orderNumber');
        String channel = req(p, 'channel');
        // An order a rep entered in Salesforce arrives with its own ID; it is used as-is instead of creating a new Order.
        Id sfOrderId = asId(str(p.get('sfOrderId')));
        Order manual = null;
        if (sfOrderId != null) {
            manual = [SELECT Id, OrderNumber, Status, AccountId, Account.Name, BillToContactId, NFY_TC_Sales_Order__c,
                          (SELECT Id FROM OrderItems LIMIT 1) FROM Order WHERE Id = :sfOrderId];
            if (manual.NFY_TC_Sales_Order__c != null) {
                Outcome sent = new Outcome(manual.Id, orderNo, orderNo + ' is already in fulfilment.');
                sent.orderId = manual.Id;
                sent.salesOrderId = manual.NFY_TC_Sales_Order__c;
                return sent;
            }
            if (manual.OrderItems.isEmpty()) {
                throw new NFYException('Order ' + manual.OrderNumber + ' has no products. Add products, then send it to fulfilment.');
            }
        }
        List<Order> existing = [SELECT Id, OrderNumber, NFY_TC_Sales_Order__c FROM Order WHERE NFY_External_Order_Id__c = :orderNo LIMIT 1];
        if (!existing.isEmpty()) {
            Outcome same = new Outcome(existing[0].Id, orderNo, orderNo + ' is already in Salesforce.');
            same.orderId = existing[0].Id;
            same.salesOrderId = existing[0].NFY_TC_Sales_Order__c;
            return same;
        }
        Date orderDate = dateOf(p.get('orderDate'), Date.today());
        Account customer = manual != null ? new Account(Id = manual.AccountId, Name = manual.Account.Name) : upsertCustomer((Map<String, Object>) p.get('customer'));
        TC_Warehouse__c requested = NFY_Ref.warehouse(p.containsKey('shipFrom') ? str(p.get('shipFrom')) : NFY_Ref.MAIN);
        Boolean allowFallback = p.containsKey('allowFallback') ? (Boolean) p.get('allowFallback') : requested.NFY_Type__c != 'Amazon FBA' || channel == 'Amazon MCF';

        // Prices in another currency (a Shopify store in INR) are converted to the corporate currency at the org's rate,
        // so the Order, TC Sales Order and billing stay in one currency. The original currency is noted on the Order.
        String payCurrency = String.isBlank(str(p.get('currency'))) ? null : str(p.get('currency')).toUpperCase();
        Decimal fx = NFY_Ref.toCorporateRate(payCurrency);

        List<LineSpec> specs = new List<LineSpec>();
        Decimal subtotal = 0;
        for (Object o : items(p, 'lines')) {
            Map<String, Object> l = (Map<String, Object>) o;
            LineSpec s = new LineSpec();
            s.product = l.containsKey('productId') ? anyProduct(asId(str(l.get('productId')))) : NFY_Ref.product(str(l.get('sku')));
            s.qty = dec(l.containsKey('qty') ? l.get('qty') : l.get('quantity')); // 'quantity': Shopify line items as sent
            s.price = (dec(l.get('price')) * fx).setScale(2, RoundingMode.HALF_UP);
            s.shipFrom = l.containsKey('shipFrom') ? NFY_Ref.warehouse(str(l.get('shipFrom'))) : requested;
            if (s.qty <= 0) {
                throw new NFYException('Line for ' + s.product.ProductCode + ' has no quantity.');
            }
            subtotal += s.qty * s.price;
            specs.add(s);
        }
        Decimal freight = (dec(p.get('freight')) * fx).setScale(2, RoundingMode.HALF_UP);
        Decimal tax = (dec(p.get('tax')) * fx).setScale(2, RoundingMode.HALF_UP);
        String currencyNote = fx == 1 ? '' : ' (' + payCurrency + ' converted at ' + (1 / fx).setScale(4) + ' per ' + NFY_Ref.corporateCurrency() + ')';

        // Routing: keep the channel's choice where stock allows; otherwise fall back to Nfinity Main.
        TC_Warehouse__c main = NFY_Ref.warehouse(NFY_Ref.MAIN);
        Map<String, Decimal> available = availableAt(specs, new List<TC_Warehouse__c>{ requested, main });
        List<String> notes = new List<String>();
        for (LineSpec s : specs) {
            if (s.product.TC_Inventory_Product__c != true || s.shipFrom.NFY_Code__c == FACTORY) {
                continue;
            }
            Decimal free = nz(available.get(key(s.product.Id, s.shipFrom.Id)));
            if (free < s.qty && allowFallback && s.shipFrom.Id != main.Id && nz(available.get(key(s.product.Id, main.Id))) >= s.qty) {
                notes.add(s.product.Name + ' out of stock at ' + s.shipFrom.Name + ', moved to ' + main.Name);
                s.shipFrom = main;
                free = nz(available.get(key(s.product.Id, main.Id)));
            }
            if (free < s.qty) {
                Decimal assign = Math.max(free, 0);
                notes.add(s.product.Name + ': requested ' + s.qty.intValue() + ', ' + assign.intValue() + ' assigned at ' + s.shipFrom.Name
                    + ', ' + (s.qty - assign).intValue() + ' short (backordered)');
            }
            String k = key(s.product.Id, s.shipFrom.Id);
            available.put(k, nz(available.get(k)) - s.qty);
        }
        String routing = (String.isBlank(str(p.get('routingReason'))) ? source + ' picked ' + requested.Name : str(p.get('routingReason')))
            + (notes.isEmpty() ? '' : '. ' + String.join(notes, '; '));

        Opportunity opp = null;
        if (manual == null && source == 'SHOPIFY' && channel != 'EU Webstore') {
            // The Opportunity is the sale record behind the Order. A Shopify order already recorded as an Opportunity
            // (by the earlier Opportunity-only recipe) is reused, so a replay never creates a second one.
            String shopifyId = str(p.get('shopifyId'));
            List<Opportunity> known = String.isBlank(shopifyId) ? new List<Opportunity>()
                : [SELECT Id, (SELECT Id FROM OpportunityLineItems LIMIT 1) FROM Opportunity WHERE NFT_Shopify_Order_Id__c = :shopifyId LIMIT 1];
            if (!known.isEmpty()) {
                opp = known[0];
            } else {
                opp = new Opportunity(Name = orderNo, AccountId = customer.Id, StageName = 'Closed Won', CloseDate = orderDate,
                    Pricebook2Id = NFY_Ref.pricebook(), NFY_Shopify_Id__c = shopifyId, NFT_Shopify_Order_Id__c = shopifyId, NFY_Demo__c = true,
                    NFY_Customer_Status__c = str(p.get('customerStatus')), NFY_Category__c = str(p.get('category')));
                insert opp;
                List<OpportunityLineItem> olis = new List<OpportunityLineItem>();
                for (LineSpec s : specs) {
                    olis.add(new OpportunityLineItem(OpportunityId = opp.Id, PricebookEntryId = entry(s.product, s.price), Quantity = s.qty, UnitPrice = s.price));
                }
                if (freight > 0) {
                    Product2 f = NFY_Ref.product(NFY_Ref.FREIGHT_SKU);
                    olis.add(new OpportunityLineItem(OpportunityId = opp.Id, PricebookEntryId = entry(f, freight), Quantity = 1, UnitPrice = freight));
                }
                insert olis;
            }
        }

        Order ord;
        if (manual != null) {
            ord = new Order(Id = manual.Id, NFY_Channel__c = channel, NFY_External_Order_Id__c = orderNo, NFY_Ship_From__c = requested.Id,
                NFY_Routing_Decision__c = routing.left(255), NFY_Sales_Rep__c = str(p.get('salesRep')), NFY_Demo__c = true);
            if (manual.BillToContactId == null) {
                Id contactId = customerContact(customer, (Map<String, Object>) p.get('customer'));
                ord.BillToContactId = contactId;
                ord.ShipToContactId = contactId;
            }
            update ord;
        } else {
            ord = new Order(AccountId = customer.Id, EffectiveDate = orderDate, Status = 'Draft', Pricebook2Id = NFY_Ref.pricebook(),
                NFY_Channel__c = channel, NFY_External_Order_Id__c = orderNo, NFY_Ship_From__c = requested.Id, NFY_Routing_Decision__c = routing.left(255),
                NFY_Sales_Rep__c = str(p.get('salesRep')), NFY_Demo__c = true, Description = 'Received from ' + source + ' as ' + orderNo + currencyNote,
                OpportunityId = opp == null ? null : opp.Id, Tax__c = tax, Shipping__c = freight);
            Id contactId = customerContact(customer, (Map<String, Object>) p.get('customer'));
            ord.BillToContactId = contactId;
            ord.ShipToContactId = contactId;
            applyShipTo(ord, p.get('shipTo'));
            insert ord;
            List<OrderItem> items = new List<OrderItem>();
            for (LineSpec s : specs) {
                items.add(new OrderItem(OrderId = ord.Id, PricebookEntryId = entry(s.product, s.price), Product2Id = s.product.Id, Quantity = s.qty, UnitPrice = s.price));
            }
            if (freight > 0) {
                Product2 f = NFY_Ref.product(NFY_Ref.FREIGHT_SKU);
                items.add(new OrderItem(OrderId = ord.Id, PricebookEntryId = entry(f, freight), Product2Id = f.Id, Quantity = 1, UnitPrice = freight));
            }
            insert items;
        }

        TC_Sales_Order__c so = new TC_Sales_Order__c(Customer__c = customer.Id, Order_Date__c = orderDate, Status__c = 'Open',
            Opportunity__c = opp == null ? null : opp.Id, NFY_Order__c = ord.Id, NFY_Channel__c = channel, NFY_External_Order_Id__c = orderNo,
            NFY_Ship_From__c = requested.Id, NFY_Routing_Decision__c = routing.left(255), NFY_Demo__c = true,
            Shipping_Address__c = str(((Map<String, Object>) p.get('customer')).get('address')));
        insert so;
        List<TC_Sales_Order_Line__c> soLines = new List<TC_Sales_Order_Line__c>();
        Integer stockedLines = 0;
        for (LineSpec s : specs) {
            // Products Nfinity does not stock are billed with the order and never reserved or shipped.
            Boolean stocked = s.product.TC_Inventory_Product__c == true;
            soLines.add(new TC_Sales_Order_Line__c(Sales_Order__c = so.Id, Product__c = s.product.Id, Quantity_Ordered__c = s.qty, Unit_Price__c = s.price,
                Description__c = s.product.Name, NFY_Ship_From__c = stocked ? s.shipFrom.Id : null,
                NFY_Location__c = stocked ? NFY_Ref.location(s.shipFrom.NFY_Code__c, 'AVL').Id : null));
            if (stocked) {
                stockedLines++;
            }
        }
        if (freight > 0) {
            Product2 f = NFY_Ref.product(NFY_Ref.FREIGHT_SKU);
            soLines.add(new TC_Sales_Order_Line__c(Sales_Order__c = so.Id, Product__c = f.Id, Quantity_Ordered__c = 1, Unit_Price__c = freight, Description__c = 'Freight'));
        }
        insert soLines;

        Boolean fullyAllocated = allocate(soLines, specs, orderDate);
        String status = fullyAllocated ? 'Awaiting Shipment' : 'Received';
        if (!fullyAllocated) {
            routing += '. Not enough stock for every line; the rest is backordered and assigned automatically when stock arrives';
        }
        String dropShip = raiseDropShipPo(so, soLines, orderNo, orderDate);
        if (dropShip != null) {
            routing += '. ' + dropShip;
        }
        // Nothing to ship: bill straight away.
        if (stockedLines == 0) {
            TC_Sales_Order__c full = [SELECT Id, Name, Customer__c, Ledger__c, Opportunity__c, NFY_Order__c, NFY_Channel__c, NFY_External_Order_Id__c
                                      FROM TC_Sales_Order__c WHERE Id = :so.Id];
            TC_Billing__c b = bill(full, orderDate);
            status = 'Billed';
            routing += '. No stocked products to ship; billed on ' + b.Name;
            update new TC_Sales_Order__c(Id = so.Id, Status__c = 'Closed');
        }
        update new TC_Sales_Order__c(Id = so.Id, NFY_Fulfillment_Status__c = status, NFY_Routing_Decision__c = routing.left(255));
        update new Order(Id = ord.Id, Status = 'Activated', NFY_TC_Sales_Order__c = so.Id, NFY_Fulfillment_Status__c = status, NFY_Routing_Decision__c = routing.left(255));
        refreshStock(new Set<Id>{ so.Id });
        if (status == 'Awaiting Shipment') {
            publishFulfilment(RELEASE, new Map<Id, String>{ ord.Id => orderNo });
        }

        Outcome out = new Outcome(ord.Id, orderNo, orderNo + ' created with TC Sales Order. ' + status + '. ' + routing + '.');
        out.orderId = ord.Id;
        out.salesOrderId = so.Id;
        return out;
    }

    /**
     * Optional shipTo { name, company, street1, street2, city, state, postalCode, country, phone } on order.upsert:
     * the delivery address, kept on the Order's shipping address so fulfilment (ShipStation) can ship to it.
     */
    private static void applyShipTo(Order ord, Object raw) {
        if (!(raw instanceof Map<String, Object>)) {
            return;
        }
        Map<String, Object> a = (Map<String, Object>) raw;
        String street = str(a.get('street1'));
        if (String.isNotBlank(str(a.get('street2')))) {
            street = (street == null ? '' : street + '\n') + str(a.get('street2'));
        }
        ord.ShippingStreet = street;
        ord.ShippingCity = str(a.get('city'));
        ord.ShippingState = str(a.get('state'));
        ord.ShippingPostalCode = str(a.get('postalCode'));
        ord.ShippingCountry = str(a.get('country'));
    }

    private static Product2 anyProduct(Id productId) {
        if (productId == null) {
            throw new NFYException('An order line has no product.');
        }
        return [SELECT Id, Name, ProductCode, TC_Inventory_Product__c, TC_Moving_Average_Cost__c, TC_Unit_Cost__c,
                    TC_Expense_GL_Account__c, TC_Inventory_GL_Account__c, NFY_Style__c, NFY_Size__c
                FROM Product2 WHERE Id = :productId];
    }

    /** The product's standard price book entry in the corporate currency; created at the order's price when only another currency has one. */
    private static Id entry(Product2 p, Decimal unitPrice) {
        Id e = NFY_Ref.priceEntry(p.Id, unitPrice);
        if (e == null) {
            throw new NFYException(p.Name + ' has no price in the standard price book.');
        }
        return e;
    }

    private static String key(Id productId, Id warehouseId) {
        return String.valueOf(productId) + '|' + String.valueOf(warehouseId);
    }

    private static Map<String, Decimal> availableAt(List<LineSpec> specs, List<TC_Warehouse__c> extra) {
        Set<Id> productIds = new Set<Id>();
        Set<Id> locationIds = new Set<Id>();
        Map<Id, Id> locToWh = new Map<Id, Id>();
        for (LineSpec s : specs) {
            productIds.add(s.product.Id);
            TC_Location__c l = NFY_Ref.location(s.shipFrom.NFY_Code__c, 'AVL');
            locationIds.add(l.Id);
            locToWh.put(l.Id, s.shipFrom.Id);
        }
        for (TC_Warehouse__c w : extra) {
            TC_Location__c l = NFY_Ref.location(w.NFY_Code__c, 'AVL');
            locationIds.add(l.Id);
            locToWh.put(l.Id, w.Id);
        }
        Map<String, Decimal> result = new Map<String, Decimal>();
        for (TC_Inventory_Balance__c b : [
            SELECT Product__c, Location__c, Available_Quantity__c FROM TC_Inventory_Balance__c
            WHERE Product__c IN :productIds AND Location__c IN :locationIds
        ]) {
            result.put(key(b.Product__c, locToWh.get(b.Location__c)), nz(b.Available_Quantity__c));
        }
        // Stock that older open orders are still waiting for is not free for a new order. Read once per order:
        // allocate() reuses it, since the new order's own lines don't exist yet and its locations are among these.
        Map<String, Decimal> waiting = committedAt(productIds, locationIds, null);
        waitingForThisOrder = waiting;
        for (String pl : waiting.keySet()) {
            List<String> parts = pl.split('\\|');
            String k = key((Id) parts[0], locToWh.get((Id) parts[1]));
            result.put(k, nz(result.get(k)) - waiting.get(pl));
        }
        return result;
    }

    /** Committed demand read by availableAt for the order being processed; used once by allocate(). */
    private static Map<String, Decimal> waitingForThisOrder;

    /**
     * Committed demand: units older open orders have ordered but not yet been assigned (backorders), per
     * product and location, keyed "productId|locationId". Lines of exceptSalesOrderId are left out.
     */
    @TestVisible
    private static Map<String, Decimal> committedAt(Set<Id> productIds, Set<Id> locationIds, Id exceptSalesOrderId) {
        Map<String, Decimal> waiting = new Map<String, Decimal>();
        for (TC_Sales_Order_Line__c l : [
            SELECT Product__c, NFY_Location__c, NFY_Short_Qty__c FROM TC_Sales_Order_Line__c
            WHERE Product__c IN :productIds AND NFY_Location__c IN :locationIds AND Sales_Order__r.Status__c = 'Open'
                AND Sales_Order__c != :exceptSalesOrderId AND NFY_Short_Qty__c > 0
            LIMIT 2000
        ]) {
            String k = String.valueOf(l.Product__c) + '|' + String.valueOf(l.NFY_Location__c);
            waiting.put(k, nz(waiting.get(k)) + nz(l.NFY_Short_Qty__c));
        }
        return waiting;
    }

    /** One SO inventory movement per inventory line at its ship-from location. Returns true when every line is covered. */
    private static Boolean allocate(List<TC_Sales_Order_Line__c> soLines, List<LineSpec> specs, Date movementDate) {
        Map<Id, Set<Id>> productsByLocation = new Map<Id, Set<Id>>();
        Id factoryAvl = NFY_Ref.hasWarehouse(FACTORY) ? NFY_Ref.location(FACTORY, 'AVL').Id : null;
        for (TC_Sales_Order_Line__c l : soLines) {
            if (l.NFY_Location__c == null || l.NFY_Location__c == factoryAvl) {
                continue;
            }
            if (!productsByLocation.containsKey(l.NFY_Location__c)) {
                productsByLocation.put(l.NFY_Location__c, new Set<Id>());
            }
            productsByLocation.get(l.NFY_Location__c).add(l.Product__c);
        }
        Map<String, TC_Inventory_Balance__c> balances = new Map<String, TC_Inventory_Balance__c>();
        for (Id locId : productsByLocation.keySet()) {
            Map<Id, TC_Inventory_Balance__c> byProduct = TC_InventoryService.balancesFor(productsByLocation.get(locId), locId, null);
            for (Id productId : byProduct.keySet()) {
                balances.put(String.valueOf(productId) + '|' + String.valueOf(locId), byProduct.get(productId));
            }
        }
        Map<Id, Decimal> free = new Map<Id, Decimal>();
        Set<Id> productIds = new Set<Id>();
        for (Set<Id> ps : productsByLocation.values()) {
            productIds.addAll(ps);
        }
        Id ownSo = soLines.isEmpty() ? null : soLines[0].Sales_Order__c;
        Map<String, Decimal> waiting = waitingForThisOrder != null ? waitingForThisOrder : committedAt(productIds, productsByLocation.keySet(), ownSo);
        waitingForThisOrder = null;
        for (TC_Inventory_Balance__c b : [SELECT Id, Product__c, Location__c, Available_Quantity__c FROM TC_Inventory_Balance__c WHERE Id IN :new Map<Id, TC_Inventory_Balance__c>(balances.values()).keySet()]) {
            // Older backorders keep their claim on stock that arrived without being assigned to them yet.
            free.put(b.Id, nz(b.Available_Quantity__c) - nz(waiting.get(String.valueOf(b.Product__c) + '|' + String.valueOf(b.Location__c))));
        }
        Boolean complete = true;
        List<TC_SO_Inventory_Movement__c> movements = new List<TC_SO_Inventory_Movement__c>();
        for (TC_Sales_Order_Line__c l : soLines) {
            if (l.NFY_Location__c == null || l.NFY_Location__c == factoryAvl) {
                continue;
            }
            TC_Inventory_Balance__c b = balances.get(String.valueOf(l.Product__c) + '|' + String.valueOf(l.NFY_Location__c));
            Decimal take = Math.max(Math.min(l.Quantity_Ordered__c, nz(free.get(b.Id))), 0);
            if (take < l.Quantity_Ordered__c) {
                complete = false;
            }
            if (take > 0) {
                movements.add(new TC_SO_Inventory_Movement__c(Inventory_Balance__c = b.Id, Sales_Order_Line__c = l.Id, Quantity__c = take, Movement_Date__c = movementDate));
                free.put(b.Id, free.get(b.Id) - take);
            }
        }
        insert movements;
        return complete;
    }

    private static Account upsertCustomer(Map<String, Object> c) {
        if (c == null) {
            throw new NFYException('The order has no customer.');
        }
        if (asId(str(c.get('accountId'))) != null) {
            return [SELECT Id, Name FROM Account WHERE Id = :asId(str(c.get('accountId')))];
        }
        String extId = req(c, 'externalId');
        // A Shopify customer already in Salesforce (matched by Shopify Customer ID) is reused and given the channel key.
        String shopifyCustomer = str(c.get('shopifyCustomerId'));
        if (String.isNotBlank(shopifyCustomer)) {
            List<Account> known = [SELECT Id, Name, NFY_External_Customer_Id__c FROM Account WHERE NFT_Shopify_Customer_Id__c = :shopifyCustomer LIMIT 1];
            if (!known.isEmpty()) {
                if (known[0].NFY_External_Customer_Id__c == null
                        && [SELECT COUNT() FROM Account WHERE NFY_External_Customer_Id__c = :extId] == 0) {
                    update new Account(Id = known[0].Id, NFY_External_Customer_Id__c = extId);
                }
                return known[0];
            }
        }
        Account a = new Account(NFY_External_Customer_Id__c = extId, NFT_Shopify_Customer_Id__c = String.isBlank(shopifyCustomer) ? null : shopifyCustomer, Name = req(c, 'name'), NFY_Demo__c = true,
            NFY_Customer_Type__c = c.containsKey('type') ? str(c.get('type')) : 'Consumer',
            BillingCity = str(c.get('city')), BillingState = str(c.get('state')), BillingCountry = str(c.get('country')),
            Phone = str(c.get('phone')));
        Database.upsert(a, Account.NFY_External_Customer_Id__c, true);
        return a;
    }

    /** The customer's contact: the existing one on the account, or a new one from the payload's name, email and phone. */
    public static Id customerContact(Account a, Map<String, Object> c) {
        List<Contact> existing = [SELECT Id FROM Contact WHERE AccountId = :a.Id ORDER BY CreatedDate LIMIT 1];
        if (!existing.isEmpty()) {
            return existing[0].Id;
        }
        String full = String.isNotBlank(str(c.get('contactName'))) ? str(c.get('contactName')) : req(c, 'name');
        Contact ct = new Contact(AccountId = a.Id, FirstName = full.contains(' ') ? full.substringBefore(' ') : null,
            LastName = full.contains(' ') ? full.substringAfter(' ') : full, Email = str(c.get('email')), Phone = str(c.get('phone')),
            MobilePhone = str(c.get('phone')), Title = str(c.get('title')), MailingCity = str(c.get('city')), MailingState = str(c.get('state')),
            MailingCountry = str(c.get('country')));
        // Demo contacts share a handful of team inboxes, so duplicate rules warn on every insert; save anyway.
        Database.DMLOptions opts = new Database.DMLOptions();
        opts.DuplicateRuleHeader.allowSave = true;
        opts.DuplicateRuleHeader.runAsCurrentUser = true;
        Database.SaveResult sr = Database.insert(ct, opts);
        if (!sr.isSuccess()) {
            throw new NFYException('Could not create the contact for ' + a.Name + ': ' + sr.getErrors()[0].getMessage());
        }
        return ct.Id;
    }

    // ------------------------------------------------------------------ shipment.created

    private static Outcome handleShipment(String source, Map<String, Object> p) {
        String extId = req(p, 'shipmentId');
        TC_Sales_Order__c so = findSalesOrder(source, str(p.get('orderNumber')), str(p.get('sfdcId')));
        TC_Warehouse__c w = NFY_Ref.warehouse(req(p, 'shipFrom'));
        Date shipDate = dateOf(p.get('shipDate'), Date.today());
        if (w.NFY_Code__c == FACTORY) {
            receiveDropShip(so, shipDate);
        }
        Map<String, Decimal> wanted = new Map<String, Decimal>();
        if (p.containsKey('lines') && p.get('lines') != null) {
            for (Object o : (List<Object>) p.get('lines')) {
                Map<String, Object> l = (Map<String, Object>) o;
                wanted.put(str(l.get('sku')), dec(l.get('qty')));
            }
        }
        List<TC_Sales_Order_Line__c> lines = [
            SELECT Id, Product__c, Product__r.ProductCode, Quantity_Allocated__c, Quantity_Shipped__c, Quantity_Ordered__c, NFY_Ship_From__c
            FROM TC_Sales_Order_Line__c WHERE Sales_Order__c = :so.Id AND Product__r.TC_Inventory_Product__c = true
        ];
        TC_Shipment__c shipment = new TC_Shipment__c(Sales_Order__c = so.Id, Status__c = 'Scheduled', Shipment_Date__c = shipDate,
            Shipping_Reference__c = str(p.get('tracking')), NFY_Tracking_Number__c = str(p.get('tracking')), NFY_Carrier__c = str(p.get('carrier')),
            NFY_Service__c = str(p.get('service')), NFY_Label_System__c = str(p.get('labelSystem')), NFY_Ship_From__c = w.Id,
            NFY_External_Id__c = extId, NFY_System__c = NFY_Ref.system(source).Id,
            NFY_Source_System__c = NFY_OriginService.systemValue(source), NFY_Source_Record_Id__c = NFY_OriginService.nativeId(extId),
            NFY_Last_Sync_Log__c = currentLogId);
        List<TC_Shipment_Line__c> shipLines = new List<TC_Shipment_Line__c>();
        for (TC_Sales_Order_Line__c l : lines) {
            if (l.NFY_Ship_From__c != w.Id) {
                continue;
            }
            Decimal open = nz(l.Quantity_Allocated__c) - nz(l.Quantity_Shipped__c);
            if (!wanted.isEmpty()) {
                open = wanted.containsKey(l.Product__r.ProductCode) ? Math.min(open, wanted.get(l.Product__r.ProductCode)) : 0;
            }
            if (open > 0) {
                shipLines.add(new TC_Shipment_Line__c(Sales_Order_Line__c = l.Id, Quantity_Shipped__c = open));
            }
        }
        if (shipLines.isEmpty()) {
            throw new NFYException('Nothing to ship from ' + w.Name + ' on ' + so.NFY_External_Order_Id__c
                + ': every line at that location is already shipped or has no stock allocated.');
        }
        insert shipment;
        Map<Id, Id> lineToShipLine = new Map<Id, Id>();
        for (TC_Shipment_Line__c sl : shipLines) {
            sl.Shipment__c = shipment.Id;
        }
        insert shipLines;
        for (TC_Shipment_Line__c sl : shipLines) {
            lineToShipLine.put(sl.Sales_Order_Line__c, sl.Id);
        }
        List<TC_SO_Inventory_Movement__c> link = new List<TC_SO_Inventory_Movement__c>();
        for (TC_SO_Inventory_Movement__c m : [
            SELECT Id, Sales_Order_Line__c FROM TC_SO_Inventory_Movement__c WHERE Sales_Order_Line__c IN :lineToShipLine.keySet() AND Shipment_Line__c = null
        ]) {
            link.add(new TC_SO_Inventory_Movement__c(Id = m.Id, Shipment_Line__c = lineToShipLine.get(m.Sales_Order_Line__c)));
        }
        update link;
        update new TC_Shipment__c(Id = shipment.Id, Status__c = 'Shipped');

        Boolean allShipped = true;
        for (TC_Sales_Order_Line__c l : [
            SELECT Quantity_Shipped__c, Quantity_Ordered__c FROM TC_Sales_Order_Line__c
            WHERE Sales_Order__c = :so.Id AND Product__r.TC_Inventory_Product__c = true
        ]) {
            if (nz(l.Quantity_Shipped__c) < nz(l.Quantity_Ordered__c)) {
                allShipped = false;
            }
        }
        String status = allShipped ? 'Shipped' : 'Partially Shipped';
        String message = 'Shipment ' + extId + ' from ' + w.Name + ' (' + str(p.get('carrier')) + ' ' + str(p.get('tracking')) + '). Order ' + status.toLowerCase() + '.';
        if (allShipped) {
            TC_Billing__c b = bill(so, shipDate);
            status = 'Billed';
            message += ' Billing ' + b.Name + ' posted to ' + so.NFY_Channel__c + ' sales.';
        }
        update new TC_Sales_Order__c(Id = so.Id, NFY_Fulfillment_Status__c = status, Status__c = status == 'Billed' ? 'Closed' : 'Open');
        if (so.NFY_Order__c != null) {
            Order o = [SELECT Id, NFY_Tracking_Numbers__c FROM Order WHERE Id = :so.NFY_Order__c];
            String tracking = String.isBlank(o.NFY_Tracking_Numbers__c) ? str(p.get('tracking')) : o.NFY_Tracking_Numbers__c + ', ' + str(p.get('tracking'));
            update new Order(Id = o.Id, NFY_Fulfillment_Status__c = status, NFY_Tracking_Numbers__c = tracking == null ? null : tracking.left(255));
        }
        Outcome out = new Outcome(shipment.Id, extId, message);
        out.orderId = so.NFY_Order__c;
        out.salesOrderId = so.Id;
        return out;
    }

    private static TC_Sales_Order__c findSalesOrder(String source, String orderNumber, String sfdcId) {
        List<TC_Sales_Order__c> found = new List<TC_Sales_Order__c>();
        String soFields = 'SELECT Id, Name, Customer__c, Ledger__c, Opportunity__c, NFY_Order__c, NFY_Channel__c, NFY_External_Order_Id__c FROM TC_Sales_Order__c ';
        Id i = asId(sfdcId);
        if (i != null) {
            found = Database.query(soFields + 'WHERE Id = :i OR NFY_Order__c = :i LIMIT 1');
        }
        if (found.isEmpty() && String.isNotBlank(orderNumber)) {
            found = Database.query(soFields + 'WHERE NFY_External_Order_Id__c = :orderNumber LIMIT 1');
        }
        if (found.isEmpty()) {
            throw new NFYException('No Salesforce order matches ' + (String.isBlank(orderNumber) ? 'SFDC ID ' + sfdcId : orderNumber)
                + '. The ' + source + ' shipment cannot be linked: the order has not synced from its channel yet. Run the order sync, then retry.');
        }
        return found[0];
    }

    /** Bills shipped inventory lines and ordered non-inventory lines to the channel's revenue account, then posts. */
    private static TC_Billing__c bill(TC_Sales_Order__c so, Date billDate) {
        List<TC_Sales_Order_Line__c> lines = [
            SELECT Id, Product__c, Product__r.ProductCode, Product__r.TC_Inventory_Product__c, Description__c, Quantity_Ordered__c, Quantity_Shipped__c, Unit_Price__c
            FROM TC_Sales_Order_Line__c WHERE Sales_Order__c = :so.Id
        ];
        TC_Billing__c b = new TC_Billing__c(Customer__c = NFY_Ref.payer(so.NFY_Channel__c, so.Customer__c), Ledger__c = so.Ledger__c,
            Opportunity__c = so.Opportunity__c, Sales_Order__c = so.Id, Date__c = billDate, Status__c = 'Approved',
            NFY_Channel__c = so.NFY_Channel__c, PO_Number__c = so.NFY_External_Order_Id__c,
            Billing_Comment__c = 'Order ' + so.NFY_External_Order_Id__c);
        insert b;
        List<TC_Billing_Line__c> billLines = new List<TC_Billing_Line__c>();
        for (TC_Sales_Order_Line__c l : lines) {
            Decimal qty = l.Product__r.TC_Inventory_Product__c == true ? nz(l.Quantity_Shipped__c) : nz(l.Quantity_Ordered__c);
            if (qty <= 0) {
                continue;
            }
            Boolean isFreight = l.Product__r.ProductCode == NFY_Ref.FREIGHT_SKU;
            billLines.add(new TC_Billing_Line__c(Billing__c = b.Id, Product__c = l.Product__c, Description__c = l.Description__c, Quantity__c = qty,
                Unit_Price__c = l.Unit_Price__c, Sales_Order_Line__c = l.Id, Date__c = billDate,
                Revenue_GL_Account__c = isFreight ? NFY_Ref.gl('4020') : NFY_Ref.revenueGl(so.NFY_Channel__c)));
        }
        insert billLines;
        postOrThrow(b.Id);
        // Payments received before shipping (prepayments) are applied as soon as the order is billed.
        applyOpenPayments(new Set<Id>{ so.Id });
        return [SELECT Id, Name, Total__c FROM TC_Billing__c WHERE Id = :b.Id];
    }

    private static void postOrThrow(Id recordId) {
        TC_PostResult r = TC_PostingEngine.post(new List<Id>{ recordId })[0];
        if (!r.isSuccess) {
            throw new NFYException('TC could not post ' + r.name + ': ' + String.join(r.errors, ' '));
        }
    }

    // ------------------------------------------------------------------ stock status and backorders

    /** Requested, assigned and short units on each order (stocked lines, excluding factory drop-ship), mirrored on the Order. */
    public static void refreshStock(Set<Id> salesOrderIds) {
        Map<Id, Decimal[]> totals = new Map<Id, Decimal[]>();
        for (Id soId : salesOrderIds) {
            totals.put(soId, new Decimal[]{ 0, 0, 0 });
        }
        for (TC_Sales_Order_Line__c l : [
            SELECT Sales_Order__c, Quantity_Ordered__c, NFY_Assigned_Qty__c, NFY_Short_Qty__c FROM TC_Sales_Order_Line__c
            WHERE Sales_Order__c IN :salesOrderIds AND Product__r.TC_Inventory_Product__c = true AND NFY_Ship_From__r.NFY_Code__c != :FACTORY
        ]) {
            Decimal[] t = totals.get(l.Sales_Order__c);
            t[0] += nz(l.Quantity_Ordered__c);
            t[1] += Math.min(nz(l.NFY_Assigned_Qty__c), nz(l.Quantity_Ordered__c));
            t[2] += nz(l.NFY_Short_Qty__c);
        }
        List<TC_Sales_Order__c> sos = new List<TC_Sales_Order__c>();
        List<Order> orders = new List<Order>();
        for (TC_Sales_Order__c so : [SELECT Id, NFY_Order__c FROM TC_Sales_Order__c WHERE Id IN :salesOrderIds]) {
            Decimal[] t = totals.get(so.Id);
            String status = t[0] == 0 ? 'Nothing to reserve' : (t[2] == 0 ? 'Fully assigned' : (t[1] > 0 ? 'Partially assigned' : 'No stock'));
            sos.add(new TC_Sales_Order__c(Id = so.Id, NFY_Units_Requested__c = t[0], NFY_Units_Assigned__c = t[1], NFY_Units_Short__c = t[2], NFY_Stock_Status__c = status));
            if (so.NFY_Order__c != null) {
                orders.add(new Order(Id = so.NFY_Order__c, NFY_Stock_Status__c = status, NFY_Units_Short__c = t[2]));
            }
        }
        update sos;
        update orders;
    }

    /**
     * Assigns newly arrived stock at these locations to short order lines there, oldest order first.
     * Orders that become fully assigned move from Received to Awaiting Shipment. Returns a note for the log.
     */
    public static String fillBackorders(Set<Id> locationIds, Date d) {
        List<TC_Sales_Order_Line__c> shortLines = [
            SELECT Id, Product__c, Product__r.Name, NFY_Location__c, NFY_Short_Qty__c, Sales_Order__c, Sales_Order__r.NFY_External_Order_Id__c
            FROM TC_Sales_Order_Line__c
            WHERE NFY_Location__c IN :locationIds AND NFY_Short_Qty__c > 0 AND Sales_Order__r.Status__c = 'Open'
            ORDER BY Sales_Order__r.Order_Date__c, Sales_Order__r.CreatedDate, Name LIMIT 200
        ];
        if (shortLines.isEmpty()) {
            return '';
        }
        Map<Id, Set<Id>> productsByLocation = new Map<Id, Set<Id>>();
        for (TC_Sales_Order_Line__c l : shortLines) {
            if (!productsByLocation.containsKey(l.NFY_Location__c)) {
                productsByLocation.put(l.NFY_Location__c, new Set<Id>());
            }
            productsByLocation.get(l.NFY_Location__c).add(l.Product__c);
        }
        Map<String, TC_Inventory_Balance__c> balances = new Map<String, TC_Inventory_Balance__c>();
        for (Id locId : productsByLocation.keySet()) {
            Map<Id, TC_Inventory_Balance__c> byProduct = TC_InventoryService.balancesFor(productsByLocation.get(locId), locId, null);
            for (Id productId : byProduct.keySet()) {
                balances.put(String.valueOf(productId) + '|' + String.valueOf(locId), byProduct.get(productId));
            }
        }
        Map<Id, Decimal> free = new Map<Id, Decimal>();
        for (TC_Inventory_Balance__c b : [SELECT Id, Available_Quantity__c FROM TC_Inventory_Balance__c WHERE Id IN :new Map<Id, TC_Inventory_Balance__c>(balances.values()).keySet()]) {
            free.put(b.Id, nz(b.Available_Quantity__c));
        }
        List<TC_SO_Inventory_Movement__c> moves = new List<TC_SO_Inventory_Movement__c>();
        Set<Id> touched = new Set<Id>();
        Set<String> orderNames = new Set<String>();
        Decimal units = 0;
        for (TC_Sales_Order_Line__c l : shortLines) {
            TC_Inventory_Balance__c b = balances.get(String.valueOf(l.Product__c) + '|' + String.valueOf(l.NFY_Location__c));
            Decimal take = Math.min(nz(l.NFY_Short_Qty__c), nz(free.get(b.Id)));
            if (take <= 0) {
                continue;
            }
            moves.add(new TC_SO_Inventory_Movement__c(Inventory_Balance__c = b.Id, Sales_Order_Line__c = l.Id, Quantity__c = take, Movement_Date__c = d));
            free.put(b.Id, free.get(b.Id) - take);
            touched.add(l.Sales_Order__c);
            orderNames.add(l.Sales_Order__r.NFY_External_Order_Id__c);
            units += take;
        }
        if (moves.isEmpty()) {
            return '';
        }
        insert moves;
        refreshStock(touched);
        List<TC_Sales_Order__c> ready = new List<TC_Sales_Order__c>();
        List<Order> readyOrders = new List<Order>();
        Map<Id, String> released = new Map<Id, String>();
        for (TC_Sales_Order__c so : [SELECT Id, NFY_Order__c, NFY_External_Order_Id__c FROM TC_Sales_Order__c WHERE Id IN :touched AND NFY_Units_Short__c = 0 AND NFY_Fulfillment_Status__c = 'Received']) {
            ready.add(new TC_Sales_Order__c(Id = so.Id, NFY_Fulfillment_Status__c = 'Awaiting Shipment'));
            if (so.NFY_Order__c != null) {
                readyOrders.add(new Order(Id = so.NFY_Order__c, NFY_Fulfillment_Status__c = 'Awaiting Shipment'));
                released.put(so.NFY_Order__c, so.NFY_External_Order_Id__c);
            }
        }
        update ready;
        update readyOrders;
        publishFulfilment(RELEASE, released);
        List<String> names = new List<String>(orderNames);
        names.sort();
        return ' Backorders: ' + units.intValue() + ' units assigned to ' + String.join(names, ', ') + '.';
    }

    // ------------------------------------------------------------------ release and cancellation

    /** Fulfilment instructions on NFY_Integration_Event__e (Severity__c); the Command Center only alerts on 'Error'. */
    public static final String RELEASE = 'Release';
    public static final String CANCEL = 'Cancel';
    /** Instructions published in this transaction, for tests. */
    @TestVisible
    private static List<NFY_Integration_Event__e> fulfilmentEvents = new List<NFY_Integration_Event__e>();

    /**
     * Tells Workato that orders are ready to ship (every stocked line assigned) or must be pulled back from
     * ShipStation. One event per Order: Log_Id__c is the Order ID, Message__c the channel order number. Events
     * publish after commit, so a rolled-back order never reaches ShipStation.
     */
    private static void publishFulfilment(String kind, Map<Id, String> orderNumbers) {
        if (orderNumbers == null || orderNumbers.isEmpty()) {
            return;
        }
        List<NFY_Integration_Event__e> events = new List<NFY_Integration_Event__e>();
        for (Id orderId : orderNumbers.keySet()) {
            events.add(new NFY_Integration_Event__e(System_Code__c = 'SHIPSTATION', Severity__c = kind, Log_Id__c = orderId,
                Message__c = orderNumbers.get(orderId) == null ? null : orderNumbers.get(orderId).left(255)));
        }
        fulfilmentEvents.addAll(events);
        try {
            EventBus.publish(events);
        } catch (Exception e) {
            System.debug(LoggingLevel.WARN, 'Fulfilment event not published: ' + e.getMessage());
        }
    }

    /**
     * order.cancelled: { orderNumber | sfdcId, reason? }. Releases every unshipped assignment (deleting a sales-order
     * movement reverses its stock and COGS), closes the TC sales order and the Order as Cancelled, hands the freed
     * stock to waiting backorders, and, if the order had been released, tells Workato to cancel it in ShipStation.
     * Orders with shipped units or posted billings are refused: those need a return or a credit memo instead.
     */
    private static Outcome handleCancel(String source, Map<String, Object> p) {
        String orderNo = str(p.get('orderNumber'));
        Id i = asId(str(p.get('sfdcId')));
        // Match on whichever reference was sent; a blank one must never match records where that field is blank too.
        List<TC_Sales_Order__c> found = new List<TC_Sales_Order__c>();
        if (i != null) {
            found = [SELECT Id, Name, Status__c, NFY_Order__c, NFY_External_Order_Id__c, NFY_Fulfillment_Status__c
                     FROM TC_Sales_Order__c WHERE Id = :i OR NFY_Order__c = :i LIMIT 1];
        }
        if (found.isEmpty() && String.isNotBlank(orderNo)) {
            found = [SELECT Id, Name, Status__c, NFY_Order__c, NFY_External_Order_Id__c, NFY_Fulfillment_Status__c
                     FROM TC_Sales_Order__c WHERE NFY_External_Order_Id__c = :orderNo LIMIT 1];
        }
        if (found.isEmpty()) {
            throw new NFYException('No Salesforce order matches ' + (String.isBlank(orderNo) ? 'SFDC ID ' + p.get('sfdcId') : orderNo) + '. Nothing to cancel.');
        }
        TC_Sales_Order__c so = found[0];
        String name = so.NFY_External_Order_Id__c == null ? so.Name : so.NFY_External_Order_Id__c;
        if (so.Status__c == 'Cancelled') {
            Outcome same = new Outcome(so.NFY_Order__c, name, name + ' is already cancelled.');
            same.orderId = so.NFY_Order__c;
            same.salesOrderId = so.Id;
            return same;
        }
        Decimal shipped = 0;
        for (TC_Sales_Order_Line__c l : [SELECT Quantity_Shipped__c FROM TC_Sales_Order_Line__c WHERE Sales_Order__c = :so.Id]) {
            shipped += nz(l.Quantity_Shipped__c);
        }
        if (shipped > 0) {
            throw new NFYException(name + ' has ' + shipped.intValue() + ' unit(s) shipped and cannot be cancelled. Record a return for what comes back.');
        }
        if ([SELECT COUNT() FROM TC_Billing__c WHERE Sales_Order__c = :so.Id AND Status__c = 'Posted'] > 0) {
            throw new NFYException(name + ' is already billed and cannot be cancelled. Issue a credit memo instead.');
        }
        List<TC_SO_Inventory_Movement__c> moves = [
            SELECT Id, Quantity__c, Inventory_Balance__r.Location__c FROM TC_SO_Inventory_Movement__c
            WHERE Sales_Order_Line__r.Sales_Order__c = :so.Id AND Shipment_Line__c = null
        ];
        Set<Id> freed = new Set<Id>();
        Decimal units = 0;
        for (TC_SO_Inventory_Movement__c m : moves) {
            freed.add(m.Inventory_Balance__r.Location__c);
            units += nz(m.Quantity__c);
        }
        delete moves;
        Boolean wasReleased = so.NFY_Fulfillment_Status__c == 'Awaiting Shipment';
        String reason = String.isBlank(str(p.get('reason'))) ? '' : ' Reason: ' + str(p.get('reason')) + '.';
        update new TC_Sales_Order__c(Id = so.Id, Status__c = 'Cancelled', NFY_Fulfillment_Status__c = 'Cancelled');
        refreshStock(new Set<Id>{ so.Id });
        if (so.NFY_Order__c != null) {
            update new Order(Id = so.NFY_Order__c, NFY_Fulfillment_Status__c = 'Cancelled');
        }
        String message = name + ' cancelled by ' + source + '.' + reason + ' ' + units.intValue() + ' assigned unit(s) returned to stock.';
        message += fillBackorders(freed, Date.today());
        if (wasReleased && so.NFY_Order__c != null) {
            publishFulfilment(CANCEL, new Map<Id, String>{ so.NFY_Order__c => name });
            message += ' Cancellation sent to fulfilment.';
        }
        Outcome out = new Outcome(so.NFY_Order__c, name, message);
        out.orderId = so.NFY_Order__c;
        out.salesOrderId = so.Id;
        return out;
    }

    // ------------------------------------------------------------------ customer payments

    /**
     * payment.received: { externalId, orderNumber, amount, currency?, date, method?, reference?, providerReference?, memo? }.
     * A confirmed customer payment captured outside Salesforce (Odoo account.payment). Records one posted
     * TC_Cash_Receipt__c for the billing customer, linked to the order, and applies it to the order's posted billings.
     * A payment that arrives before the order is billed stays unapplied and is applied when the billing posts.
     * externalId is unique (TC_Cash_Receipt__c.NFY_External_Id__c), so a payment is never recorded twice.
     */
    private static Outcome handlePayment(String source, Map<String, Object> p) {
        String extId = req(p, 'externalId').left(80);
        List<TC_Cash_Receipt__c> known = [SELECT Id, Name FROM TC_Cash_Receipt__c WHERE NFY_External_Id__c = :extId LIMIT 1];
        if (!known.isEmpty()) {
            return new Outcome(known[0].Id, known[0].Name, extId + ' is already recorded as ' + known[0].Name + '.');
        }
        String orderNo = str(p.get('orderNumber'));
        if (String.isBlank(orderNo)) {
            throw new NFYException('Payment ' + extId + ' has no order number. Add the sale order to the payment in ' + source + ', then retry.');
        }
        List<TC_Sales_Order__c> sos = [
            SELECT Id, Name, Customer__c, Ledger__c, NFY_Order__c, NFY_Channel__c, NFY_External_Order_Id__c
            FROM TC_Sales_Order__c WHERE NFY_External_Order_Id__c = :orderNo LIMIT 1
        ];
        if (sos.isEmpty()) {
            throw new NFYException('No Salesforce order matches ' + orderNo + ' for payment ' + extId + '. Sync the order first, then retry the payment.');
        }
        TC_Sales_Order__c so = sos[0];
        String payCurrency = String.isBlank(str(p.get('currency'))) ? null : str(p.get('currency')).toUpperCase();
        Decimal amount = (dec(p.get('amount')) * NFY_Ref.toCorporateRate(payCurrency)).setScale(2, RoundingMode.HALF_UP);
        if (amount <= 0) {
            throw new NFYException('Payment ' + extId + ' has no amount to record.');
        }
        Date d = dateOf(p.get('date'), Date.today());
        String method = str(p.get('method'));
        String providerRef = str(p.get('providerReference'));
        String reference = String.isBlank(str(p.get('reference'))) ? extId : str(p.get('reference'));
        String details = source + ' payment ' + reference + (method == null ? '' : ' by ' + method)
            + (providerRef == null ? '' : ', provider ref ' + providerRef) + (payCurrency == null ? '' : ', ' + payCurrency)
            + (String.isBlank(str(p.get('memo'))) ? '' : '. Memo: ' + str(p.get('memo')));

        TC_Cash_Receipt__c r = new TC_Cash_Receipt__c(Account__c = NFY_Ref.payer(so.NFY_Channel__c, so.Customer__c), Amount__c = amount,
            Receipt_Date__c = d, Payment_Reference__c = reference.left(80), Payment_Type__c = paymentType(method, providerRef),
            Bank_Account__c = NFY_Ref.gl('1000'), Status__c = 'Approved', NFY_External_Id__c = extId, NFY_Sales_Order__c = so.Id,
            Description__c = details.left(255));
        if (so.Ledger__c != null) {
            r.Ledger__c = so.Ledger__c;
        }
        insert r;
        if ([SELECT Status__c FROM TC_Cash_Receipt__c WHERE Id = :r.Id].Status__c != 'Posted') {
            postOrThrow(r.Id);
        }
        String applied = applyOpenPayments(new Set<Id>{ so.Id });
        TC_Cash_Receipt__c saved = [SELECT Name FROM TC_Cash_Receipt__c WHERE Id = :r.Id];
        Outcome out = new Outcome(r.Id, saved.Name, saved.Name + ': ' + amount.setScale(2) + ' received for ' + orderNo + ' (' + reference + ').'
            + (String.isBlank(applied) ? ' Not billed yet; it will be applied when the order is billed.' : applied));
        out.orderId = so.NFY_Order__c;
        out.salesOrderId = so.Id;
        return out;
    }

    /**
     * payment.reversed: { externalId, reason? }. The payment was cancelled or rejected at the source: its
     * applications are removed (TC reverses their postings) and the receipt is unposted, so the billing is open again.
     */
    private static Outcome handlePaymentReversed(String source, Map<String, Object> p) {
        String extId = req(p, 'externalId').left(80);
        List<TC_Cash_Receipt__c> found = [
            SELECT Id, Name, Status__c, Amount__c, Description__c, NFY_Sales_Order__c, NFY_Sales_Order__r.NFY_Order__c
            FROM TC_Cash_Receipt__c WHERE NFY_External_Id__c = :extId LIMIT 1
        ];
        if (found.isEmpty()) {
            // A payment that never reached Salesforce (it failed, for example for a missing order number) and is now
            // cancelled at the source leaves nothing to reverse: its open failures are closed. With no failure on
            // record the reversal may have overtaken the payment itself, so it still waits for a retry.
            List<NFY_Sync_Log__c> left = [
                SELECT Id, Response__c FROM NFY_Sync_Log__c
                WHERE External_Id__c = :extId AND Event_Type__c IN ('payment.received', 'payment.reconcile')
                    AND Status__c = 'Failed' AND Resolved__c = false
            ];
            if (left.isEmpty()) {
                throw new NFYException('No payment ' + extId + ' is recorded in Salesforce, so there is nothing to reverse.');
            }
            String why = String.isBlank(str(p.get('reason'))) ? '' : ' (' + str(p.get('reason')) + ')';
            for (NFY_Sync_Log__c f : left) {
                f.Resolved__c = true;
                f.Retry_Status__c = 'Superseded';
                f.Response__c = ('Closed: ' + extId + ' was cancelled in ' + source + why + ' before it was recorded in Salesforce.'
                    + (String.isBlank(f.Response__c) ? '' : ' ' + f.Response__c)).left(32768);
            }
            update left;
            Outcome none = new Outcome(null, extId, 'Nothing to reverse: ' + extId + ' was cancelled in ' + source + why
                + ' before it was recorded in Salesforce. Closed ' + left.size() + ' open failure(s) it left.');
            none.operation = 'No change';
            return none;
        }
        TC_Cash_Receipt__c r = found[0];
        List<TC_Billing_Cash_Receipt__c> apps = [SELECT Id, Applied_Amount__c FROM TC_Billing_Cash_Receipt__c WHERE Cash_Receipt__c = :r.Id];
        if (r.Status__c != 'Posted' && apps.isEmpty()) {
            Outcome same = new Outcome(r.Id, r.Name, r.Name + ' is already reversed.');
            same.salesOrderId = r.NFY_Sales_Order__c;
            same.orderId = r.NFY_Sales_Order__r == null ? null : r.NFY_Sales_Order__r.NFY_Order__c;
            return same;
        }
        Decimal unapplied = 0;
        for (TC_Billing_Cash_Receipt__c a : apps) {
            unapplied += nz(a.Applied_Amount__c);
        }
        delete apps;
        if (r.Status__c == 'Posted') {
            TC_PostResult res = TC_PostingEngine.unpost(new List<Id>{ r.Id })[0];
            if (!res.isSuccess) {
                throw new NFYException('TC could not unpost ' + r.Name + ': ' + String.join(res.errors, ' '));
            }
        }
        String reason = String.isBlank(str(p.get('reason'))) ? '' : ' (' + str(p.get('reason')) + ')';
        update new TC_Cash_Receipt__c(Id = r.Id,
            Description__c = ('Reversed by ' + source + reason + '. ' + (r.Description__c == null ? '' : r.Description__c)).left(255));
        if (nz(r.Amount__c) < 0) {
            // A cancelled refund: the money never left, so the credit created for it is withdrawn and the cash goes back on the invoices.
            String undone = undoRefundCredit(extId, r.NFY_Sales_Order__c);
            Outcome refundOut = new Outcome(r.Id, r.Name, r.Name + ' (refund) reversed' + reason + ': receipt unposted.' + undone);
            refundOut.salesOrderId = r.NFY_Sales_Order__c;
            refundOut.orderId = r.NFY_Sales_Order__r == null ? null : r.NFY_Sales_Order__r.NFY_Order__c;
            return refundOut;
        }
        Outcome out = new Outcome(r.Id, r.Name, r.Name + ' reversed' + reason + ': ' + unapplied.setScale(2) + ' removed from billings and the receipt unposted.');
        out.salesOrderId = r.NFY_Sales_Order__c;
        out.orderId = r.NFY_Sales_Order__r == null ? null : r.NFY_Sales_Order__r.NFY_Order__c;
        return out;
    }

    /**
     * payment.refunded: { externalId, orderNumber, amount, currency?, date, method?, reference?, memo? }. Money paid back to
     * the customer at the source (Odoo customer refund, an outbound customer payment). Recorded as one posted negative
     * TC_Cash_Receipt__c linked to the order (credit bank, debit unapplied cash), never twice (externalId is unique).
     *
     * TC applies cash only to invoices and only in positive amounts, so a refund is booked in this order:
     *   1. cash still unapplied on the order (paid, not billed) is refunded first;
     *   2. for the rest, that much cash is taken off the order's invoices (newest application first) and the
     *      invoices are credited instead: open credit memos of the order (returns) first, then a new refund credit
     *      memo (GL 4090, PO Number = externalId) for what is still missing;
     *   3. the negative receipt takes the money out of the bank.
     * Net effect: debit refunds (4090), credit bank; AR and unapplied cash are back to what the customer still owes or holds.
     */
    private static Outcome handleRefund(String source, Map<String, Object> p) {
        String extId = req(p, 'externalId').left(80);
        List<TC_Cash_Receipt__c> known = [SELECT Id, Name FROM TC_Cash_Receipt__c WHERE NFY_External_Id__c = :extId LIMIT 1];
        if (!known.isEmpty()) {
            return new Outcome(known[0].Id, known[0].Name, extId + ' is already recorded as ' + known[0].Name + '.');
        }
        String orderNo = str(p.get('orderNumber'));
        if (String.isBlank(orderNo)) {
            throw new NFYException('Refund ' + extId + ' has no order number. Add the sale order to the refund memo in ' + source + ', then retry.');
        }
        List<TC_Sales_Order__c> sos = [
            SELECT Id, Name, Customer__c, Ledger__c, NFY_Order__c, NFY_Channel__c, NFY_External_Order_Id__c
            FROM TC_Sales_Order__c WHERE NFY_External_Order_Id__c = :orderNo LIMIT 1
        ];
        if (sos.isEmpty()) {
            throw new NFYException('No Salesforce order matches ' + orderNo + ' for refund ' + extId + '. Sync the order first, then retry the refund.');
        }
        TC_Sales_Order__c so = sos[0];
        String payCurrency = String.isBlank(str(p.get('currency'))) ? null : str(p.get('currency')).toUpperCase();
        Decimal amount = (dec(p.get('amount')).abs() * NFY_Ref.toCorporateRate(payCurrency)).setScale(2, RoundingMode.HALF_UP);
        if (amount <= 0) {
            throw new NFYException('Refund ' + extId + ' has no amount to record.');
        }
        Date d = dateOf(p.get('date'), Date.today());
        String method = str(p.get('method'));
        String reference = String.isBlank(str(p.get('reference'))) ? extId : str(p.get('reference'));

        Decimal received = 0;
        Decimal unapplied = 0;
        for (TC_Cash_Receipt__c c : [SELECT Amount__c, Balance__c FROM TC_Cash_Receipt__c WHERE NFY_Sales_Order__c = :so.Id AND Status__c = 'Posted']) {
            received += nz(c.Amount__c);
            unapplied += nz(c.Balance__c);
        }
        if (amount > received) {
            throw new NFYException('Refund ' + extId + ' of ' + amount.setScale(2) + ' is more than the ' + received.setScale(2) + ' received for ' + orderNo
                + ' in Salesforce. Record the customer payment first, then retry the refund.');
        }
        Decimal fromUnapplied = Math.max(0, Math.min(amount, unapplied));
        Decimal toCredit = amount - fromUnapplied;
        List<String> notes = new List<String>();
        if (fromUnapplied > 0) {
            notes.add(fromUnapplied.setScale(2) + ' from unapplied cash');
        }
        if (toCredit > 0) {
            notes.add(creditInvoicesForRefund(so, toCredit, extId, reference, d));
        }

        TC_Cash_Receipt__c r = new TC_Cash_Receipt__c(Account__c = NFY_Ref.payer(so.NFY_Channel__c, so.Customer__c), Amount__c = -amount,
            Receipt_Date__c = d, Payment_Reference__c = reference.left(80), Payment_Type__c = paymentType(method, null),
            Bank_Account__c = NFY_Ref.gl('1000'), Status__c = 'Approved', NFY_External_Id__c = extId, NFY_Sales_Order__c = so.Id,
            Description__c = ('Refund to customer: ' + source + ' ' + reference + (method == null ? '' : ' by ' + method)
                + (payCurrency == null ? '' : ', ' + payCurrency) + (String.isBlank(str(p.get('memo'))) ? '' : '. Memo: ' + str(p.get('memo')))).left(255));
        if (so.Ledger__c != null) {
            r.Ledger__c = so.Ledger__c;
        }
        insert r;
        if ([SELECT Status__c FROM TC_Cash_Receipt__c WHERE Id = :r.Id].Status__c != 'Posted') {
            postOrThrow(r.Id);
        }
        String applied = applyOpenPayments(new Set<Id>{ so.Id });
        TC_Cash_Receipt__c saved = [SELECT Name FROM TC_Cash_Receipt__c WHERE Id = :r.Id];
        Outcome out = new Outcome(r.Id, saved.Name, saved.Name + ': ' + amount.setScale(2) + ' refunded for ' + orderNo + ' (' + reference + '): '
            + String.join(notes, '; ').removeEnd('.') + '.' + applied);
        out.orderId = so.NFY_Order__c;
        out.salesOrderId = so.Id;
        return out;
    }

    /**
     * Takes `amount` of cash off the order's invoices and credits the invoices instead (see handleRefund).
     * Returns a note for the log.
     */
    private static String creditInvoicesForRefund(TC_Sales_Order__c so, Decimal amount, String extId, String reference, Date d) {
        // 1. Cash off the invoices, newest application first. Applications cannot be edited, so each is replaced.
        Decimal left = amount;
        List<TC_Billing_Cash_Receipt__c> removed = new List<TC_Billing_Cash_Receipt__c>();
        List<TC_Billing_Cash_Receipt__c> remainder = new List<TC_Billing_Cash_Receipt__c>();
        for (TC_Billing_Cash_Receipt__c a : [
            SELECT Id, Billing__c, Cash_Receipt__c, Applied_Amount__c, Adjustment_Amount__c, Applied_Date__c
            FROM TC_Billing_Cash_Receipt__c
            WHERE Billing__r.Sales_Order__c = :so.Id AND Cash_Receipt__r.NFY_Sales_Order__c = :so.Id AND Applied_Amount__c > 0
            ORDER BY Applied_Date__c DESC, CreatedDate DESC
        ]) {
            if (left <= 0) {
                break;
            }
            Decimal take = Math.min(left, a.Applied_Amount__c);
            removed.add(a);
            Decimal rest = a.Applied_Amount__c - take;
            if (rest > 0 || nz(a.Adjustment_Amount__c) > 0) {
                remainder.add(new TC_Billing_Cash_Receipt__c(Billing__c = a.Billing__c, Cash_Receipt__c = a.Cash_Receipt__c,
                    Applied_Amount__c = rest, Adjustment_Amount__c = a.Adjustment_Amount__c, Applied_Date__c = a.Applied_Date__c));
            }
            left -= take;
        }
        if (left > 0) {
            throw new NFYException('Refund ' + extId + ': only ' + (amount - left).setScale(2) + ' of the customer\'s cash is applied to '
                + so.NFY_External_Order_Id__c + ' invoices, so ' + amount.setScale(2) + ' cannot be taken back. Check the order\'s cash receipts.');
        }
        delete removed;
        insert remainder;

        // 2. Credit: the order's open credit memos first, then a refund credit memo for the rest.
        List<TC_Billing__c> credits = [
            SELECT Id, Name, Balance__c FROM TC_Billing__c
            WHERE Sales_Order__c = :so.Id AND Status__c = 'Posted' AND Total__c < 0 AND Balance__c < 0 ORDER BY Date__c, Name
        ];
        Decimal open = 0;
        for (TC_Billing__c c : credits) {
            open -= c.Balance__c;
        }
        String created = '';
        if (open < amount) {
            Decimal missing = amount - open;
            TC_Billing__c cm = new TC_Billing__c(Customer__c = NFY_Ref.payer(so.NFY_Channel__c, so.Customer__c), Ledger__c = so.Ledger__c, Sales_Order__c = so.Id,
                Date__c = d, Status__c = 'Approved', NFY_Channel__c = so.NFY_Channel__c, PO_Number__c = extId.left(80),
                Billing_Comment__c = 'Refund ' + reference + ' for order ' + so.NFY_External_Order_Id__c);
            insert cm;
            insert new TC_Billing_Line__c(Billing__c = cm.Id, Description__c = 'Customer refund ' + reference, Quantity__c = 1,
                Unit_Price__c = -missing, Revenue_GL_Account__c = NFY_Ref.gl('4090'), Date__c = d);
            postOrThrow(cm.Id);
            TC_Billing__c saved = [SELECT Id, Name, Balance__c FROM TC_Billing__c WHERE Id = :cm.Id];
            credits.add(saved);
            created = ' Credit memo ' + saved.Name + ' for ' + missing.setScale(2) + ' posted.';
        }

        // 3. Apply the credit to the invoices that now carry the balance, oldest first.
        List<TC_Billing_Credit_Memo__c> apps = new List<TC_Billing_Credit_Memo__c>();
        List<String> used = new List<String>();
        Decimal toApply = amount;
        Map<Id, Decimal> creditLeft = new Map<Id, Decimal>();
        for (TC_Billing__c c : credits) {
            creditLeft.put(c.Id, -c.Balance__c);
        }
        for (TC_Billing__c inv : [
            SELECT Id, Name, Balance__c FROM TC_Billing__c
            WHERE Sales_Order__c = :so.Id AND Status__c = 'Posted' AND Total__c > 0 AND Balance__c > 0 ORDER BY Date__c, Name
        ]) {
            Decimal invLeft = inv.Balance__c;
            for (TC_Billing__c c : credits) {
                if (toApply <= 0 || invLeft <= 0) {
                    break;
                }
                Decimal amt = Math.min(Math.min(toApply, invLeft), creditLeft.get(c.Id));
                if (amt <= 0) {
                    continue;
                }
                apps.add(new TC_Billing_Credit_Memo__c(Credit_Memo__c = c.Id, Invoice__c = inv.Id, Amount__c = amt));
                used.add(amt.setScale(2) + ' of ' + c.Name + ' to ' + inv.Name);
                creditLeft.put(c.Id, creditLeft.get(c.Id) - amt);
                invLeft -= amt;
                toApply -= amt;
            }
        }
        insert apps;
        return amount.setScale(2) + ' taken off invoice(s) and credited (' + String.join(used, ', ') + ').' + created;
    }

    /**
     * Withdraws the credit a cancelled refund created: its own credit memo's applications are deleted and the memo is
     * unposted; then the order's cash is applied to the reopened invoices again. Credit from returns stays.
     */
    private static String undoRefundCredit(String extId, Id salesOrderId) {
        List<TC_Billing__c> own = [
            SELECT Id, Name FROM TC_Billing__c WHERE Sales_Order__c = :salesOrderId AND PO_Number__c = :extId AND Total__c < 0 AND Status__c = 'Posted'
        ];
        String note = '';
        if (!own.isEmpty()) {
            delete [SELECT Id FROM TC_Billing_Credit_Memo__c WHERE Credit_Memo__c IN :own];
            for (TC_PostResult res : TC_PostingEngine.unpost(new List<Id>(new Map<Id, TC_Billing__c>(own).keySet()))) {
                if (!res.isSuccess) {
                    throw new NFYException('TC could not unpost ' + res.name + ': ' + String.join(res.errors, ' '));
                }
            }
            for (TC_Billing__c b : own) {
                b.Billing_Comment__c = 'Withdrawn: refund ' + extId + ' was cancelled.';
            }
            update own;
            note = ' Credit memo ' + own[0].Name + ' withdrawn.';
        }
        String applied = salesOrderId == null ? '' : applyOpenPayments(new Set<Id>{ salesOrderId });
        return note + applied;
    }

    /**
     * Applies posted, unapplied customer payments linked to these orders to the orders' posted billings with a
     * balance, oldest first, never beyond either balance. Refunds (negative receipts) on the order reduce the cash
     * that can be applied. Returns a note for the log, or '' when nothing was applied.
     */
    @TestVisible
    private static String applyOpenPayments(Set<Id> salesOrderIds) {
        Map<Id, List<TC_Cash_Receipt__c>> receipts = new Map<Id, List<TC_Cash_Receipt__c>>();
        Map<Id, Decimal> netCash = new Map<Id, Decimal>();
        for (TC_Cash_Receipt__c r : [
            SELECT Id, Name, Account__c, Balance__c, Receipt_Date__c, NFY_Sales_Order__c FROM TC_Cash_Receipt__c
            WHERE NFY_Sales_Order__c IN :salesOrderIds AND Status__c = 'Posted' AND Balance__c != 0
            ORDER BY Receipt_Date__c, CreatedDate
        ]) {
            netCash.put(r.NFY_Sales_Order__c, (netCash.containsKey(r.NFY_Sales_Order__c) ? netCash.get(r.NFY_Sales_Order__c) : 0) + r.Balance__c);
            if (r.Balance__c < 0) {
                continue;
            }
            if (!receipts.containsKey(r.NFY_Sales_Order__c)) {
                receipts.put(r.NFY_Sales_Order__c, new List<TC_Cash_Receipt__c>());
            }
            receipts.get(r.NFY_Sales_Order__c).add(r);
        }
        for (Id soId : new List<Id>(receipts.keySet())) {
            if (netCash.get(soId) <= 0) {
                receipts.remove(soId);
            }
        }
        if (receipts.isEmpty()) {
            return '';
        }
        List<TC_Billing__c> bills = [
            SELECT Id, Name, Customer__c, Balance__c, Date__c, Sales_Order__c FROM TC_Billing__c
            WHERE Sales_Order__c IN :receipts.keySet() AND Status__c = 'Posted' AND Balance__c > 0
            ORDER BY Date__c, Name
        ];
        Map<Id, Decimal> billLeft = new Map<Id, Decimal>();
        for (TC_Billing__c b : bills) {
            billLeft.put(b.Id, b.Balance__c);
        }
        List<TC_Billing_Cash_Receipt__c> apps = new List<TC_Billing_Cash_Receipt__c>();
        List<String> notes = new List<String>();
        for (Id soId : receipts.keySet()) {
            Decimal soLeft = netCash.get(soId);
            for (TC_Cash_Receipt__c r : receipts.get(soId)) {
                Decimal left = Math.min(r.Balance__c, soLeft);
                for (TC_Billing__c b : bills) {
                    if (b.Sales_Order__c != soId || b.Customer__c != r.Account__c || left <= 0 || billLeft.get(b.Id) <= 0) {
                        continue;
                    }
                    Decimal amt = Math.min(left, billLeft.get(b.Id));
                    soLeft -= amt;
                    Date applied = r.Receipt_Date__c != null && b.Date__c != null && r.Receipt_Date__c > b.Date__c ? r.Receipt_Date__c : b.Date__c;
                    apps.add(new TC_Billing_Cash_Receipt__c(Billing__c = b.Id, Cash_Receipt__c = r.Id, Applied_Amount__c = amt, Applied_Date__c = applied));
                    notes.add(amt.setScale(2) + ' of ' + r.Name + ' applied to ' + b.Name);
                    left -= amt;
                    billLeft.put(b.Id, billLeft.get(b.Id) - amt);
                }
            }
        }
        if (apps.isEmpty()) {
            return '';
        }
        insert apps;
        return ' ' + String.join(notes, '; ') + '.';
    }

    // ------------------------------------------------------------------ payment reconciliation

    /** Most repairs (missed payments or reversals) one snapshot makes; the rest are repaired by the next run. */
    @TestVisible
    private static Integer maxRepairs = 10;

    /**
     * payment.snapshot: { snapshotId, from, to, externalIdPrefix, payments: [ { externalId, state, amount, currency, orderNumber,
     * date, method, reference, providerReference, memo } ] }. The source's customer payments changed in the window, sent once a day.
     *
     * Repaired automatically (what the payment events would have done): paid payments with no receipt are recorded,
     * cancelled or rejected payments still posted in Salesforce are reversed, and unapplied cash on billed orders is applied.
     * Reported for review as open payment.reconcile logs (one per payment, shown in the Command Center and retryable):
     * amount differences, payments paid at the source but reversed in Salesforce, and receipts that exist only in Salesforce.
     * A finding clears itself when a later snapshot or a retry finds the payment matching.
     */
    private static Outcome handlePaymentSnapshot(String source, Map<String, Object> p) {
        String snapshotId = req(p, 'snapshotId');
        List<Object> payments = items(p, 'payments');
        Datetime fromTs = datetimeOf(p.get('from'));
        Datetime toTs = datetimeOf(p.get('to'));
        String prefix = str(p.get('externalIdPrefix'));

        Set<String> seen = new Set<String>();
        Map<String, Map<String, Object>> findings = new Map<String, Map<String, Object>>();
        Map<String, String> findingText = new Map<String, String>();
        List<String> repaired = new List<String>();
        Integer[] repairsLeft = new Integer[]{ maxRepairs };
        for (Object o : payments) {
            Map<String, Object> pay = (Map<String, Object>) o;
            String extId = str(pay.get('externalId'));
            if (extId == null) {
                continue;
            }
            seen.add(extId);
            List<String> note = new List<String>();
            String issue = reconcilePayment(source, pay, note, repairsLeft);
            if (issue != null) {
                findings.put(extId, pay);
                findingText.put(extId, issue);
            } else if (!note.isEmpty()) {
                repaired.addAll(note);
            }
        }
        // Receipts recorded in Salesforce for this source in the window that the source does not list.
        if (prefix != null && fromTs != null && toTs != null) {
            String pattern = prefix + '%';
            for (TC_Cash_Receipt__c r : [
                SELECT Name, NFY_External_Id__c, Amount__c, Status__c FROM TC_Cash_Receipt__c
                WHERE NFY_External_Id__c LIKE :pattern AND CreatedDate >= :fromTs AND CreatedDate <= :toTs AND Status__c = 'Posted'
                LIMIT 500
            ]) {
                if (!seen.contains(r.NFY_External_Id__c)) {
                    findings.put(r.NFY_External_Id__c, new Map<String, Object>{ 'externalId' => r.NFY_External_Id__c, 'onlyInSalesforce' => true });
                    findingText.put(r.NFY_External_Id__c, r.Name + ' (' + r.NFY_External_Id__c + ', ' + r.Amount__c.setScale(2)
                        + ') is posted in Salesforce but ' + source + ' did not report this payment. Check it at the source.');
                }
            }
        }
        // Cash recorded before its order was billed and still unapplied: apply it now if the order has a posted billing.
        Set<Id> withCash = new Set<Id>();
        for (TC_Cash_Receipt__c r : [
            SELECT NFY_Sales_Order__c FROM TC_Cash_Receipt__c
            WHERE NFY_External_Id__c IN :seen AND Status__c = 'Posted' AND Balance__c > 0 AND NFY_Sales_Order__c != null
        ]) {
            withCash.add(r.NFY_Sales_Order__c);
        }
        String applied = withCash.isEmpty() ? '' : applyOpenPayments(withCash);
        if (String.isNotBlank(applied)) {
            repaired.add(applied.trim().removeEnd('.'));
        }
        Set<String> clean = new Set<String>(seen);
        clean.removeAll(findings.keySet());
        Integer opened = recordFindings(source, findings, findingText, clean);

        String msg = 'Payment reconciliation ' + snapshotId + ': ' + seen.size() + ' payment(s) from ' + source + ' checked. '
            + (repaired.isEmpty() ? 'Nothing to repair. ' : 'Repaired: ' + String.join(repaired, '; ') + '. ')
            + (findings.isEmpty() ? 'Everything matches.' : findings.size() + ' difference(s) need review (' + opened + ' new).');
        Outcome out = new Outcome(null, snapshotId, msg.left(32000));
        out.operation = 'No change';
        return out;
    }

    /**
     * Checks one source payment against Salesforce and repairs what is safe to repair. Returns the problem that needs
     * a person, or null when the payment matches (after any repair). note collects what was repaired.
     */
    @TestVisible
    private static String reconcilePayment(String source, Map<String, Object> pay, List<String> note) {
        return reconcilePayment(source, pay, note, new Integer[]{ maxRepairs });
    }

    private static String reconcilePayment(String source, Map<String, Object> pay, List<String> note, Integer[] repairsLeft) {
        String extId = str(pay.get('externalId'));
        if (pay.get('onlyInSalesforce') == true) {
            List<TC_Cash_Receipt__c> still = [SELECT Name FROM TC_Cash_Receipt__c WHERE NFY_External_Id__c = :extId AND Status__c = 'Posted' LIMIT 1];
            return still.isEmpty() ? null : still[0].Name + ' (' + extId + ') is posted in Salesforce but ' + source + ' did not report this payment. Check it at the source.';
        }
        String state = str(pay.get('state'));
        List<TC_Cash_Receipt__c> rs = [SELECT Id, Name, Amount__c, Status__c FROM TC_Cash_Receipt__c WHERE NFY_External_Id__c = :extId LIMIT 1];
        TC_Cash_Receipt__c r = rs.isEmpty() ? null : rs[0];
        Boolean paid = state == 'paid' || state == 'reconciled';
        Boolean reversed = state == 'canceled' || state == 'rejected';
        Boolean refund = str(pay.get('direction')) == 'outbound';
        if (paid && r == null) {
            if (repairsLeft[0] <= 0) {
                return extId + ' is paid in ' + source + ' but not recorded in Salesforce yet; it will be recorded on the next run.';
            }
            repairsLeft[0]--;
            Savepoint sp = Database.setSavepoint();
            try {
                Outcome o = refund ? handleRefund(source, pay) : handlePayment(source, pay);
                if (note != null) {
                    note.add(extId + ' recorded as ' + o.recordName);
                }
                return null;
            } catch (Exception e) {
                Database.rollback(sp);
                return extId + ' is paid in ' + source + ' but could not be recorded in Salesforce: ' + cleanMessage(e);
            }
        }
        if (paid && r.Status__c != 'Posted') {
            return extId + ' is ' + state + ' in ' + source + ' but ' + r.Name + ' is reversed in Salesforce. Check which is right.';
        }
        if (paid) {
            String cur = String.isBlank(str(pay.get('currency'))) ? null : str(pay.get('currency')).toUpperCase();
            Decimal expected = (dec(pay.get('amount')).abs() * NFY_Ref.toCorporateRate(cur)).setScale(2, RoundingMode.HALF_UP);
            if (refund) {
                expected = -expected;
            }
            if ((nz(r.Amount__c) - expected).abs() > 0.01) {
                return extId + ' is ' + expected.setScale(2) + ' in ' + source + ' but ' + r.Name + ' records ' + nz(r.Amount__c).setScale(2) + '.';
            }
            return null;
        }
        if (reversed && r != null && r.Status__c == 'Posted') {
            if (repairsLeft[0] <= 0) {
                return extId + ' is ' + state + ' in ' + source + ' but ' + r.Name + ' is still posted; it will be reversed on the next run.';
            }
            repairsLeft[0]--;
            Savepoint sp = Database.setSavepoint();
            try {
                handlePaymentReversed(source, new Map<String, Object>{ 'externalId' => extId, 'reason' => 'Payment ' + state + ' in ' + source + ' (reconciliation)' });
                if (note != null) {
                    note.add(r.Name + ' reversed');
                }
                return null;
            } catch (Exception e) {
                Database.rollback(sp);
                return extId + ' is ' + state + ' in ' + source + ' but ' + r.Name + ' could not be reversed: ' + cleanMessage(e);
            }
        }
        return null;
    }

    /**
     * One open payment.reconcile log per payment that needs review, unless an open one already says the same; open
     * findings for payments that now match are closed. Returns how many new findings were opened.
     */
    private static Integer recordFindings(String source, Map<String, Map<String, Object>> findings, Map<String, String> text, Set<String> clean) {
        Set<String> all = new Set<String>(findings.keySet());
        all.addAll(clean);
        Map<String, NFY_Sync_Log__c> open = new Map<String, NFY_Sync_Log__c>();
        for (NFY_Sync_Log__c l : [
            SELECT Id, External_Id__c, Error_Message__c FROM NFY_Sync_Log__c
            WHERE Event_Type__c = 'payment.reconcile' AND External_Id__c IN :all AND Status__c = 'Failed' AND Resolved__c = false
        ]) {
            open.put(l.External_Id__c, l);
        }
        List<NFY_Sync_Log__c> inserts = new List<NFY_Sync_Log__c>();
        List<NFY_Sync_Log__c> updates = new List<NFY_Sync_Log__c>();
        NFY_Integration_System__c sys = NFY_Ref.system(source);
        NFY_Integration_Flow__c flow = NFY_Ref.flow(source, 'Payment');
        for (String extId : findings.keySet()) {
            NFY_Sync_Log__c existing = open.get(extId);
            if (existing != null) {
                if (existing.Error_Message__c != text.get(extId)) {
                    updates.add(new NFY_Sync_Log__c(Id = existing.Id, Error_Message__c = text.get(extId)));
                }
                continue;
            }
            inserts.add(new NFY_Sync_Log__c(Event_Type__c = 'payment.reconcile', Entity__c = 'Payment', Status__c = 'Failed',
                Direction__c = 'Into Salesforce', Source__c = 'Workato', Received_At__c = System.now(), Attempts__c = 1,
                External_Id__c = extId.left(120), Error_Message__c = text.get(extId), Retry_Status__c = 'Waiting for fix', Resolved__c = false,
                Payload__c = JSON.serialize(findings.get(extId)).left(131072),
                System__c = sys == null ? null : sys.Id, Flow__c = flow == null ? null : flow.Id));
        }
        for (String extId : clean) {
            if (open.containsKey(extId)) {
                updates.add(new NFY_Sync_Log__c(Id = open.get(extId).Id, Resolved__c = true, Retry_Status__c = 'Resolved',
                    Error_Message__c = open.get(extId).Error_Message__c + ' Matched on a later reconciliation.'));
            }
        }
        insert inserts;
        update updates;
        return inserts.size();
    }

    private static Datetime datetimeOf(Object o) {
        String s = str(o);
        if (String.isBlank(s)) {
            return null;
        }
        try {
            return (Datetime) JSON.deserialize('"' + s.replace(' ', 'T') + (s.length() <= 19 ? 'Z' : '') + '"', Datetime.class);
        } catch (Exception e) {
            return null;
        }
    }

    /** TC payment type from the source's method name: checks, electronic payments (online, card, transfer), or other. */
    @TestVisible
    private static String paymentType(String method, String providerReference) {
        String m = method == null ? '' : method.toLowerCase();
        if (m.contains('check') || m.contains('cheque')) {
            return 'Check';
        }
        if (String.isNotBlank(providerReference) || m.contains('card') || m.contains('online') || m.contains('transfer') || m.contains('wire')
                || m.contains('electronic') || m.contains('bank') || m.contains('stripe') || m.contains('paypal') || m.contains('adyen')) {
            return 'Electronic';
        }
        return 'Other';
    }

    // ------------------------------------------------------------------ Direct from Factory (drop-ship)

    public static final String FACTORY = 'FACTORY';

    /** Lines that ship direct from the factory get one drop-ship PO to the factory, linked line by line. Returns a note, or null. */
    private static String raiseDropShipPo(TC_Sales_Order__c so, List<TC_Sales_Order_Line__c> soLines, String orderNo, Date orderDate) {
        if (!NFY_Ref.hasWarehouse(FACTORY)) {
            return null;
        }
        Id factory = NFY_Ref.warehouse(FACTORY).Id;
        List<TC_Sales_Order_Line__c> drop = new List<TC_Sales_Order_Line__c>();
        Decimal units = 0;
        for (TC_Sales_Order_Line__c l : soLines) {
            if (l.NFY_Ship_From__c == factory) {
                drop.add(l);
                units += l.Quantity_Ordered__c;
            }
        }
        if (drop.isEmpty()) {
            return null;
        }
        List<Account> vendor = [SELECT Id FROM Account WHERE NFY_External_Customer_Id__c = 'VENDOR-FACTORY' LIMIT 1];
        if (vendor.isEmpty()) {
            throw new NFYException('No factory vendor account (VENDOR-FACTORY). Run the Nfinity demo setup.');
        }
        TC_Purchase_Order__c po = new TC_Purchase_Order__c(Vendor__c = vendor[0].Id, Order_Date__c = orderDate, Status__c = 'Open', Type__c = 'Drop Shipment',
            Sales_Order__c = so.Id, NFY_External_Id__c = (orderNo + '-DS').left(80), NFY_Demo__c = true, Shipping_Address__c = so.Shipping_Address__c,
            Comment__c = 'Direct from factory for ' + orderNo);
        insert po;
        List<TC_Purchase_Order_Line__c> lines = new List<TC_Purchase_Order_Line__c>();
        for (TC_Sales_Order_Line__c l : drop) {
            lines.add(new TC_Purchase_Order_Line__c(Purchase_Order__c = po.Id, Product__c = l.Product__c, Quantity__c = l.Quantity_Ordered__c, Sales_Order_Line__c = l.Id));
        }
        insert lines;
        return 'Drop-ship PO ' + [SELECT Name FROM TC_Purchase_Order__c WHERE Id = :po.Id].Name + ' raised to the factory for ' + units.intValue() + ' units';
    }

    /** When the factory confirms it shipped: receive the drop-ship PO at the factory location, then allocate those units to the order. */
    private static void receiveDropShip(TC_Sales_Order__c so, Date d) {
        List<TC_Purchase_Order_Line__c> pols = [
            SELECT Id, Purchase_Order__c, Product__c, Quantity__c, Quantity_Received__c, Sales_Order_Line__c,
                Sales_Order_Line__r.Quantity_Ordered__c, Sales_Order_Line__r.Quantity_Allocated__c
            FROM TC_Purchase_Order_Line__c
            WHERE Sales_Order_Line__r.Sales_Order__c = :so.Id AND Purchase_Order__r.Type__c = 'Drop Shipment' AND Purchase_Order__r.Status__c = 'Open'
        ];
        if (pols.isEmpty()) {
            return;
        }
        TC_Location__c loc = NFY_Ref.location(FACTORY, 'AVL');
        Map<Id, List<TC_OrderService.ReceiveLine>> byPo = new Map<Id, List<TC_OrderService.ReceiveLine>>();
        Set<Id> productIds = new Set<Id>();
        for (TC_Purchase_Order_Line__c pol : pols) {
            Decimal qty = nz(pol.Quantity__c) - nz(pol.Quantity_Received__c);
            if (qty <= 0) {
                continue;
            }
            TC_OrderService.ReceiveLine r = new TC_OrderService.ReceiveLine();
            r.lineId = pol.Id;
            r.quantity = qty;
            if (!byPo.containsKey(pol.Purchase_Order__c)) {
                byPo.put(pol.Purchase_Order__c, new List<TC_OrderService.ReceiveLine>());
            }
            byPo.get(pol.Purchase_Order__c).add(r);
            productIds.add(pol.Product__c);
        }
        for (Id poId : byPo.keySet()) {
            TC_OrderService.receive(poId, loc.Id, d, byPo.get(poId));
        }
        Map<Id, TC_Inventory_Balance__c> balances = TC_InventoryService.balancesFor(productIds, loc.Id, null);
        List<TC_SO_Inventory_Movement__c> moves = new List<TC_SO_Inventory_Movement__c>();
        for (TC_Purchase_Order_Line__c pol : pols) {
            Decimal need = nz(pol.Sales_Order_Line__r.Quantity_Ordered__c) - nz(pol.Sales_Order_Line__r.Quantity_Allocated__c);
            if (need > 0 && balances.containsKey(pol.Product__c)) {
                moves.add(new TC_SO_Inventory_Movement__c(Inventory_Balance__c = balances.get(pol.Product__c).Id, Sales_Order_Line__c = pol.Sales_Order_Line__c,
                    Quantity__c = need, Movement_Date__c = d));
            }
        }
        insert moves;
        refreshStock(new Set<Id>{ so.Id });
    }

    // ------------------------------------------------------------------ inbound.update

    private static final Map<String, String> INBOUND_STATUS = new Map<String, String>{
        'WORKING' => 'Working', 'SHIPPED' => 'Shipped', 'IN_TRANSIT' => 'In Transit', 'RECEIVING' => 'Receiving',
        'RECEIVED' => 'Closed', 'CLOSED' => 'Closed', 'CANCELLED' => 'Cancelled'
    };

    private static Outcome handleInbound(String source, Map<String, Object> p) {
        String extId = req(p, 'inboundId');
        String newStatus = INBOUND_STATUS.get(req(p, 'status').toUpperCase());
        if (newStatus == null) {
            throw new NFYException('Unknown inbound status "' + str(p.get('status')) + '".');
        }
        List<NFY_Inbound_Shipment__c> found = [
            SELECT Id, Name, Status__c, Type__c, From_Warehouse__c, From_Warehouse__r.NFY_Code__c, To_Warehouse__c, To_Warehouse__r.NFY_Code__c, To_Warehouse__r.Name,
                (SELECT Id, Product__c, Product__r.ProductCode, Quantity_Shipped__c, Quantity_Received__c FROM Lines__r)
            FROM NFY_Inbound_Shipment__c WHERE External_Id__c = :extId LIMIT 1
        ];
        NFY_Inbound_Shipment__c ib;
        String previous;
        if (found.isEmpty()) {
            TC_Warehouse__c toW = NFY_Ref.warehouse(req(p, 'to'));
            TC_Warehouse__c fromW = p.containsKey('from') && p.get('from') != null ? NFY_Ref.warehouse(str(p.get('from'))) : null;
            Id poId = null;
            if (p.containsKey('poNumber')) {
                String poNo = str(p.get('poNumber'));
                List<TC_Purchase_Order__c> po = [SELECT Id FROM TC_Purchase_Order__c WHERE NFY_External_Id__c = :poNo LIMIT 1];
                poId = po.isEmpty() ? null : po[0].Id;
            }
            ib = new NFY_Inbound_Shipment__c(Name = extId, External_Id__c = extId, Status__c = 'Working',
                Type__c = p.containsKey('type') ? str(p.get('type')) : (toW.NFY_Type__c == 'Amazon FBA' ? 'Amazon FBA inbound' : '3PL ASN'),
                From_Warehouse__c = fromW == null ? null : fromW.Id, To_Warehouse__c = toW.Id, Purchase_Order__c = poId,
                System__c = NFY_Ref.system(source).Id, ETA__c = dateOf(p.get('eta'), null),
                Container_No__c = str(p.get('containerNo')), Vessel__c = str(p.get('vessel')));
            insert ib;
            List<NFY_Inbound_Shipment_Line__c> newLines = new List<NFY_Inbound_Shipment_Line__c>();
            for (Object o : items(p, 'lines')) {
                Map<String, Object> l = (Map<String, Object>) o;
                Product2 prod = NFY_Ref.product(str(l.get('sku')));
                newLines.add(new NFY_Inbound_Shipment_Line__c(Inbound_Shipment__c = ib.Id, Product__c = prod.Id, Quantity_Shipped__c = dec(l.get('shipped')),
                    Quantity_Received__c = 0, Unit_Cost__c = prod.TC_Moving_Average_Cost__c));
            }
            insert newLines;
            ib = [
                SELECT Id, Name, Status__c, Type__c, From_Warehouse__c, From_Warehouse__r.NFY_Code__c, To_Warehouse__c, To_Warehouse__r.NFY_Code__c, To_Warehouse__r.Name,
                    (SELECT Id, Product__c, Product__r.ProductCode, Quantity_Shipped__c, Quantity_Received__c FROM Lines__r)
                FROM NFY_Inbound_Shipment__c WHERE Id = :ib.Id
            ];
            previous = 'Working';
        } else {
            ib = found[0];
            previous = ib.Status__c;
        }
        if (previous == 'Closed' || previous == 'Cancelled') {
            throw new NFYException(ib.Name + ' is already ' + previous.toLowerCase() + '.');
        }
        Boolean movesStock = ib.Type__c != 'Factory container' && ib.From_Warehouse__c != null;
        Date d = dateOf(p.get('date'), Date.today());
        String message = found.isEmpty() && previous == newStatus
            ? ib.Name + ': registered as ' + newStatus + '.'
            : ib.Name + ': ' + previous + ' → ' + newStatus + '.';
        NFY_Inbound_Shipment__c upd = new NFY_Inbound_Shipment__c(Id = ib.Id, Status__c = newStatus,
            Carrier__c = str(p.get('carrier')), Tracking_Number__c = str(p.get('tracking')));

        Boolean leavingSource = previous == 'Working' && (newStatus == 'Shipped' || newStatus == 'In Transit' || newStatus == 'Receiving' || newStatus == 'Closed');
        if (leavingSource) {
            upd.Shipped_Date__c = d;
            if (movesStock) {
                Decimal units = 0;
                for (NFY_Inbound_Shipment_Line__c l : ib.Lines__r) {
                    transfer(l.Product__c, ib.From_Warehouse__r.NFY_Code__c, 'AVL', ib.To_Warehouse__r.NFY_Code__c, 'TRANSIT', nz(l.Quantity_Shipped__c), d);
                    units += nz(l.Quantity_Shipped__c);
                }
                message += ' ' + units.intValue() + ' units moved to ' + ib.To_Warehouse__r.Name + ' In Transit.';
            }
        }
        if (newStatus == 'Receiving' || newStatus == 'Closed') {
            Map<String, Decimal> received = new Map<String, Decimal>();
            for (Object o : items(p, 'lines')) {
                Map<String, Object> l = (Map<String, Object>) o;
                if (l.containsKey('received')) {
                    received.put(str(l.get('sku')), dec(l.get('received')));
                }
            }
            List<NFY_Inbound_Shipment_Line__c> lineUpdates = new List<NFY_Inbound_Shipment_Line__c>();
            List<NFY_Inventory_Recon__c> recons = new List<NFY_Inventory_Recon__c>();
            Decimal unitsIn = 0;
            for (NFY_Inbound_Shipment_Line__c l : ib.Lines__r) {
                if (!received.containsKey(l.Product__r.ProductCode)) {
                    continue;
                }
                Decimal total = received.get(l.Product__r.ProductCode);
                Decimal delta = total - nz(l.Quantity_Received__c);
                if (delta > 0 && movesStock) {
                    transfer(l.Product__c, ib.To_Warehouse__r.NFY_Code__c, 'TRANSIT', ib.To_Warehouse__r.NFY_Code__c, 'AVL', delta, d);
                }
                unitsIn += Math.max(delta, 0);
                lineUpdates.add(new NFY_Inbound_Shipment_Line__c(Id = l.Id, Quantity_Received__c = total));
                if (newStatus == 'Closed' && total != nz(l.Quantity_Shipped__c)) {
                    Decimal gap = nz(l.Quantity_Shipped__c) - total;
                    recons.add(new NFY_Inventory_Recon__c(Recon_Date__c = d, Product__c = l.Product__c, Warehouse__c = ib.To_Warehouse__c,
                        System__c = NFY_Ref.system(source).Id, Inbound_Shipment__c = ib.Id, TC_Quantity__c = l.Quantity_Shipped__c, External_Quantity__c = total,
                        Status__c = 'Open', Note__c = ib.Name + ': shipped ' + l.Quantity_Shipped__c.intValue() + ', ' + source + ' received ' + total.intValue()
                            + '. ' + gap.intValue() + ' units still in ' + ib.To_Warehouse__r.Name + ' In Transit. Open a case with ' + NFY_Ref.system(source).Name + ' or write them off.'));
                }
            }
            update lineUpdates;
            insert recons;
            if (unitsIn > 0 && movesStock) {
                message += fillBackorders(new Set<Id>{ NFY_Ref.location(ib.To_Warehouse__r.NFY_Code__c, 'AVL').Id }, d);
            }
            if (newStatus == 'Closed') {
                upd.Received_Date__c = d;
            }
            message += ' ' + unitsIn.intValue() + (movesStock ? ' units received into available stock.' : ' units recorded as received (the stock itself comes from the stock feed).')
                + (recons.isEmpty() ? '' : ' ' + recons.size() + ' line(s) short: reconciliation opened.');
        }
        update upd;
        return new Outcome(ib.Id, ib.Name, message);
    }

    /** Moves stock between two locations as TC's linked non-accounting pair, the same records TC's own Transfer action writes. */
    public static void transfer(Id productId, String fromWh, String fromKind, String toWh, String toKind, Decimal qty, Date d) {
        if (qty == null || qty <= 0) {
            return;
        }
        TC_Location__c fromLoc = NFY_Ref.location(fromWh, fromKind);
        TC_Location__c toLoc = NFY_Ref.location(toWh, toKind);
        TC_Inventory_Balance__c src = TC_InventoryService.balancesFor(new Set<Id>{ productId }, fromLoc.Id, null).get(productId);
        TC_Inventory_Balance__c dst = TC_InventoryService.balancesFor(new Set<Id>{ productId }, toLoc.Id, null).get(productId);
        TC_Inventory_Balance__c current = [SELECT Available_Quantity__c, Product__r.Name, Product__r.TC_Moving_Average_Cost__c FROM TC_Inventory_Balance__c WHERE Id = :src.Id];
        if (nz(current.Available_Quantity__c) < qty) {
            throw new NFYException('Only ' + nz(current.Available_Quantity__c).intValue() + ' of ' + current.Product__r.Name + ' at ' + fromLoc.Name
                + '; cannot move ' + qty.intValue() + '.');
        }
        Decimal cost = current.Product__r.TC_Moving_Average_Cost__c == null ? 0 : current.Product__r.TC_Moving_Average_Cost__c.setScale(6, RoundingMode.HALF_UP);
        Boolean previous = TC_TriggerGate.allowInventoryTransfer;
        try {
            TC_TriggerGate.allowInventoryTransfer = true;
            TC_Outbound_Inventory_Movement__c outbound = new TC_Outbound_Inventory_Movement__c(Inventory_Balance__c = src.Id, Type__c = 'Non-Accounting',
                Quantity__c = qty, Unit_Cost__c = cost, Movement_Date__c = d);
            insert outbound;
            insert new TC_Inbound_Inventory_Movement__c(Inventory_Balance__c = dst.Id, Type__c = 'Non-Accounting', Quantity__c = qty,
                Unit_Cost__c = cost, Movement_Date__c = d, Outbound_Inventory_Movement__c = outbound.Id);
        } finally {
            TC_TriggerGate.allowInventoryTransfer = previous;
        }
    }

    // ------------------------------------------------------------------ po.receipt

    private static Outcome handlePoReceipt(String source, Map<String, Object> p) {
        String poNo = req(p, 'poNumber');
        List<TC_Purchase_Order__c> pos = [
            SELECT Id, Name, Status__c, (SELECT Id, Product__c, Product__r.ProductCode, Quantity__c, Quantity_Received__c FROM Purchase_Order_Lines__r)
            FROM TC_Purchase_Order__c WHERE NFY_External_Id__c = :poNo LIMIT 1
        ];
        if (pos.isEmpty()) {
            throw new NFYException('No purchase order ' + poNo + ' in Salesforce.');
        }
        TC_Purchase_Order__c po = pos[0];
        TC_Warehouse__c w = NFY_Ref.warehouse(req(p, 'warehouse'));
        Map<String, TC_Purchase_Order_Line__c> bySku = new Map<String, TC_Purchase_Order_Line__c>();
        for (TC_Purchase_Order_Line__c l : po.Purchase_Order_Lines__r) {
            bySku.put(l.Product__r.ProductCode, l);
        }
        List<TC_OrderService.ReceiveLine> receipts = new List<TC_OrderService.ReceiveLine>();
        Map<Id, Decimal> receivedByProduct = new Map<Id, Decimal>();
        Decimal units = 0;
        for (Object o : items(p, 'lines')) {
            Map<String, Object> l = (Map<String, Object>) o;
            TC_Purchase_Order_Line__c pol = bySku.get(str(l.get('sku')));
            if (pol == null) {
                throw new NFYException(str(l.get('sku')) + ' is not on ' + poNo + '.');
            }
            TC_OrderService.ReceiveLine r = new TC_OrderService.ReceiveLine();
            r.lineId = pol.Id;
            r.quantity = dec(l.get('qty'));
            receipts.add(r);
            receivedByProduct.put(pol.Product__c, nz(receivedByProduct.get(pol.Product__c)) + r.quantity);
            units += r.quantity;
        }
        Date d = dateOf(p.get('date'), Date.today());
        TC_OrderService.receive(po.Id, NFY_Ref.location(w.NFY_Code__c, 'AVL').Id, d, receipts);

        // Keep the container's lines in step with what each warehouse received.
        String inboundId = str(p.get('inboundId'));
        if (String.isNotBlank(inboundId)) {
            List<NFY_Inbound_Shipment__c> ibs = [
                SELECT Id, (SELECT Id, Product__c, Quantity_Shipped__c, Quantity_Received__c FROM Lines__r) FROM NFY_Inbound_Shipment__c WHERE External_Id__c = :inboundId LIMIT 1
            ];
            if (!ibs.isEmpty()) {
                List<NFY_Inbound_Shipment_Line__c> ups = new List<NFY_Inbound_Shipment_Line__c>();
                Boolean done = true;
                for (NFY_Inbound_Shipment_Line__c l : ibs[0].Lines__r) {
                    Decimal rec = nz(l.Quantity_Received__c) + nz(receivedByProduct.get(l.Product__c));
                    ups.add(new NFY_Inbound_Shipment_Line__c(Id = l.Id, Quantity_Received__c = rec));
                    if (rec < nz(l.Quantity_Shipped__c)) {
                        done = false;
                    }
                }
                update ups;
                update new NFY_Inbound_Shipment__c(Id = ibs[0].Id, Status__c = done ? 'Closed' : 'Receiving', Received_Date__c = done ? d : null);
            }
        }
        String status = [SELECT Status__c FROM TC_Purchase_Order__c WHERE Id = :po.Id].Status__c;
        String filled = fillBackorders(new Set<Id>{ NFY_Ref.location(w.NFY_Code__c, 'AVL').Id }, d);
        return new Outcome(po.Id, po.Name, units.intValue() + ' units of ' + poNo + ' received at ' + w.Name + '. PO is ' + status.toLowerCase() + '.' + filled);
    }

    // ------------------------------------------------------------------ inventory.snapshot

    private static Outcome handleSnapshot(String source, Map<String, Object> p) {
        TC_Warehouse__c w = NFY_Ref.warehouse(req(p, 'warehouse'));
        Date d = dateOf(p.get('asOf'), Date.today());
        Map<Id, Decimal> theirs = new Map<Id, Decimal>();
        for (Object o : items(p, 'items')) {
            Map<String, Object> i = (Map<String, Object>) o;
            theirs.put(NFY_Ref.product(str(i.get('sku'))).Id, dec(i.get('qty')));
        }
        Map<Id, Decimal> ours = new Map<Id, Decimal>();
        for (TC_Inventory_Balance__c b : [
            SELECT Product__c, Available_Quantity__c FROM TC_Inventory_Balance__c
            WHERE Location__c = :NFY_Ref.location(w.NFY_Code__c, 'AVL').Id AND Product__c IN :theirs.keySet()
        ]) {
            ours.put(b.Product__c, nz(b.Available_Quantity__c));
        }
        List<NFY_Inventory_Recon__c> recons = new List<NFY_Inventory_Recon__c>();
        Id sysId = NFY_Ref.system(source).Id;
        for (Id productId : theirs.keySet()) {
            Decimal tc = nz(ours.get(productId));
            if (tc != theirs.get(productId)) {
                recons.add(new NFY_Inventory_Recon__c(Recon_Date__c = d, Product__c = productId, Warehouse__c = w.Id, System__c = sysId,
                    TC_Quantity__c = tc, External_Quantity__c = theirs.get(productId), Status__c = 'Open',
                    Note__c = source + ' counts ' + theirs.get(productId).intValue() + ' at ' + w.Name + '; TC shows ' + tc.intValue() + '.'));
            }
        }
        insert recons;
        return new Outcome(w.Id, w.Name, theirs.size() + ' SKUs compared at ' + w.Name + '. ' + recons.size() + ' mismatch(es) opened for review.');
    }

    // ------------------------------------------------------------------ return.received

    private static Outcome handleReturn(String source, Map<String, Object> p) {
        String rma = req(p, 'rma');
        TC_Sales_Order__c so = findSalesOrder(source, str(p.get('orderNumber')), str(p.get('sfdcId')));
        Product2 prod = NFY_Ref.product(req(p, 'sku'));
        Decimal qty = dec(p.get('qty'));
        String condition = req(p, 'condition');
        TC_Warehouse__c w = NFY_Ref.warehouse(req(p, 'warehouse'));
        Date d = dateOf(p.get('date'), Date.today());
        Decimal refund = dec(p.get('refund'));

        NFY_Return__c ret = new NFY_Return__c(Name = rma, External_Id__c = rma, Channel__c = so.NFY_Channel__c, System__c = NFY_Ref.system(source).Id,
            Order__c = so.NFY_Order__c, Sales_Order__c = so.Id, Product__c = prod.Id, Quantity__c = qty, Condition__c = condition,
            Warehouse__c = w.Id, Refund_Amount__c = refund, Reason__c = str(p.get('reason')), Received_Date__c = d, Status__c = 'Received');
        insert ret;
        String message = rma + ': ' + qty.intValue() + ' × ' + prod.Name + ' returned ' + condition.toLowerCase() + ' to ' + w.Name + '.';
        if (condition == 'Sellable') {
            TC_Inventory_Balance__c b = TC_InventoryService.balancesFor(new Set<Id>{ prod.Id }, NFY_Ref.location(w.NFY_Code__c, 'AVL').Id, null).get(prod.Id);
            Decimal cost = prod.TC_Moving_Average_Cost__c == null ? nz(prod.TC_Unit_Cost__c) : prod.TC_Moving_Average_Cost__c.setScale(6, RoundingMode.HALF_UP);
            insert new TC_Inbound_Inventory_Movement__c(Inventory_Balance__c = b.Id, Type__c = 'Accounting', Quantity__c = qty, Unit_Cost__c = cost,
                Movement_Date__c = d, Credit_GL_Account__c = prod.TC_Expense_GL_Account__c);
            message += ' Restocked.';
            ret.Status__c = 'Restocked';
            message += fillBackorders(new Set<Id>{ NFY_Ref.location(w.NFY_Code__c, 'AVL').Id }, d);
        } else {
            message += ' Not restocked; flagged for write-off.';
            ret.Status__c = 'Written off';
        }
        if (refund > 0) {
            TC_Billing__c cm = new TC_Billing__c(Customer__c = NFY_Ref.payer(so.NFY_Channel__c, so.Customer__c), Ledger__c = so.Ledger__c, Sales_Order__c = so.Id,
                Date__c = d, Status__c = 'Approved', NFY_Channel__c = so.NFY_Channel__c, PO_Number__c = rma, Billing_Comment__c = 'Refund for ' + rma);
            insert cm;
            insert new TC_Billing_Line__c(Billing__c = cm.Id, Product__c = prod.Id, Description__c = 'Refund: ' + prod.Name, Quantity__c = 1,
                Unit_Price__c = -refund, Revenue_GL_Account__c = NFY_Ref.gl('4090'), Date__c = d);
            postOrThrow(cm.Id);
            ret.Credit_Memo__c = cm.Id;
            message += ' Credit memo for $' + refund.setScale(2) + ' posted.';
        }
        update ret;
        Outcome out = new Outcome(ret.Id, rma, message);
        out.orderId = so.NFY_Order__c;
        out.salesOrderId = so.Id;
        return out;
    }

    // ------------------------------------------------------------------ settlement.posted

    private static Outcome handleSettlement(String source, Map<String, Object> p) {
        String extId = req(p, 'settlementId');
        Boolean amazon = source == 'AMAZON';
        Date startD = dateOf(p.get('periodStart'), Date.today().addDays(-14));
        Date endD = dateOf(p.get('periodEnd'), Date.today());
        Decimal gross = dec(p.get('grossSales'));
        Decimal mFees = dec(p.get('marketplaceFees'));
        Decimal fFees = dec(p.get('fulfillmentFees'));
        Decimal pFees = dec(p.get('paymentFees'));
        Decimal refunds = dec(p.get('refunds'));
        Decimal fees = mFees + fFees + pFees;
        Decimal toClear = gross - refunds;
        String payerCode = amazon ? 'PAYER-AMAZON' : 'PAYER-SHOPIFY';
        Account payer = [SELECT Id, Name FROM Account WHERE NFY_External_Customer_Id__c = :payerCode LIMIT 1];
        Id sysId = NFY_Ref.system(source).Id;

        NFY_Settlement__c s = new NFY_Settlement__c(Name = extId, External_Id__c = extId, Source__c = amazon ? 'Amazon settlement' : 'Shopify payout',
            System__c = sysId, Period_Start__c = startD, Period_End__c = endD, Gross_Sales__c = gross, Marketplace_Fees__c = mFees,
            Fulfillment_Fees__c = fFees, Payment_Fees__c = pFees, Refunds__c = refunds, Net_Payout__c = toClear - fees, Status__c = 'Imported');
        insert s;

        // Apply the payout to open billings for this payer in the period, oldest first.
        Decimal remaining = toClear;
        Decimal matched = 0;
        List<TC_Billing__c> toApply = new List<TC_Billing__c>();
        for (TC_Billing__c b : [
            SELECT Id, Balance__c FROM TC_Billing__c
            WHERE Customer__c = :payer.Id AND Status__c = 'Posted' AND Balance__c > 0 AND NFY_Settlement__c = null AND Date__c >= :startD AND Date__c <= :endD
            ORDER BY Date__c, Name LIMIT 500
        ]) {
            if (remaining <= 0) {
                break;
            }
            if (b.Balance__c <= remaining) {
                toApply.add(b);
                remaining -= b.Balance__c;
                matched += b.Balance__c;
            }
        }
        if (matched > 0) {
            TC_Cash_Receipt__c receipt = new TC_Cash_Receipt__c(Account__c = payer.Id, Amount__c = matched, Payment_Reference__c = extId,
                Receipt_Date__c = endD, Status__c = 'Approved', Payment_Type__c = 'Electronic', Bank_Account__c = NFY_Ref.gl('1000'),
                Description__c = s.Source__c + ' ' + extId);
            insert receipt;
            if ([SELECT Status__c FROM TC_Cash_Receipt__c WHERE Id = :receipt.Id].Status__c != 'Posted') {
                postOrThrow(receipt.Id);
            }
            List<TC_Billing_Cash_Receipt__c> apps = new List<TC_Billing_Cash_Receipt__c>();
            List<TC_Billing__c> tagged = new List<TC_Billing__c>();
            for (TC_Billing__c b : toApply) {
                apps.add(new TC_Billing_Cash_Receipt__c(Billing__c = b.Id, Cash_Receipt__c = receipt.Id, Applied_Amount__c = b.Balance__c, Applied_Date__c = endD));
                tagged.add(new TC_Billing__c(Id = b.Id, NFY_Settlement__c = s.Id));
            }
            insert apps;
            update tagged;
        }
        Id jeId = null;
        if (fees > 0) {
            TC_Journal_Entry__c je = new TC_Journal_Entry__c(Name = (s.Source__c + ' fees ' + extId).left(80), Journal_Date__c = endD, Status__c = 'Approved',
                Reference__c = extId, Description__c = s.Source__c + ' ' + extId + ': fees withheld from payout', NFY_Demo__c = true);
            insert je;
            List<TC_Journal_Entry_Line__c> lines = new List<TC_Journal_Entry_Line__c>();
            if (mFees > 0) lines.add(new TC_Journal_Entry_Line__c(Journal_Entry__c = je.Id, GL_Account__c = NFY_Ref.gl('6100'), Debit__c = mFees, Description__c = 'Marketplace / selling fees'));
            if (fFees > 0) lines.add(new TC_Journal_Entry_Line__c(Journal_Entry__c = je.Id, GL_Account__c = NFY_Ref.gl('6110'), Debit__c = fFees, Description__c = 'FBA fulfillment fees'));
            if (pFees > 0) lines.add(new TC_Journal_Entry_Line__c(Journal_Entry__c = je.Id, GL_Account__c = NFY_Ref.gl('6120'), Debit__c = pFees, Description__c = 'Payment processing fees'));
            lines.add(new TC_Journal_Entry_Line__c(Journal_Entry__c = je.Id, GL_Account__c = NFY_Ref.gl('1000'), Credit__c = fees, Description__c = 'Withheld from payout ' + extId));
            insert lines;
            postOrThrow(je.Id);
            jeId = je.Id;
        }
        Decimal unmatched = toClear - matched;
        update new NFY_Settlement__c(Id = s.Id, Journal_Entry__c = jeId, Matched_Billings__c = toApply.size(), Matched_Amount__c = matched,
            Unmatched_Amount__c = unmatched, Status__c = unmatched == 0 ? 'Matched' : 'Exceptions');
        return new Outcome(s.Id, extId, s.Source__c + ' ' + extId + ': ' + toApply.size() + ' billings cleared ($' + matched.setScale(2) + '), fees $' + fees.setScale(2)
            + ' posted' + (unmatched == 0 ? '.' : '. $' + unmatched.setScale(2) + ' has no matching billing in Salesforce.'));
    }

    // ------------------------------------------------------------------ alerts

    /**
     * Versioned events often fail once on a half-saved state (an Odoo product before its Internal
     * Reference is stored) and are superseded seconds later. Their alert waits a minute and is sent
     * only if the failure is still open; every other failure alerts at once.
     */
    private static void raiseAlert(NFY_Sync_Log__c log, String source) {
        if (versioned(log) && !System.isQueueable() && !System.isBatch() && !System.isFuture()
                && Limits.getQueueableJobs() < Limits.getLimitQueueableJobs()) {
            System.enqueueJob(new AlertJob(log.Id, source), ALERT_DELAY_MINUTES);
            return;
        }
        alert(log, source);
    }

    private static final Integer ALERT_DELAY_MINUTES = 1;

    /** Alerts sent by AlertJob, for tests. */
    @TestVisible private static Integer delayedAlertsSent = 0;

    public class AlertJob implements Queueable {
        private Id logId;
        private String source;
        public AlertJob(Id logId, String source) {
            this.logId = logId;
            this.source = source;
        }
        public void execute(QueueableContext ctx) {
            List<NFY_Sync_Log__c> logs = [SELECT Id, Event_Type__c, External_Id__c, Error_Message__c, Status__c, Resolved__c FROM NFY_Sync_Log__c WHERE Id = :logId];
            if (logs.isEmpty() || logs[0].Status__c != 'Failed' || logs[0].Resolved__c) {
                return; // superseded or fixed in the meantime
            }
            delayedAlertsSent++;
            alert(logs[0], source);
        }
    }

    private static void alert(NFY_Sync_Log__c log, String source) {
        String title = (source == null ? 'Integration' : source) + ' sync failed: ' + log.Event_Type__c;
        try {
            EventBus.publish(new NFY_Integration_Event__e(System_Code__c = source, Severity__c = 'Error', Log_Id__c = log.Id,
                Message__c = log.Error_Message__c == null ? title : log.Error_Message__c.left(255)));
        } catch (Exception e) {
            System.debug(LoggingLevel.WARN, 'Platform event not published: ' + e.getMessage());
        }
        try {
            List<CustomNotificationType> types = [SELECT Id FROM CustomNotificationType WHERE DeveloperName = 'NFY_Integration_Alert' LIMIT 1];
            if (types.isEmpty()) {
                return;
            }
            Set<String> recipients = new Set<String>{ UserInfo.getUserId() };
            for (PermissionSetAssignment a : [SELECT AssigneeId FROM PermissionSetAssignment WHERE PermissionSet.Name = 'NFY_Demo_User' AND Assignee.IsActive = true LIMIT 20]) {
                recipients.add(a.AssigneeId);
            }
            Messaging.CustomNotification n = new Messaging.CustomNotification();
            n.setNotificationTypeId(types[0].Id);
            n.setTitle(title);
            n.setBody(log.Error_Message__c == null ? 'See the sync log.' : log.Error_Message__c.left(750));
            n.setTargetId(log.Id);
            n.send(recipients);
        } catch (Exception e) {
            System.debug(LoggingLevel.WARN, 'Notification not sent: ' + e.getMessage());
        }
    }

    // ------------------------------------------------------------------ helpers

    private static Map<String, Object> parse(String json) {
        if (String.isBlank(json)) {
            return null;
        }
        try {
            return (Map<String, Object>) System.JSON.deserializeUntyped(json);
        } catch (Exception e) {
            return null;
        }
    }

    public static String cleanMessage(Exception e) {
        if (e instanceof DmlException) {
            return ((DmlException) e).getDmlMessage(0);
        }
        return e.getMessage();
    }

    private static String req(Map<String, Object> m, String k) {
        String v = str(m.get(k));
        if (String.isBlank(v)) {
            throw new NFYException('Missing "' + k + '" in the payload.');
        }
        return v;
    }

    private static List<Object> items(Map<String, Object> m, String k) {
        Object v = m.get(k);
        if (v == null || ((List<Object>) v).isEmpty()) {
            throw new NFYException('The payload has no "' + k + '".');
        }
        return (List<Object>) v;
    }

    private static String str(Object o) {
        return o == null ? null : String.valueOf(o);
    }

    private static Decimal dec(Object o) {
        if (o == null) {
            return 0;
        }
        if (o instanceof Decimal) {
            return (Decimal) o;
        }
        if (o instanceof Integer) {
            return Decimal.valueOf((Integer) o);
        }
        if (o instanceof Long) {
            return Decimal.valueOf((Long) o);
        }
        if (o instanceof Double) {
            return Decimal.valueOf((Double) o);
        }
        return Decimal.valueOf(String.valueOf(o));
    }

    private static Date dateOf(Object o, Date fallback) {
        String s = str(o);
        return String.isBlank(s) ? fallback : Date.valueOf(s.left(10));
    }

    private static Id asId(String s) {
        if (String.isBlank(s)) {
            return null;
        }
        try {
            return Id.valueOf(s);
        } catch (Exception e) {
            return null;
        }
    }

    private static Decimal nz(Decimal d) {
        return d == null ? 0 : d;
    }
}