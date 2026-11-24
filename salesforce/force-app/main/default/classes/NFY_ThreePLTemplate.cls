/**
 * Plug-in template for a new 3PL: one call creates the integration system, the warehouse with
 * Available and In Transit locations, and the standard flows every 3PL runs. Order routing,
 * shipments, stock snapshots and inbound then work through the same services as ShipMonk.
 */
public with sharing class NFY_ThreePLTemplate {

    public static final List<List<String>> STANDARD_FLOWS = new List<List<String>>{
        // entity, direction, mode, schedule, recipe suffix
        new List<String>{ 'Order', 'Out of Salesforce', 'Webhook', 'Real-time', 'Orders to WMS' },
        new List<String>{ 'Shipment', 'Into Salesforce', 'Webhook', 'Real-time', 'Shipments + tracking' },
        new List<String>{ 'Inventory', 'Into Salesforce', 'Polling', 'Every 4 hours', 'Stock snapshot' },
        new List<String>{ 'Inbound', 'Into Salesforce', 'Webhook', 'Real-time', 'Inbound receipts (ASN)' },
        new List<String>{ 'PO Receipt', 'Into Salesforce', 'Webhook', 'Real-time', 'PO receipts' },
        new List<String>{ 'Return', 'Into Salesforce', 'Webhook', 'Real-time', 'Returns' }
    };

    @AuraEnabled
    public static Id onboard(String name, String code, String city, String region, String currencyCode, String systemCode) {
        if (String.isBlank(name) || String.isBlank(code) || String.isBlank(systemCode)) {
            throw new AuraHandledException('Enter a name, a warehouse code and the 3PL system.');
        }
        code = code.toUpperCase();
        systemCode = systemCode.toUpperCase();
        if (!([SELECT Id FROM TC_Warehouse__c WHERE NFY_Code__c = :code].isEmpty())) {
            throw new AuraHandledException('Warehouse ' + code + ' already exists.');
        }
        List<NFY_Integration_System__c> systems = [SELECT Id, Name FROM NFY_Integration_System__c WHERE Code__c = :systemCode LIMIT 1];
        NFY_Integration_System__c sys = systems.isEmpty()
            ? new NFY_Integration_System__c(Name = systemCode, Code__c = systemCode, Category__c = '3PL / WMS')
            : systems[0];
        sys.Status__c = 'Connected';
        sys.Mode__c = 'Webhook';
        sys.Region__c = region;
        upsert sys;

        Decimal rank = 1;
        for (AggregateResult ar : [SELECT MAX(NFY_Routing_Rank__c) r FROM TC_Warehouse__c]) {
            rank = ar.get('r') == null ? 1 : (Decimal) ar.get('r') + 1;
        }
        TC_Warehouse__c w = new TC_Warehouse__c(Name = name, Active__c = true, NFY_Code__c = code, NFY_Type__c = '3PL', NFY_Region__c = region,
            NFY_Currency__c = currencyCode, NFY_City__c = city, NFY_Routing_Rank__c = rank, NFY_System__c = sys.Id, NFY_Physical__c = true,
            Address__c = city);
        insert w;
        insert new List<TC_Location__c>{
            new TC_Location__c(Name = name + ' · Available', Warehouse__c = w.Id, NFY_Code__c = code + '-AVL', NFY_Location_Type__c = 'Available'),
            new TC_Location__c(Name = name + ' · In Transit', Warehouse__c = w.Id, NFY_Code__c = code + '-TRANSIT', NFY_Location_Type__c = 'In Transit', NFY_Active_In_Shopify__c = false)
        };
        List<NFY_Integration_Flow__c> flows = new List<NFY_Integration_Flow__c>();
        for (List<String> f : STANDARD_FLOWS) {
            String flowCode = systemCode + '-' + f[0].toUpperCase().replace(' ', '_');
            if ([SELECT COUNT() FROM NFY_Integration_Flow__c WHERE Code__c = :flowCode] > 0) {
                continue;
            }
            flows.add(new NFY_Integration_Flow__c(Name = sys.Name + ': ' + f[4], Code__c = flowCode, System__c = sys.Id, Entity__c = f[0],
                Direction__c = f[1], Mode__c = f[2], Schedule__c = f[3], Environment__c = 'Production', Active__c = true, Version__c = 'v1.0',
                Owner__c = 'Twopir integration team', Workato_Recipe__c = '[3PL template] ' + f[4] + ' (' + sys.Name + ')',
                Last_Changed__c = Date.today(), Change_Note__c = 'Created from the 3PL connector template.'));
        }
        insert flows;
        NFY_Ref.reset();
        return w.Id;
    }
}