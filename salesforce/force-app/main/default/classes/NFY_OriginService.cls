/**
 * Source-system tracking for integrated records. The Integration Service calls it in the same
 * transaction as the business write, so every record an event touches carries its origin
 * (Source System, Source Record ID, Source Key) and its last-sync summary (status, time,
 * operation, count, log). Failures here never block the business sync: they roll back only the
 * stamping and are written to the debug log.
 */
public without sharing class NFY_OriginService {

    /** Integration System code -> value of the NFY Integration Systems global picklist. */
    public static final Map<String, String> SYSTEM_VALUE = new Map<String, String>{
        'ODOO_SHOP' => 'Odoo', 'ODOO' => 'Odoo', 'SHOPIFY' => 'Shopify', 'AMAZON' => 'Amazon', 'GLOBALE' => 'Global-e',
        'SHIPSTATION' => 'ShipStation', 'SHIPMONK' => 'ShipMonk', 'SALESFORCE' => 'Salesforce'
    };

    /** Order channel -> source system, used by the backfill of records created before tracking existed. */
    public static final Map<String, String> CHANNEL_SYSTEM = new Map<String, String>{
        'Shopify .com' => 'Shopify', 'Shopify POS' => 'Shopify', 'EU Webstore' => 'Shopify',
        'Amazon FBA' => 'Amazon', 'Amazon FBM' => 'Amazon', 'Buy with Prime' => 'Amazon', 'Amazon MCF' => 'Amazon',
        'Global-e' => 'Global-e', 'Wholesale / Team' => 'Salesforce', 'Odoo' => 'Odoo'
    };

    private static final List<String> KEY_PREFIXES = new List<String>{ 'ODOO-', 'SHOPIFY-', 'AMAZON-', 'GLOBALE-', 'SHIPSTATION-' };

    public static String systemValue(String code) {
        return code == null ? null : SYSTEM_VALUE.get(code.toUpperCase());
    }

    /** The native ID inside a SYSTEM-nativeId key: ODOO-S01001 -> S01001. Keys without a known prefix are returned as they are. */
    public static String nativeId(String key) {
        if (key == null) {
            return null;
        }
        for (String p : KEY_PREFIXES) {
            if (key.startsWithIgnoreCase(p)) {
                return key.substring(p.length());
            }
        }
        return key;
    }

    public static String syncedVia(NFY_Sync_Log__c log) {
        String transport = String.isBlank(log.Source__c) ? 'Manual' : log.Source__c;
        return (transport + (String.isBlank(log.Workato_Job_Id__c) ? '' : ' · job ' + log.Workato_Job_Id__c)).left(255);
    }

    /** Created for a new order, No change when the order was already in Salesforce, Updated for events on an existing order. */
    public static String operationFor(String entity, String message) {
        String m = message == null ? '' : message;
        if (m.contains('is already in Salesforce') || m.contains('is already in fulfilment')) {
            return 'No change';
        }
        if (entity == 'Product') {
            return m.startsWith('Created') ? 'Created' : 'Updated';
        }
        return entity == 'Order' ? 'Created' : 'Updated';
    }

    /** Groups an error message into the categories ops filter and retry on. */
    public static String categorize(String message) {
        if (String.isBlank(message)) {
            return 'Unknown';
        }
        String m = message.toLowerCase();
        if (m.contains('unknown sku') || m.contains('unknown product') || m.contains('unknown warehouse') || m.contains('mapping')) {
            return 'Mapping';
        }
        if (m.contains('has not synced') || m.contains('no salesforce order matches') || m.contains('not found')) {
            return 'Dependency';
        }
        if ((m.startsWith('only ') && m.contains(' of ')) || m.contains('stock')) {
            return 'Stock';
        }
        if (m.contains('unknown source') || m.contains('not valid json') || m.contains('required') || m.contains('missing') || m.contains('has no')) {
            return 'Validation';
        }
        if (m.contains('limit') || m.contains('unable to lock') || m.contains('timeout')) {
            return 'Platform';
        }
        return 'Unknown';
    }

    /**
     * After a successful event: stamp the order it touched and, for a new order, its account, contact and lines.
     * Runs in its own Queueable so it adds no queries or DML to the order transaction. Inside an async
     * context (where enqueueing could collide with the caller's own chaining) it stamps inline, and only
     * when enough query budget is left.
     */
    public static void stampSuccess(NFY_Sync_Log__c log, String sourceCode, Id orderId, String operation) {
        if (orderId == null) {
            return;
        }
        Boolean async = System.isQueueable() || System.isBatch() || System.isFuture() || System.isScheduled();
        if (!async && log.Id != null && Limits.getQueueableJobs() < Limits.getLimitQueueableJobs()) {
            System.enqueueJob(new StampJob(log.Id, sourceCode, orderId, operation));
            return;
        }
        if (Limits.getQueries() > Limits.getLimitQueries() - 30) {
            System.debug(LoggingLevel.WARN, 'Origin stamp skipped (query budget) for order ' + orderId);
            return;
        }
        stampNow(log, sourceCode, orderId, operation);
    }

    /** Background stamping job: one per successful event. */
    public class StampJob implements Queueable {
        private Id logId;
        private String sourceCode;
        private Id orderId;
        private String operation;
        public StampJob(Id logId, String sourceCode, Id orderId, String operation) {
            this.logId = logId;
            this.sourceCode = sourceCode;
            this.orderId = orderId;
            this.operation = operation;
        }
        public void execute(QueueableContext ctx) {
            List<NFY_Sync_Log__c> logs = [SELECT Id, Name, Entity__c, Source__c, Workato_Job_Id__c, Account__c FROM NFY_Sync_Log__c WHERE Id = :logId];
            if (logs.isEmpty()) {
                return;
            }
            NFY_Sync_Log__c log = logs[0];
            stampNow(log, sourceCode, orderId, operation);
            if (log.Account__c != null) {
                update new NFY_Sync_Log__c(Id = log.Id, Account__c = log.Account__c);
            }
        }
    }

    private static void stampNow(NFY_Sync_Log__c log, String sourceCode, Id orderId, String operation) {
        Savepoint sp = Database.setSavepoint();
        try {
            Order o = [
                SELECT Id, AccountId, BillToContactId, NFY_External_Order_Id__c, NFY_Source_System__c, NFY_Sync_Count__c, NFY_TC_Sales_Order__c,
                    (SELECT Id, NFY_Source_Key__c FROM OrderItems ORDER BY CreatedDate, Id)
                FROM Order WHERE Id = :orderId
            ];
            String sys = systemValue(sourceCode);
            String via = syncedVia(log);
            Datetime now = System.now();
            Boolean counts = operation != 'No change';
            Boolean originEvent = log.Entity__c == 'Order';

            Order ou = new Order(Id = o.Id, NFY_Synced_Via__c = via, NFY_Last_Sync_Status__c = 'Success', NFY_Last_Synced_At__c = now,
                NFY_Last_Sync_Operation__c = operation, NFY_Last_Sync_Log__c = log.Id);
            if (o.NFY_Source_System__c == null && sys != null && originEvent) {
                ou.NFY_Source_System__c = sys;
                ou.NFY_Source_Record_Id__c = nativeId(o.NFY_External_Order_Id__c);
            }
            if (counts) {
                ou.NFY_Sync_Count__c = (o.NFY_Sync_Count__c == null ? 0 : o.NFY_Sync_Count__c) + 1;
            }
            update ou;
            log.Account__c = o.AccountId;
            stampSalesOrder(o, sys, log.Id, originEvent);

            if (!originEvent || operation != 'Created' || sys == null) {
                return;
            }
            stampCustomer(o, sys, via, now, log.Id);
            Savepoint lineSp = Database.setSavepoint();
            try {
                stampLines(o, sys);
            } catch (Exception e) {
                Database.rollback(lineSp);
                System.debug(LoggingLevel.WARN, 'Line keys skipped for ' + log.Name + ': ' + e.getMessage());
            }
        } catch (Exception e) {
            Database.rollback(sp);
            System.debug(LoggingLevel.WARN, 'Origin stamp skipped for ' + log.Name + ': ' + e.getMessage());
        }
    }

    /** The accounting sales order behind an order carries the same origin; every event moves its last-sync link. */
    private static void stampSalesOrder(Order o, String sys, Id logId, Boolean originEvent) {
        if (o.NFY_TC_Sales_Order__c == null) {
            return;
        }
        TC_Sales_Order__c so = [SELECT Id, NFY_Source_System__c FROM TC_Sales_Order__c WHERE Id = :o.NFY_TC_Sales_Order__c];
        TC_Sales_Order__c su = new TC_Sales_Order__c(Id = so.Id, NFY_Last_Sync_Log__c = logId);
        if (so.NFY_Source_System__c == null && sys != null && originEvent) {
            su.NFY_Source_System__c = sys;
            su.NFY_Source_Record_Id__c = nativeId(o.NFY_External_Order_Id__c);
        }
        update su;
    }

    /**
     * Product and shipment events: stamp the record the event created or updated, in the same
     * transaction (one query, one update). The first system to send a record becomes its source.
     */
    public static void stampRecord(NFY_Sync_Log__c log, String sourceCode, Id recordId) {
        if (recordId == null || log.Id == null) {
            return;
        }
        Schema.SObjectType t = recordId.getSObjectType();
        if (t != Product2.SObjectType && t != TC_Shipment__c.SObjectType) {
            return;
        }
        String sys = systemValue(sourceCode);
        Savepoint sp = Database.setSavepoint();
        try {
            if (t == Product2.SObjectType) {
                Product2 p = [SELECT Id, NFY_Source_System__c, NFY_Sync_Count__c, NFY_Odoo_Product_Id__c, NFT_Shopify_Variant_Id__c FROM Product2 WHERE Id = :recordId];
                Boolean isNew = p.NFY_Source_System__c == null;
                Product2 pu = new Product2(Id = p.Id, NFY_Synced_Via__c = syncedVia(log), NFY_Last_Sync_Status__c = 'Success',
                    NFY_Last_Synced_At__c = System.now(), NFY_Last_Sync_Operation__c = log.Operation__c == null ? (isNew ? 'Created' : 'Updated') : log.Operation__c, NFY_Last_Sync_Log__c = log.Id,
                    NFY_Sync_Count__c = (p.NFY_Sync_Count__c == null ? 0 : p.NFY_Sync_Count__c) + 1);
                if (isNew && sys != null) {
                    pu.NFY_Source_System__c = sys;
                    pu.NFY_Source_Record_Id__c = sys == 'Odoo' ? p.NFY_Odoo_Product_Id__c : (sys == 'Shopify' ? p.NFT_Shopify_Variant_Id__c : null);
                }
                update pu;
            } else {
                TC_Shipment__c s = [SELECT Id, NFY_Source_System__c, NFY_External_Id__c, NFY_Last_Sync_Log__c FROM TC_Shipment__c WHERE Id = :recordId];
                if (s.NFY_Source_System__c != null && s.NFY_Last_Sync_Log__c == log.Id) {
                    return; // stamped when it was created
                }
                TC_Shipment__c su = new TC_Shipment__c(Id = s.Id, NFY_Last_Sync_Log__c = log.Id);
                if (s.NFY_Source_System__c == null && sys != null) {
                    su.NFY_Source_System__c = sys;
                    su.NFY_Source_Record_Id__c = nativeId(s.NFY_External_Id__c);
                }
                update su;
            }
        } catch (Exception e) {
            Database.rollback(sp);
            System.debug(LoggingLevel.WARN, 'Record stamp skipped for ' + log.Name + ': ' + e.getMessage());
        }
    }

    /** After a failed order.upsert for an order that already exists: show the failure on the order itself. */
    public static void stampFailure(NFY_Sync_Log__c log) {
        if (log.Event_Type__c != 'order.upsert' || String.isBlank(log.External_Id__c)) {
            return;
        }
        Savepoint sp = Database.setSavepoint();
        try {
            List<Order> orders = [SELECT Id, AccountId FROM Order WHERE NFY_External_Order_Id__c = :log.External_Id__c LIMIT 1];
            if (orders.isEmpty()) {
                return;
            }
            update new Order(Id = orders[0].Id, NFY_Last_Sync_Status__c = 'Failed', NFY_Last_Synced_At__c = System.now(),
                NFY_Last_Sync_Log__c = log.Id, NFY_Synced_Via__c = syncedVia(log));
            log.Order__c = orders[0].Id;
            log.Account__c = orders[0].AccountId;
        } catch (Exception e) {
            Database.rollback(sp);
            System.debug(LoggingLevel.WARN, 'Failure stamp skipped for ' + log.Name + ': ' + e.getMessage());
        }
    }

    private static void stampCustomer(Order o, String sys, String via, Datetime now, Id logId) {
        if (o.AccountId == null) {
            return;
        }
        Account a = [SELECT Id, NFY_Source_System__c, NFY_External_Customer_Id__c, NFY_Sync_Count__c, NFY_Odoo_Partner_Id__c FROM Account WHERE Id = :o.AccountId];
        Boolean isNew = a.NFY_Source_System__c == null;
        Account au = new Account(Id = a.Id, NFY_Synced_Via__c = via, NFY_Last_Sync_Status__c = 'Success', NFY_Last_Synced_At__c = now,
            NFY_Last_Sync_Operation__c = isNew ? 'Created' : 'Updated', NFY_Last_Sync_Log__c = logId,
            NFY_Sync_Count__c = (a.NFY_Sync_Count__c == null ? 0 : a.NFY_Sync_Count__c) + 1);
        if (isNew) {
            au.NFY_Source_System__c = sys;
            au.NFY_Source_Record_Id__c = nativeId(a.NFY_External_Customer_Id__c);
        }
        if (sys == 'Odoo' && a.NFY_Odoo_Partner_Id__c == null && a.NFY_External_Customer_Id__c != null
                && a.NFY_External_Customer_Id__c.startsWithIgnoreCase('ODOO-')) {
            au.NFY_Odoo_Partner_Id__c = nativeId(a.NFY_External_Customer_Id__c);
        }
        update au;

        if (o.BillToContactId != null) {
            Contact c = [SELECT Id, NFY_Source_System__c FROM Contact WHERE Id = :o.BillToContactId];
            Contact cu = new Contact(Id = c.Id, NFY_Synced_Via__c = via, NFY_Last_Synced_At__c = now);
            if (c.NFY_Source_System__c == null) {
                cu.NFY_Source_System__c = sys;
                cu.NFY_Source_Record_Id__c = nativeId(a.NFY_External_Customer_Id__c);
                cu.NFY_Source_Key__c = a.NFY_External_Customer_Id__c == null ? null : (a.NFY_External_Customer_Id__c + '-CONTACT').left(120);
            }
            update cu;
        }
    }

    private static void stampLines(Order o, String sys) {
        List<OrderItem> items = new List<OrderItem>();
        Integer n = 0;
        for (OrderItem i : o.OrderItems) {
            n++;
            if (i.NFY_Source_Key__c == null && o.NFY_External_Order_Id__c != null) {
                items.add(new OrderItem(Id = i.Id, NFY_Source_System__c = sys,
                    NFY_Source_Record_Id__c = (nativeId(o.NFY_External_Order_Id__c) + '-L' + n).left(80),
                    NFY_Source_Key__c = (o.NFY_External_Order_Id__c + '-L' + n).left(120)));
            }
        }
        if (!items.isEmpty()) {
            update items;
        }
    }
}