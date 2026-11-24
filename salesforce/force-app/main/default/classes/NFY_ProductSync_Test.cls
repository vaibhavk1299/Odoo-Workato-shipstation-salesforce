/**
 * product.upsert through the Integration Service: Odoo and Shopify create and update one Product2
 * per variant, match by source ID then SKU, respect field ownership, keep prices per currency,
 * skip replays and reject bad data with a categorised log.
 */
@IsTest
private class NFY_ProductSync_Test {

    @TestSetup
    static void setup() {
        insert new List<NFY_Integration_System__c>{
            new NFY_Integration_System__c(Name = 'Odoo (Commerce)', Code__c = 'ODOO_SHOP', Category__c = 'Sales channel', Status__c = 'Connected', Mode__c = 'Webhook'),
            new NFY_Integration_System__c(Name = 'Shopify', Code__c = 'SHOPIFY', Category__c = 'Sales channel', Status__c = 'Connected', Mode__c = 'Webhook')
        };
    }

    private static String corporate() {
        for (SObject c : Database.query('SELECT IsoCode FROM CurrencyType WHERE IsCorporate = true')) {
            return (String) c.get('IsoCode');
        }
        return UserInfo.getDefaultCurrency();
    }

    private static String otherCurrency() {
        for (SObject c : Database.query('SELECT IsoCode FROM CurrencyType WHERE IsActive = true AND IsCorporate = false LIMIT 1')) {
            return (String) c.get('IsoCode');
        }
        return null;
    }

    private static Map<String, Object> odoo(String id, String sku, String name, Decimal price) {
        return new Map<String, Object>{
            'eventId' => 'ODOO-PRODUCT-' + id + '@' + sku + name + price, 'sku' => sku, 'name' => name, 'description' => 'Odoo description of ' + name,
            'family' => 'Footwear', 'active' => true, 'uom' => 'Each', 'price' => price, 'currency' => corporate(), 'cost' => 21.5, 'storable' => true,
            'sourceProductId' => 'T' + id, 'sourceVariantId' => id
        };
    }

    private static Map<String, Object> shopify(String variantId, String sku, String name, Decimal price, String currencyCode) {
        return new Map<String, Object>{
            'eventId' => 'SHOPIFY-VARIANT-' + variantId + '@' + sku + name + price, 'sku' => sku, 'name' => name, 'description' => 'Shopify copy',
            'shortDescription' => 'Shopify copy', 'family' => 'Shoes', 'active' => true, 'uom' => 'Each', 'price' => price, 'currency' => currencyCode,
            'sourceProductId' => '900', 'sourceVariantId' => variantId, 'displayUrl' => 'https://shop.example.com/products/x',
            'imageUrl' => 'https://cdn.example.com/x.png', 'onHand' => 7, 'available' => 7
        };
    }

    private static NFY_IntegrationService.Result send(String source, Map<String, Object> payload) {
        return NFY_IntegrationService.process('product.upsert', source, JSON.serialize(payload), 'j-' + Crypto.getRandomInteger(), 'Workato');
    }

    private static NFY_Sync_Log__c log(Id logId) {
        return [SELECT Status__c, Operation__c, Error_Category__c, Error_Message__c, Response__c, Entity__c, Record_Id__c FROM NFY_Sync_Log__c WHERE Id = :logId];
    }

    private static Decimal price(Id productId, String currencyCode) {
        Id book = Test.getStandardPricebookId();
        List<SObject> e = Database.query('SELECT UnitPrice FROM PricebookEntry WHERE Product2Id = :productId AND Pricebook2Id = :book AND CurrencyIsoCode = :currencyCode');
        return e.isEmpty() ? null : (Decimal) e[0].get('UnitPrice');
    }

