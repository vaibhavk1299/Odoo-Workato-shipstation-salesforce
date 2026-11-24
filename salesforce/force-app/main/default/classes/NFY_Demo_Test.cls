/**
 * Runs every demo scene against a fresh TC ledger. Each method maps to the feature tests in the
 * scope (T05-T26), so a green run here is the automated half of the rehearsal checklist.
 */
@IsTest
private class NFY_Demo_Test {

    @TestSetup
    static void setup() {
        User u = TC_TestFactory.accountant();
        System.runAs(u) {
            TC_TestFactory.setup();
            NFY_DemoData.seedReference();
            NFY_DemoData.seedStock();
        }
    }

    private static User accountant() {
        return [SELECT Id FROM User WHERE Username LIKE 'tc.accountant.%' ORDER BY CreatedDate DESC LIMIT 1];
    }

    private static Decimal available(String sku, String locationCode) {
        List<TC_Inventory_Balance__c> b = [SELECT Available_Quantity__c FROM TC_Inventory_Balance__c WHERE Product__r.ProductCode = :sku AND Location__r.NFY_Code__c = :locationCode];
        return b.isEmpty() || b[0].Available_Quantity__c == null ? 0 : b[0].Available_Quantity__c;
    }

    private static TC_Sales_Order__c so(String orderNo) {
        return [SELECT Id, NFY_Fulfillment_Status__c, Status__c, NFY_Routing_Decision__c,
                    (SELECT Product__r.ProductCode, NFY_Ship_From__r.NFY_Code__c, Quantity_Allocated__c FROM Sales_Order_Lines__r)
                FROM TC_Sales_Order__c WHERE NFY_External_Order_Id__c = :orderNo];
    }

    // T05-T09
    @IsTest
    static void shopifyOrderFallsBackAndBills() {
        System.runAs(accountant()) {
            Decimal pa1Before = available('840386208702', 'SM-PA1-AVL');
            NFY_SimulatorController.SceneResult r = NFY_SimulatorController.shopifyOrder(true);
            System.assert(r.results[0].success, r.results[0].message);
            String no = r.reference;
            TC_Sales_Order__c s = so(no);
            System.assertEquals('Awaiting Shipment', s.NFY_Fulfillment_Status__c);
            for (TC_Sales_Order_Line__c l : s.Sales_Order_Lines__r) {
                if (l.Product__r.ProductCode == '840386215403') {
                    System.assertEquals('MAIN', l.NFY_Ship_From__r.NFY_Code__c, 'Youth size is not stocked at PA1 and falls back to Main');
                }
            }
            System.assertEquals(pa1Before - 1, available('840386208702', 'SM-PA1-AVL'));

            Test.startTest();
            NFY_SimulatorController.shipFrom(no, 'SM-PA1');
            System.assertEquals('Partially Shipped', so(no).NFY_Fulfillment_Status__c);
            NFY_SimulatorController.SceneResult last = NFY_SimulatorController.shipFrom(no, 'MAIN');
            Test.stopTest();
            System.assert(last.results[0].success, last.results[0].message);
            s = so(no);
            System.assertEquals('Billed', s.NFY_Fulfillment_Status__c);
            System.assertEquals('Closed', s.Status__c);
            TC_Billing__c b = [SELECT Status__c, Customer__r.NFY_External_Customer_Id__c FROM TC_Billing__c WHERE Sales_Order__c = :s.Id];
            System.assertEquals('Posted', b.Status__c);
            System.assertEquals('PAYER-SHOPIFY', b.Customer__r.NFY_External_Customer_Id__c);
            System.assertEquals(2, [SELECT COUNT() FROM TC_Shipment__c WHERE Sales_Order__c = :s.Id AND Status__c = 'Shipped']);
        }
    }

    // T05-T06: the order is recorded once, with its Opportunity, however often Shopify sends it
    @IsTest
    static void shopifyOrderIsRecordedOnce() {
        System.runAs(accountant()) {
            Test.startTest();
            NFY_SimulatorController.SceneResult r = NFY_SimulatorController.shopifyOrder(true);
            NFY_SimulatorController.SceneResult dup = NFY_SimulatorController.resendLastOrder();
            Test.stopTest();
            System.assert(r.results[0].success, r.results[0].message);
            System.assertEquals('Duplicate skipped', dup.results[0].status);
            System.assertEquals(1, [SELECT COUNT() FROM Order WHERE NFY_External_Order_Id__c = :r.reference]);
            System.assertEquals(1, [SELECT COUNT() FROM Opportunity WHERE Name = :r.reference AND StageName = 'Closed Won']);
        }
    }

