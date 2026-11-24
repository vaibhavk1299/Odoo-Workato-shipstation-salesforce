/**
 * stock.adjusted: keeps Salesforce stock in step with the system that physically holds it (Odoo
 * today). One event per completed stock move:
 *
 *   { moveId, reference, date, reason, sku, qty, from, to, unitCost }
 *
 *   from / to   Salesforce warehouse codes (TC Warehouse NFY Code). The sender resolves them from its
 *               own location setup; only one side is set for a receipt or a write-off, both for a transfer.
 *   reason      receipt | adjustment | scrap | production | transfer
 *   unitCost    the sender's unit cost; the product's moving average cost is used when it is missing.
 *
 * Nothing is hardcoded: the product comes from the SKU, the location from the warehouse code, the
 * ledger from TC's default ledger, the inventory account from the product, and the offset account
 * from TC's GL Account Defaults for that ledger (Vouchers Payable for receipts, Inventory Variance
 * for counts, scrap and production). Increases release backorders waiting at that warehouse.
 */
public without sharing class NFY_StockSyncService {
    public class StockSyncException extends Exception {}

    public class Outcome {
        public Id recordId;
        public String recordName;
        public String message;
    }

    /** Which TC GL Account Default carries the other side of the entry, by reason. */
    private static final Map<String, String> OFFSET_SPEC = new Map<String, String>{
        'receipt' => TC_AccountingContext.VOUCHERS_PAYABLE,
        'adjustment' => 'Inventory_Variance',
        'scrap' => 'Inventory_Variance',
        'production' => 'Inventory_Variance'
    };

    /** Source of every inventory movement this event writes: the sending system, its stock move ID and the log entry. */
    private static void origin(SObject m, String source, Map<String, Object> p) {
        m.put('NFY_Source_System__c', NFY_OriginService.systemValue(source));
        String moveId = text(p, 'moveId');
        m.put('NFY_Source_Record_Id__c', moveId == null ? null : NFY_OriginService.nativeId(moveId).left(80));
        m.put('NFY_Last_Sync_Log__c', NFY_IntegrationService.currentLogId);
    }

    public static Outcome apply(String source, Map<String, Object> p) {
        String sku = text(p, 'sku');
        if (String.isBlank(sku)) {
            throw new StockSyncException('The stock move has no SKU.');
        }
        Decimal qty = num(p, 'qty');
        if (qty == null || qty <= 0) {
            throw new StockSyncException('The stock move for ' + sku + ' has no quantity.');
        }
        String fromCode = text(p, 'from');
        String toCode = text(p, 'to');
        if (fromCode == null && toCode == null) {
            throw new StockSyncException('The stock move for ' + sku + ' has no Salesforce warehouse on either side. '
                + 'Set the Salesforce warehouse code on the ' + source + ' location.');
        }
        String reason = String.isBlank(text(p, 'reason')) ? (fromCode != null && toCode != null ? 'transfer' : 'adjustment') : text(p, 'reason').toLowerCase();
        Date d = dateOf(text(p, 'date'));
        String ref = text(p, 'reference');

        Product2 prod = NFY_Ref.product(sku);
        if (prod.TC_Inventory_Product__c != true) {
            throw new StockSyncException(prod.Name + ' (' + sku + ') has no stock tracking in Salesforce, so its stock is not kept here. '
                + 'Turn on Track Inventory for it in ' + source + ' and save the product.');
        }
        Id ledger = TC_AccountingContext.getDefaultLedgerId();
        Decimal cost = num(p, 'unitCost');
        if (cost == null || cost <= 0) {
            cost = prod.TC_Moving_Average_Cost__c != null ? prod.TC_Moving_Average_Cost__c : nz(prod.TC_Unit_Cost__c);
        }
        cost = cost.setScale(6, RoundingMode.HALF_UP);
        String what = qty.stripTrailingZeros().toPlainString() + ' × ' + prod.Name;
        String tag = ' (' + reason + (ref == null ? '' : ' ' + ref) + ')';

        Outcome o = new Outcome();
        if (fromCode != null && toCode != null) {
            TC_Warehouse__c fw = NFY_Ref.warehouse(fromCode);
            TC_Warehouse__c tw = NFY_Ref.warehouse(toCode);
            if (fw.Id == tw.Id) {
                TC_Inventory_Balance__c b = balance(prod, fw, ledger);
                o.recordId = b.Id;
                o.recordName = b.Name;
                o.message = 'No stock change: ' + what + ' moved inside ' + fw.Name + tag + '.';
                return o;
            }
            TC_Inventory_Balance__c src = balance(prod, fw, ledger);
            TC_Inventory_Balance__c dst = balance(prod, tw, ledger);
            requireAvailable(src, qty, prod, fw);
            TC_TriggerGate.allowInventoryTransfer = true;
            try {
                TC_Outbound_Inventory_Movement__c out = new TC_Outbound_Inventory_Movement__c(Inventory_Balance__c = src.Id, Type__c = 'Non-Accounting',
                    Quantity__c = qty, Unit_Cost__c = cost, Movement_Date__c = d, Ledger__c = ledger);
                origin(out, source, p);
                insert out;
                TC_Inbound_Inventory_Movement__c inb = new TC_Inbound_Inventory_Movement__c(Inventory_Balance__c = dst.Id, Type__c = 'Non-Accounting', Quantity__c = qty,
                    Unit_Cost__c = cost, Movement_Date__c = d, Ledger__c = ledger, Outbound_Inventory_Movement__c = out.Id);
                origin(inb, source, p);
                insert inb;
            } finally {
                TC_TriggerGate.allowInventoryTransfer = false;
            }
            o.recordId = dst.Id;
            o.recordName = dst.Name;
            o.message = 'Moved ' + what + ' from ' + fw.Name + ' to ' + tw.Name + tag + '. Available: ' + fw.Name + ' ' + available(src.Id)
                + ', ' + tw.Name + ' ' + available(dst.Id) + '.' + NFY_IntegrationService.fillBackorders(new Set<Id>{ dst.Location__c }, d);
            return o;
        }

        Id offset = offsetAccount(ledger, reason);
        if (toCode != null) {
            TC_Warehouse__c w = NFY_Ref.warehouse(toCode);
            TC_Inventory_Balance__c b = balance(prod, w, ledger);
            TC_Inbound_Inventory_Movement__c inb = new TC_Inbound_Inventory_Movement__c(Inventory_Balance__c = b.Id, Type__c = 'Accounting', Quantity__c = qty, Unit_Cost__c = cost,
                Movement_Date__c = d, Ledger__c = ledger, Debit_GL_Account__c = prod.TC_Inventory_GL_Account__c, Credit_GL_Account__c = offset);
            origin(inb, source, p);
            insert inb;
            o.recordId = b.Id;
            o.recordName = b.Name;
            o.message = 'Added ' + what + ' at ' + w.Name + ' at ' + cost.setScale(2) + tag + '. Available now ' + available(b.Id) + '.'
                + NFY_IntegrationService.fillBackorders(new Set<Id>{ b.Location__c }, d);
            return o;
        }

        TC_Warehouse__c w = NFY_Ref.warehouse(fromCode);
        TC_Inventory_Balance__c b = balance(prod, w, ledger);
        requireAvailable(b, qty, prod, w);
        TC_Outbound_Inventory_Movement__c outb = new TC_Outbound_Inventory_Movement__c(Inventory_Balance__c = b.Id, Type__c = 'Accounting', Quantity__c = qty, Unit_Cost__c = cost,
            Movement_Date__c = d, Ledger__c = ledger, Debit_GL_Account__c = offset, Credit_GL_Account__c = prod.TC_Inventory_GL_Account__c);
        origin(outb, source, p);
        insert outb;
        o.recordId = b.Id;
        o.recordName = b.Name;
        o.message = 'Removed ' + what + ' at ' + w.Name + tag + '. Available now ' + available(b.Id) + '.';
        return o;
    }

    private static TC_Inventory_Balance__c balance(Product2 prod, TC_Warehouse__c w, Id ledger) {
        Id locId = NFY_Ref.location(w.NFY_Code__c, 'AVL').Id;
        Id balanceId = TC_InventoryService.balancesFor(new Set<Id>{ prod.Id }, locId, ledger).get(prod.Id).Id;
        return [SELECT Id, Name, Location__c, Available_Quantity__c FROM TC_Inventory_Balance__c WHERE Id = :balanceId];
    }

    private static void requireAvailable(TC_Inventory_Balance__c b, Decimal qty, Product2 prod, TC_Warehouse__c w) {
        Decimal free = nz(b.Available_Quantity__c);
        if (free < qty) {
            throw new StockSyncException('Only ' + free.stripTrailingZeros().toPlainString() + ' of ' + prod.Name + ' at ' + w.Name
                + ' are free in Salesforce; cannot remove ' + qty.stripTrailingZeros().toPlainString()
                + '. Check open reservations, or send the matching receipt first.');
        }
    }

    private static Id offsetAccount(Id ledger, String reason) {
        String spec = OFFSET_SPEC.get(reason);
        if (spec == null) {
            throw new StockSyncException('Unknown stock move reason "' + reason + '". Use receipt, adjustment, scrap, production or transfer.');
        }
        Id gl = TC_AccountingContext.getGLDefault(ledger, spec);
        if (gl == null) {
            throw new StockSyncException('The ledger has no ' + spec.replace('_', ' ') + ' GL account default. Set it under GL Account Defaults.');
        }
        return gl;
    }

    private static String available(Id balanceId) {
        Decimal q = [SELECT Available_Quantity__c FROM TC_Inventory_Balance__c WHERE Id = :balanceId].Available_Quantity__c;
        return nz(q).stripTrailingZeros().toPlainString();
    }

    private static String text(Map<String, Object> p, String key) {
        Object v = p.get(key);
        if (v == null || v instanceof Boolean) {
            return null;
        }
        String s = String.valueOf(v).trim();
        return String.isBlank(s) ? null : s;
    }

    private static Decimal num(Map<String, Object> p, String key) {
        String s = text(p, key);
        if (s == null) {
            return null;
        }
        try {
            return Decimal.valueOf(s);
        } catch (Exception e) {
            throw new StockSyncException('Field ' + key + ' must be a number, got "' + s.left(40) + '".');
        }
    }

    private static Date dateOf(String s) {
        if (s == null) {
            return Date.today();
        }
        try {
            return Date.valueOf(s.left(10));
        } catch (Exception e) {
            throw new StockSyncException('Invalid date: ' + s.left(40));
        }
    }

    private static Decimal nz(Decimal d) {
        return d == null ? 0 : d;
    }
}