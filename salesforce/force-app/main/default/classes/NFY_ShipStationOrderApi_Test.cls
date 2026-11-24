/**
 * The ShipStation order endpoint sends only released orders, only lines at ShipStation-operated warehouses,
 * and never an order another active flow already delivers to ShipStation.
 */
@IsTest
private class NFY_ShipStationOrderApi_Test {

    private static final String SKU = '840386208702';

    @TestSetup
    static void setup() {
        User u = TC_TestFactory.accountant();
        insert new PermissionSetAssignment(AssigneeId = u.Id,
            PermissionSetId = [SELECT Id FROM PermissionSet WHERE Name = 'NFY_Integration_Tracking'].Id);
        System.runAs(u) {
            TC_TestFactory.setup();
            NFY_DemoData.seedReference();
            NFY_DemoData.seedStock();
            List<NFY_Integration_System__c> sys = new List<NFY_Integration_System__c>();
            for (String c : new List<String>{ 'ODOO_SHOP', 'SHIPSTATION' }) {
                if ([SELECT COUNT() FROM NFY_Integration_System__c WHERE Code__c = :c] == 0) {
                    sys.add(new NFY_Integration_System__c(Name = c, Code__c = c, Category__c = 'Sales channel', Status__c = 'Connected', Mode__c = 'Webhook'));
                }
            }
            insert sys;
            // Main ships through ShipStation, as in the org.
            TC_Warehouse__c main = [SELECT Id FROM TC_Warehouse__c WHERE NFY_Code__c = 'MAIN'];
            main.NFY_System__c = [SELECT Id FROM NFY_Integration_System__c WHERE Code__c = 'SHIPSTATION' LIMIT 1].Id;
            update main;
            // No flow already delivers orders to ShipStation unless a test adds one.
            for (NFY_Integration_Flow__c f : [SELECT Id FROM NFY_Integration_Flow__c WHERE Direction__c = 'System to system' AND Entity__c = 'Order']) {
                f.Active__c = false;
                update f;
            }
        }
    }

    private static User accountant() {
        return [SELECT Id FROM User WHERE Username LIKE 'tc.accountant.%' ORDER BY CreatedDate DESC LIMIT 1];
    }

    private static Order order(String orderNo, Decimal qty) {
        System.assert(NFY_IntegrationService.process('order.upsert', 'ODOO_SHOP', JSON.serialize(new Map<String, Object>{
            'orderNumber' => orderNo, 'channel' => 'Odoo', 'orderDate' => String.valueOf(Date.today()), 'shipFrom' => 'MAIN', 'allowFallback' => false,
            'tax' => 0, 'freight' => 5,
            'customer' => new Map<String, Object>{ 'externalId' => 'ODOO-SSAPI-1', 'name' => 'Api Buyer', 'email' => 'api@example.com', 'city' => 'Austin', 'country' => 'US' },
            'lines' => new List<Object>{ new Map<String, Object>{ 'sku' => SKU, 'qty' => qty, 'price' => 100 } }
        }), 'ss-' + orderNo, 'Workato').success);
        Order o = [SELECT Id, NFY_Source_System__c FROM Order WHERE NFY_External_Order_Id__c = :orderNo];
        update new Order(Id = o.Id, NFY_Source_System__c = 'Odoo');
        return o;
    }

    @IsTest
    static void releasedOrderBecomesACreateOrderPayload() {
        System.runAs(accountant()) {
            Test.startTest();
            Order o = order('ODOO-S9500', 2);
            Test.stopTest();
            NFY_ShipStationOrderApi.Reply r = NFY_ShipStationOrderApi.build(o.Id, NFY_IntegrationService.RELEASE);
            System.assert(r.send, r.reason);
            System.assertEquals('ODOO-S9500', r.payload.get('orderNumber'));
            System.assertEquals('ODOO-S9500', r.payload.get('orderKey'), 'resends update the same ShipStation order');
            System.assertEquals('awaiting_shipment', r.payload.get('orderStatus'));
            Map<String, Object> asSent = (Map<String, Object>) JSON.deserializeUntyped(r.payloadJson);
            System.assertEquals('ODOO-S9500', asSent.get('orderKey'), 'payloadJson is the same body');
            System.assert(!r.payloadJson.contains('null'), 'blank fields are left out');
            List<Object> items = (List<Object>) r.payload.get('items');
            System.assertEquals(1, items.size());
            System.assertEquals(SKU, ((Map<String, Object>) items[0]).get('sku'));
            System.assertEquals(2, ((Map<String, Object>) items[0]).get('quantity'));
            Map<String, Object> shipTo = (Map<String, Object>) r.payload.get('shipTo');
            System.assertEquals('Austin', shipTo.get('city'));
            System.assertEquals('US', shipTo.get('country'));
            System.assert(String.join(r.warnings, ' ').contains('street'), 'missing street is reported, not invented');
        }
    }