    // S9: more requested than stock; the shortfall is backordered and filled when stock arrives
    @IsTest
    static void shortfallIsBackorderedThenFilled() {
        System.runAs(accountant()) {
            NFY_SimulatorController.SceneResult r = NFY_SimulatorController.shortfallOrder();
            System.assert(r.results[0].success, r.results[0].message);
            TC_Sales_Order__c s = [SELECT NFY_Fulfillment_Status__c, NFY_Stock_Status__c, NFY_Units_Requested__c, NFY_Units_Assigned__c, NFY_Units_Short__c,
                                       (SELECT NFY_Stock_Status__c, NFY_Short_Qty__c, NFY_Ship_From__r.NFY_Code__c FROM Sales_Order_Lines__r)
                                   FROM TC_Sales_Order__c WHERE NFY_External_Order_Id__c = :r.reference];
            System.assertEquals('Received', s.NFY_Fulfillment_Status__c, 'Not fully covered, so not ready to ship in full');
            System.assertEquals('Partially assigned', s.NFY_Stock_Status__c);
            System.assertEquals(s.NFY_Units_Requested__c - s.NFY_Units_Assigned__c, s.NFY_Units_Short__c);
            System.assertEquals(40, s.NFY_Units_Short__c);
            System.assertEquals('SM-NV3', s.Sales_Order_Lines__r[0].NFY_Ship_From__r.NFY_Code__c, 'The ship-from is fixed to NV3, so no fallback');
            System.assertEquals('Partially assigned', s.Sales_Order_Lines__r[0].NFY_Stock_Status__c);
            System.assertEquals('Partially assigned', [SELECT NFY_Stock_Status__c FROM Order WHERE NFY_External_Order_Id__c = :r.reference].NFY_Stock_Status__c);

            Test.startTest();
            NFY_SimulatorController.SceneResult arrive = NFY_SimulatorController.stockArrives(r.reference);
            Test.stopTest();
            System.assert(arrive.results[0].success, arrive.results[0].message);
            System.assert(arrive.results[0].message.contains('Backorders: 40 units assigned'), arrive.results[0].message);
            s = [SELECT NFY_Fulfillment_Status__c, NFY_Stock_Status__c, NFY_Units_Short__c FROM TC_Sales_Order__c WHERE NFY_External_Order_Id__c = :r.reference];
            System.assertEquals('Fully assigned', s.NFY_Stock_Status__c);
            System.assertEquals(0, s.NFY_Units_Short__c);
            System.assertEquals('Awaiting Shipment', s.NFY_Fulfillment_Status__c);
        }
    }

    // T10-T12
    @IsTest
    static void fbaInboundShortReceiptOpensRecon() {
        System.runAs(accountant()) {
            Decimal mainBefore = available('840386208702', 'MAIN-AVL');
            Decimal fbaBefore = available('840386208702', 'FBA-US-AVL');
            String id = NFY_SimulatorController.fbaInboundPlan('840386208702', 240).reference;
            System.assertEquals(mainBefore, available('840386208702', 'MAIN-AVL'), 'Planning does not move stock');
            Test.startTest();
            NFY_SimulatorController.SceneResult shipped = NFY_SimulatorController.fbaInboundShipped(id);
            System.assert(shipped.results[0].success, shipped.results[0].message);
            System.assertEquals(mainBefore - 240, available('840386208702', 'MAIN-AVL'));
            System.assertEquals(240, available('840386208702', 'FBA-US-TRANSIT'));
            NFY_SimulatorController.SceneResult r = NFY_SimulatorController.fbaInboundReceived(id, 3);
            Test.stopTest();
            System.assert(r.results[0].success, r.results[0].message);
            System.assertEquals(fbaBefore + 237, available('840386208702', 'FBA-US-AVL'));
            System.assertEquals(3, available('840386208702', 'FBA-US-TRANSIT'));
            NFY_Inventory_Recon__c rec = [SELECT Status__c, Variance__c FROM NFY_Inventory_Recon__c WHERE Inbound_Shipment__r.External_Id__c = :id];
            System.assertEquals('Open', rec.Status__c);
            System.assertEquals(-3, rec.Variance__c);
        }
    }