    /**
     * What Odoo does on create: the same save (same eventId) is sent first without the Internal Reference,
     * then with it. The half-saved state fails once, its exact repeats are skipped, but the complete state
     * is processed and the "no SKU" failure is resolved as superseded.
     */
    @IsTest
    static void halfSavedOdooProductDoesNotBlockTheCompleteOne() {
        Map<String, Object> half = odoo('777', '', 'Half Saved Shoe', 50);
        half.put('eventId', 'ODOO-PRODUCT-777@2026-11-13 10:05:21');
        Map<String, Object> complete = half.clone();
        complete.put('sku', 'TST-HALF-1');

        Test.startTest();
        NFY_IntegrationService.Result noSku = send('ODOO_SHOP', half);
        NFY_IntegrationService.Result repeat = send('ODOO_SHOP', half);
        NFY_IntegrationService.Result withSku = send('ODOO_SHOP', complete);
        NFY_IntegrationService.Result withSkuAgain = send('ODOO_SHOP', complete);
        Test.stopTest();

        System.assertEquals('Failed', noSku.status);
        System.assert(noSku.message.contains('no SKU'), noSku.message);
        System.assertEquals('Duplicate skipped', repeat.status, 'An exact repeat of an open failure is skipped');
        System.assertNotEquals('Duplicate skipped', withSku.status, 'The complete state of the same save is processed');
        System.assertEquals('Duplicate skipped', withSkuAgain.status, 'Its exact repeat is skipped');
        NFY_Sync_Log__c first = [SELECT Resolved__c, Response__c FROM NFY_Sync_Log__c WHERE Id = :noSku.logId];
        System.assert(first.Resolved__c, 'The half-saved failure is superseded');
        System.assert(first.Response__c.startsWith('Superseded by'), first.Response__c);
        System.assertEquals(0, [SELECT COUNT() FROM Product2 WHERE NFY_Odoo_Product_Id__c = '777' AND ProductCode = null], 'No product without a SKU');
        System.assert([SELECT COUNT() FROM Product2 WHERE NFY_Odoo_Product_Id__c = '777'] <= 1, 'Never more than one product');
    }

    /** A product that really has no SKU still alerts, a minute later; a half-saved state that is superseded never does. */
    @IsTest
    static void onlyFailuresThatStayOpenAlert() {
        Map<String, Object> missing = odoo('781', '', 'Really No SKU', 10);
        missing.put('eventId', 'ODOO-PRODUCT-781@2026-11-17 12:00:00');
        Map<String, Object> half = odoo('782', '', 'Half Saved', 10);
        half.put('eventId', 'ODOO-PRODUCT-782@2026-11-17 12:00:00');
        Map<String, Object> complete = half.clone();
        complete.put('sku', 'TST-ALERT-2');

        Test.startTest();
        send('ODOO_SHOP', missing);
        send('ODOO_SHOP', half);
        send('ODOO_SHOP', complete);
        Test.stopTest(); // runs the delayed alert jobs

        System.assertEquals(1, NFY_IntegrationService.delayedAlertsSent, 'Only the product that still has no SKU alerts');
    }

    /** Retry (the button on a failed log) re-runs a versioned product event in full. */
    @IsTest
    static void retryOfAFailedProductRunsAgain() {
        Map<String, Object> half = odoo('778', '', 'Retry Shoe', 50);
        half.put('eventId', 'ODOO-PRODUCT-778@2026-11-13 11:00:00');
        NFY_IntegrationService.Result failed = send('ODOO_SHOP', half);
        Test.startTest();
        NFY_IntegrationService.Result again = NFY_IntegrationService.retry(failed.logId);
        Test.stopTest();
        System.assertEquals('Failed', again.status, 'Still no SKU, so it fails again');
        System.assertEquals(2, again.attempts);
        System.assertEquals(2, [SELECT Attempts__c FROM NFY_Sync_Log__c WHERE Id = :failed.logId].Attempts__c);
    }

