@IsTest
private class CustomerProfileServiceTest {

    @TestSetup
    static void setup() {
        Account acc = new Account(Name = 'Customers');
        insert acc;
        List<Contact> cs = new List<Contact>();
        for (Integer i = 0; i < 50; i++) {
            cs.add(new Contact(AccountId = acc.Id, LastName = 'Customer ' + i, Email = 'customer' + i + '@example.com'));
        }
        insert cs;
        Product2 bike = new Product2(Name = 'Bike A', Family = 'Bikes', Description = 'A', IsActive = true);
        insert bike;
        PricebookEntry pbe = new PricebookEntry(Pricebook2Id = Test.getStandardPricebookId(), Product2Id = bike.Id, UnitPrice = 6000, IsActive = true);
        insert pbe;
        List<Order> orders = new List<Order>();
        for (Contact c : cs) {
            orders.add(new Order(AccountId = acc.Id, BillToContactId = c.Id, Pricebook2Id = pbe.Pricebook2Id,
                                 EffectiveDate = Date.today(), Status = 'Draft'));
        }
        insert orders;
        List<OrderItem> items = new List<OrderItem>();
        for (Order o : orders) items.add(new OrderItem(OrderId = o.Id, PricebookEntryId = pbe.Id, Quantity = 1, UnitPrice = 6000));
        insert items;
    }

    private static Set<Id> customers(Integer howMany) {
        return new Map<Id, Contact>([SELECT Id FROM Contact ORDER BY LastName LIMIT :howMany]).keySet();
    }

    @IsTest
    static void queryCountDoesNotGrowWithTheNumberOfCustomers() {
        Set<Id> one = customers(1), fifty = customers(50);

        Integer before = Limits.getQueries();
        CustomerProfileService.getProfiles(one);
        Integer forOne = Limits.getQueries() - before;

        before = Limits.getQueries();
        Map<Id, CustomerProfileService.Profile> profiles = CustomerProfileService.getProfiles(fifty);
        Integer forFifty = Limits.getQueries() - before;

        Assert.areEqual(50, profiles.size());
        Assert.areEqual(forOne, forFifty, 'bulk-safe: same number of SOQL queries for 1 or 50 customers');
        Assert.areEqual(1, profiles.values()[0].pendingOrderNumbers.size(), 'each customer has one unconfirmed order');
    }

    @IsTest
    static void dataCloudValueWinsOverCrm() {
        Id cid = new List<Id>(customers(1))[0];
        CustomerProfileService.insightRowsForTest.put(cid, new List<Object>{ 15000.7, 3, '2030-01-02 00:00:00.000 UTC' });
        CustomerProfileService.LifetimeValue v = CustomerProfileService.getLifetimeValues(new Set<Id>{ cid }).get(cid);
        Assert.areEqual(15001, v.spend);
        Assert.areEqual(3, v.orderCount);
        Assert.areEqual('2030-01-02', v.lastOrderDate);
        Assert.areEqual('Gold', v.tier);
        Assert.areEqual(CustomerProfileService.SOURCE_DATA_CLOUD, v.source);
    }

    @IsTest
    static void dataCloudOutageFallsBackToCrm() {
        Id cid = new List<Id>(customers(1))[0];
        CustomerProfileService.simulateDataCloudError = true;
        CustomerProfileService.LifetimeValue v = CustomerProfileService.getLifetimeValues(new Set<Id>{ cid }).get(cid);
        Assert.areEqual(0, v.spend, 'the only order is a draft');
        Assert.areEqual('New', v.tier);
        Assert.areEqual(CustomerProfileService.SOURCE_CRM_ERROR, v.source);
    }

    @IsTest
    static void emptyInputIsEmptyOutput() {
        Assert.isTrue(CustomerProfileService.getProfiles(new Set<Id>()).isEmpty());
        Assert.isTrue(CustomerProfileService.getLifetimeValues(null).isEmpty());
        Assert.areEqual('Member', CustomerProfileService.tierFor(100));
    }
}