    // T13
    @IsTest
    static void amazonFbaOrderShipsFromFba() {
        System.runAs(accountant()) {
            Decimal fbaBefore = available('840386208702', 'FBA-US-AVL');
            NFY_SimulatorController.SceneResult fba = NFY_SimulatorController.amazonOrder(false);
            System.assert(fba.results[0].success, fba.results[0].message);
            System.assertEquals(fbaBefore - 1, available('840386208702', 'FBA-US-AVL'));
            Test.startTest();
            NFY_SimulatorController.SceneResult ship = NFY_SimulatorController.shipFrom(fba.reference, 'FBA-US');
            Test.stopTest();
            System.assert(ship.results[0].success, ship.results[0].message);
            System.assertEquals('Billed', so(fba.reference).NFY_Fulfillment_Status__c);
            System.assertEquals('PAYER-AMAZON', [SELECT Customer__r.NFY_External_Customer_Id__c FROM TC_Billing__c WHERE Sales_Order__r.NFY_External_Order_Id__c = :fba.reference].Customer__r.NFY_External_Customer_Id__c);
        }
    }

    // T13 (MCF)
    @IsTest
    static void mcfOrderIsShopifySaleFromFba() {
        System.runAs(accountant()) {
            NFY_SimulatorController.SceneResult mcf = NFY_SimulatorController.amazonOrder(true);
            System.assert(mcf.results[0].success, mcf.results[0].message);
            TC_Sales_Order__c s = so(mcf.reference);
            System.assertEquals('FBA-US', s.Sales_Order_Lines__r[0].NFY_Ship_From__r.NFY_Code__c);
            System.assertEquals('Amazon MCF', [SELECT NFY_Channel__c FROM Order WHERE NFY_External_Order_Id__c = :mcf.reference].NFY_Channel__c);
        }
    }

    // T14 (sellable)
    @IsTest
    static void sellableReturnIsRestocked() {
        System.runAs(accountant()) {
            NFY_SimulatorController.SceneResult fba = NFY_SimulatorController.amazonOrder(false);
            Test.startTest();
            NFY_SimulatorController.shipFrom(fba.reference, 'FBA-US');
            Decimal fbaAfterSale = available('840386208702', 'FBA-US-AVL');
            NFY_SimulatorController.SceneResult ret = NFY_SimulatorController.amazonReturn('Sellable');
            Test.stopTest();
            System.assert(ret.results[0].success, ret.results[0].message);
            System.assertEquals(fbaAfterSale + 1, available('840386208702', 'FBA-US-AVL'));
            NFY_Return__c r = [SELECT Status__c, Credit_Memo__r.Status__c FROM NFY_Return__c];
            System.assertEquals('Restocked', r.Status__c);
            System.assertEquals('Posted', r.Credit_Memo__r.Status__c);
        }
    }

    // T14 (unfulfillable)
    @IsTest
    static void unfulfillableReturnIsNotRestocked() {
        System.runAs(accountant()) {
            NFY_SimulatorController.SceneResult fba = NFY_SimulatorController.amazonOrder(false);
            Test.startTest();
            NFY_SimulatorController.shipFrom(fba.reference, 'FBA-US');
            Decimal fbaAfterSale = available('840386208702', 'FBA-US-AVL');
            NFY_SimulatorController.SceneResult ret = NFY_SimulatorController.amazonReturn('Unfulfillable');
            Test.stopTest();
            System.assert(ret.results[0].success, ret.results[0].message);
            System.assertEquals(fbaAfterSale, available('840386208702', 'FBA-US-AVL'));
            System.assertEquals('Written off', [SELECT Status__c FROM NFY_Return__c].Status__c);
        }
    }