    @IsTest
    static void odooCreatesUpdatesAndReplays() {
        Test.startTest();
        NFY_IntegrationService.Result c = send('ODOO_SHOP', odoo('501', 'TST-ODOO-1', 'Test Trainer 9', 80));
        Map<String, Object> changedPayload = odoo('501', 'TST-ODOO-1', 'Test Trainer 9 Pro', 95);
        NFY_IntegrationService.Result u = send('ODOO_SHOP', changedPayload);
        NFY_IntegrationService.Result replay = send('ODOO_SHOP', changedPayload);
        changedPayload.put('eventId', 'ODOO-PRODUCT-501@later');
        NFY_IntegrationService.Result same = send('ODOO_SHOP', changedPayload);
        Test.stopTest();

        System.assert(c.success, c.message);
        Product2 p = [SELECT Name, ProductCode, StockKeepingUnit, NFT_SKU__c, NFY_Odoo_Product_Id__c, Family, IsActive, NFY_Demo__c, TC_Unit_Cost__c,
                          TC_Inventory_Product__c, Description FROM Product2 WHERE NFY_Odoo_Product_Id__c = '501'];
        System.assertEquals('Test Trainer 9 Pro', p.Name);
        System.assertEquals('TST-ODOO-1', p.ProductCode);
        System.assertEquals('TST-ODOO-1', p.StockKeepingUnit);
        System.assertEquals('TST-ODOO-1', p.NFT_SKU__c);
        System.assertEquals('Footwear', p.Family);
        System.assert(p.NFY_Demo__c && p.TC_Inventory_Product__c);
        System.assertEquals(21.5, p.TC_Unit_Cost__c);
        System.assertEquals(95, price(p.Id, corporate()));
        System.assertEquals('Created', log(c.logId).Operation__c);
        System.assertEquals('Product', log(c.logId).Entity__c);
        System.assertEquals('Updated', log(u.logId).Operation__c);
        System.assertEquals('Duplicate skipped', replay.status);
        System.assertEquals('No change', log(same.logId).Operation__c, log(same.logId).Response__c);
        System.assertEquals(1, [SELECT COUNT() FROM Product2 WHERE ProductCode = 'TST-ODOO-1']);

        // Source tracking: the product carries its origin and links to its log entries.
        Product2 src = [SELECT NFY_Source_System__c, NFY_Source_Record_Id__c, NFY_Last_Sync_Status__c, NFY_Last_Sync_Log__c, NFY_Sync_Count__c
                        FROM Product2 WHERE Id = :p.Id];
        System.assertEquals('Odoo', src.NFY_Source_System__c);
        System.assertEquals('501', src.NFY_Source_Record_Id__c);
        System.assertEquals('Success', src.NFY_Last_Sync_Status__c);
        System.assertEquals(same.logId, src.NFY_Last_Sync_Log__c);
        System.assertEquals(3, src.NFY_Sync_Count__c, 'Created, updated, no change; the replay is skipped');
        System.assertEquals(p.Id, [SELECT Product__c FROM NFY_Sync_Log__c WHERE Id = :c.logId].Product__c);
        NFY_IntegrationOriginController.Origin card = NFY_IntegrationOriginController.getOrigin(p.Id);
        System.assertEquals('Odoo', card.sourceSystem);
        System.assert(card.logs.size() >= 3, 'The card lists the product\'s log entries');
        Boolean hasOdooId = false;
        for (NFY_IntegrationOriginController.SystemId sid : card.systemIds) {
            hasOdooId = hasOdooId || (sid.label == 'Odoo product' && sid.value == '501');
        }
        System.assert(hasOdooId, 'The card shows the Odoo product ID');
    }

