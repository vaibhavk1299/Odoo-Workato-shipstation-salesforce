/**
 * Seeds and resets the Nfinity demo. Everything is invented, shaped on Nfinity's org as seen on
 * 20 Oct 2026 (warehouse names, one product per size, #SPFY order numbers, channel mix).
 *
 *   NFY_DemoData.seedReference();             GL accounts, systems, flows, warehouses, payers, products
 *   NFY_DemoData.seedStock();                 opening stock (posted against 3900 Opening Balances)
 *   Database.executeBatch(new NFY_HistoryBatch(0, 120, 2), 1);   60 days of orders through the integration service
 *   NFY_DemoData.seedOpenItems();             containers, FBA inbound, settlements, returns, sync-log history
 *   Database.executeBatch(new NFY_ResetBatch(null), 1);          removes demo transactions (null = everything)
 */
public without sharing class NFY_DemoData {

    public static final Date OPENING_DATE = Date.newInstance(2026, 9, 1);
    public static final Integer HISTORY_DAYS = 60;

    // ------------------------------------------------------------------ reference data

    public static void seedReference() {
        seedGlAccounts();
        seedSystemsAndFlows();
        seedWarehouses();
        seedAccounts();
        seedProducts();
        NFY_Ref.reset();
    }

    private static void seedGlAccounts() {
        List<List<String>> defs = new List<List<String>>{
            new List<String>{ '3900-Opening Balances', 'Balance Sheet', 'Owners Equity' },
            new List<String>{ '4001-Sales - Shopify', 'Revenue', 'Revenue' },new List<String>{ '4002-Sales - Amazon', 'Revenue', 'Revenue' },
            new List<String>{ '4003-Sales - Wholesale & Team', 'Revenue', 'Revenue' }, new List<String>{ '4004-Sales - Global-e', 'Revenue', 'Revenue' },
            new List<String>{ '4005-Sales - EU Webstore', 'Revenue', 'Revenue' }, new List<String>{ '4020-Freight Revenue', 'Revenue', 'Revenue' },
            new List<String>{ '4090-Sales Returns & Refunds', 'Revenue', 'Revenue' }, new List<String>{ '6100-Marketplace Fees', 'Expense', 'Operating Expenses' },
            new List<String>{ '6110-FBA Fulfillment Fees', 'Expense', 'Operating Expenses' }, new List<String>{ '6120-Payment Processing Fees', 'Expense', 'Operating Expenses' }
        };
        Set<String> existing = new Set<String>();
        for (TC_GL_Account__c g : [SELECT Name FROM TC_GL_Account__c]) {
            existing.add(g.Name);
        }
        List<TC_GL_Account__c> toInsert = new List<TC_GL_Account__c>();
        for (List<String> d : defs) {
            if (!existing.contains(d[0])) {
                toInsert.add(new TC_GL_Account__c(Name = d[0], Type__c = d[1], Sub_Type_1__c = d[2], Active__c = true, Bank__c = false,
                    Mileage_Account__c = false, Used_in_Expense_Reports__c = false, Control_Account__c = false, Description__c = 'Nfinity demo'));
            }
        }
        insert toInsert;
    }

    private static void seedSystemsAndFlows() {
        List<NFY_Integration_System__c> systems = new List<NFY_Integration_System__c>{
            sys('SHOPIFY', 'Shopify', 'Sales channel', 'Connected', 'Webhook', 1, 'US', 'Nfinity Cheer store: .com, Shop app, Meta shop and POS. Decides the ship-from with ranked locations.'),
            sys('AMAZON', 'Amazon Seller Central', 'Sales channel', 'Connected', 'Polling', 2, 'US', 'FBA, FBM, Buy with Prime and MCF. Orders, FBA inbound, inventory, returns and settlement reports through SP-API.'),
            sys('GLOBALE', 'Global-e', 'Sales channel', 'Connected', 'Daily batch', 3, 'Global', 'International checkout, merchant of record. Orders ship from Nfinity Main.'),
            sys('SHIPMONK', 'ShipMonk', '3PL / WMS', 'Connected', 'Webhook', 4, 'US', '3PL: PA1 Pittston, NV3 Las Vegas, CA. Pulls assigned orders, returns tracking and daily stock.'),
            sys('SHIPSTATION', 'ShipStation', 'Label system', 'Degraded', 'Polling', 5, 'US', 'Labels for Nfinity Main. Three stores: Shopify, Amazon, Salesforce.'),
            sys('ODOO', 'Odoo (NL 3PL)', '3PL / WMS', 'Planned', 'Webhook', 6, 'EU', 'Netherlands 3PL for UK/EU, go-live Q1 2027. Onboarded from the 3PL template.'),
            sys('WORKATO', 'Workato', 'Integration hub', 'Connected', 'Webhook', 7, 'Global', 'Integration hub. Every recipe calls the Nfinity Integration API and writes a sync log.'),
            sys('SALESFORCE', 'Salesforce + TC Accounting', 'CRM', 'Connected', 'Webhook', 8, 'US', 'B2B orders entered by reps, receiving at Nfinity Main, decorator confirmations.')
        };
        upsert systems NFY_Integration_System__c.Code__c;
        Map<String, Id> ids = new Map<String, Id>();
        for (NFY_Integration_System__c s : systems) {
            ids.put(s.Code__c, s.Id);
        }
        List<List<String>> defs = new List<List<String>>{
            // system, entity, direction, mode, schedule, recipe, version
            new List<String>{ 'SHOPIFY', 'Order', 'Into Salesforce', 'Webhook', 'Real-time', '[Shopify to SFDC] - Orders Synchronization', 'v3.2' },
            new List<String>{ 'SHOPIFY', 'Inventory', 'Out of Salesforce', 'Polling', 'Every 15 min', '[SFDC to Shopify] - Available Stock by Location', 'v2.0' },
            new List<String>{ 'SHOPIFY', 'Return', 'Into Salesforce', 'Webhook', 'Real-time', '[ReturnGO to SFDC] - Returns and Exchanges', 'v1.4' },
            new List<String>{ 'SHOPIFY', 'Settlement', 'Into Salesforce', 'Daily batch', 'Daily 03:00', '[Shopify to SFDC] - Payouts', 'v1.1' },
            new List<String>{ 'AMAZON', 'Order', 'Into Salesforce', 'Polling', 'Every 15 min', '[Amazon to SFDC] - Orders (FBA / FBM)', 'v2.3' },
            new List<String>{ 'AMAZON', 'Shipment', 'Into Salesforce', 'Polling', 'Every 15 min', '[Amazon to SFDC] - FBA Shipments', 'v2.1' },
            new List<String>{ 'AMAZON', 'Inbound', 'Two-way', 'Polling', 'Every 30 min', '[Amazon to SFDC] - FBA Inbound Shipments', 'v1.0' },
            new List<String>{ 'AMAZON', 'Inventory', 'Into Salesforce', 'Polling', 'Every 4 hours', '[Amazon to SFDC] - FBA Inventory', 'v1.0' },
            new List<String>{ 'AMAZON', 'Return', 'Into Salesforce', 'Polling', 'Daily 05:00', '[Amazon to SFDC] - Customer Returns', 'v1.0' },
            new List<String>{ 'AMAZON', 'Settlement', 'Into Salesforce', 'Daily batch', 'Daily 06:00', '[Amazon to SFDC] - Settlement Reports', 'v1.0' },
            new List<String>{ 'GLOBALE', 'Order', 'Into Salesforce', 'Daily batch', 'Daily 02:00', '[Global-e to SFDC] - International Orders', 'v1.2' },
            new List<String>{ 'SHIPMONK', 'Order', 'Out of Salesforce', 'Webhook', 'Real-time', '[SFDC to ShipMonk] - Assigned Orders', 'v1.6' },
            new List<String>{ 'SHIPMONK', 'Shipment', 'Into Salesforce', 'Webhook', 'Real-time', '[ShipMonk to SFDC] - Shipments + Tracking', 'v2.0' },
            new List<String>{ 'SHIPMONK', 'Inventory', 'Into Salesforce', 'Polling', 'Every 4 hours', '[ShipMonk to SFDC] - Stock Snapshot', 'v1.3' },
            new List<String>{ 'SHIPMONK', 'Inbound', 'Into Salesforce', 'Webhook', 'Real-time', '[ShipMonk to SFDC] - ASN Receipts', 'v1.0' },
            new List<String>{ 'SHIPMONK', 'PO Receipt', 'Into Salesforce', 'Webhook', 'Real-time', '[ShipMonk to SFDC] - PO Receipts', 'v1.0' },
            new List<String>{ 'SHIPSTATION', 'Shipment', 'Into Salesforce', 'Polling', 'Every 30 min', '[ShipStation to SFDC] - Shipments Synchronization (Salesforce Store)', 'v2.7' },
            new List<String>{ 'SALESFORCE', 'Order', 'Into Salesforce', 'Manual', 'On entry', 'B2B sales orders (reps)', 'v1.0' },
            new List<String>{ 'SALESFORCE', 'Shipment', 'Into Salesforce', 'Manual', 'On entry', 'Decorator ship confirmations', 'v1.0' },
            new List<String>{ 'SALESFORCE', 'PO Receipt', 'Into Salesforce', 'Manual', 'On entry', 'Receiving at Nfinity Main', 'v1.0' },
            new List<String>{ 'SALESFORCE', 'Inbound', 'Into Salesforce', 'Manual', 'On entry', 'Container tracking (forwarder updates)', 'v1.0' }
        };
        List<NFY_Integration_Flow__c> flows = new List<NFY_Integration_Flow__c>();
        for (List<String> d : defs) {
            flows.add(new NFY_Integration_Flow__c(Name = d[5].left(80), Code__c = d[0] + '-' + d[1].toUpperCase().replace(' ', '_'), System__c = ids.get(d[0]),
                Entity__c = d[1], Direction__c = d[2], Mode__c = d[3], Schedule__c = d[4], Workato_Recipe__c = d[5], Version__c = d[6],
                Environment__c = 'Production', Active__c = true, Owner__c = 'Integration team',
                Last_Changed__c = Date.newInstance(2026, 10, 1).addDays(-Math.mod(d[5].length() * 7, 60)), Change_Note__c = 'Baseline from audit catalogue.'));
        }
        upsert flows NFY_Integration_Flow__c.Code__c;
    }

    private static NFY_Integration_System__c sys(String code, String name, String category, String status, String mode, Integer sortOrder, String region, String description) {
        return new NFY_Integration_System__c(Code__c = code, Name = name, Category__c = category, Status__c = status, Mode__c = mode,
            Sort_Order__c = sortOrder, Region__c = region, Description__c = description, Owner_Team__c = 'Nfinity ops');
    }

    private static void seedWarehouses() {
        Map<String, Id> sysIds = new Map<String, Id>();
        for (NFY_Integration_System__c s : [SELECT Id, Code__c FROM NFY_Integration_System__c]) {
            sysIds.put(s.Code__c, s.Id);
        }
        // code, name, type, rank, system, city, address, transit?
        List<List<String>> defs = new List<List<String>>{
            new List<String>{ 'SM-PA1', 'ShipMonk Pennsylvania (PA1)', '3PL', '1', 'SHIPMONK', 'Pittston, PA', 'ShipMonk PA1, Pittston PA', 'Y' },
            new List<String>{ 'SM-NV3', 'ShipMonk Nevada 3', '3PL', '1', 'SHIPMONK', 'Las Vegas, NV', 'ShipMonk NV3, Las Vegas NV', 'Y' },
            new List<String>{ 'MAIN', 'Nfinity Main Warehouse', 'In-house warehouse', '2', 'SHIPSTATION', 'Atlanta, GA', '1440 Dutch Valley Place NE, Atlanta GA', 'Y' },
            new List<String>{ 'RETAIL', 'Nfinity Retail', 'Retail store', '3', 'SHOPIFY', 'Atlanta, GA', 'Nfinity Retail, Atlanta GA', 'N' },
            new List<String>{ 'SM-CA', 'ShipMonk_CA', '3PL', '4', 'SHIPMONK', 'Ontario, CA', 'ShipMonk CA, Ontario CA', 'Y' },
            new List<String>{ 'FBA-US', 'Amazon_FBA US', 'Amazon FBA', '5', 'AMAZON', 'Amazon network', 'Amazon fulfillment network (US)', 'Y' },
            new List<String>{ 'PRINTFUL', 'Printful', 'Print on demand', '6', 'SALESFORCE', 'Charlotte, NC', 'Printful (print on demand)', 'N' },
            new List<String>{ 'CUSTOMWEAR', 'Customwear Location', 'Decorator', '', 'SALESFORCE', 'Atlanta, GA', 'Customwear decorator, Atlanta GA', 'N' },
            new List<String>{ 'FACTORY', 'Direct from Factory', 'Factory', '', 'SALESFORCE', 'Xiamen, CN', 'Factory direct ship, Xiamen', 'N' },
            new List<String>{ 'FIELD', 'Field & Events', 'Field & events', '', 'SHOPIFY', 'Various', 'Sales reps and event pop-ups', 'N' }
        };
        List<TC_Warehouse__c> ws = new List<TC_Warehouse__c>();
        for (List<String> d : defs) {
            ws.add(new TC_Warehouse__c(NFY_Code__c = d[0], Name = d[1], NFY_Type__c = d[2], NFY_Routing_Rank__c = String.isBlank(d[3]) ? null : Decimal.valueOf(d[3]),
                NFY_System__c = sysIds.get(d[4]), NFY_City__c = d[5], Address__c = d[6], NFY_Region__c = 'US', NFY_Currency__c = 'USD',
                NFY_Physical__c = d[0] != 'FIELD', Active__c = true));
        }
        upsert ws TC_Warehouse__c.NFY_Code__c;
        Map<String, Id> wIds = new Map<String, Id>();
        for (TC_Warehouse__c w : ws) {
            wIds.put(w.NFY_Code__c, w.Id);
        }
        List<TC_Location__c> locs = new List<TC_Location__c>();
        for (List<String> d : defs) {
            if (d[0] == 'FIELD') {
                continue;
            }
            locs.add(new TC_Location__c(Name = d[1], Warehouse__c = wIds.get(d[0]), NFY_Code__c = d[0] + '-AVL', NFY_Location_Type__c = 'Available', NFY_Address__c = d[6]));
            if (d[7] == 'Y') {
                locs.add(new TC_Location__c(Name = d[1] + ' · In Transit', Warehouse__c = wIds.get(d[0]), NFY_Code__c = d[0] + '-TRANSIT', NFY_Location_Type__c = 'In Transit', NFY_Active_In_Shopify__c = false));
            }
        }
        // Sales-attribution locations as they appear in Shopify; not sellable stock.
        List<List<String>> field = new List<List<String>>{
            new List<String>{ 'SARAH', 'Sarah', 'Y' }, new List<String>{ 'REP2', 'Sales Rep 2', 'Y' }, new List<String>{ 'REP5', 'Sales Rep 5', 'Y' },
            new List<String>{ 'NCA2026', 'NCA 2026', 'Y' }, new List<String>{ 'PEACH2026', 'Peach Classic 2026', 'Y' }, new List<String>{ 'FINALS2026', 'The Finals 2026', 'Y' },
            new List<String>{ 'ACC2024', 'ACC Tampa 2024', 'Y' }, new List<String>{ 'CALI2024', 'Cali Showcase 2024', 'Y' }, new List<String>{ 'BIGSKILLS2026', 'Big Skills / GenNext 2026', 'N' }
        };
        for (List<String> f : field) {
            locs.add(new TC_Location__c(Name = f[1], Warehouse__c = wIds.get('FIELD'), NFY_Code__c = 'FIELD-' + f[0], NFY_Location_Type__c = 'Field / Event',
                NFY_Active_In_Shopify__c = f[2] == 'Y'));
        }
        upsert locs TC_Location__c.NFY_Code__c;
    }

    private static void seedAccounts() {
        List<Account> accts = new List<Account>{
            new Account(Name = 'Shopify Payments', NFY_External_Customer_Id__c = 'PAYER-SHOPIFY', NFY_Customer_Type__c = 'Marketplace buyer', TC_Accounting_Type__c = 'Customer', NFY_Demo__c = true),
            new Account(Name = 'Amazon Marketplace (Seller Central)', NFY_External_Customer_Id__c = 'PAYER-AMAZON', NFY_Customer_Type__c = 'Marketplace buyer', TC_Accounting_Type__c = 'Customer', NFY_Demo__c = true),
            new Account(Name = 'Global-e (Merchant of Record)', NFY_External_Customer_Id__c = 'PAYER-GLOBALE', NFY_Customer_Type__c = 'Marketplace buyer', TC_Accounting_Type__c = 'Customer', NFY_Demo__c = true),
            new Account(Name = 'Xiamen Stride Footwear Co.', NFY_External_Customer_Id__c = 'VENDOR-FACTORY', NFY_Customer_Type__c = 'Vendor', TC_Accounting_Type__c = 'Vendor', NFY_Demo__c = true,
                BillingCity = 'Xiamen', BillingCountry = 'CN')
        };
        upsert accts Account.NFY_External_Customer_Id__c;
    }

    public class ProductDef {
        public String sku;
        public String name;
        public String family;
        public String style;
        public String size;
        public Decimal price;
        public Decimal cost;
        ProductDef(String sku, String name, String family, String style, String size, Decimal price, Decimal cost) {
            this.sku = sku;
            this.name = name;
            this.family = family;
            this.style = style;
            this.size = size;
            this.price = price;
            this.cost = cost;
        }
    }

    public static List<ProductDef> catalogue() {
        return new List<ProductDef>{
            new ProductDef('840386208701', 'Nfinity Evolution 7', 'Footwear', 'Evolution', '7', 99.99, 19.30),
            new ProductDef('840386208702', 'Nfinity Evolution 8', 'Footwear', 'Evolution', '8', 99.99, 19.30),
            new ProductDef('840386208703', 'Nfinity Evolution 9', 'Footwear', 'Evolution', '9', 99.99, 19.30),
            new ProductDef('840386208704', 'Nfinity Evolution 10', 'Footwear', 'Evolution', '10', 99.99, 19.30),
            new ProductDef('840386211201', 'Nfinity Vengeance 7', 'Footwear', 'Vengeance', '7', 129.99, 24.10),
            new ProductDef('840386211202', 'Nfinity Vengeance 8', 'Footwear', 'Vengeance', '8', 129.99, 24.10),
            new ProductDef('840386211203', 'Nfinity Vengeance 9', 'Footwear', 'Vengeance', '9', 129.99, 24.10),
            new ProductDef('840386215465', 'Nfinity Flyte - Adult 6.5', 'Footwear', 'Flyte', 'Adult 6.5', 144.99, 27.80),
            new ProductDef('840386215475', 'Nfinity Flyte - Adult 7.5', 'Footwear', 'Flyte', 'Adult 7.5', 144.99, 27.80),
            new ProductDef('840386215485', 'Nfinity Flyte - Adult 8.5', 'Footwear', 'Flyte', 'Adult 8.5', 144.99, 27.80),
            new ProductDef('840386215403', 'Nfinity Flyte - Youth 3', 'Footwear', 'Flyte', 'Youth 3', 119.99, 22.40),
            new ProductDef('840386215404', 'Nfinity Flyte - Youth 4', 'Footwear', 'Flyte', 'Youth 4', 119.99, 22.40),
            new ProductDef('840386219108', 'Nfinity Rival 8', 'Footwear', 'Rival', '8', 89.99, 17.60),
            new ProductDef('840386219109', 'Nfinity Rival 9', 'Footwear', 'Rival', '9', 89.99, 17.60),
            new ProductDef('840386230011', 'Nfinity Royal Blue Makeup Bag', 'Accessories', 'Royal Blue', null, 39.99, 6.20),
            new ProductDef('840386230022', 'Nfinity Cheer Backpack - Black', 'Accessories', 'Backpack', null, 64.99, 11.90),
            new ProductDef('840386230033', 'Nfinity Team Warm-Up Jacket - M', 'Apparel', 'Warm-Up Jacket', 'M', 79.99, 15.50),
            new ProductDef('840386230034', 'Nfinity Team Warm-Up Jacket - L', 'Apparel', 'Warm-Up Jacket', 'L', 79.99, 15.50),
            new ProductDef('840386230045', 'Nfinity Bow - Royal Blue', 'Accessories', 'Bow', null, 19.99, 2.40)
        };
    }

    private static void seedProducts() {
        Id vendor = [SELECT Id FROM Account WHERE NFY_External_Customer_Id__c = 'VENDOR-FACTORY'].Id;
        Id inv = NFY_Ref.gl('1500');
        Id cogs = NFY_Ref.gl('5000');
        Id rev = NFY_Ref.gl('4000');
        Map<String, Product2> existing = new Map<String, Product2>();
        for (Product2 p : [SELECT Id, ProductCode FROM Product2 WHERE NFY_Demo__c = true]) {
            existing.put(p.ProductCode, p);
        }
        List<Product2> prods = new List<Product2>();
        Map<String, Decimal> prices = new Map<String, Decimal>();
        for (ProductDef d : catalogue()) {
            Product2 p = existing.containsKey(d.sku) ? existing.get(d.sku) : new Product2();
            p.Name = d.name;
            p.ProductCode = d.sku;
            p.Family = d.family;
            p.IsActive = true;
            p.NFY_Style__c = d.style;
            p.NFY_Size__c = d.size;
            p.NFY_ASIN__c = 'B0' + d.sku.right(8);
            p.NFY_Demo__c = true;
            p.TC_Inventory_Product__c = true;
            p.TC_Inventory_Type__c = 'Purchased';
            p.TC_Unit_Cost__c = d.cost;
            p.TC_Inventory_GL_Account__c = inv;
            p.TC_Expense_GL_Account__c = cogs;
            p.TC_Revenue_GL_Account__c = rev;
            p.TC_Default_Vendor__c = vendor;
            prods.add(p);
            prices.put(d.sku, d.price);
        }
        Product2 freight = existing.containsKey(NFY_Ref.FREIGHT_SKU) ? existing.get(NFY_Ref.FREIGHT_SKU) : new Product2();
        freight.Name = 'Freight';
        freight.ProductCode = NFY_Ref.FREIGHT_SKU;
        freight.Family = 'Shipping';
        freight.IsActive = true;
        freight.NFY_Demo__c = true;
        freight.TC_Inventory_Product__c = false;
        freight.TC_Revenue_GL_Account__c = NFY_Ref.gl('4020');
        prods.add(freight);
        prices.put(NFY_Ref.FREIGHT_SKU, 0);
        upsert prods;

        Id pb = NFY_Ref.pricebook();
        Set<Id> priced = new Set<Id>();
        for (PricebookEntry e : [SELECT Product2Id FROM PricebookEntry WHERE Pricebook2Id = :pb AND Product2Id IN :prods]) {
            priced.add(e.Product2Id);
        }
        List<PricebookEntry> entries = new List<PricebookEntry>();
        for (Product2 p : prods) {
            if (!priced.contains(p.Id)) {
                entries.add(new PricebookEntry(Pricebook2Id = pb, Product2Id = p.Id, UnitPrice = prices.get(p.ProductCode), IsActive = true));
            }
        }
        insert entries;
    }

    /** Puts every Nfinity product in every active price book, so a rep can order them whichever price book the order uses. */
    public static Integer seedPriceBooks() {
        Map<Id, Decimal> standardPrice = new Map<Id, Decimal>();
        for (PricebookEntry e : [SELECT Product2Id, UnitPrice FROM PricebookEntry WHERE Pricebook2Id = :NFY_Ref.pricebook() AND Product2.NFY_Demo__c = true]) {
            standardPrice.put(e.Product2Id, e.UnitPrice);
        }
        Set<String> existing = new Set<String>();
        for (PricebookEntry e : [SELECT Pricebook2Id, Product2Id FROM PricebookEntry WHERE Product2.NFY_Demo__c = true AND Pricebook2.IsStandard = false]) {
            existing.add(String.valueOf(e.Pricebook2Id) + String.valueOf(e.Product2Id));
        }
        List<PricebookEntry> entries = new List<PricebookEntry>();
        for (Pricebook2 pb : [SELECT Id FROM Pricebook2 WHERE IsActive = true AND IsStandard = false]) {
            for (Id productId : standardPrice.keySet()) {
                if (!existing.contains(String.valueOf(pb.Id) + String.valueOf(productId))) {
                    entries.add(new PricebookEntry(Pricebook2Id = pb.Id, Product2Id = productId, UnitPrice = standardPrice.get(productId),
                        IsActive = true, UseStandardPrice = false));
                }
            }
        }
        insert entries;
        return entries.size();
    }

    // ------------------------------------------------------------------ sample contacts

    private static final Map<String, List<String>> FIXED_CONTACTS = new Map<String, List<String>>{
        // external ID => first, last, title
        'PAYER-SHOPIFY' => new List<String>{ 'Shopify', 'Payouts', 'Payout notifications' },
        'PAYER-AMAZON' => new List<String>{ 'Amazon', 'Settlements', 'Seller Central settlements' },
        'PAYER-GLOBALE' => new List<String>{ 'Global-e', 'Remittance', 'Merchant of record remittance' },
        'VENDOR-FACTORY' => new List<String>{ 'Lin', 'Chen', 'Export Sales Manager' }
    };

    /**
     * Gives every demo account the sample phone and one contact with a Twopir team inbox, and links
     * each order's bill-to and ship-to contact. Safe to run again.
     */
    public static Integer backfillContacts() {
        List<Account> accts = [SELECT Id, Name, NFY_External_Customer_Id__c, NFY_Customer_Type__c, BillingCity, BillingState, BillingCountry, Phone,
                                   (SELECT Id, Phone, MobilePhone, Email FROM Contacts ORDER BY CreatedDate LIMIT 1)
                               FROM Account WHERE NFY_Demo__c = true AND NFY_External_Customer_Id__c != null];
        List<Account> accountUpdates = new List<Account>();
        List<Contact> newContacts = new List<Contact>();
        List<Contact> contactUpdates = new List<Contact>();
        NFY_SimulatorController.reseed(5150L);
        for (Account a : accts) {
            if (a.Phone != NFY_SimulatorController.PHONE) {
                accountUpdates.add(new Account(Id = a.Id, Phone = NFY_SimulatorController.PHONE));
            }
            String email = NFY_SimulatorController.emailFor(a.NFY_External_Customer_Id__c);
            if (!a.Contacts.isEmpty()) {
                Contact c = a.Contacts[0];
                if (c.Phone != NFY_SimulatorController.PHONE || c.Email == null) {
                    contactUpdates.add(new Contact(Id = c.Id, Phone = NFY_SimulatorController.PHONE, MobilePhone = NFY_SimulatorController.PHONE,
                        Email = c.Email == null ? email : c.Email));
                }
                continue;
            }
            List<String> fixed = FIXED_CONTACTS.get(a.NFY_External_Customer_Id__c);
            String first;
            String last;
            String title;
            if (fixed != null) {
                first = fixed[0];
                last = fixed[1];
                title = fixed[2];
            } else if (a.NFY_Customer_Type__c == 'School' || a.NFY_Customer_Type__c == 'Cheer gym / team') {
                first = new List<String>{ 'Dana', 'Kelsey', 'Morgan', 'Tracy', 'Jordan', 'Shannon' }[NFY_SimulatorController.rand(6)];
                last = new List<String>{ 'Pruitt', 'Ellison', 'Barrow', 'Sutton', 'Holloway', 'Ashby' }[NFY_SimulatorController.rand(6)];
                title = a.NFY_Customer_Type__c == 'School' ? 'Cheer Coach' : 'Gym Owner';
            } else {
                first = a.Name.contains(' ') ? a.Name.substringBefore(' ') : null;
                last = a.Name.contains(' ') ? a.Name.substringAfter(' ') : a.Name;
            }
            newContacts.add(new Contact(AccountId = a.Id, FirstName = first, LastName = last, Title = title, Email = email,
                Phone = NFY_SimulatorController.PHONE, MobilePhone = NFY_SimulatorController.PHONE,
                MailingCity = a.BillingCity, MailingState = a.BillingState, MailingCountry = a.BillingCountry));
        }
        update accountUpdates;
        Database.DMLOptions opts = new Database.DMLOptions();
        opts.DuplicateRuleHeader.allowSave = true;
        opts.DuplicateRuleHeader.runAsCurrentUser = true;
        Database.update(contactUpdates, opts);
        Database.insert(newContacts, opts);

        Map<Id, Id> contactByAccount = new Map<Id, Id>();
        for (Contact c : [SELECT Id, AccountId FROM Contact WHERE Account.NFY_Demo__c = true ORDER BY CreatedDate]) {
            if (!contactByAccount.containsKey(c.AccountId)) {
                contactByAccount.put(c.AccountId, c.Id);
            }
        }
        List<Order> orders = new List<Order>();
        for (Order o : [SELECT Id, AccountId FROM Order WHERE NFY_Demo__c = true AND (BillToContactId = null OR ShipToContactId = null)]) {
            Id cid = contactByAccount.get(o.AccountId);
            if (cid != null) {
                orders.add(new Order(Id = o.Id, BillToContactId = cid, ShipToContactId = cid));
            }
        }
        update orders;
        return newContacts.size();
    }

    // ------------------------------------------------------------------ opening stock

    /** warehouse code -> units of each shoe size, accessory and apparel item on 1 Sep. */
    public static Map<String, List<Integer>> openingLevels() {
        return new Map<String, List<Integer>>{
            //                 shoes, accessories, jackets
            'MAIN' => new List<Integer>{ 320, 220, 60 },
            'SM-PA1' => new List<Integer>{ 240, 140, 0 },
            'SM-NV3' => new List<Integer>{ 170, 110, 0 },
            'FBA-US' => new List<Integer>{ 120, 60, 0 },
            'RETAIL' => new List<Integer>{ 12, 20, 6 },
            'CUSTOMWEAR' => new List<Integer>{ 0, 0, 120 }
        };
    }

    public static void seedStock() {
        NFY_Ref.reset();
        Id opening = NFY_Ref.gl('3900');
        List<TC_Inbound_Inventory_Movement__c> moves = new List<TC_Inbound_Inventory_Movement__c>();
        Map<String, List<Integer>> levels = openingLevels();
        List<ProductDef> defs = catalogue();
        for (String wh : levels.keySet()) {
            Id locId = NFY_Ref.location(wh, 'AVL').Id;
            Set<Id> productIds = new Set<Id>();
            for (ProductDef d : defs) {
                productIds.add(NFY_Ref.product(d.sku).Id);
            }
            Map<Id, TC_Inventory_Balance__c> balances = TC_InventoryService.balancesFor(productIds, locId, null);
            for (ProductDef d : defs) {
                Integer qty = d.family == 'Footwear' ? levels.get(wh)[0] : (d.family == 'Apparel' ? levels.get(wh)[2] : levels.get(wh)[1]);
                // Youth sizes are not stocked at PA1, which is what sends those lines back to Main.
                if (wh == 'SM-PA1' && d.size != null && d.size.startsWith('Youth')) {
                    qty = 0;
                }
                if (qty <= 0) {
                    continue;
                }
                Product2 p = NFY_Ref.product(d.sku);
                moves.add(new TC_Inbound_Inventory_Movement__c(Inventory_Balance__c = balances.get(p.Id).Id, Type__c = 'Accounting', Quantity__c = qty,
                    Unit_Cost__c = d.cost, Movement_Date__c = OPENING_DATE, Credit_GL_Account__c = opening));
            }
        }
        insert moves;
    }

    /** Rep and event holdings, as on Lauren's inventory screen. Separate from seedStock to keep each step inside limits. */
    public static void seedFieldHoldings() {
        Id evo8 = NFY_Ref.product('840386208702').Id;
        NFY_IntegrationService.transfer(evo8, 'MAIN', 'AVL', 'FIELD', 'SARAH', 2, OPENING_DATE.addDays(3));
        NFY_IntegrationService.transfer(evo8, 'MAIN', 'AVL', 'FIELD', 'NCA2026', 10, OPENING_DATE.addDays(3));
        NFY_IntegrationService.transfer(evo8, 'MAIN', 'AVL', 'FIELD', 'PEACH2026', 3, OPENING_DATE.addDays(3));
        NFY_IntegrationService.transfer(evo8, 'MAIN', 'AVL', 'FIELD', 'FINALS2026', 2, OPENING_DATE.addDays(3));
    }

    // ------------------------------------------------------------------ order history

    public class Planned {
        public String orderNo;
        public String channel;
        public String source;
        public String shipFrom;
        public Date orderDate;
        public Integer index;
    }

    /** Channel mix: Shopify .com about 55%, Amazon FBA 20%, FBM 5%, MCF 5%, wholesale 10%, Global-e 5%. */
    public static Planned plan(Integer i, Integer total) {
        NFY_SimulatorController.reseed(7919L * (i + 1));
        Planned p = new Planned();
        p.index = i;
        p.orderDate = Date.today().addDays(-HISTORY_DAYS + (i * HISTORY_DAYS / total));
        Integer roll = NFY_SimulatorController.rand(100);
        if (roll < 55) {
            p.channel = 'Shopify .com';
            p.source = 'SHOPIFY';
            p.orderNo = '#SPFY' + String.valueOf(384100 + i * 15);
        } else if (roll < 75) {
            p.channel = 'Amazon FBA';
            p.source = 'AMAZON';
            p.shipFrom = 'FBA-US';
            p.orderNo = '11' + String.valueOf(1 + NFY_SimulatorController.rand(4)) + '-' + String.valueOf(1000000 + i * 7919).right(7) + '-' + String.valueOf(3000000 + i * 104729).right(7);
        } else if (roll < 80) {
            p.channel = 'Amazon FBM';
            p.source = 'AMAZON';
            p.shipFrom = 'MAIN';
            p.orderNo = '11' + String.valueOf(1 + NFY_SimulatorController.rand(4)) + '-' + String.valueOf(2000000 + i * 6007).right(7) + '-' + String.valueOf(5000000 + i * 99991).right(7);
        } else if (roll < 85) {
            p.channel = 'Amazon MCF';
            p.source = 'SHOPIFY';
            p.shipFrom = 'FBA-US';
            p.orderNo = '#SPFY' + String.valueOf(384100 + i * 15);
        } else if (roll < 95) {
            p.channel = 'Wholesale / Team';
            p.source = 'SALESFORCE';
            p.shipFrom = 'MAIN';
            p.orderNo = 'B2B-' + String.valueOf(10400 + i);
        } else {
            p.channel = 'Global-e';
            p.source = 'GLOBALE';
            p.shipFrom = 'MAIN';
            p.orderNo = 'GE-' + String.valueOf(5521000 + i * 37);
        }
        return p;
    }

    /** Sends one planned order through the integration service. Returns the sync log ID. */
    public static Id sendOrder(Planned pl) {
        Map<String, Object> cust = NFY_SimulatorController.customer(pl.channel);
        String shipFrom = pl.shipFrom;
        if (shipFrom == null) {
            shipFrom = cust.containsKey('region') ? (String) cust.get('region') : 'SM-PA1';
        }
        List<Object> lines = new List<Object>();
        List<String> shoes = NFY_SimulatorController.SHOE_SKUS;
        List<String> extras = NFY_SimulatorController.ACCESSORY_SKUS;
        if (pl.channel == 'Wholesale / Team') {
            lines.add(NFY_SimulatorController.line(shoes[NFY_SimulatorController.rand(shoes.size())], 6 + NFY_SimulatorController.rand(10)));
            if (NFY_SimulatorController.rand(3) == 0) {
                Map<String, Object> jacket = NFY_SimulatorController.line('840386230033', 8 + NFY_SimulatorController.rand(8));
                jacket.put('shipFrom', 'CUSTOMWEAR');
                lines.add(jacket);
            }
        } else {
            lines.add(NFY_SimulatorController.line(shoes[NFY_SimulatorController.rand(shoes.size())], 1));
            if (NFY_SimulatorController.rand(3) == 0 && !pl.channel.startsWith('Amazon')) {
                lines.add(NFY_SimulatorController.line(extras[NFY_SimulatorController.rand(extras.size())], 1));
            }
        }
        Map<String, Object> payload = NFY_SimulatorController.order(pl.orderNo, pl.channel, cust, shipFrom, lines, pl.orderDate);
        payload.put('routingReason', pl.source == 'SHOPIFY' && pl.shipFrom == null ? 'Shopify ranked ' + shipFrom + ' for ' + cust.get('state') : null);
        return NFY_IntegrationService.process('order.upsert', pl.source, JSON.serialize(payload), 'j-' + String.valueOf(87400000 + pl.index * 131), 'Workato').logId;
    }

    /** Ship-froms on a planned order, in a fixed order so each job ships the next one. */
    public static List<String> orderedShipFroms(String orderNo) {
        List<String> froms = new List<String>(NFY_SimulatorController.shipFroms(orderNo));
        froms.sort();
        return froms;
    }

    /** One history event. Phase 0 is the order; phase n ships the order's n-th ship-from. */
    public static void runHistoryStep(Integer index, Integer total, Integer phase) {
        Planned pl = plan(index, total);
        Id logId;
        if (phase == 0) {
            if ([SELECT COUNT() FROM Order WHERE NFY_External_Order_Id__c = :pl.orderNo] > 0) {
                return;
            }
            logId = sendOrder(pl);
        } else {
            if (pl.orderDate > Date.today().addDays(-3) || (Math.mod(pl.index, 11) == 5 && phase > 1)) {
                return;
            }
            List<String> froms = orderedShipFroms(pl.orderNo);
            if (phase > froms.size()) {
                return;
            }
            String sf = froms[phase - 1];
            if ([SELECT COUNT() FROM TC_Shipment__c WHERE Sales_Order__r.NFY_External_Order_Id__c = :pl.orderNo AND NFY_Ship_From__r.NFY_Code__c = :sf] > 0) {
                return;
            }
            String src = NFY_SimulatorController.sourceFor(sf);
            NFY_SimulatorController.reseed(7919L * (index + 1) + phase * 31);
            Map<String, Object> s = NFY_SimulatorController.shipment(src.left(2) + '-' + String.valueOf(4000000 + index * 13 + phase), pl.orderNo, sf,
                pl.orderDate.addDays(phase));
            logId = NFY_IntegrationService.process('shipment.created', src, JSON.serialize(s), 'j-' + String.valueOf(87400000 + index * 131 + phase), 'Workato').logId;
        }
        Datetime at = Datetime.newInstance(pl.orderDate.addDays(phase), Time.newInstance(9 + Math.mod(index, 9), Math.mod(index * 7, 60), 0, 0));
        update new NFY_Sync_Log__c(Id = logId, Received_At__c = at, Processed_At__c = at.addSeconds(2));
    }

    // ------------------------------------------------------------------ open items and log history

    public static void seedOpenItems() {
        NFY_Ref.reset();
        // A container on the water to Main.
        Account vendor = [SELECT Id FROM Account WHERE NFY_External_Customer_Id__c = 'VENDOR-FACTORY'];
        TC_Purchase_Order__c po = new TC_Purchase_Order__c(Vendor__c = vendor.Id, Order_Date__c = Date.today().addDays(-35), Status__c = 'Open', Type__c = 'Standard',
            NFY_External_Id__c = 'PO-NFY-2611', NFY_Demo__c = true, Comment__c = 'Holiday restock, FOB Xiamen');
        insert po;
        insert new List<TC_Purchase_Order_Line__c>{
            new TC_Purchase_Order_Line__c(Purchase_Order__c = po.Id, Product__c = NFY_Ref.product('840386215465').Id, Quantity__c = 600),
            new TC_Purchase_Order_Line__c(Purchase_Order__c = po.Id, Product__c = NFY_Ref.product('840386215475').Id, Quantity__c = 600)
        };
        NFY_SimulatorController.send('inbound.update', 'SALESFORCE', new Map<String, Object>{ 'inboundId' => 'CNT-MSCU4471029', 'status' => 'IN_TRANSIT',
            'type' => 'Factory container', 'to' => 'MAIN', 'poNumber' => 'PO-NFY-2611', 'containerNo' => 'MSCU4471029', 'vessel' => 'MSC Lucia',
            'eta' => String.valueOf(Date.today().addDays(6)), 'lines' => new List<Object>{
                new Map<String, Object>{ 'sku' => '840386215465', 'shipped' => 600 }, new Map<String, Object>{ 'sku' => '840386215475', 'shipped' => 600 } } });
        // An FBA inbound on its way.
        NFY_SimulatorController.send('inbound.update', 'AMAZON', new Map<String, Object>{ 'inboundId' => 'FBA19K7QD2M', 'status' => 'WORKING', 'type' => 'Amazon FBA inbound',
            'from' => 'MAIN', 'to' => 'FBA-US', 'lines' => new List<Object>{ new Map<String, Object>{ 'sku' => '840386208703', 'shipped' => 96 },
                new Map<String, Object>{ 'sku' => '840386208704', 'shipped' => 72 } } });
        NFY_SimulatorController.send('inbound.update', 'AMAZON', new Map<String, Object>{ 'inboundId' => 'FBA19K7QD2M', 'status' => 'SHIPPED', 'carrier' => 'UPS',
            'tracking' => '1ZA7F29303' + '84410022', 'date' => String.valueOf(Date.today().addDays(-4)) });
        // Earlier settlements, fully matched.
        settle('AMAZON', 'AMZ-STL-' + Date.today().addDays(-18).format().replace('/', ''), Date.today().addDays(-HISTORY_DAYS - 1), Date.today().addDays(-18));
        settle('SHOPIFY', 'SHP-PO-' + Date.today().addDays(-10).format().replace('/', ''), Date.today().addDays(-HISTORY_DAYS - 1), Date.today().addDays(-10));
        seedLogHistory();
    }

    public static void settle(String source, String id, Date startD, Date endD) {
        String payer = source == 'AMAZON' ? 'PAYER-AMAZON' : 'PAYER-SHOPIFY';
        Decimal gross = 0;
        for (AggregateResult ar : [
            SELECT SUM(Balance__c) t FROM TC_Billing__c WHERE Customer__r.NFY_External_Customer_Id__c = :payer AND Status__c = 'Posted' AND Balance__c > 0
            AND NFY_Settlement__c = null AND Date__c >= :startD AND Date__c <= :endD
        ]) {
            gross = ar.get('t') == null ? 0 : (Decimal) ar.get('t');
        }
        if (gross == 0) {
            return;
        }
        Boolean amazon = source == 'AMAZON';
        NFY_SimulatorController.send('settlement.posted', source, new Map<String, Object>{ 'settlementId' => id, 'periodStart' => String.valueOf(startD),
            'periodEnd' => String.valueOf(endD), 'grossSales' => gross, 'refunds' => 0,
            'marketplaceFees' => amazon ? (gross * 0.15).setScale(2) : 0, 'fulfillmentFees' => amazon ? (gross * 0.11).setScale(2) : 0,
            'paymentFees' => amazon ? 0 : (gross * 0.029).setScale(2) });
    }

    /** Polling and snapshot jobs the replay does not create, at each system's usual failure rate. */
    public static void seedLogHistory() {
        Map<String, NFY_Integration_System__c> sys = new Map<String, NFY_Integration_System__c>();
        for (NFY_Integration_System__c s : [SELECT Id, Code__c FROM NFY_Integration_System__c]) {
            sys.put(s.Code__c, s);
        }
        Map<String, Id> flows = new Map<String, Id>();
        for (NFY_Integration_Flow__c f : [SELECT Id, Code__c FROM NFY_Integration_Flow__c]) {
            flows.put(f.Code__c, f.Id);
        }
        // system, event, entity, per-day count, failure % , error
        List<List<String>> defs = new List<List<String>>{
            new List<String>{ 'SHIPSTATION', 'shipment.created', 'Shipment', '4', '15', 'No Salesforce order matches the ShipStation order. The SHIPSTATION shipment cannot be linked: the order has not synced from its channel yet. Run the order sync, then retry.' },
            new List<String>{ 'SHIPMONK', 'inventory.snapshot', 'Inventory', '2', '2', 'Read timed out after 30000 ms calling ShipMonk /inventory?page=3.' },
            new List<String>{ 'AMAZON', 'inventory.snapshot', 'Inventory', '2', '4', 'SP-API QuotaExceeded on getInventorySummaries. Retry after 60 seconds.' },
            new List<String>{ 'SHOPIFY', 'order.upsert', 'Order', '1', '1', 'Unknown SKU "840386299001". Add the product in Salesforce or fix the SKU mapping in the recipe.' },
            new List<String>{ 'GLOBALE', 'order.upsert', 'Order', '1', '3', 'Missing "customer" in the payload.' }
        };
        List<NFY_Sync_Log__c> logs = new List<NFY_Sync_Log__c>();
        NFY_SimulatorController.reseed(424242L);
        for (Integer day = HISTORY_DAYS; day >= 0; day--) {
            Date d = Date.today().addDays(-day);
            for (List<String> def : defs) {
                for (Integer k = 0; k < Integer.valueOf(def[3]); k++) {
                    Boolean failed = NFY_SimulatorController.rand(100) < Integer.valueOf(def[4]);
                    Datetime at = Datetime.newInstance(d, Time.newInstance(1 + NFY_SimulatorController.rand(22), NFY_SimulatorController.rand(60), 0, 0));
                    if (at > System.now()) {
                        continue;
                    }
                    logs.add(new NFY_Sync_Log__c(System__c = sys.get(def[0]).Id, Flow__c = flows.get(def[0] + '-' + def[2].toUpperCase().replace(' ', '_')),
                        Event_Type__c = def[1], Entity__c = def[2], Direction__c = 'Into Salesforce', Source__c = 'Workato',
                        Status__c = failed ? 'Failed' : 'Success', Error_Message__c = failed ? def[5] : null,
                        Response__c = failed ? null : (def[2] == 'Inventory' ? 'Stock snapshot matched TC.' : 'Processed.'),
                        Attempts__c = failed ? 1 : 1, Resolved__c = failed && day > 2, Received_At__c = at, Processed_At__c = at.addSeconds(1 + NFY_SimulatorController.rand(4)),
                        Duration_ms__c = 300 + NFY_SimulatorController.rand(2500), Workato_Job_Id__c = 'j-' + String.valueOf(88000000 + logs.size() * 17),
                        External_Id__c = def[0].left(3) + '-HIST-' + logs.size()));
                }
            }
        }
        insert logs;
    }

    // ------------------------------------------------------------------ reset

    public static final Integer LAST_STEP = 11;

    /** Returns true when the step has more records left to remove. */
    public static Boolean runStep(Integer step, Datetime since) {
        Datetime t = since == null ? Datetime.newInstance(2000, 1, 1) : since;
        Integer n = 150;
        switch on step {
            when 0 {
                // Settlements: unapply and unpost cash, unpost fee journals.
                List<TC_Billing_Cash_Receipt__c> apps = [SELECT Id FROM TC_Billing_Cash_Receipt__c WHERE Billing__r.NFY_Channel__c != null AND CreatedDate >= :t LIMIT :n];
                delete apps;
                List<TC_Cash_Receipt__c> receipts = [SELECT Id, Status__c FROM TC_Cash_Receipt__c WHERE Account__r.NFY_External_Customer_Id__c LIKE 'PAYER-%' AND CreatedDate >= :t LIMIT :n];
                unpostAndDelete(receipts);
                List<TC_Journal_Entry__c> jes = [SELECT Id, Status__c FROM TC_Journal_Entry__c WHERE NFY_Demo__c = true AND CreatedDate >= :t LIMIT :n];
                unpostAndDelete(jes);
                return apps.size() == n || receipts.size() == n || jes.size() == n;
            }
            when 1 {
                List<NFY_Settlement__c> s = [SELECT Id FROM NFY_Settlement__c WHERE CreatedDate >= :t LIMIT :n];
                delete s;
                return s.size() == n;
            }
            when 2 {
                List<TC_Billing__c> b = [SELECT Id, Status__c FROM TC_Billing__c WHERE (NFY_Channel__c != null OR Sales_Order__r.NFY_Demo__c = true) AND CreatedDate >= :t LIMIT 60];
                unpostAndDelete(b);
                return b.size() == 60;
            }
            when 3 {
                List<TC_SO_Inventory_Movement__c> m = [SELECT Id FROM TC_SO_Inventory_Movement__c WHERE Sales_Order_Line__r.Sales_Order__r.NFY_Demo__c = true AND CreatedDate >= :t LIMIT 100];
                delete m;
                return m.size() == 100;
            }
            when 4 {
                List<TC_Shipment__c> s = [SELECT Id FROM TC_Shipment__c WHERE Sales_Order__r.NFY_Demo__c = true AND CreatedDate >= :t LIMIT :n];
                delete s;
                return s.size() == n;
            }
            when 5 {
                List<TC_Sales_Order__c> so = [SELECT Id FROM TC_Sales_Order__c WHERE NFY_Demo__c = true AND CreatedDate >= :t LIMIT :n];
                delete [SELECT Id FROM TC_Sales_Order_Line__c WHERE Sales_Order__c IN :so];
                delete so;
                return so.size() == n;
            }
            when 6 {
                List<Order> o = [SELECT Id, Status FROM Order WHERE NFY_Demo__c = true AND CreatedDate >= :t LIMIT :n];
                for (Order x : o) {
                    x.Status = 'Draft';
                }
                update o;
                delete o;
                List<Opportunity> opp = [SELECT Id FROM Opportunity WHERE NFY_Demo__c = true AND CreatedDate >= :t LIMIT :n];
                delete opp;
                return o.size() == n || opp.size() == n;
            }
            when 7 {
                // Transfers, returns restock and opening stock.
                List<TC_Inbound_Inventory_Movement__c> ins = [SELECT Id FROM TC_Inbound_Inventory_Movement__c WHERE Inventory_Balance__r.Product__r.NFY_Demo__c = true AND CreatedDate >= :t LIMIT 100];
                delete ins;
                List<TC_Outbound_Inventory_Movement__c> outs = [SELECT Id FROM TC_Outbound_Inventory_Movement__c WHERE Inventory_Balance__r.Product__r.NFY_Demo__c = true AND CreatedDate >= :t LIMIT 100];
                delete outs;
                return ins.size() == 100 || outs.size() == 100;
            }
            when 8 {
                List<TC_PO_Inventory_Movement__c> m = [SELECT Id FROM TC_PO_Inventory_Movement__c WHERE Purchase_Order_Line__r.Purchase_Order__r.NFY_Demo__c = true AND CreatedDate >= :t LIMIT 100];
                delete m;
                if (m.size() == 100) {
                    return true;
                }
                List<TC_Purchase_Order__c> po = [SELECT Id FROM TC_Purchase_Order__c WHERE NFY_Demo__c = true AND CreatedDate >= :t LIMIT :n];
                delete [SELECT Id FROM TC_Purchase_Order_Line__c WHERE Purchase_Order__c IN :po];
                delete po;
                return po.size() == n;
            }
            when 9 {
                List<SObject> recs = new List<SObject>();
                recs.addAll((List<SObject>) [SELECT Id FROM NFY_Return__c WHERE CreatedDate >= :t LIMIT :n]);
                recs.addAll((List<SObject>) [SELECT Id FROM NFY_Inventory_Recon__c WHERE CreatedDate >= :t LIMIT :n]);
                recs.addAll((List<SObject>) [SELECT Id FROM NFY_Inbound_Shipment__c WHERE CreatedDate >= :t LIMIT :n]);
                delete recs;
                return recs.size() >= n;
            }
            when 10 {
                List<NFY_Sync_Log__c> logs = [SELECT Id FROM NFY_Sync_Log__c WHERE CreatedDate >= :t LIMIT 2000];
                delete logs;
                return logs.size() == 2000;
            }
            when 11 {
                if (since == null) {
                    delete [SELECT Id FROM TC_Inventory_Balance__c WHERE Product__r.NFY_Demo__c = true AND Id NOT IN (SELECT Inventory_Balance__c FROM TC_Inbound_Inventory_Movement__c) LIMIT 500];
                    delete [SELECT Id FROM Account WHERE NFY_Demo__c = true AND (NOT NFY_External_Customer_Id__c LIKE 'PAYER-%') AND NFY_External_Customer_Id__c != 'VENDOR-FACTORY' AND CreatedDate >= :t LIMIT 500];
                }
                delete [SELECT Id FROM TC_Warehouse__c WHERE NFY_Code__c = 'NL-ODOO' AND CreatedDate >= :t];
                for (NFY_Integration_System__c s : [SELECT Id FROM NFY_Integration_System__c WHERE Code__c = 'ODOO']) {
                    update new NFY_Integration_System__c(Id = s.Id, Status__c = 'Planned');
                }
                delete [SELECT Id FROM NFY_Integration_Flow__c WHERE System__r.Code__c = 'ODOO'];
                return false;
            }
        }
        return false;
    }

    private static void unpostAndDelete(List<SObject> recs) {
        List<Id> posted = new List<Id>();
        for (SObject r : recs) {
            if (r.get('Status__c') == 'Posted') {
                posted.add(r.Id);
            }
        }
        if (!posted.isEmpty()) {
            TC_PostingEngine.unpost(posted);
        }
        Boolean previous = TC_TriggerGate.allowTransactionDelete;
        try {
            TC_TriggerGate.allowTransactionDelete = true;
            delete recs;
        } finally {
            TC_TriggerGate.allowTransactionDelete = previous;
        }
    }
}