    // T15
    @IsTest
    static void b2bOrderShipsFromTwoLocations() {
        System.runAs(accountant()) {
            NFY_SimulatorController.SceneResult r = NFY_SimulatorController.b2bOrder();
            System.assert(r.results[0].success, r.results[0].message);
            TC_Purchase_Order__c drop = [SELECT Type__c, Status__c, (SELECT Quantity__c FROM Purchase_Order_Lines__r) FROM TC_Purchase_Order__c WHERE NFY_External_Id__c = :(r.reference + '-DS')];
            System.assertEquals('Drop Shipment', drop.Type__c);
            System.assertEquals(24, drop.Purchase_Order_Lines__r[0].Quantity__c);
            Test.startTest();
            NFY_SimulatorController.shipFrom(r.reference, 'MAIN');
            NFY_SimulatorController.SceneResult cw = NFY_SimulatorController.shipFrom(r.reference, 'CUSTOMWEAR');
            Test.stopTest();
            System.assert(cw.results[0].success, cw.results[0].message);
            System.assertEquals('Partially Shipped', so(r.reference).NFY_Fulfillment_Status__c, 'The factory line is still to ship');
            System.assertEquals('Decorator', [SELECT NFY_Label_System__c FROM TC_Shipment__c WHERE NFY_Ship_From__r.NFY_Code__c = 'CUSTOMWEAR' LIMIT 1].NFY_Label_System__c);
        }
    }

    // T15 (Direct from Factory)
    @IsTest
    static void factoryLineShipsAsDropShip() {
        System.runAs(accountant()) {
            NFY_SimulatorController.SceneResult r = NFY_SimulatorController.b2bOrder();
            Test.startTest();
            NFY_SimulatorController.SceneResult f = NFY_SimulatorController.shipFrom(r.reference, 'FACTORY');
            Test.stopTest();
            System.assert(f.results[0].success, f.results[0].message);
            System.assertEquals('Factory (direct)', [SELECT NFY_Label_System__c FROM TC_Shipment__c WHERE NFY_Ship_From__r.NFY_Code__c = 'FACTORY' LIMIT 1].NFY_Label_System__c);
            System.assertEquals('Closed', [SELECT Status__c FROM TC_Purchase_Order__c WHERE NFY_External_Id__c = :(r.reference + '-DS')].Status__c);
            System.assertEquals(24, [SELECT SUM(Quantity__c) q FROM TC_PO_Inventory_Movement__c WHERE Purchase_Order_Line__r.Purchase_Order__r.NFY_External_Id__c = :(r.reference + '-DS')][0].get('q'));
        }
    }