    @IsTest
    static void shopifyOnlyProductKeepsShopifyMapping() {
        String cur = otherCurrency() == null ? corporate() : otherCurrency();
        Test.startTest();
        NFY_IntegrationService.Result c = send('SHOPIFY', shopify('7001', 'TST-SHOP-1', 'Test Book', 165, cur));
        NFY_IntegrationService.Result u = send('SHOPIFY', shopify('7001', 'TST-SHOP-1', 'Test Book (2nd ed.)', 175, cur));
        Map<String, Object> giftCard = shopify('7002', 'TST-SHOP-GIFT', 'Gift Card', 500, cur);
        giftCard.put('storable', false);
        NFY_IntegrationService.Result g = send('SHOPIFY', giftCard);
        Test.stopTest();
        System.assert(c.success && u.success && g.success, c.message + ' / ' + u.message + ' / ' + g.message);
        Product2 p = [SELECT Name, ProductCode, NFT_Shopify_Variant_Id__c, NFT_Shopify_Product_Id__c, DisplayUrl, Image_URL__c, NFT_Total_On_Hand__c,
                          NFY_Demo__c, Family, Short_Description__c, TC_Inventory_Product__c FROM Product2 WHERE NFT_Shopify_Variant_Id__c = '7001'];
        System.assert(p.TC_Inventory_Product__c, 'A Shopify-only product is stocked so its orders reserve and ship');
        System.assert(![SELECT TC_Inventory_Product__c FROM Product2 WHERE NFT_Shopify_Variant_Id__c = '7002'].TC_Inventory_Product__c,
            'storable false (gift card, service) stays non-stock');
        System.assertEquals('Test Book (2nd ed.)', p.Name);
        System.assertEquals('900', p.NFT_Shopify_Product_Id__c);
        System.assertEquals('Shoes', p.Family);
        System.assertEquals(7, p.NFT_Total_On_Hand__c);
        System.assertEquals('https://shop.example.com/products/x', p.DisplayUrl);
        System.assert(!p.NFY_Demo__c);
        System.assertEquals(175, price(p.Id, cur));
    }

    @IsTest
    static void sameSkuFromBothSourcesIsOneProduct() {
        String cur = otherCurrency();
        Test.startTest();
        // Odoo first, then Shopify: Shopify links by SKU and may not change Odoo-owned fields
        send('ODOO_SHOP', odoo('601', 'TST-BOTH-1', 'Odoo Name', 80));
        NFY_IntegrationService.Result s = send('SHOPIFY', shopify('8001', 'TST-BOTH-1', 'Shopify Name', 999, corporate()));
        // Shopify first, then Odoo: Odoo links by SKU and takes over the catalogue fields
        send('SHOPIFY', shopify('8002', 'TST-BOTH-2', 'Shopify First', 50, cur == null ? corporate() : cur));
        NFY_IntegrationService.Result o = send('ODOO_SHOP', odoo('602', 'TST-BOTH-2', 'Odoo Takes Over', 60));
        Test.stopTest();

        System.assert(s.success, s.message);
        Product2 p1 = [SELECT Name, Description, NFY_Odoo_Product_Id__c, NFT_Shopify_Variant_Id__c, DisplayUrl FROM Product2 WHERE ProductCode = 'TST-BOTH-1'];
        System.assertEquals('Odoo Name', p1.Name);
        System.assertEquals('Odoo description of Odoo Name', p1.Description);
        System.assertEquals('601', p1.NFY_Odoo_Product_Id__c);
        System.assertEquals('8001', p1.NFT_Shopify_Variant_Id__c);
        System.assertEquals('https://shop.example.com/products/x', p1.DisplayUrl);
        System.assertEquals(80, price(p1.Id, corporate()), 'Shopify may not overwrite the Odoo price in the corporate currency');
        System.assert(log(s.logId).Response__c.contains('Kept Odoo-owned'), log(s.logId).Response__c);
        System.assertEquals('Updated', log(s.logId).Operation__c);

        System.assert(o.success, o.message);
        Product2 p2 = [SELECT Name, NFY_Odoo_Product_Id__c, NFT_Shopify_Variant_Id__c, NFY_Demo__c FROM Product2 WHERE ProductCode = 'TST-BOTH-2'];
        System.assertEquals('Odoo Takes Over', p2.Name);
        System.assertEquals('602', p2.NFY_Odoo_Product_Id__c);
        System.assertEquals('8002', p2.NFT_Shopify_Variant_Id__c);
        System.assert(p2.NFY_Demo__c);
        System.assertEquals(2, [SELECT COUNT() FROM Product2 WHERE ProductCode IN ('TST-BOTH-1', 'TST-BOTH-2')]);
    }

