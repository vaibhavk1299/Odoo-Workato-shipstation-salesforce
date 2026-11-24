/**
 * Feeds the Integration Origin component: where a record came from, its last sync, and the
 * Integration Log entries that touched it. Reads respect the user's field access; fields the
 * user cannot see are left out instead of failing the card.
 */
public with sharing class NFY_IntegrationOriginController {

    private static final String WORKATO_HOST = 'https://app.trial.workato.com';

    /** The matching key shown on the card, per object; others use NFY_Source_Key__c. */
    private static final Map<String, String> KEY_FIELD = new Map<String, String>{
        'Order' => 'NFY_External_Order_Id__c', 'Account' => 'NFY_External_Customer_Id__c',
        'TC_Sales_Order__c' => 'NFY_External_Order_Id__c', 'TC_Shipment__c' => 'NFY_External_Id__c'
    };

    /** IDs other systems hold for the same record; shown when the object has the field and it is filled. */
    private static final Map<String, String> SYSTEM_ID_FIELDS = new Map<String, String>{
        'NFY_Odoo_Partner_Id__c' => 'Odoo partner', 'NFT_Shopify_Customer_Id__c' => 'Shopify customer', 'NFT_Amazon_Buyer_Id__c' => 'Amazon buyer',
        'NFT_Shopify_Order_Id__c' => 'Shopify order', 'NFY_ShipStation_Order_Id__c' => 'ShipStation order',
        'NFY_Odoo_Product_Id__c' => 'Odoo product', 'NFT_Shopify_Product_Id__c' => 'Shopify product', 'NFT_Shopify_Variant_Id__c' => 'Shopify variant'
    };

    public class SystemId {
        @AuraEnabled public String label;
        @AuraEnabled public String value;
        SystemId(String label, String value) {
            this.label = label;
            this.value = value;
        }
    }

    public class LogRow {
        @AuraEnabled public Id id;
        @AuraEnabled public String name;
        @AuraEnabled public String url;
        @AuraEnabled public String systemName;
        @AuraEnabled public String eventType;
        @AuraEnabled public String status;
        @AuraEnabled public String operation;
        @AuraEnabled public String transport;
        @AuraEnabled public String jobId;
        @AuraEnabled public String jobUrl;
        @AuraEnabled public Datetime receivedAt;
        @AuraEnabled public Decimal attempts;
        @AuraEnabled public String externalId;
        @AuraEnabled public String error;
        @AuraEnabled public String errorCategory;
        @AuraEnabled public String retryStatus;
        @AuraEnabled public Boolean resolved;
        @AuraEnabled public String recordName;
        @AuraEnabled public String recordUrl;
    }

    public class Origin {
        @AuraEnabled public Boolean integrated = false;
        @AuraEnabled public String sourceSystem;
        @AuraEnabled public String sourceRecordId;
        @AuraEnabled public String sourceKey;
        @AuraEnabled public String sourceUrl;
        @AuraEnabled public String syncedVia;
        @AuraEnabled public String lastStatus;
        @AuraEnabled public String lastOperation;
        @AuraEnabled public Datetime lastSyncedAt;
        @AuraEnabled public Decimal syncCount;
        @AuraEnabled public Id lastLogId;
        @AuraEnabled public String lastLogName;
        @AuraEnabled public String workatoJobUrl;
        @AuraEnabled public List<SystemId> systemIds = new List<SystemId>();
        @AuraEnabled public List<LogRow> logs = new List<LogRow>();
    }

    @AuraEnabled
    public static Origin getOrigin(Id recordId) {
        Origin out = new Origin();
        if (recordId == null) {
            return out;
        }
        Schema.DescribeSObjectResult d = recordId.getSObjectType().getDescribe();
        Map<String, Schema.SObjectField> fm = d.fields.getMap();
        String keyField = KEY_FIELD.containsKey(d.getName()) ? KEY_FIELD.get(d.getName()) : 'NFY_Source_Key__c';
        List<String> wanted = new List<String>{ 'NFY_Source_System__c', 'NFY_Source_Record_Id__c', 'NFY_Synced_Via__c', 'NFY_Last_Sync_Status__c',
            'NFY_Last_Synced_At__c', 'NFY_Last_Sync_Operation__c', 'NFY_Sync_Count__c', 'NFY_Last_Sync_Log__c', keyField };
        wanted.addAll(SYSTEM_ID_FIELDS.keySet());
        List<String> fields = new List<String>{ 'Id' };
        for (String f : wanted) {
            Schema.SObjectField sf = fm.get(f.toLowerCase());
            if (sf != null && sf.getDescribe().isAccessible() && !fields.contains(f)) {
                fields.add(f);
            }
        }
        SObject rec = Database.query('SELECT ' + String.join(fields, ', ') + ' FROM ' + d.getName() + ' WHERE Id = :recordId');

        out.sourceSystem = (String) value(rec, fields, 'NFY_Source_System__c');
        out.integrated = out.sourceSystem != null;
        out.sourceRecordId = (String) value(rec, fields, 'NFY_Source_Record_Id__c');
        out.sourceKey = (String) value(rec, fields, keyField);
        out.syncedVia = (String) value(rec, fields, 'NFY_Synced_Via__c');
        out.lastStatus = (String) value(rec, fields, 'NFY_Last_Sync_Status__c');
        out.lastOperation = (String) value(rec, fields, 'NFY_Last_Sync_Operation__c');
        out.lastSyncedAt = (Datetime) value(rec, fields, 'NFY_Last_Synced_At__c');
        out.syncCount = (Decimal) value(rec, fields, 'NFY_Sync_Count__c');
        out.lastLogId = (Id) value(rec, fields, 'NFY_Last_Sync_Log__c');

        for (String f : SYSTEM_ID_FIELDS.keySet()) {
            addId(out, rec, fields, f, SYSTEM_ID_FIELDS.get(f));
        }
        out.sourceUrl = sourceUrl(out.sourceSystem, out.sourceRecordId, d.getName());

        String idText = String.valueOf(recordId);
        for (NFY_Sync_Log__c l : [
            SELECT Id, Name, System__r.Name, Event_Type__c, Status__c, Operation__c, Source__c, Workato_Job_Id__c, Flow__r.Workato_Recipe_Id__c,
                Received_At__c, Attempts__c, External_Id__c, Error_Message__c, Error_Category__c, Retry_Status__c, Resolved__c, Record_Id__c, Record_Name__c
            FROM NFY_Sync_Log__c
            WHERE Order__c = :recordId OR Account__c = :recordId OR Sales_Order__c = :recordId OR Product__c = :recordId
                OR Shipment__c = :recordId OR Record_Id__c = :idText OR Id = :out.lastLogId
            ORDER BY Received_At__c DESC LIMIT 25
        ]) {
            LogRow row = row(l);
            out.logs.add(row);
            if (l.Id == out.lastLogId) {
                out.lastLogName = l.Name;
                out.workatoJobUrl = row.jobUrl;
            }
        }
        return out;
    }

    @AuraEnabled
    public static LogRow getLog(Id logId) {
        List<NFY_Sync_Log__c> logs = [
            SELECT Id, Name, System__r.Name, Event_Type__c, Status__c, Operation__c, Source__c, Workato_Job_Id__c, Flow__r.Workato_Recipe_Id__c,
                Received_At__c, Attempts__c, External_Id__c, Error_Message__c, Error_Category__c, Retry_Status__c, Resolved__c, Record_Id__c, Record_Name__c
            FROM NFY_Sync_Log__c WHERE Id = :logId
        ];
        return logs.isEmpty() ? null : row(logs[0]);
    }

    @AuraEnabled
    public static NFY_IntegrationService.Result retryLog(Id logId) {
        try {
            return NFY_IntegrationService.retry(logId);
        } catch (Exception e) {
            AuraHandledException ex = new AuraHandledException(e.getMessage());
            ex.setMessage(e.getMessage());
            throw ex;
        }
    }

    private static Object value(SObject rec, List<String> fields, String f) {
        return fields.contains(f) ? rec.get(f) : null;
    }

    private static void addId(Origin out, SObject rec, List<String> fields, String f, String label) {
        Object v = value(rec, fields, f);
        if (v != null) {
            out.systemIds.add(new SystemId(label, String.valueOf(v)));
        }
    }

    /** Odoo model that holds each Salesforce object's source record, for "{model}" in a link template. */
    private static final Map<String, String> ODOO_MODEL = new Map<String, String>{
        'Account' => 'res.partner', 'Contact' => 'res.partner', 'Product2' => 'product.product'
    };

    /**
     * Link to the record in its source system, from the system's template in NFY Source Link. A template with
     * "{model}" works only for objects whose source record ID is that system's numeric record ID; other
     * objects (orders, shipments, stock moves keep a name, not an ID) get no link rather than a broken one.
     */
    @TestVisible
    private static String sourceUrl(String sys, String nativeId, String objectName) {
        if (sys == null || String.isBlank(nativeId)) {
            return null;
        }
        for (NFY_Source_Link__mdt m : [SELECT Record_URL_Template__c FROM NFY_Source_Link__mdt WHERE System__c = :sys LIMIT 1]) {
            String t = m.Record_URL_Template__c;
            if (String.isBlank(t)) {
                return null;
            }
            if (t.contains('{model}')) {
                String model = sys == 'Odoo' ? ODOO_MODEL.get(objectName) : null;
                if (model == null || !nativeId.isNumeric()) {
                    return null;
                }
                t = t.replace('{model}', model);
            }
            return t.replace('{id}', EncodingUtil.urlEncode(nativeId, 'UTF-8'));
        }
        return null;
    }

    private static LogRow row(NFY_Sync_Log__c l) {
        LogRow r = new LogRow();
        r.id = l.Id;
        r.name = l.Name;
        r.url = '/' + l.Id;
        r.systemName = l.System__r == null ? null : l.System__r.Name;
        r.eventType = l.Event_Type__c;
        r.status = l.Status__c;
        r.operation = l.Operation__c;
        r.transport = l.Source__c;
        r.jobId = l.Workato_Job_Id__c;
        r.receivedAt = l.Received_At__c;
        r.attempts = l.Attempts__c;
        r.externalId = l.External_Id__c;
        r.error = l.Error_Message__c;
        r.errorCategory = l.Error_Category__c;
        r.retryStatus = l.Retry_Status__c;
        r.resolved = l.Resolved__c;
        r.recordName = l.Record_Name__c;
        r.recordUrl = String.isBlank(l.Record_Id__c) ? null : '/' + l.Record_Id__c;
        String recipe = l.Flow__r == null ? null : l.Flow__r.Workato_Recipe_Id__c;
        if (l.Source__c == 'Workato' && String.isNotBlank(recipe) && String.isNotBlank(l.Workato_Job_Id__c)) {
            r.jobUrl = WORKATO_HOST + '/recipes/' + recipe + '/job/' + l.Workato_Job_Id__c;
        }
        return r;
    }
}