    // Orders entered by hand go to fulfilment by themselves when activated, with any price book and any product.
    @IsTest
    static void activatingAHandEnteredOrderSendsItAutomatically() {
        System.runAs(accountant()) {
            Account acct = new Account(Name = 'Walk-in Wholesale Co.', BillingCity = 'Atlanta');
            insert acct;
            Pricebook2 other = new Pricebook2(Name = 'Partner Price Book', IsActive = true);
            insert other;
            Product2 outside = new Product2(Name = 'Install service (not stocked)', ProductCode = 'SVC-1', IsActive = true);
            insert outside;
            insert new PricebookEntry(Pricebook2Id = NFY_Ref.pricebook(), Product2Id = outside.Id, UnitPrice = 50, IsActive = true);
            insert new PricebookEntry(Pricebook2Id = other.Id, Product2Id = outside.Id, UnitPrice = 50, IsActive = true);
            System.assert(NFY_DemoData.seedPriceBooks() > 0, 'Nfinity products are added to the other price book');
            Product2 shoe = NFY_Ref.product('840386208701');
            Id shoeEntry = [SELECT Id FROM PricebookEntry WHERE Pricebook2Id = :other.Id AND Product2Id = :shoe.Id].Id;
            Id outsideEntry = [SELECT Id FROM PricebookEntry WHERE Pricebook2Id = :other.Id AND Product2Id = :outside.Id].Id;

            Order stocked = new Order(AccountId = acct.Id, EffectiveDate = Date.today(), Status = 'Draft', Pricebook2Id = other.Id);
            Order serviceOnly = new Order(AccountId = acct.Id, EffectiveDate = Date.today(), Status = 'Draft', Pricebook2Id = other.Id);
            insert new List<Order>{ stocked, serviceOnly };
            OrderItem shoeItem = new OrderItem(OrderId = stocked.Id, PricebookEntryId = shoeEntry, Quantity = 2, UnitPrice = 99.99);
            insert new List<OrderItem>{ shoeItem,
                new OrderItem(OrderId = stocked.Id, PricebookEntryId = outsideEntry, Quantity = 1, UnitPrice = 50),
                new OrderItem(OrderId = serviceOnly.Id, PricebookEntryId = outsideEntry, Quantity = 3, UnitPrice = 50) };

            Test.startTest();
            NFY_OrderFulfilmentController.activate(stocked.Id, 'MAIN', new Map<String, String>{ String.valueOf(shoeItem.Id) => 'SM-PA1' });
            Test.stopTest();

            Order after = [SELECT Status, NFY_TC_Sales_Order__c, NFY_Fulfillment_Status__c, NFY_Ship_From__r.NFY_Code__c FROM Order WHERE Id = :stocked.Id];
            System.assertEquals('Activated', after.Status);
            System.assertNotEquals(null, after.NFY_TC_Sales_Order__c, 'Activation sent the order to fulfilment');
            System.assertEquals('Awaiting Shipment', after.NFY_Fulfillment_Status__c);
            System.assertEquals('MAIN', after.NFY_Ship_From__r.NFY_Code__c);
            for (TC_Sales_Order_Line__c l : [SELECT Product__c, NFY_Ship_From__r.NFY_Code__c, Quantity_Allocated__c FROM TC_Sales_Order_Line__c WHERE Sales_Order__c = :after.NFY_TC_Sales_Order__c]) {
                if (l.Product__c == shoe.Id) {
                    System.assertEquals('SM-PA1', l.NFY_Ship_From__r.NFY_Code__c, 'The per-line choice saved on the order product is used');
                    System.assertEquals(2, l.Quantity_Allocated__c);
                } else {
                    System.assertEquals(null, l.NFY_Ship_From__c, 'Products Nfinity does not stock are not reserved');
                }
            }

            NFY_IntegrationService.Result r = NFY_OrderFulfilmentController.send(serviceOnly.Id, null, null);
            System.assert(r.success, r.message);
            TC_Sales_Order__c s = [SELECT NFY_Fulfillment_Status__c, Status__c FROM TC_Sales_Order__c WHERE NFY_Order__c = :serviceOnly.Id];
            System.assertEquals('Billed', s.NFY_Fulfillment_Status__c, 'Nothing to ship, so it is billed straight away');
            System.assertEquals('Closed', s.Status__c);
            System.assertEquals('Posted', [SELECT Status__c FROM TC_Billing__c WHERE Sales_Order__c = :s.Id].Status__c);
        }
    }