    /** A second Odoo product saved with an Internal Reference another Odoo product already owns is refused; the first keeps its product. */
    @IsTest
    static void duplicateSkuFromAnotherOdooProductIsRefused() {
        Test.startTest();
        NFY_IntegrationService.Result first = send('ODOO_SHOP', odoo('801', 'TST-DUP-1', 'Original Shoe', 109));
        NFY_IntegrationService.Result dup = send('ODOO_SHOP', odoo('802', 'TST-DUP-1', 'Duplicate Shoe', 99));
        Test.stopTest();
        System.assert(first.success, first.message);
        System.assertEquals('Failed', dup.status);
        System.assert(dup.message.contains('Mapping conflict') && dup.message.contains('801'), dup.message);
        Product2 p = [SELECT Name, NFY_Odoo_Product_Id__c FROM Product2 WHERE ProductCode = 'TST-DUP-1'];
        System.assertEquals('801', p.NFY_Odoo_Product_Id__c);
        System.assertEquals('Original Shoe', p.Name);
        System.assertEquals(109, price(p.Id, corporate()));
    }

    @IsTest
    static void badDataIsRejectedAndLogged() {
        insert new List<Product2>{ new Product2(Name = 'Twin A', ProductCode = 'TST-TWIN'), new Product2(Name = 'Twin B', ProductCode = 'TST-TWIN') };
        Test.startTest();
        NFY_IntegrationService.Result noSku = send('ODOO_SHOP', odoo('701', '', 'No SKU', 10));
        NFY_IntegrationService.Result twin = send('ODOO_SHOP', odoo('702', 'TST-TWIN', 'Twin', 10));
        send('ODOO_SHOP', odoo('703', 'TST-OWN-1', 'Owned', 10));
        send('ODOO_SHOP', odoo('704', 'TST-OWN-2', 'Owned 2', 10));
        NFY_IntegrationService.Result conflict = send('ODOO_SHOP', odoo('703', 'TST-OWN-2', 'Owned', 10));
        Map<String, Object> badCurrency = odoo('705', 'TST-CUR', 'Currency', 10);
        badCurrency.put('currency', 'XXX');
        NFY_IntegrationService.Result cur = send('ODOO_SHOP', badCurrency);
        send('SHOPIFY', shopify('9001', 'TST-OWN-1', 'Owned', 10, corporate()));
        NFY_IntegrationService.Result skuChange = send('SHOPIFY', shopify('9001', 'TST-OWN-1-B', 'Owned', 10, corporate()));
        NFY_IntegrationService.Result badSource = NFY_IntegrationService.process('product.upsert', 'AMAZON', JSON.serialize(odoo('1', 'X', 'X', 1)), 'j', 'Workato');
        Map<String, Object> badPrice = odoo('706', 'TST-PRICE', 'Price', -5);
        NFY_IntegrationService.Result neg = send('ODOO_SHOP', badPrice);
        Test.stopTest();

        System.assertEquals('Failed', noSku.status);
        System.assertEquals('Validation', log(noSku.logId).Error_Category__c);
        System.assertEquals('Rejected', log(noSku.logId).Operation__c);
        System.assertEquals('Mapping', log(twin.logId).Error_Category__c, log(twin.logId).Error_Message__c);
        System.assertEquals('Mapping', log(conflict.logId).Error_Category__c, log(conflict.logId).Error_Message__c);
        System.assertEquals('Validation', log(cur.logId).Error_Category__c, log(cur.logId).Error_Message__c);
        System.assertEquals('Mapping', log(skuChange.logId).Error_Category__c, log(skuChange.logId).Error_Message__c);
        System.assertEquals('Failed', badSource.status);
        System.assertEquals('Failed', neg.status);
        System.assertEquals(0, [SELECT COUNT() FROM Product2 WHERE ProductCode IN ('TST-CUR', 'TST-PRICE') OR NFY_Odoo_Product_Id__c IN ('701', '702')]);
        System.assertEquals('TST-OWN-1', [SELECT ProductCode FROM Product2 WHERE NFY_Odoo_Product_Id__c = '703'].ProductCode);
    }
}