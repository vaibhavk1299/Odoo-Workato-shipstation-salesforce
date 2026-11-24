/**
 * product.upsert: keeps one Salesforce Product2 per sellable variant, whichever system sends it.
 * Workato's "[Product Sync] - Upsert Product to Salesforce" function calls it for Odoo and Shopify
 * with the same standard payload:
 *
 *   { eventId, sku, name, description, shortDescription, family, active, uom, price, currency, cost,
 *     storable, sourceProductId, sourceVariantId, displayUrl, imageUrl, onHand, available }
 *
 * Matching: the sending system's own variant ID first, then the SKU (Product Code, Product SKU or
 * SKU key), otherwise a new product. Name is never used to match.
 *
 * Field ownership: Odoo is the product master. Once a product carries an Odoo Product ID, only Odoo
 * changes its catalogue fields (name, SKU, description, family, active, unit, cost) and its price in
 * the corporate currency. Shopify always maintains its own IDs, storefront fields (URL, image, short
 * description) and its own price-book currency; on a product Odoo does not know, Shopify owns
 * everything, as the original Shopify recipe did.
 */
public without sharing class NFY_ProductSyncService {
    public class ProductSyncException extends Exception {}

    public class Outcome {
        public Id recordId;
        public String recordName;
        public String message;
    }

    public static final String ODOO = 'ODOO_SHOP';
    public static final String SHOPIFY = 'SHOPIFY';

    private static final Map<String, String> SOURCE_LABEL = new Map<String, String>{ ODOO => 'Odoo', SHOPIFY => 'Shopify' };

    public static Outcome upsertProduct(String source, Map<String, Object> p) {
        String src = source == null ? null : source.toUpperCase();
        if (!SOURCE_LABEL.containsKey(src)) {
            throw new ProductSyncException('Unknown source "' + source + '" for product.upsert. Products sync from ODOO_SHOP or SHOPIFY.');
        }
        String label = SOURCE_LABEL.get(src);
        String sku = text(p, 'sku');
        if (String.isBlank(sku)) {
            throw new ProductSyncException('The ' + label + ' product has no SKU. Set ' + (src == ODOO ? 'the Internal Reference' : 'the variant SKU')
                + ' and save it again.');
        }
        sku = sku.trim();
        if (sku.length() > 180) {
            throw new ProductSyncException('SKU "' + sku.left(40) + '..." is longer than the 180 characters Salesforce allows; it has no valid SKU.');
        }
        String name = text(p, 'name');
        if (String.isBlank(name)) {
            throw new ProductSyncException('The ' + label + ' product ' + sku + ' has no name.');
        }
        String sourceId = text(p, 'sourceVariantId');
        if (String.isBlank(sourceId)) {
            throw new ProductSyncException('The ' + label + ' product ' + sku + ' has no source ID (sourceVariantId).');
        }
        Decimal price = num(p, 'price');
        if (price != null && price < 0) {
            throw new ProductSyncException('The ' + label + ' product ' + sku + ' has no valid price (' + price + ').');
        }

        // ---- match: source ID, then SKU
        List<Product2> byId = src == ODOO
            ? [SELECT Id FROM Product2 WHERE NFY_Odoo_Product_Id__c = :sourceId LIMIT 2]
            : [SELECT Id FROM Product2 WHERE NFT_Shopify_Variant_Id__c = :sourceId LIMIT 2];
        List<Product2> bySku = [SELECT Id, Name, NFY_Odoo_Product_Id__c, NFT_Shopify_Variant_Id__c FROM Product2
                                WHERE ProductCode = :sku OR StockKeepingUnit = :sku OR NFT_SKU__c = :sku LIMIT 5];
        if (bySku.size() > 1) {
            List<String> names = new List<String>();
            for (Product2 x : bySku) {
                names.add('"' + x.Name + '"');
            }
            throw new ProductSyncException('Mapping conflict: SKU ' + sku + ' matches ' + bySku.size() + ' Salesforce products (' + String.join(names, ', ')
                + '). Merge or recode them, then sync again.');
        }
        Id idMatch = byId.isEmpty() ? null : byId[0].Id;
        Id skuMatch = bySku.isEmpty() ? null : bySku[0].Id;
        if (idMatch != null && skuMatch != null && idMatch != skuMatch) {
            throw new ProductSyncException('Mapping conflict: ' + label + ' product ' + sourceId + ' is linked to another Salesforce product, but SKU ' + sku
                + ' belongs to "' + bySku[0].Name + '". Fix the SKU in ' + label + ' or merge the products.');
        }
        // A product found only by SKU that is already linked to a different product in the same system is a duplicate
        // SKU at the source (two Odoo products with one Internal Reference): refuse it rather than take the product over.
        if (idMatch == null && skuMatch != null) {
            String linked = src == ODOO ? bySku[0].NFY_Odoo_Product_Id__c : bySku[0].NFT_Shopify_Variant_Id__c;
            if (String.isNotBlank(linked) && linked != sourceId) {
                // An archived duplicate is the fix the error asks for, not a new problem: record it and change nothing.
                if (p.get('active') != null && !bool(p, 'active')) {
                    Outcome skipped = new Outcome();
                    skipped.recordName = sku;
                    skipped.message = 'Archived ' + label + ' product ' + sourceId + ' shares SKU ' + sku + ' with "' + bySku[0].Name
                        + '" (' + label + ' product ' + linked + '), which is already in Salesforce. Nothing changed.';
                    return skipped;
                }
                throw new ProductSyncException('Mapping conflict: SKU ' + sku + ' already belongs to "' + bySku[0].Name + '", linked to ' + label
                    + ' product ' + linked + '. ' + label + ' product ' + sourceId + ' uses the same SKU. Give it its own SKU or archive the duplicate.');
            }
        }
        Id matchId = idMatch != null ? idMatch : skuMatch;
        Product2 existing = matchId == null ? null : load(matchId);
        Boolean created = existing == null;
        Boolean linking = !created && idMatch == null;

        // ---- ownership
        Boolean odooOwned = src == ODOO || (existing != null && existing.NFY_Odoo_Product_Id__c != null);
        Boolean master = src == ODOO || !odooOwned;

        Product2 rec = created ? new Product2() : new Product2(Id = existing.Id);
        List<String> changed = new List<String>();
        List<String> kept = new List<String>();

        if (src == ODOO) {
            put(rec, existing, 'NFY_Odoo_Product_Id__c', sourceId, null, changed);
        } else {
            put(rec, existing, 'NFT_Shopify_Variant_Id__c', sourceId, null, changed);
            put(rec, existing, 'NFT_Shopify_Product_Id__c', text(p, 'sourceProductId'), null, changed);
        }

        // SKU: set on create; a change at source only from the master
        if (created) {
            rec.ProductCode = sku;
            rec.StockKeepingUnit = sku;
        } else if (existing.ProductCode != sku) {
            if (!master) {
                throw new ProductSyncException('Mapping conflict: Shopify SKU ' + sku + ' differs from the Odoo-owned SKU ' + existing.ProductCode
                    + ' on "' + existing.Name + '". Fix the SKU in Shopify.');
            }
            put(rec, existing, 'ProductCode', sku, 'SKU', changed);
            put(rec, existing, 'StockKeepingUnit', sku, null, changed);
        }
        if (sku.length() <= 30 && (created || existing.NFT_SKU__c != sku)) {
            put(rec, existing, 'NFT_SKU__c', sku, null, changed);
        }

        // catalogue fields
        Map<String, Object> catalogue = new Map<String, Object>{
            'Name' => name.left(255),
            'Description' => trimTo(text(p, 'description'), 4000),
            'IsActive' => p.get('active') == null ? true : bool(p, 'active'),
            'QuantityUnitOfMeasure' => String.isBlank(text(p, 'uom')) ? 'Each' : text(p, 'uom')
        };
        if (String.isNotBlank(text(p, 'family'))) {
            catalogue.put('Family', text(p, 'family').left(255));
        }
        for (String f : new List<String>{ 'Name', 'Description', 'Family', 'IsActive', 'QuantityUnitOfMeasure' }) {
            if (!catalogue.containsKey(f)) {
                continue;
            }
            if (master) {
                put(rec, existing, f, catalogue.get(f), labelOf(f), changed);
            } else if (existing != null && existing.get(f) != catalogue.get(f)) {
                kept.add(labelOf(f));
            }
        }
        Decimal cost = num(p, 'cost');
        if (src == ODOO && cost != null && cost > 0) {
            put(rec, existing, 'TC_Unit_Cost__c', cost, 'cost', changed);
        }

        // storefront fields: Shopify's
        if (src == SHOPIFY) {
            put(rec, existing, 'DisplayUrl', trimTo(text(p, 'displayUrl'), 1000), 'store URL', changed);
            put(rec, existing, 'Image_URL__c', trimTo(text(p, 'imageUrl'), 255), 'image', changed);
            put(rec, existing, 'Short_Description__c', trimTo(text(p, 'shortDescription'), 102), null, changed);
            if (!odooOwned) {
                put(rec, existing, 'NFT_Total_On_Hand__c', num(p, 'onHand'), null, changed);
                put(rec, existing, 'NFT_Total_Available__c', num(p, 'available'), null, changed);
            }
        }

        // Odoo products belong to the Nfinity catalogue the order flow sells from, with its accounting defaults
        if (src == ODOO) {
            put(rec, existing, 'NFY_Demo__c', true, null, changed);
            if (bool(p, 'storable')) {
                applyAccountingDefaults(rec, existing, changed);
            }
        }
        // A product only Shopify knows is a physical, stocked good unless Shopify says otherwise (storable false),
        // so its orders reserve stock and ship instead of billing straight away. Odoo-owned products follow Odoo.
        if (src == SHOPIFY && !odooOwned && p.get('storable') != false) {
            applyAccountingDefaults(rec, existing, changed);
        }

        if (created) {
            insert rec;
        } else if (!changed.isEmpty()) {
            update rec;
        }

        // price in the standard price book, one entry per currency
        String priceNote = null;
        if (price != null) {
            String currencyCode = String.isBlank(text(p, 'currency')) ? corporateCurrency() : text(p, 'currency').toUpperCase();
            if (!activeCurrencies().contains(currencyCode)) {
                throw new ProductSyncException('Currency ' + currencyCode + ' is not active in Salesforce; the ' + label + ' product ' + sku
                    + ' has no valid price currency.');
            }
            if (src == SHOPIFY && odooOwned && currencyCode == corporateCurrency()) {
                kept.add('price ' + currencyCode);
            } else {
                priceNote = upsertPrice(rec.Id, currencyCode, price);
                if (priceNote != null) {
                    changed.add(priceNote);
                }
            }
        }

        changed = distinct(changed);
        kept = distinct(kept);
        Outcome o = new Outcome();
        o.recordId = rec.Id;
        o.recordName = name.left(120);
        String keptNote = kept.isEmpty() ? '' : ' Kept Odoo-owned ' + String.join(kept, ', ') + '.';
        if (created) {
            o.message = 'Created product "' + name + '" (SKU ' + sku + ') from ' + label + (priceNote == null ? '' : ', ' + priceNote) + '.';
        } else if (changed.isEmpty()) {
            o.message = 'Product "' + existing.Name + '" (SKU ' + sku + ') is already in Salesforce with these values.' + keptNote;
            o.recordName = existing.Name.left(120);
        } else {
            o.message = (linking ? 'Linked ' + label + ' product ' + sourceId + ' to existing product "' + existing.Name + '" by SKU ' + sku + ' and updated '
                : 'Updated product "' + (master ? name : existing.Name) + '" (SKU ' + sku + '): ') + String.join(changed, ', ') + '.' + keptNote;
            if (!master) {
                o.recordName = existing.Name.left(120);
            }
        }
        return o;
    }

    // ------------------------------------------------------------------ helpers

    private static Product2 load(Id productId) {
        return [
            SELECT Id, Name, ProductCode, StockKeepingUnit, NFT_SKU__c, Description, Family, IsActive, QuantityUnitOfMeasure, DisplayUrl,
                Image_URL__c, Short_Description__c, NFT_Shopify_Product_Id__c, NFT_Shopify_Variant_Id__c, NFY_Odoo_Product_Id__c,
                TC_Unit_Cost__c, TC_Inventory_Product__c, TC_Inventory_Type__c, TC_Inventory_GL_Account__c, TC_Expense_GL_Account__c,
                TC_Revenue_GL_Account__c, NFY_Demo__c, NFT_Total_On_Hand__c, NFT_Total_Available__c
            FROM Product2 WHERE Id = :productId
        ];
    }

    /** Sets a field when it is new or different; records a readable change. */
    private static void put(Product2 rec, Product2 existing, String field, Object value, String changeLabel, List<String> changed) {
        if (existing != null && same(existing.get(field), value)) {
            return;
        }
        if (existing == null && value == null) {
            return;
        }
        rec.put(field, value);
        if (existing != null) {
            changed.add(changeLabel == null ? labelOf(field) : changeLabel);
        }
    }

    /** Equality that ignores decimal scale (21.5 = 21.50) and treats blank text as empty. */
    private static Boolean same(Object a, Object b) {
        if (a instanceof Decimal && b instanceof Decimal) {
            return (Decimal) a == (Decimal) b;
        }
        if ((a == null || a instanceof String) && (b == null || b instanceof String)) {
            return String.isBlank((String) a) ? String.isBlank((String) b) : ((String) a).equals((String) b);
        }
        return a == b;
    }

    private static void applyAccountingDefaults(Product2 rec, Product2 existing, List<String> changed) {
        if (existing != null && existing.TC_Inventory_GL_Account__c != null) {
            return;
        }
        List<Product2> template = [
            SELECT TC_Inventory_GL_Account__c, TC_Expense_GL_Account__c, TC_Revenue_GL_Account__c, TC_Inventory_Type__c
            FROM Product2 WHERE NFY_Demo__c = true AND TC_Inventory_Product__c = true AND TC_Inventory_GL_Account__c != null
            ORDER BY CreatedDate LIMIT 1
        ];
        put(rec, existing, 'TC_Inventory_Product__c', true, 'inventory product', changed);
        if (template.isEmpty()) {
            return;
        }
        put(rec, existing, 'TC_Inventory_Type__c', template[0].TC_Inventory_Type__c, null, changed);
        put(rec, existing, 'TC_Inventory_GL_Account__c', template[0].TC_Inventory_GL_Account__c, 'GL accounts', changed);
        put(rec, existing, 'TC_Expense_GL_Account__c', template[0].TC_Expense_GL_Account__c, 'GL accounts', changed);
        put(rec, existing, 'TC_Revenue_GL_Account__c', template[0].TC_Revenue_GL_Account__c, 'GL accounts', changed);
    }

    private static List<String> distinct(List<String> items) {
        List<String> out = new List<String>();
        for (String s : items) {
            if (!out.contains(s)) {
                out.add(s);
            }
        }
        return out;
    }

    /** Creates or updates the product's standard price book entry in one currency. Returns a change note, or null when unchanged. */
    private static String upsertPrice(Id productId, String currencyCode, Decimal price) {
        Id book = NFY_Ref.pricebook();
        List<SObject> entries = Database.query(
            'SELECT Id, UnitPrice, IsActive FROM PricebookEntry WHERE Product2Id = :productId AND Pricebook2Id = :book AND CurrencyIsoCode = :currencyCode LIMIT 1');
        if (entries.isEmpty()) {
            SObject e = new PricebookEntry(Product2Id = productId, Pricebook2Id = book, UnitPrice = price, IsActive = true);
            e.put('CurrencyIsoCode', currencyCode);
            insert e;
            return 'price ' + currencyCode + ' ' + price.setScale(2);
        }
        PricebookEntry e = (PricebookEntry) entries[0];
        if (e.UnitPrice == price && e.IsActive) {
            return null;
        }
        update new PricebookEntry(Id = e.Id, UnitPrice = price, IsActive = true);
        return 'price ' + currencyCode + ' ' + e.UnitPrice.setScale(2) + ' → ' + price.setScale(2);
    }

    private static String corporate;
    private static Set<String> active;

    private static String corporateCurrency() {
        if (corporate == null) {
            loadCurrencies();
        }
        return corporate;
    }

    private static Set<String> activeCurrencies() {
        if (active == null) {
            loadCurrencies();
        }
        return active;
    }

    private static void loadCurrencies() {
        active = new Set<String>();
        corporate = UserInfo.getDefaultCurrency();
        if (!Schema.getGlobalDescribe().containsKey('currencytype')) {
            active.add(corporate);
            return;
        }
        for (SObject c : Database.query('SELECT IsoCode, IsCorporate FROM CurrencyType WHERE IsActive = true')) {
            active.add((String) c.get('IsoCode'));
            if ((Boolean) c.get('IsCorporate')) {
                corporate = (String) c.get('IsoCode');
            }
        }
    }

    private static final Map<String, String> LABELS = new Map<String, String>{
        'Name' => 'name', 'Description' => 'description', 'Family' => 'family', 'IsActive' => 'active', 'QuantityUnitOfMeasure' => 'unit',
        'NFY_Odoo_Product_Id__c' => 'Odoo product ID', 'NFT_Shopify_Variant_Id__c' => 'Shopify variant ID', 'NFT_Shopify_Product_Id__c' => 'Shopify product ID',
        'StockKeepingUnit' => 'SKU', 'NFT_SKU__c' => 'SKU key', 'Short_Description__c' => 'short description', 'NFT_Total_On_Hand__c' => 'Shopify on hand',
        'NFT_Total_Available__c' => 'Shopify available', 'NFY_Demo__c' => 'Nfinity catalogue', 'TC_Inventory_Type__c' => 'inventory type'
    };

    private static String labelOf(String field) {
        return LABELS.containsKey(field) ? LABELS.get(field) : field;
    }

    private static String text(Map<String, Object> p, String key) {
        Object v = p.get(key);
        if (v == null) {
            return null;
        }
        String s = String.valueOf(v).trim();
        return String.isBlank(s) || s == 'false' && key != 'active' ? null : s;
    }

    private static String trimTo(String s, Integer max) {
        return s == null ? null : s.left(max);
    }

    private static Decimal num(Map<String, Object> p, String key) {
        Object v = p.get(key);
        if (v == null || v instanceof Boolean || String.isBlank(String.valueOf(v))) {
            return null;
        }
        try {
            return Decimal.valueOf(String.valueOf(v));
        } catch (Exception e) {
            throw new ProductSyncException('Field ' + key + ' must be a number, got "' + String.valueOf(v).left(40) + '"; the product has no valid ' + key + '.');
        }
    }

    private static Boolean bool(Map<String, Object> p, String key) {
        Object v = p.get(key);
        if (v instanceof Boolean) {
            return (Boolean) v;
        }
        return v != null && String.valueOf(v).trim().toLowerCase() == 'true';
    }
}