    // Orders entered by hand in Salesforce
    @IsTest
    static void manualOrderGoesToFulfilment() {
        System.runAs(accountant()) {
            Account gym = new Account(Name = 'Hand-entered Allstars', BillingCity = 'Atlanta', BillingState = 'GA');
            insert gym;
            Order o = new Order(AccountId = gym.Id, EffectiveDate = Date.today(), Status = 'Draft', Pricebook2Id = NFY_Ref.pricebook());
            insert o;
            Product2 shoe = NFY_Ref.product('840386211202');
            Product2 rival = NFY_Ref.product('840386219109');
            Product2 freight = NFY_Ref.product(NFY_Ref.FREIGHT_SKU);
            OrderItem shoeItem = new OrderItem(OrderId = o.Id, Product2Id = shoe.Id, PricebookEntryId = NFY_Ref.priceEntry(shoe.Id), Quantity = 6, UnitPrice = 129.99);
            OrderItem rivalItem = new OrderItem(OrderId = o.Id, Product2Id = rival.Id, PricebookEntryId = NFY_Ref.priceEntry(rival.Id), Quantity = 10, UnitPrice = 89.99);
            insert new List<OrderItem>{ shoeItem, rivalItem,
                new OrderItem(OrderId = o.Id, Product2Id = freight.Id, PricebookEntryId = NFY_Ref.priceEntry(freight.Id), Quantity = 1, UnitPrice = 25) };

            NFY_OrderFulfilmentController.Context before = NFY_OrderFulfilmentController.getContext(o.Id);
            System.assertEquals(false, before.sent);
            System.assertEquals(3, before.lines.size());
            System.assert(!before.warehouses.isEmpty());

            Test.startTest();
            NFY_IntegrationService.Result r = NFY_OrderFulfilmentController.send(o.Id, 'MAIN', new Map<String, String>{ String.valueOf(rivalItem.Id) => 'FACTORY' });
            System.assert(r.success, r.message);
            NFY_IntegrationService.Result again = NFY_OrderFulfilmentController.send(o.Id, 'MAIN', null);
            NFY_IntegrationService.Result ship = NFY_OrderFulfilmentController.recordShipment(o.Id, 'MAIN');
            Test.stopTest();
            System.assert(again.success && again.message.contains('already'), 'A second send changes nothing: ' + again.message);
            System.assertEquals(1, [SELECT COUNT() FROM TC_Sales_Order__c WHERE NFY_Order__c = :o.Id]);
            System.assert(ship.success, ship.message);

            Order after = [SELECT Status, NFY_TC_Sales_Order__c, NFY_External_Order_Id__c, NFY_Sales_Rep__c, BillToContactId FROM Order WHERE Id = :o.Id];
            System.assertEquals('Activated', after.Status);
            System.assertEquals(1, [SELECT COUNT() FROM Order WHERE AccountId = :gym.Id], 'The rep\'s order is used, not copied');
            System.assertNotEquals(null, after.NFY_Sales_Rep__c);
            System.assertNotEquals(null, after.BillToContactId);
            TC_Sales_Order__c s = so(after.NFY_External_Order_Id__c);
            System.assertEquals('Partially Shipped', s.NFY_Fulfillment_Status__c);
            for (TC_Sales_Order_Line__c l : s.Sales_Order_Lines__r) {
                if (l.Product__r.ProductCode == '840386219109') {
                    System.assertEquals('FACTORY', l.NFY_Ship_From__r.NFY_Code__c);
                }
            }
            NFY_OrderFulfilmentController.Context ctx = NFY_OrderFulfilmentController.getContext(o.Id);
            System.assertEquals(true, ctx.sent);
            System.assertEquals(1, ctx.pending.size());
            System.assertEquals('FACTORY', ctx.pending[0].code);
        }
    }

    // T16-T17
    @IsTest
    static void factoryPoSplitReceipt() {
        System.runAs(accountant()) {
            NFY_SimulatorController.SceneResult po = NFY_SimulatorController.factoryPo();
            System.assert(po.results[0].success, po.results[0].message);
            Decimal mainBefore = available('840386208702', 'MAIN-AVL');
            Test.startTest();
            NFY_SimulatorController.SceneResult r = NFY_SimulatorController.receivePo(po.reference);
            Test.stopTest();
            System.assert(r.results[1].success, r.results[1].message);
            System.assertEquals(mainBefore + 600, available('840386208702', 'MAIN-AVL'));
            System.assertEquals('Closed', [SELECT Status__c FROM TC_Purchase_Order__c WHERE NFY_External_Id__c = :po.reference].Status__c);
            System.assertEquals('Closed', [SELECT Status__c FROM NFY_Inbound_Shipment__c WHERE Purchase_Order__r.NFY_External_Id__c = :po.reference].Status__c);
        }
    }

    // T18-T19
    @IsTest
    static void netherlandsThreePlPlugsIn() {
        System.runAs(accountant()) {
            NFY_SimulatorController.onboardNetherlands();
            System.assertEquals(6, [SELECT COUNT() FROM NFY_Integration_Flow__c WHERE System__r.Code__c = 'ODOO']);
            Test.startTest();
            NFY_SimulatorController.SceneResult eu = NFY_SimulatorController.euOrder();
            System.assert(eu.results[0].success, eu.results[0].message);
            NFY_SimulatorController.SceneResult ship = NFY_SimulatorController.shipFrom(eu.reference, 'NL-ODOO');
            Test.stopTest();
            System.assert(ship.results[0].success, ship.results[0].message);
            System.assertEquals('Billed', so(eu.reference).NFY_Fulfillment_Status__c);
            System.assertEquals(59, available('840386208702', 'NL-ODOO-AVL'));
        }
    }

