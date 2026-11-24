/**
 * Cached reference data for the Nfinity integration: systems, flows, warehouses, locations,
 * GL accounts, demo products and the standard price book. Loaded once per transaction.
 */
public without sharing class NFY_Ref {
    public class RefException extends Exception {}

    private static Map<String, NFY_Integration_System__c> systems;
    private static Map<String, NFY_Integration_Flow__c> flows;
    private static Map<String, TC_Warehouse__c> warehouses;
    private static Map<String, TC_Location__c> locations;
    private static Map<String, Id> glByNumber;
    private static Map<String, Product2> products;
    private static Map<Id, Id> priceEntries;
    private static Id pricebookId;
    private static Map<String, Id> payers;

    /** Channel to revenue GL account number. MCF is a Shopify sale fulfilled by Amazon. */
    public static final Map<String, String> CHANNEL_GL = new Map<String, String>{
        'Shopify .com' => '4001', 'Shopify POS' => '4001', 'Amazon MCF' => '4001',
        'Amazon FBA' => '4002', 'Amazon FBM' => '4002', 'Buy with Prime' => '4002',
        'Wholesale / Team' => '4003', 'Global-e' => '4004', 'EU Webstore' => '4005'
    };

    /** Who pays the billing: marketplaces settle in bulk, B2B customers pay their own invoices. */
    public static final Map<String, String> CHANNEL_PAYER = new Map<String, String>{
        'Shopify .com' => 'PAYER-SHOPIFY', 'Shopify POS' => 'PAYER-SHOPIFY', 'Amazon MCF' => 'PAYER-SHOPIFY', 'EU Webstore' => 'PAYER-SHOPIFY',
        'Amazon FBA' => 'PAYER-AMAZON', 'Amazon FBM' => 'PAYER-AMAZON', 'Buy with Prime' => 'PAYER-AMAZON',
        'Global-e' => 'PAYER-GLOBALE'
    };

    public static final String FREIGHT_SKU = 'NFY-FREIGHT';
    public static final String MAIN = 'MAIN';

    public static void reset() {
        systems = null;
        flows = null;
        warehouses = null;
        locations = null;
        glByNumber = null;
        products = null;
        priceEntries = null;
        pricebookId = null;
        payers = null;
    }

    public static NFY_Integration_System__c system(String code) {
        if (systems == null) {
            systems = new Map<String, NFY_Integration_System__c>();
            for (NFY_Integration_System__c s : [SELECT Id, Name, Code__c, Category__c, Status__c FROM NFY_Integration_System__c]) {
                systems.put(s.Code__c, s);
            }
        }
        return code == null ? null : systems.get(code.toUpperCase());
    }

    /** Flow codes are SYSTEM-ENTITY, e.g. SHOPIFY-ORDER. */
    public static NFY_Integration_Flow__c flow(String systemCode, String entity) {
        if (flows == null) {
            flows = new Map<String, NFY_Integration_Flow__c>();
            for (NFY_Integration_Flow__c f : [SELECT Id, Code__c, Name FROM NFY_Integration_Flow__c]) {
                flows.put(f.Code__c, f);
            }
        }
        if (systemCode == null || entity == null) {
            return null;
        }
        return flows.get(systemCode.toUpperCase() + '-' + entity.toUpperCase().replace(' ', '_'));
    }

    public static TC_Warehouse__c warehouse(String code) {
        if (warehouses == null) {
            warehouses = new Map<String, TC_Warehouse__c>();
            for (TC_Warehouse__c w : [SELECT Id, Name, NFY_Code__c, NFY_Type__c, NFY_Region__c, NFY_Currency__c, NFY_Physical__c, NFY_System__c
                                      FROM TC_Warehouse__c WHERE NFY_Code__c != null]) {
                warehouses.put(w.NFY_Code__c, w);
            }
        }
        TC_Warehouse__c w = code == null ? null : warehouses.get(code.toUpperCase());
        if (w == null) {
            throw new RefException('Unknown warehouse code "' + code + '". Add it under Warehouses or onboard it with the 3PL template.');
        }
        return w;
    }

    public static Boolean hasWarehouse(String code) {
        try {
            warehouse(code);
            return true;
        } catch (RefException e) {
            return false;
        }
    }

    public static List<TC_Warehouse__c> allWarehouses() {
        warehouse(MAIN);
        return warehouses.values();
    }

    /** Location codes are WAREHOUSE-AVL or WAREHOUSE-TRANSIT. */
    public static TC_Location__c location(String warehouseCode, String kind) {
        if (locations == null) {
            locations = new Map<String, TC_Location__c>();
            for (TC_Location__c l : [SELECT Id, Name, NFY_Code__c, Warehouse__c FROM TC_Location__c WHERE NFY_Code__c != null]) {
                locations.put(l.NFY_Code__c, l);
            }
        }
        String key = warehouseCode.toUpperCase() + '-' + kind;
        TC_Location__c l = locations.get(key);
        if (l == null) {
            throw new RefException('Warehouse ' + warehouseCode + ' has no ' + (kind == 'AVL' ? 'Available' : 'In Transit') + ' location.');
        }
        return l;
    }

    public static Id gl(String accountNumber) {
        if (glByNumber == null) {
            glByNumber = new Map<String, Id>();
            for (TC_GL_Account__c g : [SELECT Id, Name FROM TC_GL_Account__c]) {
                glByNumber.put(g.Name.substringBefore('-'), g.Id);
            }
        }
        Id result = glByNumber.get(accountNumber);
        if (result == null) {
            throw new RefException('GL account ' + accountNumber + ' is missing. Run the Nfinity demo setup.');
        }
        return result;
    }

    public static Id revenueGl(String channel) {
        return gl(CHANNEL_GL.containsKey(channel) ? CHANNEL_GL.get(channel) : '4000');
    }

    public static Product2 product(String sku) {
        if (products == null) {
            products = new Map<String, Product2>();
            for (Product2 p : [SELECT Id, Name, ProductCode, TC_Inventory_Product__c, TC_Moving_Average_Cost__c, TC_Unit_Cost__c,
                                   TC_Expense_GL_Account__c, TC_Inventory_GL_Account__c, NFY_Style__c, NFY_Size__c
                               FROM Product2 WHERE NFY_Demo__c = true]) {
                products.put(p.ProductCode, p);
            }
        }
        Product2 p = sku == null ? null : products.get(sku);
        if (p == null && sku != null) {
            // A product synced from a sales channel (e.g. a Shopify-only product) is outside the Nfinity catalogue flag;
            // find it by its SKU, preferring the catalogue product when two share it.
            for (Product2 x : [SELECT Id, Name, ProductCode, TC_Inventory_Product__c, TC_Moving_Average_Cost__c, TC_Unit_Cost__c,
                                    TC_Expense_GL_Account__c, TC_Inventory_GL_Account__c, NFY_Style__c, NFY_Size__c
                                FROM Product2 WHERE IsActive = true AND (ProductCode = :sku OR StockKeepingUnit = :sku)
                                ORDER BY NFY_Demo__c DESC, CreatedDate LIMIT 1]) {
                p = x;
                products.put(sku, x);
            }
        }
        if (p == null) {
            throw new RefException('Unknown SKU "' + sku + '". Add the product in Salesforce or fix the SKU mapping in the recipe.');
        }
        return p;
    }

    private static String corporateIso;
    private static Map<String, Decimal> rates;

    /** The org's corporate currency (the user's currency when multi-currency is off). */
    public static String corporateCurrency() {
        loadRates();
        return corporateIso;
    }

    /** Factor that turns an amount in the given currency into the corporate currency (1 when blank or unknown to the org). */
    public static Decimal toCorporateRate(String isoCode) {
        loadRates();
        if (String.isBlank(isoCode) || isoCode.toUpperCase() == corporateIso) {
            return 1;
        }
        Decimal r = rates.get(isoCode.toUpperCase());
        if (r == null || r == 0) {
            throw new RefException('Currency ' + isoCode + ' is not active in Salesforce, so the order cannot be converted.');
        }
        return 1 / r;
    }

    private static void loadRates() {
        if (rates != null) {
            return;
        }
        rates = new Map<String, Decimal>();
        corporateIso = UserInfo.getDefaultCurrency();
        if (!Schema.getGlobalDescribe().containsKey('currencytype')) {
            return;
        }
        for (SObject c : Database.query('SELECT IsoCode, ConversionRate, IsCorporate FROM CurrencyType WHERE IsActive = true')) {
            rates.put((String) c.get('IsoCode'), (Decimal) c.get('ConversionRate'));
            if ((Boolean) c.get('IsCorporate')) {
                corporateIso = (String) c.get('IsoCode');
            }
        }
    }

    /**
     * The product's standard price book entry in the corporate currency. When it has none (a product priced only in a
     * channel currency), one is created at the given corporate-currency price so the order can be recorded.
     */
    public static Id priceEntry(Id productId, Decimal corporatePrice) {
        Id e = priceEntry(productId);
        if (e != null || productId == null) {
            return e;
        }
        Boolean multi = Schema.getGlobalDescribe().containsKey('currencytype');
        String iso = corporateCurrency();
        Id book = pricebook();
        String q = 'SELECT Id FROM PricebookEntry WHERE Pricebook2Id = :book AND Product2Id = :productId' + (multi ? ' AND CurrencyIsoCode = :iso' : '') + ' LIMIT 1';
        List<SObject> found = Database.query(q);
        if (!found.isEmpty()) {
            e = found[0].Id;
        } else if (corporatePrice != null) {
            SObject pe = new PricebookEntry(Pricebook2Id = book, Product2Id = productId, UnitPrice = corporatePrice, IsActive = true);
            if (multi) {
                pe.put('CurrencyIsoCode', iso);
            }
            insert pe;
            e = pe.Id;
        }
        if (e != null) {
            priceEntries.put(productId, e);
        }
        return e;
    }

    public static List<Product2> allProducts() {
        product(FREIGHT_SKU);
        return products.values();
    }

    public static Id pricebook() {
        if (pricebookId == null) {
            pricebookId = Test.isRunningTest() ? Test.getStandardPricebookId() : [SELECT Id FROM Pricebook2 WHERE IsStandard = true LIMIT 1].Id;
        }
        return pricebookId;
    }

    public static Id priceEntry(Id productId) {
        if (priceEntries == null) {
            priceEntries = new Map<Id, Id>();
            // Corporate-currency entries only: a channel-currency entry (INR from Shopify) cannot be used on a corporate-currency Order.
            Id book = pricebook();
            String iso = corporateCurrency();
            Boolean multi = Schema.getGlobalDescribe().containsKey('currencytype');
            for (SObject e : Database.query('SELECT Id, Product2Id FROM PricebookEntry WHERE Pricebook2Id = :book AND Product2.NFY_Demo__c = true'
                    + (multi ? ' AND CurrencyIsoCode = :iso' : ''))) {
                priceEntries.put((Id) e.get('Product2Id'), e.Id);
            }
        }
        return priceEntries.get(productId);
    }

    public static Id payer(String channel, Id customerId) {
        String code = CHANNEL_PAYER.get(channel);
        if (code == null) {
            return customerId;
        }
        if (payers == null) {
            payers = new Map<String, Id>();
            for (Account a : [SELECT Id, NFY_External_Customer_Id__c FROM Account WHERE NFY_External_Customer_Id__c LIKE 'PAYER-%']) {
                payers.put(a.NFY_External_Customer_Id__c, a.Id);
            }
        }
        return payers.containsKey(code) ? payers.get(code) : customerId;
    }
}