    @IsTest
    static void shipToAddressOnTheOrderIsSent() {
        System.runAs(accountant()) {
            Test.startTest();
            System.assert(NFY_IntegrationService.process('order.upsert', 'SALESFORCE', JSON.serialize(new Map<String, Object>{
                'orderNumber' => 'SF-S9504', 'channel' => 'Wholesale / Team', 'orderDate' => String.valueOf(Date.today()), 'shipFrom' => 'MAIN', 'allowFallback' => false,
                'tax' => 0, 'freight' => 0,
                'customer' => new Map<String, Object>{ 'externalId' => 'SF-SSAPI-2', 'name' => 'Ship Buyer', 'email' => 'ship@example.com', 'city' => 'Austin' },
                'shipTo' => new Map<String, Object>{ 'name' => 'Ship Buyer', 'street1' => '500 Congress Ave', 'street2' => 'Suite 2', 'city' => 'Austin',
                    'state' => 'TX', 'postalCode' => '78701', 'country' => 'US' },
                'lines' => new List<Object>{ new Map<String, Object>{ 'sku' => SKU, 'qty' => 1, 'price' => 100 } }
            }), 'ss-shipto', 'Manual').success);
            Test.stopTest();
            Order o = [SELECT Id, ShippingStreet, ShippingPostalCode FROM Order WHERE NFY_External_Order_Id__c = 'SF-S9504'];
            System.assertEquals('500 Congress Ave\nSuite 2', o.ShippingStreet);
            NFY_ShipStationOrderApi.Reply r = NFY_ShipStationOrderApi.build(o.Id, NFY_IntegrationService.RELEASE);
            System.assert(r.send, r.reason);
            Map<String, Object> shipTo = (Map<String, Object>) r.payload.get('shipTo');
            System.assertEquals('500 Congress Ave', shipTo.get('street1'));
            System.assertEquals('Suite 2', shipTo.get('street2'));
            System.assertEquals('78701', shipTo.get('postalCode'));
            System.assert(r.warnings.isEmpty(), String.join(r.warnings, ' '));
        }
    }

    @IsTest
    static void shopifyShippingAddressBecomesShipTo() {
        Map<String, Object> mapped = NFY_ShopifyOrderMapper.toOrder(new Map<String, Object>{
            'order_number' => 1099, 'email' => 'a@example.com', 'line_items' => new List<Object>(),
            'shipping_address' => new Map<String, Object>{ 'first_name' => 'Ann', 'last_name' => 'Lee', 'address1' => '1 Main St', 'city' => 'Boston',
                'province_code' => 'MA', 'zip' => '02108', 'country_code' => 'US' }
        });
        Map<String, Object> shipTo = (Map<String, Object>) mapped.get('shipTo');
        System.assertEquals('1 Main St', shipTo.get('street1'));
        System.assertEquals('MA', shipTo.get('state'));
        System.assertEquals('02108', shipTo.get('postalCode'));
        System.assertEquals('Ann Lee', shipTo.get('name'));
    }

    @IsTest
    static void orderAnotherFlowSendsIsSkipped() {
        System.runAs(accountant()) {
            Test.startTest();
            Order o = order('ODOO-S9501', 1);
            Test.stopTest();
            insert new NFY_Integration_Flow__c(Name = '[Odoo to ShipStation] - Orders', Code__c = 'TST-SS-ORDER', Active__c = true,
                System__c = [SELECT Id FROM NFY_Integration_System__c WHERE Code__c = 'SHIPSTATION' LIMIT 1].Id,
                Direction__c = 'System to system', Entity__c = 'Order', Mode__c = 'Webhook', Workato_Recipe_Id__c = '412419');
            NFY_ShipStationOrderApi.Reply r = NFY_ShipStationOrderApi.build('ODOO-S9501', NFY_IntegrationService.RELEASE);
            System.assert(!r.send);
            System.assert(r.reason.contains('412419'), r.reason);
        }
    }

    @IsTest
    static void backorderedAndUnknownOrdersAreNotSent() {
        System.runAs(accountant()) {
            Id productId = NFY_Ref.product(SKU).Id;
            Id locId = NFY_Ref.location('MAIN', 'AVL').Id;
            Decimal onHand = [SELECT Available_Quantity__c FROM TC_Inventory_Balance__c WHERE Product__c = :productId AND Location__c = :locId].Available_Quantity__c;
            Test.startTest();
            Order o = order('ODOO-S9502', onHand + 5);
            Test.stopTest();
            NFY_ShipStationOrderApi.Reply r = NFY_ShipStationOrderApi.build(o.Id, NFY_IntegrationService.RELEASE);
            System.assert(!r.send);
            System.assert(r.reason.contains('not ready'), r.reason);
            NFY_ShipStationOrderApi.Reply none = NFY_ShipStationOrderApi.build('ODOO-NOPE', NFY_IntegrationService.RELEASE);
            System.assertEquals(null, none.orderId);
            System.assert(!none.send);
        }
    }

    @IsTest
    static void cancelledOrderIsSentAsCancelledOverRest() {
        System.runAs(accountant()) {
            Test.startTest();
            Order o = order('ODOO-S9503', 1);
            System.assert(NFY_IntegrationService.process('order.cancelled', 'ODOO_SHOP', JSON.serialize(new Map<String, Object>{ 'orderNumber' => 'ODOO-S9503' }),
                'ss-cancel', 'Workato').success);
            Test.stopTest();
            RestRequest req = new RestRequest();
            req.requestURI = '/services/apexrest/nfinity/v1/shipstation/order/ODOO-S9503';
            req.httpMethod = 'GET';
            req.params.put('kind', NFY_IntegrationService.CANCEL);
            RestContext.request = req;
            RestContext.response = new RestResponse();
            NFY_ShipStationOrderApi.get();
            System.assertEquals(200, RestContext.response.statusCode);
            Map<String, Object> body = (Map<String, Object>) JSON.deserializeUntyped(RestContext.response.responseBody.toString());
            System.assertEquals(true, body.get('send'), String.valueOf(body.get('reason')));
            System.assertEquals('cancelled', ((Map<String, Object>) body.get('payload')).get('orderStatus'));
        }
    }
}