    // T20-T22
    @IsTest
    static void failedShipmentRetriesAfterOrderSync() {
        System.runAs(accountant()) {
            NFY_SimulatorController.SceneResult fail = NFY_SimulatorController.shipStationFailure();
            System.assertEquals('Failed', fail.results[0].status);
            System.assertEquals(0, [SELECT COUNT() FROM TC_Shipment__c WHERE Sales_Order__r.NFY_External_Order_Id__c = :fail.reference]);
            Test.startTest();
            NFY_SimulatorController.runOrderSyncFor(fail.reference);
            NFY_SimulatorController.SceneResult again = NFY_SimulatorController.retry(fail.results[0].logId);
            Test.stopTest();
            System.assert(again.results[0].success, again.results[0].message);
            NFY_Sync_Log__c log = [SELECT Status__c, Attempts__c, Resolved__c FROM NFY_Sync_Log__c WHERE Id = :fail.results[0].logId];
            System.assertEquals('Success', log.Status__c);
            System.assertEquals(2, log.Attempts__c);
            System.assertEquals(1, [SELECT COUNT() FROM TC_Shipment__c WHERE Sales_Order__r.NFY_External_Order_Id__c = :fail.reference]);
        }
    }

    // T23-T25
    @IsTest
    static void snapshotAndSettlement() {
        System.runAs(accountant()) {
            NFY_SimulatorController.SceneResult snap = NFY_SimulatorController.stockSnapshot('SM-PA1');
            System.assert(snap.results[0].success, snap.results[0].message);
            System.assertEquals(2, [SELECT COUNT() FROM NFY_Inventory_Recon__c WHERE Status__c = 'Open']);
            NFY_SimulatorController.SceneResult o = NFY_SimulatorController.shopifyOrder(false);
            Test.startTest();
            NFY_SimulatorController.shipFrom(o.reference, 'SM-PA1');
            NFY_SimulatorController.SceneResult st = NFY_SimulatorController.settlement('SHOPIFY');
            Test.stopTest();
            System.assert(st.results[0].success, st.results[0].message);
            NFY_Settlement__c s = [SELECT Status__c, Matched_Billings__c, Unmatched_Amount__c, Journal_Entry__r.Status__c FROM NFY_Settlement__c];
            System.assertEquals(1, s.Matched_Billings__c);
            System.assertEquals('Exceptions', s.Status__c);
            System.assertEquals(129.99, s.Unmatched_Amount__c);
            System.assertEquals('Posted', s.Journal_Entry__r.Status__c);
        }
    }

    @IsTest
    static void ordersGetSampleContacts() {
        System.runAs(accountant()) {
            NFY_SimulatorController.SceneResult o = NFY_SimulatorController.shopifyOrder(false);
            System.assert(o.results[0].success, o.results[0].message);
            Order ord = [SELECT BillToContact.Email, BillToContact.Phone, ShipToContactId, Account.Phone FROM Order WHERE Id = :o.recordId];
            System.assert(NFY_SimulatorController.EMAILS.contains(ord.BillToContact.Email));
            System.assertEquals('123457890', ord.BillToContact.Phone);
            System.assertEquals('123457890', ord.Account.Phone);
            System.assertNotEquals(null, ord.ShipToContactId);
            Test.startTest();
            Integer created = NFY_DemoData.backfillContacts();
            Test.stopTest();
            System.assertEquals(4, created, 'Payers and the factory get a contact; the customer already has one');
            System.assertEquals(0, [SELECT COUNT() FROM Account WHERE NFY_Demo__c = true AND Phone != '123457890' AND NFY_External_Customer_Id__c != null]);
        }
    }

    // T03-T04 and the Order Journey
    @IsTest
    static void commandCenterAndJourney() {
        System.runAs(accountant()) {
            NFY_SimulatorController.SceneResult o = NFY_SimulatorController.shopifyOrder(false);
            NFY_SimulatorController.shipStationFailure();
            Test.startTest();
            NFY_CommandCenterController.Summary s = NFY_CommandCenterController.getSummary();
            List<Map<String, Object>> matrix = NFY_CommandCenterController.getStockMatrix('Footwear');
            NFY_OrderJourneyController.Journey j = NFY_OrderJourneyController.getJourney(o.recordId);
            Test.stopTest();
            System.assert(!s.systems.isEmpty());
            System.assertEquals(1, s.failures.size());
            System.assert(!matrix.isEmpty());
            System.assertEquals(o.reference, j.orderNumber);
            System.assertEquals(1, j.stageIndex);
            System.assert(!j.steps.isEmpty());
        }
    }

