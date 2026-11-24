/**
 * Data for the Nfinity Ops Command Center: order, stock and shipment KPIs, integration health per
 * system, open failures, inbound in transit and close-checklist counts. Read-only.
 */
public with sharing class NFY_CommandCenterController {

    public class Kpi {
        @AuraEnabled public String key;
        @AuraEnabled public String label;
        @AuraEnabled public Decimal value;
        @AuraEnabled public String note;
        @AuraEnabled public String tone;
        Kpi(String key, String label, Decimal value, String note, String tone) {
            this.key = key;
            this.label = label;
            this.value = value;
            this.note = note;
            this.tone = tone;
        }
    }

    public class ChannelRow {
        @AuraEnabled public String channel;
        @AuraEnabled public Integer awaiting = 0;
        @AuraEnabled public Integer partial = 0;
        @AuraEnabled public Integer shipped = 0;
        @AuraEnabled public Integer billed = 0;
        @AuraEnabled public Integer last30 = 0;
        @AuraEnabled public Decimal revenue30 = 0;
    }

    public class StockRow {
        @AuraEnabled public Id warehouseId;
        @AuraEnabled public String code;
        @AuraEnabled public String name;
        @AuraEnabled public String type;
        @AuraEnabled public Decimal rank;
        @AuraEnabled public Decimal available = 0;
        @AuraEnabled public Decimal inTransit = 0;
        @AuraEnabled public Decimal value = 0;
        @AuraEnabled public Boolean physical;
        @AuraEnabled public String systemName;
    }

    public class SystemRow {
        @AuraEnabled public Id id;
        @AuraEnabled public String code;
        @AuraEnabled public String name;
        @AuraEnabled public String category;
        @AuraEnabled public String status;
        @AuraEnabled public String mode;
        @AuraEnabled public Datetime lastSync;
        @AuraEnabled public Integer jobs24h = 0;
        @AuraEnabled public Integer failed24h = 0;
        @AuraEnabled public Integer jobs7d = 0;
        @AuraEnabled public Integer failed7d = 0;
        @AuraEnabled public Integer openErrors = 0;
        @AuraEnabled public Integer flows = 0;
        @AuraEnabled public Decimal failureRate7d = 0;
        @AuraEnabled public String health;
        // Derived from the system's flows and logs, never from hand-maintained fields.
        @AuraEnabled public Integer totalFlows = 0;
        @AuraEnabled public Integer recipes = 0;
        @AuraEnabled public String stage;      // live | idle | planned | unmapped
        @AuraEnabled public String direction;  // in | out | both | none
        @AuraEnabled public String placement;  // left | right | hub
        @AuraEnabled public List<String> entities = new List<String>();
        @AuraEnabled public List<FlowRow> flowList = new List<FlowRow>();
    }

    public class FlowRow {
        @AuraEnabled public String name;
        @AuraEnabled public String direction;
        @AuraEnabled public String entity;
        @AuraEnabled public String mode;
        @AuraEnabled public String recipeId;
        @AuraEnabled public Boolean active;
    }

    /** Where a system sits on the map, by its category. */
    private static final Map<String, String> PLACEMENT = new Map<String, String>{
        'Sales channel' => 'left', '3PL / WMS' => 'right', 'Label system' => 'right',
        'Integration hub' => 'hub', 'CRM' => 'hub', 'Accounting / ERP' => 'hub'
    };

    /** Days without an event after which a live system counts as idle. */
    private static final Integer IDLE_DAYS = 7;

    public class LogRow {
        @AuraEnabled public Id id;
        @AuraEnabled public String name;
        @AuraEnabled public String systemName;
        @AuraEnabled public String eventType;
        @AuraEnabled public String externalId;
        @AuraEnabled public String error;
        @AuraEnabled public Datetime receivedAt;
        @AuraEnabled public Integer attempts;
        @AuraEnabled public String status;
    }

    public class InboundRow {
        @AuraEnabled public Id id;
        @AuraEnabled public String name;
        @AuraEnabled public String type;
        @AuraEnabled public String status;
        @AuraEnabled public String fromName;
        @AuraEnabled public String toName;
        @AuraEnabled public Decimal units;
        @AuraEnabled public Date eta;
        @AuraEnabled public Date shippedDate;
    }

    public class Summary {
        @AuraEnabled public List<Kpi> kpis = new List<Kpi>();
        @AuraEnabled public List<ChannelRow> channels = new List<ChannelRow>();
        @AuraEnabled public List<StockRow> stock = new List<StockRow>();
        @AuraEnabled public List<SystemRow> systems = new List<SystemRow>();
        @AuraEnabled public List<LogRow> failures = new List<LogRow>();
        @AuraEnabled public List<InboundRow> inbound = new List<InboundRow>();
        @AuraEnabled public Map<String, Integer> close = new Map<String, Integer>();
        @AuraEnabled public Datetime asOf;
    }

    @AuraEnabled(cacheable=false)
    public static Summary getSummary() {
        Summary s = new Summary();
        s.asOf = System.now();
        Datetime dayAgo = System.now().addHours(-24);
        Datetime weekAgo = System.now().addDays(-7);
        Date monthAgo = Date.today().addDays(-30);

        // Orders by channel and fulfillment status.
        Map<String, ChannelRow> byChannel = new Map<String, ChannelRow>();
        Integer awaiting = 0;
        Integer partial = 0;
        for (AggregateResult ar : [
            SELECT NFY_Channel__c ch, NFY_Fulfillment_Status__c st, COUNT(Id) c FROM TC_Sales_Order__c
            WHERE NFY_Demo__c = true GROUP BY NFY_Channel__c, NFY_Fulfillment_Status__c
        ]) {
            ChannelRow row = channelRow(byChannel, (String) ar.get('ch'));
            Integer c = (Integer) ar.get('c');
            String st = (String) ar.get('st');
            if (st == 'Awaiting Shipment' || st == 'Received') { row.awaiting += c; awaiting += c; }
            else if (st == 'Partially Shipped') { row.partial += c; partial += c; }
            else if (st == 'Shipped') { row.shipped += c; }
            else if (st == 'Billed') { row.billed += c; }
        }
        for (AggregateResult ar : [
            SELECT NFY_Channel__c ch, COUNT(Id) c, SUM(TotalAmount) t FROM Order WHERE NFY_Demo__c = true AND EffectiveDate >= :monthAgo GROUP BY NFY_Channel__c
        ]) {
            ChannelRow row = channelRow(byChannel, (String) ar.get('ch'));
            row.last30 = (Integer) ar.get('c');
            row.revenue30 = ar.get('t') == null ? 0 : (Decimal) ar.get('t');
        }
        s.channels = byChannel.values();

        Integer shippedToday = [SELECT COUNT() FROM TC_Shipment__c WHERE Sales_Order__r.NFY_Demo__c = true AND Status__c = 'Shipped' AND Shipment_Date__c = TODAY];
        Integer ordersToday = [SELECT COUNT() FROM Order WHERE NFY_Demo__c = true AND EffectiveDate = TODAY];

        // Stock by warehouse: available and in transit, at average cost.
        Map<Id, StockRow> byWh = new Map<Id, StockRow>();
        for (TC_Warehouse__c w : [SELECT Id, Name, NFY_Code__c, NFY_Type__c, NFY_Routing_Rank__c, NFY_Physical__c, NFY_System__r.Name FROM TC_Warehouse__c WHERE NFY_Code__c != null ORDER BY NFY_Routing_Rank__c NULLS LAST, Name]) {
            StockRow r = new StockRow();
            r.warehouseId = w.Id;
            r.code = w.NFY_Code__c;
            r.name = w.Name;
            r.type = w.NFY_Type__c;
            r.rank = w.NFY_Routing_Rank__c;
            r.physical = w.NFY_Physical__c;
            r.systemName = w.NFY_System__r.Name;
            byWh.put(w.Id, r);
        }
        for (AggregateResult ar : [
            SELECT Warehouse__c wh, Location__r.NFY_Location_Type__c lt, SUM(Available_Quantity__c) q FROM TC_Inventory_Balance__c
            WHERE Product__r.NFY_Demo__c = true AND Warehouse__c IN :byWh.keySet() GROUP BY Warehouse__c, Location__r.NFY_Location_Type__c
        ]) {
            StockRow r = byWh.get((Id) ar.get('wh'));
            Decimal q = ar.get('q') == null ? 0 : (Decimal) ar.get('q');
            if ((String) ar.get('lt') == 'In Transit') {
                r.inTransit += q;
            } else {
                r.available += q;
            }
        }
        s.stock = byWh.values();

        // Integration health: everything below comes from the flow records (configuration) and the sync
        // logs (what actually ran). The system record's own Status, Mode and Last Sync fields are not used.
        Map<Id, SystemRow> bySys = new Map<Id, SystemRow>();
        for (NFY_Integration_System__c x : [
            SELECT Id, Code__c, Name, Category__c,
                (SELECT Name, Active__c, Direction__c, Entity__c, Mode__c, Workato_Recipe_Id__c FROM Flows__r ORDER BY Active__c DESC, Name)
            FROM NFY_Integration_System__c ORDER BY Sort_Order__c
        ]) {
            SystemRow r = new SystemRow();
            r.id = x.Id;
            r.code = x.Code__c;
            r.name = x.Name;
            r.category = x.Category__c;
            r.placement = PLACEMENT.containsKey(x.Category__c) ? PLACEMENT.get(x.Category__c) : 'right';
            describeFlows(r, x.Flows__r);
            bySys.put(x.Id, r);
        }
        for (AggregateResult ar : [SELECT System__c sid, MAX(Received_At__c) lastAt FROM NFY_Sync_Log__c WHERE System__c IN :bySys.keySet() GROUP BY System__c]) {
            SystemRow r = bySys.get((Id) ar.get('sid'));
            if (r != null) r.lastSync = (Datetime) ar.get('lastAt');
        }
        for (AggregateResult ar : [SELECT System__c sid, Status__c st, Retry_Status__c rs, COUNT(Id) c FROM NFY_Sync_Log__c WHERE Received_At__c >= :weekAgo GROUP BY System__c, Status__c, Retry_Status__c]) {
            SystemRow r = bySys.get((Id) ar.get('sid'));
            if (r == null) continue;
            Integer c = (Integer) ar.get('c');
            r.jobs7d += c;
            if (countsAsFailure(ar)) r.failed7d += c;
        }
        for (AggregateResult ar : [SELECT System__c sid, Status__c st, Retry_Status__c rs, COUNT(Id) c FROM NFY_Sync_Log__c WHERE Received_At__c >= :dayAgo GROUP BY System__c, Status__c, Retry_Status__c]) {
            SystemRow r = bySys.get((Id) ar.get('sid'));
            if (r == null) continue;
            Integer c = (Integer) ar.get('c');
            r.jobs24h += c;
            if (countsAsFailure(ar)) r.failed24h += c;
        }
        for (AggregateResult ar : [SELECT System__c sid, COUNT(Id) c FROM NFY_Sync_Log__c WHERE Status__c = 'Failed' AND Resolved__c = false GROUP BY System__c]) {
            SystemRow r = bySys.get((Id) ar.get('sid'));
            if (r != null) r.openErrors = (Integer) ar.get('c');
        }
        Integer failedToday = 0;
        Integer openErrors = 0;
        Datetime idleSince = System.now().addDays(-IDLE_DAYS);
        for (SystemRow r : bySys.values()) {
            r.failureRate7d = r.jobs7d == 0 ? 0 : (100.0 * r.failed7d / r.jobs7d).setScale(1);
            if (r.totalFlows == 0) {
                r.stage = 'unmapped';
            } else if (r.flows == 0) {
                r.stage = 'planned';
            } else {
                r.stage = r.lastSync != null && r.lastSync >= idleSince ? 'live' : 'idle';
            }
            r.health = healthOf(r);
            r.status = STAGE_LABEL.get(r.stage);
            failedToday += r.failed24h;
            openErrors += r.openErrors;
        }
        s.systems = bySys.values();

        for (NFY_Sync_Log__c l : [
            SELECT Id, Name, System__r.Name, Event_Type__c, External_Id__c, Error_Message__c, Received_At__c, Attempts__c, Status__c
            FROM NFY_Sync_Log__c WHERE Status__c = 'Failed' AND Resolved__c = false ORDER BY Received_At__c DESC LIMIT 8
        ]) {
            LogRow r = new LogRow();
            r.id = l.Id;
            r.name = l.Name;
            r.systemName = l.System__r.Name;
            r.eventType = l.Event_Type__c;
            r.externalId = l.External_Id__c;
            r.error = l.Error_Message__c;
            r.receivedAt = l.Received_At__c;
            r.attempts = l.Attempts__c == null ? 0 : l.Attempts__c.intValue();
            r.status = l.Status__c;
            s.failures.add(r);
        }

        Decimal inboundUnits = 0;
        for (NFY_Inbound_Shipment__c ib : [
            SELECT Id, Name, Type__c, Status__c, From_Warehouse__r.Name, To_Warehouse__r.Name, Units_Shipped__c, Units_Received__c, ETA__c, Shipped_Date__c
            FROM NFY_Inbound_Shipment__c WHERE Status__c NOT IN ('Closed', 'Cancelled') ORDER BY ETA__c NULLS LAST, Shipped_Date__c LIMIT 10
        ]) {
            InboundRow r = new InboundRow();
            r.id = ib.Id;
            r.name = ib.Name;
            r.type = ib.Type__c;
            r.status = ib.Status__c;
            r.fromName = ib.Type__c == 'Factory container' ? 'Factory (Xiamen)' : ib.From_Warehouse__r.Name;
            r.toName = ib.To_Warehouse__r.Name;
            r.units = (ib.Units_Shipped__c == null ? 0 : ib.Units_Shipped__c) - (ib.Units_Received__c == null ? 0 : ib.Units_Received__c);
            r.eta = ib.ETA__c;
            r.shippedDate = ib.Shipped_Date__c;
            inboundUnits += r.units;
            s.inbound.add(r);
        }

        Integer openRecons = [SELECT COUNT() FROM NFY_Inventory_Recon__c WHERE Status__c = 'Open'];
        Integer unposted = [SELECT COUNT() FROM TC_Billing__c WHERE NFY_Channel__c != null AND Status__c != 'Posted'];
        Integer exceptions = [SELECT COUNT() FROM NFY_Settlement__c WHERE Status__c = 'Exceptions'];
        Integer unsettled = [SELECT COUNT() FROM TC_Billing__c WHERE NFY_Channel__c != null AND Status__c = 'Posted' AND Balance__c > 0 AND Customer__r.NFY_External_Customer_Id__c LIKE 'PAYER-%'];
        s.close.put('unpostedBillings', unposted);
        s.close.put('settlementExceptions', exceptions);
        s.close.put('openRecons', openRecons);
        s.close.put('awaitingSettlement', unsettled);
        s.close.put('openErrors', openErrors);

        s.kpis.add(new Kpi('ordersToday', 'Orders today', ordersToday, 'All channels', 'neutral'));
        s.kpis.add(new Kpi('awaiting', 'Waiting to ship', awaiting, partial + ' partially shipped', awaiting > 25 ? 'warning' : 'neutral'));
        s.kpis.add(new Kpi('shippedToday', 'Shipped today', shippedToday, 'TC shipments', 'neutral'));
        s.kpis.add(new Kpi('inbound', 'Units inbound', inboundUnits, s.inbound.size() + ' shipments on the way', 'neutral'));
        s.kpis.add(new Kpi('failed', 'Sync failures (24h)', failedToday, openErrors + ' still open', openErrors > 0 ? 'critical' : 'ok'));
        s.kpis.add(new Kpi('recons', 'Stock mismatches', openRecons, 'Open reconciliation items', openRecons > 0 ? 'warning' : 'ok'));
        return s;
    }

    private static final Map<String, String> STAGE_LABEL = new Map<String, String>{
        'live' => 'Live', 'idle' => 'Connected, no recent events', 'planned' => 'Planned', 'unmapped' => 'No flows defined'
    };

    /**
     * Mode, direction, entities and recipe count from the system's flows. Active flows describe what
     * runs today; when none is active, the planned flows describe what is intended.
     */
    @TestVisible
    private static void describeFlows(SystemRow r, List<NFY_Integration_Flow__c> flows) {
        List<NFY_Integration_Flow__c> active = new List<NFY_Integration_Flow__c>();
        for (NFY_Integration_Flow__c f : flows) {
            FlowRow fr = new FlowRow();
            fr.name = f.Name;
            fr.direction = f.Direction__c;
            fr.entity = f.Entity__c;
            fr.mode = f.Mode__c;
            fr.recipeId = f.Workato_Recipe_Id__c;
            fr.active = f.Active__c;
            r.flowList.add(fr);
            if (f.Active__c) active.add(f);
        }
        r.totalFlows = flows.size();
        r.flows = active.size();
        List<NFY_Integration_Flow__c> basis = active.isEmpty() ? flows : active;
        Set<String> modes = new Set<String>();
        Set<String> recipes = new Set<String>();
        Boolean dirIn = false;
        Boolean dirOut = false;
        for (NFY_Integration_Flow__c f : basis) {
            if (String.isNotBlank(f.Mode__c)) modes.add(f.Mode__c);
            if (String.isNotBlank(f.Entity__c) && !r.entities.contains(f.Entity__c)) r.entities.add(f.Entity__c);
            if (f.Direction__c == 'Into Salesforce' || f.Direction__c == 'Two-way') dirIn = true;
            if (f.Direction__c == 'Out of Salesforce' || f.Direction__c == 'Two-way' || f.Direction__c == 'System to system') dirOut = true;
        }
        for (NFY_Integration_Flow__c f : active) {
            if (String.isNotBlank(f.Workato_Recipe_Id__c)) recipes.add(f.Workato_Recipe_Id__c);
        }
        r.recipes = recipes.size();
        r.mode = modes.isEmpty() ? (flows.isEmpty() ? null : 'Mode not set') : String.join(new List<String>(modes), ' + ');
        r.direction = dirIn && dirOut ? 'both' : (dirIn ? 'in' : (dirOut ? 'out' : 'none'));
    }

    @TestVisible
    private static String healthOf(SystemRow r) {
        if (r.stage == 'planned' || r.stage == 'unmapped') return 'planned';
        if (r.openErrors > 0) return 'error';
        if (r.stage == 'idle') return 'idle';
        if (r.failureRate7d >= 10) return 'warning';
        return 'ok';
    }

    /**
     * A failure counts against a system's health unless a newer state of the same record replaced it
     * (Retry Status "Superseded"), such as the half-saved Odoo product sent before its SKU was stored.
     */
    private static Boolean countsAsFailure(AggregateResult ar) {
        return (String) ar.get('st') == 'Failed' && (String) ar.get('rs') != 'Superseded';
    }

    private static ChannelRow channelRow(Map<String, ChannelRow> m, String ch) {
        String k = ch == null ? 'Unassigned' : ch;
        if (!m.containsKey(k)) {
            ChannelRow r = new ChannelRow();
            r.channel = k;
            m.put(k, r);
        }
        return m.get(k);
    }

    /** Stock matrix for one product family: rows are products, columns are physical warehouses. */
    @AuraEnabled(cacheable=false)
    public static List<Map<String, Object>> getStockMatrix(String family) {
        List<Map<String, Object>> rows = new List<Map<String, Object>>();
        Map<Id, Map<String, Object>> byProduct = new Map<Id, Map<String, Object>>();
        List<String> families = String.isBlank(family) ? new List<String>{ 'Footwear', 'Apparel', 'Accessories' } : new List<String>{ family };
        for (Product2 p : [SELECT Id, Name, ProductCode FROM Product2 WHERE NFY_Demo__c = true AND TC_Inventory_Product__c = true AND Family IN :families ORDER BY Name]) {
            Map<String, Object> r = new Map<String, Object>{ 'productId' => p.Id, 'name' => p.Name, 'sku' => p.ProductCode };
            byProduct.put(p.Id, r);
            rows.add(r);
        }
        for (AggregateResult ar : [
            SELECT Product__c pid, Location__r.NFY_Code__c loc, SUM(Available_Quantity__c) q FROM TC_Inventory_Balance__c
            WHERE Product__c IN :byProduct.keySet() GROUP BY Product__c, Location__r.NFY_Code__c
        ]) {
            String loc = (String) ar.get('loc');
            if (loc == null) continue;
            Map<String, Object> r = byProduct.get((Id) ar.get('pid'));
            String col = loc.startsWith('FIELD-') ? 'FIELD' : loc.removeEnd('-AVL');
            Decimal q = ar.get('q') == null ? 0 : (Decimal) ar.get('q');
            r.put(col, (r.containsKey(col) ? (Decimal) r.get(col) : 0) + q);
        }
        return rows;
    }

    @AuraEnabled
    public static NFY_IntegrationService.Result retryLog(Id logId) {
        return NFY_IntegrationService.retry(logId);
    }
}