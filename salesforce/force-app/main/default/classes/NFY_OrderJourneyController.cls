/**
 * The Order Journey: the business lifecycle of one order, built from the records each step produces.
 *
 * Eight stages in dependency order (origin order -> received by the integration -> Salesforce sales order ->
 * allocation -> sent to ShipStation -> shipped -> billed -> billing back to the origin). Each stage's status
 * comes from real records: sync logs for the integration hops, sales order lines for allocation,
 * TC shipments and lines for shipping, TC billings for billing. Repeated or replayed integration messages
 * are folded into the stage they belong to instead of becoming timeline entries of their own, and the
 * progress bar is derived from the same stages so the two always agree.
 *
 * The raw integration messages are still returned (steps) for the audit view. Works from an Order, a TC
 * Sales Order or the Shopify Opportunity.
 */
public with sharing class NFY_OrderJourneyController {

    public static final String COMPLETED = 'Completed';
    public static final String PARTIAL = 'Partially Completed';
    public static final String PROCESSING = 'Processing';
    public static final String PENDING = 'Pending';
    public static final String FAILED = 'Failed';
    public static final String NOT_NEEDED = 'Not needed';
    public static final String NOT_AVAILABLE = 'Not available';

    /**
     * One entry in the order history. Entries sort by lifecycle step first (an event cannot come before the
     * event it depends on), then by its real timestamp, then by record number for same-second ties.
     */
    public class Step implements Comparable {
        @AuraEnabled public Integer rank;
        @AuraEnabled public String note;
        @AuraEnabled public Datetime at;
        @AuraEnabled public String systemName;
        @AuraEnabled public String title;
        @AuraEnabled public String detail;
        @AuraEnabled public String status;
        @AuraEnabled public Id recordId;
        @AuraEnabled public String recordName;
        @AuraEnabled public String kind;
        /** Systems the event passed through, source first (e.g. Odoo, Workato, Salesforce). */
        @AuraEnabled public List<String> route = new List<String>();
        /** Processing status in business words: Completed, Partially Completed, Processing, Failed. */
        @AuraEnabled public String statusLabel;
        /** Real records this event created or used (sales order, shipment, invoice, sync log). */
        @AuraEnabled public List<Ref> refs = new List<Ref>();
        /** Integration job that carried the event, when there was one. */
        @AuraEnabled public String job;
        public Integer compareTo(Object other) {
            Step o = (Step) other;
            if (rank != o.rank) return rank < o.rank ? -1 : 1;
            if (at != o.at) {
                if (at == null) return 1;
                if (o.at == null) return -1;
                return at < o.at ? -1 : 1;
            }
            return String.valueOf(recordName).compareTo(String.valueOf(o.recordName));
        }
    }

    /** A link from a history event to a real record. */
    public class Ref {
        @AuraEnabled public String label;
        @AuraEnabled public String kind;
        @AuraEnabled public Id recordId;
        Ref(String kind, String label, Id recordId) { this.kind = kind; this.label = label; this.recordId = recordId; }
    }

    /** One line under a stage: a real record or message that belongs to it. */
    public class Item {
        @AuraEnabled public Datetime at;
        @AuraEnabled public String text;
        @AuraEnabled public String status;
        @AuraEnabled public Id recordId;
        @AuraEnabled public String recordName;
        Item(Datetime at, String text, String status, Id recordId, String recordName) {
            this.at = at; this.text = text; this.status = status; this.recordId = recordId; this.recordName = recordName;
        }
    }

    public class Stage {
        @AuraEnabled public Integer num;
        @AuraEnabled public String key;
        @AuraEnabled public String path;
        @AuraEnabled public String title;
        @AuraEnabled public String status = PENDING;
        @AuraEnabled public Datetime at;
        @AuraEnabled public String detail;
        @AuraEnabled public Id recordId;
        @AuraEnabled public String recordName;
        @AuraEnabled public List<Item> items = new List<Item>();
        Stage(Integer num, String key, String path, String title) {
            this.num = num; this.key = key; this.path = path; this.title = title;
        }
        Boolean done() { return status == COMPLETED || status == NOT_NEEDED; }
        Boolean started() { return done() || status == PARTIAL; }
    }

    public class Journey {
        @AuraEnabled public String orderNumber;
        @AuraEnabled public String channel;
        @AuraEnabled public String originSystem;
        @AuraEnabled public String fulfillmentStatus;
        @AuraEnabled public String routing;
        @AuraEnabled public Id orderId;
        @AuraEnabled public Id salesOrderId;
        @AuraEnabled public String salesOrderName;
        @AuraEnabled public List<String> stages = new List<String>{ 'Order created', 'Allocated', 'Shipped', 'Billed' };
        @AuraEnabled public Integer stageIndex = 0;
        @AuraEnabled public List<Stage> lifecycle = new List<Stage>();
        @AuraEnabled public List<Step> steps = new List<Step>();
        @AuraEnabled public List<Map<String, Object>> lines = new List<Map<String, Object>>();
    }

    @AuraEnabled(cacheable=false)
    public static Journey getJourney(Id recordId) {
        Journey j = new Journey();
        List<TC_Sales_Order__c> found = [
            SELECT Id, Name, NFY_Order__c, NFY_Order__r.OrderNumber, NFY_Order__r.NFY_ShipStation_Order_Id__c, NFY_Channel__c,
                NFY_Fulfillment_Status__c, NFY_External_Order_Id__c, NFY_Routing_Decision__c, NFY_Source_System__c,
                NFY_Source_Record_Id__c, CreatedDate, Customer__r.Name, Order_Date__c
            FROM TC_Sales_Order__c WHERE Id = :recordId OR NFY_Order__c = :recordId OR Opportunity__c = :recordId LIMIT 1
        ];
        if (found.isEmpty()) {
            return j;
        }
        TC_Sales_Order__c so = found[0];
        j.orderNumber = so.NFY_External_Order_Id__c;
        j.channel = so.NFY_Channel__c;
        j.fulfillmentStatus = so.NFY_Fulfillment_Status__c;
        j.routing = so.NFY_Routing_Decision__c;
        j.orderId = so.NFY_Order__c;
        j.salesOrderId = so.Id;
        j.salesOrderName = so.Name;

        String extId = so.NFY_External_Order_Id__c;
        String versionedKey = extId + '@%';
        List<NFY_Sync_Log__c> logs = [
            SELECT Id, Name, System__r.Name, Event_Type__c, Status__c, Response__c, Error_Message__c, Received_At__c, Attempts__c,
                Workato_Job_Id__c, Source__c, Payload__c, Resolved__c, Shipment__c
            FROM NFY_Sync_Log__c
            WHERE Sales_Order__c = :so.Id OR (Order__c != null AND Order__c = :so.NFY_Order__c) OR External_Id__c = :extId OR External_Id__c LIKE :versionedKey
            ORDER BY Received_At__c, Name
        ];
        List<TC_Sales_Order_Line__c> soLines = [
            SELECT Product__r.Name, Quantity_Ordered__c, Quantity_Allocated__c, Quantity_Shipped__c, Unit_Price__c, NFY_Ship_From__r.Name,
                Product__r.TC_Inventory_Product__c, NFY_Short_Qty__c, NFY_Stock_Status__c
            FROM TC_Sales_Order_Line__c WHERE Sales_Order__c = :so.Id ORDER BY Name
        ];
        List<TC_Shipment__c> shipments = [
            SELECT Id, Name, CreatedDate, Shipment_Date__c, Status__c, NFY_Carrier__c, NFY_Tracking_Number__c, Shipping_Reference__c,
                NFY_Source_System__c, NFY_Ship_From__r.Name, (SELECT Quantity_Shipped__c FROM Shipment_Lines__r)
            FROM TC_Shipment__c WHERE Sales_Order__c = :so.Id ORDER BY CreatedDate, Name
        ];
        List<TC_Billing__c> billings = [
            SELECT Id, Name, Status__c, Total__c, CreatedDate, Date__c FROM TC_Billing__c WHERE Sales_Order__c = :so.Id ORDER BY CreatedDate, Name
        ];
        // Stock receipts that filled this order's backorder say so in their response.
        List<NFY_Sync_Log__c> backorderFills = new List<NFY_Sync_Log__c>();
        if (String.isNotBlank(extId)) {
            for (NFY_Sync_Log__c f : [
                SELECT Id, Name, Received_At__c, Response__c FROM NFY_Sync_Log__c
                WHERE Event_Type__c = 'stock.adjusted' AND Status__c = 'Success' AND Received_At__c >= :so.CreatedDate
                ORDER BY Received_At__c LIMIT 200
            ]) {
                if (f.Response__c != null && f.Response__c.contains(extId)) backorderFills.add(f);
            }
        }
        Decimal requested = 0, assigned = 0, shortQty = 0, shippedOnLines = 0;
        Boolean anyInventory = false;
        for (TC_Sales_Order_Line__c l : soLines) {
            Boolean inv = l.Product__r.TC_Inventory_Product__c == true;
            j.lines.add(new Map<String, Object>{ 'product' => l.Product__r.Name, 'ordered' => l.Quantity_Ordered__c, 'allocated' => l.Quantity_Allocated__c,
                'shipped' => l.Quantity_Shipped__c, 'price' => l.Unit_Price__c, 'shipFrom' => l.NFY_Ship_From__r.Name, 'inventory' => inv,
                'short' => l.NFY_Short_Qty__c, 'stockStatus' => l.NFY_Stock_Status__c });
            requested += nz(l.Quantity_Ordered__c);
            shippedOnLines += nz(l.Quantity_Shipped__c);
            if (inv) {
                anyInventory = true;
                // Units already shipped were allocated first, even if the allocation has since been consumed.
                assigned += Math.max(nz(l.Quantity_Allocated__c), nz(l.Quantity_Shipped__c));
                shortQty += nz(l.NFY_Short_Qty__c);
            } else {
                assigned += nz(l.Quantity_Ordered__c);
            }
        }

        // Sort the integration messages into the stage they belong to.
        List<NFY_Sync_Log__c> orderLogs = new List<NFY_Sync_Log__c>(), sendLogs = new List<NFY_Sync_Log__c>(), shipLogs = new List<NFY_Sync_Log__c>();
        for (NFY_Sync_Log__c l : logs) {
            if (l.Event_Type__c == 'order.upsert') {
                orderLogs.add(l);
            } else if (l.Event_Type__c == 'shipstation.order.sent') {
                sendLogs.add(l);
            } else if (l.Event_Type__c == 'shipment.created' || l.Event_Type__c == 'shipstation.notify') {
                shipLogs.add(l);
            }
        }
        NFY_Sync_Log__c firstOrderLog = orderLogs.isEmpty() ? null : orderLogs[0];
        j.originSystem = firstOrderLog != null && firstOrderLog.System__r != null ? firstOrderLog.System__r.Name
            : (String.isBlank(so.NFY_Source_System__c) ? so.NFY_Channel__c : so.NFY_Source_System__c);
        String origin = shortName(String.isBlank(so.NFY_Source_System__c) ? j.channel : so.NFY_Source_System__c);
        String transport = firstOrderLog != null && String.isNotBlank(firstOrderLog.Source__c) ? firstOrderLog.Source__c : 'Integration';

        Stage s1 = originStage(origin, so, firstOrderLog);
        Stage s2 = receivedStage(origin, transport, orderLogs);
        Stage s3 = salesOrderStage(transport, so);
        Stage s4 = allocationStage(so, requested, assigned, shortQty, anyInventory, backorderFills);
        Stage s6 = shipmentStage(so, shipments, shipLogs, requested, shippedOnLines);
        Stage s5 = shipStationStage(so, sendLogs, shipments);
        Stage s7 = billingStage(billings, s6);
        Stage s8 = new Stage(8, 'origin-billing', origin, 'Billing synced back to ' + origin);
        s8.status = NOT_AVAILABLE;
        s8.detail = 'The integration does not send billing back to ' + origin + ', so there is no confirmation to show. Salesforce / TC Accounting is the system of record for billing.';

        j.lifecycle.addAll(new List<Stage>{ s1, s2, s3, s4, s5, s6, s7, s8 });

        // The progress bar is read from the same stages.
        if (s7.done()) {
            j.stageIndex = 3;
        } else if (s6.started()) {
            j.stageIndex = 2;
            if (s6.status == PARTIAL) j.stages[2] = 'Partially shipped';
        } else if (s4.started()) {
            j.stageIndex = 1;
            if (s4.status == PARTIAL) j.stages[1] = 'Partially allocated';
        } else {
            j.stageIndex = 0;
        }
        j.steps = history(so, logs, billings, shipments, s1, s4, backorderFills, transport, origin);
        return j;
    }

    /**
     * The order history: every real event once, oldest first within the lifecycle. Each event says which
     * systems it passed through, its processing status and the records it touched. Replays of a message are
     * folded into the original; a shipment message is folded into the shipment it created; a message that
     * another system sent in parallel keeps its real time and says why it is earlier.
     */
    private static List<Step> history(TC_Sales_Order__c so, List<NFY_Sync_Log__c> logs, List<TC_Billing__c> billings,
            List<TC_Shipment__c> shipments, Stage origin, Stage allocation, List<NFY_Sync_Log__c> fills, String transport, String originName) {
        List<Step> out = new List<Step>();

        // Created in the source system.
        Step created = new Step();
        created.rank = 1; created.at = origin.at; created.kind = 'origin';
        created.route = new List<String>{ originName };
        created.title = 'Sales order created in ' + originName;
        created.detail = origin.detail;
        created.status = 'Success'; created.statusLabel = COMPLETED; created.recordName = '';
        out.add(created);

        // Integration messages, once each.
        Map<String, Integer> repeats = new Map<String, Integer>();
        Map<String, Step> firstByKey = new Map<String, Step>();
        Map<Id, List<NFY_Sync_Log__c>> shipmentLogs = new Map<Id, List<NFY_Sync_Log__c>>();
        Boolean orderSeen = false, sendSeen = false;
        for (NFY_Sync_Log__c l : logs) {
            String key = l.Event_Type__c + '|' + l.Payload__c;
            if (l.Status__c == 'Duplicate skipped') {
                repeats.put(key, (repeats.containsKey(key) ? repeats.get(key) : 0) + 1);
                continue;
            }
            Boolean shipMsg = l.Event_Type__c == 'shipment.created' || l.Event_Type__c == 'shipstation.notify';
            if (shipMsg && l.Shipment__c != null && l.Status__c == 'Success') {
                if (!shipmentLogs.containsKey(l.Shipment__c)) shipmentLogs.put(l.Shipment__c, new List<NFY_Sync_Log__c>());
                shipmentLogs.get(l.Shipment__c).add(l);
                continue; // shown with the shipment it created
            }
            Step st = rawStep(l);
            String src = l.System__r == null ? originName : shortName(l.System__r.Name);
            String via = String.isBlank(l.Source__c) ? transport : l.Source__c;
            if (l.Event_Type__c == 'order.upsert') {
                st.route = new List<String>{ src, via, 'Salesforce' };
                st.title = l.Status__c == 'Failed' ? 'Order message failed' : (orderSeen ? 'Order updated from ' + src : 'Order received from ' + src);
                if (l.Status__c == 'Success') orderSeen = true;
            } else if (l.Event_Type__c == 'shipstation.order.sent') {
                st.route = new List<String>{ originName, via, 'ShipStation' };
                st.title = l.Status__c == 'Failed' ? 'ShipStation order failed' : (sendSeen ? 'ShipStation order updated' : 'Order sent to ShipStation');
                if (l.Status__c == 'Success') sendSeen = true;
            } else if (shipMsg) {
                st.route = new List<String>{ src, via, 'Salesforce' };
                st.title = l.Status__c == 'Failed' ? 'Shipment message failed' : 'Shipment message received';
            } else {
                st.route = new List<String>{ src, via, 'Salesforce' };
            }
            firstByKey.put(key, st);
            out.add(st);
        }
        for (String k : repeats.keySet()) {
            Integer n = repeats.get(k);
            String note = 'Sent again ' + n + ' time' + (n == 1 ? '' : 's') + ' by the integration; ignored, nothing changed.';
            if (firstByKey.containsKey(k)) {
                Step st = firstByKey.get(k);
                st.note = st.note == null ? note : st.note + ' ' + note;
            }
        }

        // Created in Salesforce.
        Step soStep = new Step();
        soStep.rank = 3; soStep.at = so.CreatedDate; soStep.kind = 'record';
        soStep.route = new List<String>{ transport, 'Salesforce' };
        soStep.title = 'Sales order created in Salesforce';
        soStep.detail = so.Name + (so.NFY_Order__r == null ? '' : ' and Order ' + so.NFY_Order__r.OrderNumber) + ' created for ' + so.NFY_External_Order_Id__c
            + (String.isBlank(so.NFY_Routing_Decision__c) ? '' : '. ' + so.NFY_Routing_Decision__c.substringBefore('. ') + '.');
        soStep.status = 'Success'; soStep.statusLabel = COMPLETED; soStep.recordId = so.Id; soStep.recordName = so.Name;
        soStep.refs.add(new Ref('record', so.Name, so.Id));
        if (so.NFY_Order__c != null) soStep.refs.add(new Ref('record', 'Order ' + so.NFY_Order__r.OrderNumber, so.NFY_Order__c));
        out.add(soStep);

        // Allocated in Salesforce.
        if (allocation.status != NOT_NEEDED) {
            Step al = new Step();
            al.rank = 4; al.at = so.CreatedDate; al.kind = 'record';
            al.route = new List<String>{ 'Salesforce' };
            al.title = 'Inventory allocated';
            al.detail = allocation.detail;
            al.status = 'Success'; al.statusLabel = allocation.status; al.recordId = so.Id; al.recordName = '';
            out.add(al);
            for (NFY_Sync_Log__c f : fills) {
                Step st = new Step();
                st.rank = 4; st.at = f.Received_At__c; st.kind = 'log';
                st.route = new List<String>{ originName, transport, 'Salesforce' };
                st.title = 'Backorder filled from new stock';
                st.detail = f.Response__c; st.status = 'Success'; st.statusLabel = COMPLETED;
                st.recordId = f.Id; st.recordName = f.Name;
                st.refs.add(new Ref('log', f.Name, f.Id));
                out.add(st);
            }
        }

        // Shipments: the record, with the message that reported it.
        for (TC_Shipment__c sh : shipments) {
            Decimal units = 0;
            for (TC_Shipment_Line__c l : sh.Shipment_Lines__r) units += nz(l.Quantity_Shipped__c);
            String reporter = String.isBlank(sh.NFY_Source_System__c) ? 'Salesforce' : sh.NFY_Source_System__c;
            Step st = new Step();
            st.rank = 6; st.at = sh.CreatedDate; st.kind = 'shipment';
            st.route = reporter == 'Salesforce' ? new List<String>{ 'Salesforce' } : new List<String>{ reporter, transport, 'Salesforce' };
            st.title = 'Shipment dispatched';
            String tracking = String.isNotBlank(sh.NFY_Tracking_Number__c) ? sh.NFY_Tracking_Number__c : sh.Shipping_Reference__c;
            List<String> bits = new List<String>{ fmt(units) + ' unit' + (units == 1 ? '' : 's') };
            if (sh.NFY_Ship_From__r != null) bits.add('from ' + sh.NFY_Ship_From__r.Name);
            if (String.isNotBlank(sh.NFY_Carrier__c) || String.isNotBlank(tracking)) bits.add('via ' + (nzs(sh.NFY_Carrier__c) + ' ' + nzs(tracking)).trim());
            if (sh.Shipment_Date__c != null) bits.add('shipped ' + sh.Shipment_Date__c.format());
            st.detail = String.join(bits, ' · ');
            st.status = 'Success'; st.statusLabel = COMPLETED; st.recordId = sh.Id; st.recordName = sh.Name;
            st.refs.add(new Ref('record', sh.Name, sh.Id));
            if (shipmentLogs.containsKey(sh.Id)) {
                for (NFY_Sync_Log__c l : shipmentLogs.get(sh.Id)) {
                    st.refs.add(new Ref('log', l.Name, l.Id));
                    if (String.isNotBlank(l.Workato_Job_Id__c)) st.job = nzs(l.Source__c) + ' job ' + l.Workato_Job_Id__c;
                }
            }
            out.add(st);
        }

        // Billing in TC Accounting.
        for (TC_Billing__c b : billings) {
            Boolean credit = nz(b.Total__c) < 0;
            Step st = new Step();
            st.rank = 7; st.at = b.CreatedDate; st.kind = 'billing';
            st.route = new List<String>{ 'Salesforce', 'TC Accounting' };
            st.title = (credit ? 'Credit memo ' : 'Invoice ') + (b.Status__c == 'Posted' ? 'generated and posted' : 'generated');
            st.detail = b.Name + ' · ' + money(b.Total__c) + (b.Date__c == null ? '' : ' · dated ' + b.Date__c.format()) + ' · ' + nzs(b.Status__c);
            st.status = b.Status__c == 'Posted' ? 'Success' : 'Received';
            st.statusLabel = b.Status__c == 'Posted' ? COMPLETED : PROCESSING;
            st.recordId = b.Id; st.recordName = b.Name;
            st.refs.add(new Ref('record', b.Name, b.Id));
            out.add(st);
        }

        out.sort();
        // Say so when an event carries an earlier time than the event it follows.
        Datetime latest;
        for (Step st : out) {
            if (latest != null && st.at != null && st.at < latest && st.rank == 5) {
                String why = 'Sent by ' + originName + ' at the same moment as the order, so ShipStation recorded it before Salesforce finished the steps above.';
                st.note = st.note == null ? why : why + ' ' + st.note;
            }
            if (st.at != null && (latest == null || st.at > latest)) latest = st.at;
        }
        return out;
    }

    /** Lifecycle step an integration message belongs to. */
    private static Integer rankOf(String eventType) {
        switch on eventType {
            when 'order.upsert' { return 2; }
            when 'shipstation.order.sent' { return 5; }
            when 'shipment.created', 'shipstation.notify' { return 6; }
            when 'return.received' { return 8; }
            when 'settlement.posted' { return 9; }
            when else { return 10; }
        }
    }

    // ---- stages -------------------------------------------------------------------------------------------

    private static Stage originStage(String origin, TC_Sales_Order__c so, NFY_Sync_Log__c first) {
        Stage s = new Stage(1, 'origin', origin, 'Sales order confirmed in ' + origin);
        Map<String, Object> p = first == null ? new Map<String, Object>() : payload(first.Payload__c);
        String originNo = String.isNotBlank(so.NFY_Source_Record_Id__c) ? so.NFY_Source_Record_Id__c : so.NFY_External_Order_Id__c;
        List<String> parts = new List<String>{ origin + ' order ' + originNo };
        Map<String, Object> customer = p.get('customer') instanceof Map<String, Object> ? (Map<String, Object>) p.get('customer') : null;
        String customerName = customer != null && customer.get('name') != null ? String.valueOf(customer.get('name')) : (so.Customer__r == null ? null : so.Customer__r.Name);
        if (String.isNotBlank(customerName)) parts.add('for ' + customerName);
        Object od = p.get('orderDate');
        if (od != null) {
            parts.add('dated ' + String.valueOf(od));
        } else if (so.Order_Date__c != null) {
            parts.add('dated ' + so.Order_Date__c.format());
        }
        if (p.get('shipFrom') != null) parts.add('ship from ' + String.valueOf(p.get('shipFrom')));
        s.detail = String.join(parts, ' · ');
        // The origin system's own confirmation time is not sent; the first message it fired is the closest real time.
        s.at = first != null ? first.Received_At__c : so.CreatedDate;
        s.status = COMPLETED;
        return s;
    }

    private static Stage receivedStage(String origin, String transport, List<NFY_Sync_Log__c> orderLogs) {
        Stage s = new Stage(2, 'received', origin + ' → ' + transport, 'Order received by ' + transport);
        NFY_Sync_Log__c ok, lastFail;
        Integer repeats = 0;
        for (NFY_Sync_Log__c l : orderLogs) {
            if (l.Status__c == 'Success' && ok == null) {
                ok = l;
            } else if (l.Status__c == 'Duplicate skipped') {
                repeats++;
                s.items.add(new Item(l.Received_At__c, 'Same order sent again; ignored, nothing changed', 'info', l.Id, label(l)));
            } else if (l.Status__c == 'Failed') {
                lastFail = l;
                s.items.add(new Item(l.Received_At__c, 'Failed: ' + nzs(l.Error_Message__c), l.Resolved__c == true ? 'info' : 'bad', l.Id, label(l)));
            } else if (l.Status__c == 'Success' && ok != null) {
                s.items.add(new Item(l.Received_At__c, 'Order updated', 'ok', l.Id, label(l)));
            }
        }
        if (ok != null) {
            s.status = COMPLETED;
            s.at = ok.Received_At__c;
            s.detail = transport + ' delivered the order to Salesforce' + (nz(ok.Attempts__c) > 1 ? ' on attempt ' + ok.Attempts__c.intValue() : '')
                + (repeats > 0 ? ' · ' + repeats + ' repeat' + (repeats == 1 ? '' : 's') + ' ignored' : '');
            s.recordId = ok.Id;
            s.recordName = label(ok);
        } else if (lastFail != null) {
            s.status = FAILED;
            s.at = lastFail.Received_At__c;
            s.detail = nzs(lastFail.Error_Message__c);
            s.recordId = lastFail.Id;
            s.recordName = label(lastFail);
        } else if (!orderLogs.isEmpty()) {
            s.status = PROCESSING;
            s.at = orderLogs[0].Received_At__c;
            s.detail = 'Received, still being processed.';
        } else {
            s.status = NOT_AVAILABLE;
            s.detail = 'This order was not received through the integration (no sync log).';
        }
        return s;
    }

    private static Stage salesOrderStage(String transport, TC_Sales_Order__c so) {
        Stage s = new Stage(3, 'sales-order', transport + ' → Salesforce', 'Sales order created in Salesforce');
        s.status = COMPLETED;
        s.at = so.CreatedDate;
        s.detail = so.Name + (so.NFY_Order__r == null ? '' : ' and Order ' + so.NFY_Order__r.OrderNumber)
            + ', linked to ' + so.NFY_External_Order_Id__c;
        s.recordId = so.Id;
        s.recordName = so.Name;
        return s;
    }

    private static Stage allocationStage(TC_Sales_Order__c so, Decimal requested, Decimal assigned, Decimal shortQty, Boolean anyInventory,
            List<NFY_Sync_Log__c> fills) {
        Stage s = new Stage(4, 'allocation', 'Salesforce', 'Inventory allocated');
        s.at = so.CreatedDate;
        for (NFY_Sync_Log__c f : fills) {
            s.items.add(new Item(f.Received_At__c, 'Stock arrived: ' + nzs(f.Response__c), 'ok', f.Id, f.Name));
            s.at = f.Received_At__c;
        }
        String counts = 'Requested ' + fmt(requested) + ' · assigned ' + fmt(assigned) + ' · short ' + fmt(shortQty);
        if (!anyInventory) {
            s.status = NOT_NEEDED;
            s.detail = 'No stocked products on this order.';
        } else if (requested > 0 && shortQty <= 0) {
            s.status = COMPLETED;
            s.detail = counts + (fills.isEmpty() ? '. Fully assigned.' : '. Fully assigned after backordered stock arrived.');
        } else if (assigned > 0) {
            s.status = PARTIAL;
            s.detail = counts + '. The rest is backordered and assigned automatically when stock arrives.';
        } else {
            s.status = PENDING;
            s.detail = counts + '. Waiting for stock.';
        }
        return s;
    }

    private static Stage shipStationStage(TC_Sales_Order__c so, List<NFY_Sync_Log__c> sendLogs, List<TC_Shipment__c> shipments) {
        Stage s = new Stage(5, 'shipstation', 'Odoo → Workato → ShipStation', 'Shipment order created in ShipStation');
        String ssId = so.NFY_Order__r == null ? null : so.NFY_Order__r.NFY_ShipStation_Order_Id__c;
        NFY_Sync_Log__c last, firstOk;
        for (NFY_Sync_Log__c l : sendLogs) {
            String resp = l.Status__c == 'Failed' ? 'Failed: ' + nzs(l.Error_Message__c) : nzs(l.Response__c);
            s.items.add(new Item(l.Received_At__c, resp, l.Status__c == 'Failed' ? 'bad' : (l.Status__c == 'Success' ? 'ok' : 'info'), l.Id, label(l)));
            if (l.Status__c == 'Success' && firstOk == null) firstOk = l;
            if (l.Status__c == 'Success' || l.Status__c == 'Failed') last = l;
            if (ssId == null && l.Response__c != null && l.Response__c.contains('(order ')) {
                ssId = l.Response__c.substringAfter('(order ').substringBefore(')');
            }
        }
        if (sendLogs.isEmpty()) {
            Boolean shippedElsewhere = false;
            for (TC_Shipment__c sh : shipments) {
                if (sh.NFY_Source_System__c != 'ShipStation') shippedElsewhere = true;
            }
            if (shippedElsewhere) {
                s.status = NOT_NEEDED;
                s.detail = 'Shipped by the warehouse itself, not through ShipStation. Only Main warehouse orders go to ShipStation.';
            } else {
                s.status = PENDING;
                s.detail = 'Not sent to ShipStation. Only orders shipping from the Main warehouse go there, once stock is reserved.';
            }
            return s;
        }
        s.at = (firstOk != null ? firstOk : sendLogs[0]).Received_At__c;
        Boolean partly = last != null && last.Response__c != null && last.Response__c.contains('Partly reserved');
        if (last == null) {
            s.status = PROCESSING;
        } else if (last.Status__c == 'Failed' && firstOk == null) {
            s.status = FAILED;
        } else if (partly) {
            s.status = PARTIAL;
        } else {
            s.status = COMPLETED;
        }
        String latest = last == null ? '' : nzs(last.Response__c);
        s.detail = (ssId == null ? '' : 'ShipStation order ' + ssId + ' · ')
            + (latest.contains(': ') ? latest.substringAfter(': ') : latest)
            + (sendLogs.size() > 1 ? ' · updated ' + (sendLogs.size() - 1) + ' time' + (sendLogs.size() == 2 ? '' : 's') + ' as stock was reserved' : '')
            + (s.at != null && s.at < so.CreatedDate ? ' · Sent straight from Odoo, so it can reach ShipStation a few seconds before the Salesforce sales order exists.' : '');
        if (last != null) {
            s.recordId = last.Id;
            s.recordName = label(last);
        }
        return s;
    }

    private static Stage shipmentStage(TC_Sales_Order__c so, List<TC_Shipment__c> shipments, List<NFY_Sync_Log__c> shipLogs, Decimal requested, Decimal shippedOnLines) {
        Stage s = new Stage(6, 'shipment', 'ShipStation / warehouse', 'Shipment dispatched');
        Decimal shipped = 0;
        for (TC_Shipment__c sh : shipments) {
            Decimal units = 0;
            for (TC_Shipment_Line__c l : sh.Shipment_Lines__r) units += nz(l.Quantity_Shipped__c);
            shipped += units;
            String tracking = String.isNotBlank(sh.NFY_Tracking_Number__c) ? sh.NFY_Tracking_Number__c : sh.Shipping_Reference__c;
            List<String> bits = new List<String>{ sh.Name };
            if (String.isNotBlank(sh.NFY_Carrier__c) || String.isNotBlank(tracking)) bits.add(nzs(sh.NFY_Carrier__c) + ' ' + nzs(tracking));
            bits.add(fmt(units) + ' unit' + (units == 1 ? '' : 's'));
            if (sh.NFY_Ship_From__r != null) bits.add('from ' + sh.NFY_Ship_From__r.Name);
            if (String.isNotBlank(sh.NFY_Source_System__c)) bits.add('reported by ' + sh.NFY_Source_System__c);
            if (sh.Shipment_Date__c != null) bits.add('shipped ' + sh.Shipment_Date__c.format());
            s.items.add(new Item(sh.CreatedDate, String.join(bits, ' · '), 'ok', sh.Id, sh.Name));
            if (s.at == null) s.at = sh.CreatedDate;
        }
        shipped = Math.max(shipped, shippedOnLines);
        NFY_Sync_Log__c openFail;
        for (NFY_Sync_Log__c l : shipLogs) {
            if (l.Status__c == 'Failed') {
                s.items.add(new Item(l.Received_At__c, 'Shipment message failed: ' + nzs(l.Error_Message__c), l.Resolved__c == true ? 'info' : 'bad', l.Id, label(l)));
                if (l.Resolved__c != true) openFail = l;
            } else if (l.Status__c == 'Duplicate skipped') {
                s.items.add(new Item(l.Received_At__c, 'Same shipment reported again; ignored', 'info', l.Id, label(l)));
            }
        }
        if (shipments.isEmpty()) {
            s.status = openFail != null ? FAILED : PENDING;
            s.detail = openFail != null ? nzs(openFail.Error_Message__c) : 'Not shipped yet.';
            return s;
        }
        s.status = requested > 0 && shipped < requested ? PARTIAL : COMPLETED;
        s.detail = shipments.size() + ' shipment' + (shipments.size() == 1 ? '' : 's') + ' · ' + fmt(shipped) + ' of ' + fmt(requested) + ' units shipped'
            + (s.status == PARTIAL ? '. The rest ships when it is available.' : '.');
        s.recordId = shipments[shipments.size() - 1].Id;
        s.recordName = shipments[shipments.size() - 1].Name;
        return s;
    }

    private static Stage billingStage(List<TC_Billing__c> billings, Stage shipment) {
        Stage s = new Stage(7, 'billing', 'Salesforce / TC Accounting', 'Billing created');
        Boolean posted = false;
        Decimal total = 0;
        for (TC_Billing__c b : billings) {
            Boolean credit = nz(b.Total__c) < 0;
            s.items.add(new Item(b.CreatedDate, (credit ? 'Credit memo ' : 'Invoice ') + b.Name + ' · ' + money(b.Total__c) + ' · '
                + (b.Date__c == null ? '' : 'dated ' + b.Date__c.format() + ' · ') + String.valueOf(b.Status__c).toLowerCase(), 'ok', b.Id, b.Name));
            if (b.Status__c == 'Posted' && !credit) posted = true;
            total += nz(b.Total__c);
            if (s.at == null) s.at = b.CreatedDate;
        }
        if (billings.isEmpty()) {
            s.status = PENDING;
            s.detail = 'Billed automatically once the order ships.';
            return s;
        }
        TC_Billing__c last = billings[billings.size() - 1];
        s.recordId = last.Id;
        s.recordName = last.Name;
        if (!posted) {
            s.status = PROCESSING;
            s.detail = 'Billing created, not posted yet.';
        } else if (shipment.status == PARTIAL) {
            s.status = PARTIAL;
            s.detail = 'Billed ' + money(total) + ' for the units shipped so far.';
        } else {
            s.status = COMPLETED;
            s.detail = (billings.size() == 1 ? 'Invoice ' + last.Name + ' posted' : billings.size() + ' billings posted') + ' · ' + money(total)
                + (last.Date__c == null ? '' : ' · dated ' + last.Date__c.format());
        }
        return s;
    }

    // ---- helpers ------------------------------------------------------------------------------------------

    private static Step rawStep(NFY_Sync_Log__c l) {
        Step s = new Step();
        s.rank = rankOf(l.Event_Type__c);
        s.at = l.Received_At__c;
        s.systemName = l.System__r == null ? null : l.System__r.Name;
        s.title = eventLabel(l.Event_Type__c) + (nz(l.Attempts__c) > 1 ? ' (attempt ' + l.Attempts__c.intValue() + ')' : '');
        s.detail = l.Status__c == 'Failed' ? l.Error_Message__c : l.Response__c;
        s.status = l.Status__c;
        s.recordId = l.Id;
        s.recordName = label(l);
        s.kind = 'log';
        s.statusLabel = l.Status__c == 'Success' ? COMPLETED
            : (l.Status__c == 'Failed' ? (l.Resolved__c == true ? 'Failed · resolved' : FAILED)
            : (l.Status__c == 'Received' || l.Status__c == 'Processing' ? PROCESSING : l.Status__c));
        s.refs.add(new Ref('log', l.Name, l.Id));
        if (String.isNotBlank(l.Workato_Job_Id__c)) s.job = nzs(l.Source__c) + ' job ' + l.Workato_Job_Id__c;
        return s;
    }

    private static String label(NFY_Sync_Log__c l) {
        return l.Name + (String.isBlank(l.Workato_Job_Id__c) ? '' : ' · ' + nzs(l.Source__c) + ' ' + l.Workato_Job_Id__c);
    }

    private static String eventLabel(String eventType) {
        switch on eventType {
            when 'order.upsert' { return 'Order received'; }
            when 'shipment.created' { return 'Shipment reported'; }
            when 'shipstation.order.sent' { return 'Sent to ShipStation'; }
            when 'shipstation.notify' { return 'ShipStation shipment notice'; }
            when 'return.received' { return 'Return received'; }
            when 'settlement.posted' { return 'Settlement posted'; }
            when else { return eventType; }
        }
    }

    private static String shortName(String systemName) {
        if (String.isBlank(systemName)) return 'Source system';
        return systemName.substringBefore(' (').trim();
    }

    private static Map<String, Object> payload(String body) {
        if (String.isBlank(body)) return new Map<String, Object>();
        try {
            Object o = JSON.deserializeUntyped(body);
            return o instanceof Map<String, Object> ? (Map<String, Object>) o : new Map<String, Object>();
        } catch (Exception e) {
            return new Map<String, Object>();
        }
    }

    private static Decimal nz(Decimal d) { return d == null ? 0 : d; }
    private static String nzs(String s) { return s == null ? '' : s; }
    private static String fmt(Decimal d) { return String.valueOf(nz(d).stripTrailingZeros().toPlainString()); }
    private static String money(Decimal d) { return '$' + String.valueOf(nz(d).setScale(2)); }
}