    @IsTest
    static void restApi() {
        System.runAs(accountant()) {
            Map<String, Object> payload = NFY_SimulatorController.order('#SPFY999001', 'Shopify .com', NFY_SimulatorController.customer('Shopify .com'), 'MAIN',
                new List<Object>{ NFY_SimulatorController.line('840386208701', 1) }, Date.today());
            RestRequest req = new RestRequest();
            req.requestURI = '/services/apexrest/nfinity/v1/events';
            req.httpMethod = 'POST';
            req.requestBody = Blob.valueOf(JSON.serialize(new Map<String, Object>{ 'event' => 'order.upsert', 'source' => 'SHOPIFY', 'jobId' => 'j-1', 'payload' => payload }));
            RestContext.request = req;
            RestContext.response = new RestResponse();
            Test.startTest();
            NFY_IntegrationApi.receive();
            System.assertEquals(200, RestContext.response.statusCode, RestContext.response.responseBody.toString());
            req.requestBody = Blob.valueOf('not json');
            NFY_IntegrationApi.receive();
            System.assertEquals(400, RestContext.response.statusCode);
            payload.put('orderNumber', '#SPFY999002');
            req.requestBody = Blob.valueOf(JSON.serialize(new Map<String, Object>{ 'event' => 'order.upsert', 'source' => 'NOPE', 'payload' => payload }));
            NFY_IntegrationApi.receive();
            System.assertEquals(422, RestContext.response.statusCode);
            NFY_IntegrationApi.health();
            Test.stopTest();
            System.assertEquals('j-1', [SELECT Workato_Job_Id__c FROM NFY_Sync_Log__c WHERE External_Id__c = '#SPFY999001' AND Status__c = 'Success'].Workato_Job_Id__c);
        }
    }

    @IsTest
    static void historyReplay() {
        System.runAs(accountant()) {
            Test.startTest();
            Database.executeBatch(new NFY_HistoryBatch(0, 1, 0), 1);
            Test.stopTest();
            System.assert([SELECT COUNT() FROM Order WHERE NFY_Demo__c = true] >= 1);
            System.assert([SELECT COUNT() FROM NFY_Sync_Log__c WHERE Received_At__c < TODAY] >= 1);
        }
    }

    @IsTest
    static void openItemsAndLogHistory() {
        System.runAs(accountant()) {
            Test.startTest();
            NFY_DemoData.seedOpenItems();
            Test.stopTest();
            System.assertEquals(2, [SELECT COUNT() FROM NFY_Inbound_Shipment__c]);
            System.assert([SELECT COUNT() FROM NFY_Sync_Log__c WHERE Status__c = 'Failed'] > 0);
        }
    }

    @IsTest
    static void resetBatchRuns() {
        System.runAs(accountant()) {
            Test.startTest();
            Database.executeBatch(new NFY_ResetBatch(System.now()), 200);
            Test.stopTest();
            System.assertEquals(0, [SELECT COUNT() FROM NFY_Sync_Log__c]);
        }
    }

    // T02
    @IsTest
    static void resetRemovesDemoTransactions() {
        System.runAs(accountant()) {
            NFY_SimulatorController.SceneResult o = NFY_SimulatorController.shopifyOrder(false);
            System.assert(o.results[0].success, o.results[0].message);
            Test.startTest();
            for (Integer step = 0; step <= NFY_DemoData.LAST_STEP; step++) {
                Integer guard = 0;
                while (NFY_DemoData.runStep(step, null) && guard < 5) {
                    guard++;
                }
            }
            Test.stopTest();
            System.assertEquals(0, [SELECT COUNT() FROM Order WHERE NFY_Demo__c = true]);
            System.assertEquals(0, [SELECT COUNT() FROM TC_Sales_Order__c WHERE NFY_Demo__c = true]);
            System.assertEquals(0, [SELECT COUNT() FROM NFY_Sync_Log__c]);
            System.assertEquals(0, [SELECT COUNT() FROM TC_Inbound_Inventory_Movement__c WHERE Inventory_Balance__r.Product__r.NFY_Demo__c = true]);
        }
    }
}