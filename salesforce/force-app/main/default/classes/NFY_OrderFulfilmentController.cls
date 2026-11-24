/**
 * Fulfilment for orders a rep enters by hand in Salesforce (team, wholesale, scholastic).
 *
 * The rep adds products from any price book and, optionally, picks where each line ships from on the
 * order's Fulfilment card (saved on the order lines). Activating the order sends it to fulfilment
 * automatically (NFY_OrderTrigger → NFY_FulfilmentJob): it goes through the same Integration API as
 * Shopify and Amazon orders and gets a TC Sales Order, reserved stock and the same lifecycle.
 * Products Nfinity does not stock are billed with the order and never shipped.
 */
public with sharing class NFY_OrderFulfilmentController {

    /** Where a rep order can ship from: Nfinity's own sites, the 3PLs, the decorator and the factory. Never Amazon FBA or field stock. */
    private static final Set<String> SHIP_FROM_TYPES = new Set<String>{ 'In-house warehouse', 'Retail store', '3PL', 'Decorator', 'Factory' };

    public class Line {
        @AuraEnabled public Id itemId;
        @AuraEnabled public String product;
        @AuraEnabled public String sku;
        @AuraEnabled public Decimal quantity;
        @AuraEnabled public Decimal unitPrice;
        @AuraEnabled public Boolean isFreight;
        @AuraEnabled public Boolean stocked;
        @AuraEnabled public String shipFrom;
        // Preview before activation: what stock would cover this line.
        @AuraEnabled public Decimal available;
        @AuraEnabled public Decimal willAssign;
        @AuraEnabled public Decimal shortQty;
        @AuraEnabled public String stockStatus;
        @AuraEnabled public String note;
    }

    /** A TC Sales Order line after the order is sent: requested, assigned, short and status. */
    public class SoLine {
        @AuraEnabled public Id id;
        @AuraEnabled public String product;
        @AuraEnabled public String shipFrom;
        @AuraEnabled public Decimal requested;
        @AuraEnabled public Decimal assigned;
        @AuraEnabled public Decimal shortQty;
        @AuraEnabled public Decimal shipped;
        @AuraEnabled public String stockStatus;
    }

    public class Option {
        @AuraEnabled public String label;
        @AuraEnabled public String value;
        Option(String label, String value) {
            this.label = label;
            this.value = value;
        }
    }

    public class Pending {
        @AuraEnabled public String code;
        @AuraEnabled public String name;
        @AuraEnabled public Decimal units;
    }

    public class Context {
        @AuraEnabled public Id orderId;
        @AuraEnabled public String orderNumber;
        @AuraEnabled public String accountName;
        @AuraEnabled public String status;
        @AuraEnabled public Boolean sent = false;
        @AuraEnabled public Id salesOrderId;
        @AuraEnabled public String salesOrderName;
        @AuraEnabled public String externalOrderId;
        @AuraEnabled public String fulfilmentStatus;
        @AuraEnabled public String defaultShipFrom;
        @AuraEnabled public String lastLogStatus;
        @AuraEnabled public String lastLogMessage;
        @AuraEnabled public Id lastLogId;
        @AuraEnabled public List<Line> lines = new List<Line>();
        @AuraEnabled public List<Option> warehouses = new List<Option>();
        @AuraEnabled public List<Pending> pending = new List<Pending>();
        @AuraEnabled public List<SoLine> soLines = new List<SoLine>();
        @AuraEnabled public String stockStatus;
        @AuraEnabled public Decimal unitsRequested;
        @AuraEnabled public Decimal unitsAssigned;
        @AuraEnabled public Decimal unitsShort;
    }

    public static String orderKey(String orderNumber) {
        return 'SF-' + orderNumber;
    }

    @AuraEnabled(cacheable=false)
    public static Context getContext(Id orderId) {
        Order o = [
            SELECT Id, OrderNumber, Status, Account.Name, NFY_TC_Sales_Order__c, NFY_TC_Sales_Order__r.Name, NFY_External_Order_Id__c,
                NFY_Fulfillment_Status__c, NFY_Ship_From__r.NFY_Code__c,
                (SELECT Id, Quantity, UnitPrice, Product2.Name, Product2.ProductCode, Product2.TC_Inventory_Product__c, NFY_Ship_From__r.NFY_Code__c
                 FROM OrderItems ORDER BY OrderItemNumber)
            FROM Order WHERE Id = :orderId
        ];
        Context c = new Context();
        c.orderId = o.Id;
        c.orderNumber = o.OrderNumber;
        c.accountName = o.Account.Name;
        c.status = o.Status;
        c.sent = o.NFY_TC_Sales_Order__c != null;
        c.salesOrderId = o.NFY_TC_Sales_Order__c;
        c.salesOrderName = o.NFY_TC_Sales_Order__r.Name;
        c.externalOrderId = o.NFY_External_Order_Id__c;
        c.fulfilmentStatus = o.NFY_Fulfillment_Status__c;
        c.defaultShipFrom = o.NFY_Ship_From__r.NFY_Code__c == null ? NFY_Ref.MAIN : o.NFY_Ship_From__r.NFY_Code__c;
        for (OrderItem i : o.OrderItems) {
            Line l = new Line();
            l.itemId = i.Id;
            l.product = i.Product2.Name;
            l.sku = i.Product2.ProductCode;
            l.quantity = i.Quantity;
            l.unitPrice = i.UnitPrice;
            l.isFreight = i.Product2.ProductCode == NFY_Ref.FREIGHT_SKU;
            l.stocked = i.Product2.TC_Inventory_Product__c == true;
            l.shipFrom = i.NFY_Ship_From__r.NFY_Code__c == null ? c.defaultShipFrom : i.NFY_Ship_From__r.NFY_Code__c;
            c.lines.add(l);
        }
        for (TC_Warehouse__c w : [
            SELECT Name, NFY_Code__c FROM TC_Warehouse__c WHERE NFY_Code__c != null AND NFY_Type__c IN :SHIP_FROM_TYPES AND Active__c = true
            ORDER BY NFY_Routing_Rank__c NULLS LAST, Name
        ]) {
            c.warehouses.add(new Option(w.Name, w.NFY_Code__c));
        }
        if (!c.sent) {
            preview(c);
        }
        String key = orderKey(o.OrderNumber);
        for (NFY_Sync_Log__c l : [
            SELECT Id, Status__c, Error_Message__c, Response__c FROM NFY_Sync_Log__c
            WHERE Event_Type__c = 'order.upsert' AND External_Id__c = :key ORDER BY CreatedDate DESC LIMIT 1
        ]) {
            c.lastLogId = l.Id;
            c.lastLogStatus = l.Status__c;
            c.lastLogMessage = l.Status__c == 'Failed' ? l.Error_Message__c : l.Response__c;
        }
        if (c.sent) {
            TC_Sales_Order__c so = [SELECT NFY_Stock_Status__c, NFY_Units_Requested__c, NFY_Units_Assigned__c, NFY_Units_Short__c FROM TC_Sales_Order__c WHERE Id = :o.NFY_TC_Sales_Order__c];
            c.stockStatus = so.NFY_Stock_Status__c;
            c.unitsRequested = so.NFY_Units_Requested__c;
            c.unitsAssigned = so.NFY_Units_Assigned__c;
            c.unitsShort = so.NFY_Units_Short__c;
            for (TC_Sales_Order_Line__c l : [
                SELECT Id, Product__r.Name, NFY_Ship_From__r.Name, Quantity_Ordered__c, NFY_Assigned_Qty__c, NFY_Short_Qty__c, Quantity_Shipped__c, NFY_Stock_Status__c
                FROM TC_Sales_Order_Line__c WHERE Sales_Order__c = :o.NFY_TC_Sales_Order__c ORDER BY Name
            ]) {
                if (l.Product__r.Name == 'Freight') {
                    continue;
                }
                SoLine s = new SoLine();
                s.id = l.Id;
                s.product = l.Product__r.Name;
                s.shipFrom = l.NFY_Ship_From__r.Name;
                s.requested = l.Quantity_Ordered__c;
                s.assigned = l.NFY_Assigned_Qty__c;
                s.shortQty = l.NFY_Short_Qty__c;
                s.shipped = l.Quantity_Shipped__c;
                s.stockStatus = l.NFY_Stock_Status__c;
                c.soLines.add(s);
            }
            Map<String, Pending> byCode = new Map<String, Pending>();
            for (TC_Sales_Order_Line__c l : [
                SELECT Quantity_Ordered__c, Quantity_Shipped__c, NFY_Ship_From__r.NFY_Code__c, NFY_Ship_From__r.Name FROM TC_Sales_Order_Line__c
                WHERE Sales_Order__c = :o.NFY_TC_Sales_Order__c AND Product__r.TC_Inventory_Product__c = true AND NFY_Ship_From__c != null
            ]) {
                Decimal open = (l.Quantity_Ordered__c == null ? 0 : l.Quantity_Ordered__c) - (l.Quantity_Shipped__c == null ? 0 : l.Quantity_Shipped__c);
                if (open <= 0) {
                    continue;
                }
                String code = l.NFY_Ship_From__r.NFY_Code__c;
                if (!byCode.containsKey(code)) {
                    Pending p = new Pending();
                    p.code = code;
                    p.name = l.NFY_Ship_From__r.Name;
                    p.units = 0;
                    byCode.put(code, p);
                }
                byCode.get(code).units += open;
            }
            c.pending = byCode.values();
        }
        return c;
    }

    /**
     * What activating would do with today's stock, using the same rule as the service: the chosen ship-from
     * if it covers the line, else Nfinity Main if Main covers it, else whatever the chosen ship-from has.
     */
    private static void preview(Context c) {
        Set<Id> productIds = new Set<Id>();
        Map<Id, Id> productByItem = new Map<Id, Id>();
        for (OrderItem i : [SELECT Id, Product2Id FROM OrderItem WHERE OrderId = :c.orderId]) {
            productByItem.put(i.Id, i.Product2Id);
            productIds.add(i.Product2Id);
        }
        Map<String, Decimal> avail = new Map<String, Decimal>();
        Map<String, String> nameByCode = new Map<String, String>();
        for (TC_Inventory_Balance__c b : [
            SELECT Product__c, Location__r.NFY_Code__c, Warehouse__r.Name, Available_Quantity__c FROM TC_Inventory_Balance__c
            WHERE Product__c IN :productIds AND Location__r.NFY_Location_Type__c = 'Available'
        ]) {
            String code = b.Location__r.NFY_Code__c == null ? null : b.Location__r.NFY_Code__c.removeEnd('-AVL');
            avail.put(String.valueOf(b.Product__c) + '|' + code, b.Available_Quantity__c == null ? 0 : b.Available_Quantity__c);
            nameByCode.put(code, b.Warehouse__r.Name);
        }
        Map<String, Decimal> used = new Map<String, Decimal>();
        for (Line l : c.lines) {
            if (l.isFreight || !l.stocked) {
                l.stockStatus = l.isFreight ? 'Billed, not shipped' : 'Billed only';
                continue;
            }
            if (l.shipFrom == NFY_IntegrationService.FACTORY) {
                l.stockStatus = 'Factory drop-ship';
                l.note = 'A drop-ship PO goes to the factory; nothing is reserved.';
                continue;
            }
            Id productId = productByItem.get(l.itemId);
            String chosen = String.valueOf(productId) + '|' + l.shipFrom;
            String main = String.valueOf(productId) + '|' + NFY_Ref.MAIN;
            Decimal atChosen = (avail.containsKey(chosen) ? avail.get(chosen) : 0) - (used.containsKey(chosen) ? used.get(chosen) : 0);
            Decimal atMain = (avail.containsKey(main) ? avail.get(main) : 0) - (used.containsKey(main) ? used.get(main) : 0);
            String keyUsed = chosen;
            l.available = Math.max(atChosen, 0);
            if (atChosen < l.quantity && l.shipFrom != NFY_Ref.MAIN && atMain >= l.quantity) {
                l.note = 'Only ' + l.available.intValue() + ' at the chosen ship-from; falls back to Nfinity Main (' + atMain.intValue() + ' available).';
                l.willAssign = l.quantity;
                keyUsed = main;
            } else {
                l.willAssign = Math.min(l.quantity, l.available);
            }
            l.shortQty = l.quantity - l.willAssign;
            l.stockStatus = l.shortQty == 0 ? 'Fully assigned' : (l.willAssign > 0 ? 'Partially assigned' : 'No stock');
            if (l.shortQty > 0) {
                l.note = l.shortQty.intValue() + ' short: backordered, and assigned automatically when stock arrives at this ship-from.';
            }
            used.put(keyUsed, (used.containsKey(keyUsed) ? used.get(keyUsed) : 0) + l.willAssign);
        }
    }

    /** Saves the default ship-from on the order and any per-line choice on its order products. */
    @AuraEnabled
    public static void saveShipFrom(Id orderId, String defaultShipFrom, Map<String, String> lineShipFroms) {
        Map<String, Id> warehouseByCode = new Map<String, Id>();
        for (TC_Warehouse__c w : [SELECT Id, NFY_Code__c FROM TC_Warehouse__c WHERE NFY_Code__c != null]) {
            warehouseByCode.put(w.NFY_Code__c, w.Id);
        }
        if (String.isNotBlank(defaultShipFrom)) {
            update new Order(Id = orderId, NFY_Ship_From__c = warehouseByCode.get(defaultShipFrom));
        }
        if (lineShipFroms != null && !lineShipFroms.isEmpty()) {
            List<OrderItem> items = new List<OrderItem>();
            for (String itemId : lineShipFroms.keySet()) {
                items.add(new OrderItem(Id = Id.valueOf(itemId), NFY_Ship_From__c = warehouseByCode.get(lineShipFroms.get(itemId))));
            }
            update items;
        }
    }

    /** Saves the choices and activates the order; the Order trigger then sends it to fulfilment in the background. */
    @AuraEnabled
    public static void activate(Id orderId, String defaultShipFrom, Map<String, String> lineShipFroms) {
        saveShipFrom(orderId, defaultShipFrom, lineShipFroms);
        try {
            update new Order(Id = orderId, Status = 'Activated');
        } catch (DmlException e) {
            throw new AuraHandledException(e.getDmlMessage(0));
        }
    }

    /** Sends the order now (also the retry when an automatic run failed). Choices passed here are saved first. */
    @AuraEnabled
    public static NFY_IntegrationService.Result send(Id orderId, String defaultShipFrom, Map<String, String> lineShipFroms) {
        saveShipFrom(orderId, defaultShipFrom, lineShipFroms);
        return sendFromStored(orderId);
    }

    /** Builds the order event from the order as saved (ship-from per line, else the order's default, else Nfinity Main) and sends it. */
    public static NFY_IntegrationService.Result sendFromStored(Id orderId) {
        Order o = [
            SELECT Id, OrderNumber, EffectiveDate, AccountId, Account.Name, Account.BillingCity, Account.BillingState, Account.BillingCountry, Tax__c,
                NFY_Ship_From__r.NFY_Code__c,
                (SELECT Id, Quantity, UnitPrice, Product2Id, Product2.ProductCode, NFY_Ship_From__r.NFY_Code__c FROM OrderItems)
            FROM Order WHERE Id = :orderId
        ];
        if (o.OrderItems.isEmpty()) {
            throw new AuraHandledException('Add products to the order first.');
        }
        String fallbackCode = o.NFY_Ship_From__r.NFY_Code__c == null ? NFY_Ref.MAIN : o.NFY_Ship_From__r.NFY_Code__c;
        List<Object> lines = new List<Object>();
        Decimal freight = 0;
        for (OrderItem i : o.OrderItems) {
            if (i.Product2.ProductCode == NFY_Ref.FREIGHT_SKU) {
                freight += i.Quantity * i.UnitPrice;
                continue;
            }
            String code = i.NFY_Ship_From__r.NFY_Code__c == null ? fallbackCode : i.NFY_Ship_From__r.NFY_Code__c;
            lines.add(new Map<String, Object>{ 'productId' => i.Product2Id, 'sku' => i.Product2.ProductCode, 'qty' => i.Quantity,
                'price' => i.UnitPrice, 'shipFrom' => code });
        }
        if (lines.isEmpty()) {
            throw new AuraHandledException('The order has only freight. Add the products to ship.');
        }
        Map<String, Object> payload = new Map<String, Object>{
            'orderNumber' => orderKey(o.OrderNumber),
            'sfOrderId' => o.Id,
            'channel' => 'Wholesale / Team',
            'orderDate' => String.valueOf(o.EffectiveDate),
            'shipFrom' => fallbackCode,
            'allowFallback' => true,
            'salesRep' => UserInfo.getName(),
            'routingReason' => 'Entered in Salesforce by ' + UserInfo.getName() + '; ship-from as chosen on the order',
            'freight' => freight,
            'tax' => o.Tax__c == null ? 0 : o.Tax__c,
            'lines' => lines,
            'customer' => new Map<String, Object>{ 'accountId' => o.AccountId, 'name' => o.Account.Name,
                'email' => NFY_SimulatorController.emailFor(String.valueOf(o.AccountId)), 'phone' => NFY_SimulatorController.PHONE,
                'city' => o.Account.BillingCity, 'state' => o.Account.BillingState, 'country' => o.Account.BillingCountry, 'address' => o.Account.BillingCity }
        };
        return NFY_IntegrationService.process('order.upsert', 'SALESFORCE', JSON.serialize(payload), null, 'Manual');
    }

    /** Demo only: records the shipment that ShipStation, the decorator, the factory or a 3PL would report for one ship-from. */
    @AuraEnabled
    public static NFY_IntegrationService.Result recordShipment(Id orderId, String shipFromCode) {
        Order o = [SELECT NFY_External_Order_Id__c FROM Order WHERE Id = :orderId];
        return NFY_SimulatorController.shipFrom(o.NFY_External_Order_Id__c, shipFromCode).results[0];
    }
}