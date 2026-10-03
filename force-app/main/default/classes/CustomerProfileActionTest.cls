@IsTest
private class CustomerProfileActionTest {

    @TestSetup
    static void setup() {
        Account acc = new Account(Name = 'Profile Customer');
        insert acc;
        insert new List<Contact>{
            new Contact(FirstName = 'Vera', LastName = 'Buyer', Email = 'vera@example.com', AccountId = acc.Id),
            new Contact(FirstName = 'Nina', LastName = 'New', Email = 'nina@example.com', AccountId = acc.Id)
        };
        List<Product2> prods = new List<Product2>{
            new Product2(Name = 'Bike A', Family = 'Bikes', Description = 'A', IsActive = true),
            new Product2(Name = 'Bike B', Family = 'Bikes', Description = 'B', IsActive = true),
            new Product2(Name = 'Bike C', Family = 'Bikes', Description = 'C', IsActive = true),
            new Product2(Name = 'Helmet', Family = 'Gear', Description = 'S', IsActive = true)
        };
        insert prods;
        Id pb = Test.getStandardPricebookId();
        List<PricebookEntry> pbes = new List<PricebookEntry>{
            new PricebookEntry(Pricebook2Id = pb, Product2Id = prods[0].Id, UnitPrice = 6000, IsActive = true),
            new PricebookEntry(Pricebook2Id = pb, Product2Id = prods[1].Id, UnitPrice = 5800, IsActive = true),
            new PricebookEntry(Pricebook2Id = pb, Product2Id = prods[2].Id, UnitPrice = 1800, IsActive = true),
            new PricebookEntry(Pricebook2Id = pb, Product2Id = prods[3].Id, UnitPrice = 150, IsActive = true)
        };
        insert pbes;
        Contact vera = [SELECT Id FROM Contact WHERE Email = 'vera@example.com'];
        Order o = new Order(AccountId = acc.Id, BillToContactId = vera.Id, EffectiveDate = Date.today(), Status = 'Draft', Pricebook2Id = pb);
        insert o;
        insert new OrderItem(OrderId = o.Id, PricebookEntryId = pbes[0].Id, Quantity = 1, UnitPrice = 6000);
        o.Status = 'Activated';
        update o;
        insert new Store_Appointment__c(Customer__c = vera.Id, Store__c = 'Lausanne', Purpose__c = 'Bike Service',
            Appointment_DateTime__c = Datetime.now().addDays(10), Status__c = 'Confirmed');
    }

    private static CustomerProfileAction.Result run(String email) {
        CustomerProfileAction.Request r = new CustomerProfileAction.Request();
        r.email = email;
        return CustomerProfileAction.getProfile(new List<CustomerProfileAction.Request>{ r })[0];
    }

    private static void addDraftOrder(String email, String productName, Decimal price) {
        Contact c = [SELECT Id, AccountId FROM Contact WHERE Email = :email];
        Id pb = Test.getStandardPricebookId();
        PricebookEntry pbe = [SELECT Id FROM PricebookEntry WHERE Pricebook2Id = :pb AND Product2.Name = :productName];
        Order draft = new Order(AccountId = c.AccountId, BillToContactId = c.Id, EffectiveDate = Date.today().addDays(5),
                                Status = 'Draft', Pricebook2Id = pb);
        insert draft;
        insert new OrderItem(OrderId = draft.Id, PricebookEntryId = pbe.Id, Quantity = 1, UnitPrice = price);
    }

    @IsTest
    static void goldCustomerGetsGearAndSimilarBike() {
        CustomerProfileAction.Result res = run('VERA@example.com '.trim().toLowerCase());
        Assert.isTrue(res.found);
        Assert.areEqual('Gold', res.tier);
        Assert.areEqual(6000, res.lifetimeSpend);
        Assert.areEqual('Bike A', res.ownedProducts);
        Assert.isTrue(res.recommendations.startsWith('Helmet'), res.recommendations);
        Assert.isTrue(res.recommendations.contains('Bike B'), 'closest price to past spend');
        Assert.isFalse(res.recommendations.contains('Bike A'), 'never recommend what is owned');
        Assert.isTrue(res.upcomingAppointments.contains('Lausanne'));
        Assert.isTrue(res.dataSource.contains('CRM'), 'Data Cloud is skipped in tests');
    }

    @IsTest
    static void draftOrdersAreIgnored() {
        // A later draft order (not a purchase) must not change count, last date, ownership or price range
        addDraftOrder('vera@example.com', 'Bike C', 1800);
        CustomerProfileAction.Result res = run('vera@example.com');
        Assert.areEqual(1, res.orderCount, 'draft orders are not counted');
        Assert.areEqual(String.valueOf(Date.today()), res.lastOrderDate, 'last date comes from the confirmed order');
        Assert.areEqual(6000, res.lifetimeSpend);
        Assert.areEqual('Bike A', res.ownedProducts, 'draft items are not owned');
        Assert.isTrue(res.recommendations.contains('Bike B'), 'target stays at the confirmed average: ' + res.recommendations);
        Assert.areEqual('Salesforce CRM (no confirmed purchases in Data Cloud)', res.dataSource);
    }

    @IsTest
    static void pendingItemsAreNotRecommended() {
        // Nina has a pending order for the entry bike: it must not be suggested again
        addDraftOrder('nina@example.com', 'Bike C', 1800);
        CustomerProfileAction.Result res = run('nina@example.com');
        Assert.areEqual('New', res.tier);
        Assert.areEqual('None yet', res.ownedProducts);
        Assert.isFalse(res.recommendations.contains('Bike C'), 'already on order: ' + res.recommendations);
        Assert.isTrue(res.recommendations.startsWith('Bike B'), 'next entry-level bike: ' + res.recommendations);
    }

    @IsTest
    static void newCustomerIsNewWithEntryLevelBikes() {
        CustomerProfileAction.Result res = run('nina@example.com');
        Assert.areEqual('New', res.tier);
        Assert.areEqual('None yet', res.ownedProducts);
        Assert.areEqual(0, res.orderCount);
        Assert.isTrue(res.recommendations.startsWith('Bike C'), 'cheapest bike first for new customers');
        Assert.isFalse(res.recommendations.contains('Helmet'));
    }

    @IsTest
    static void onlyTheMostAffordableMissingGearIsSuggested() {
        Product2 lights = new Product2(Name = 'Lights', Family = 'Gear', Description = 'L', IsActive = true);
        insert lights;
        insert new PricebookEntry(Pricebook2Id = Test.getStandardPricebookId(), Product2Id = lights.Id, UnitPrice = 90, IsActive = true);
        CustomerProfileAction.Result res = run('vera@example.com');
        Assert.isTrue(res.recommendations.startsWith('Lights'), 'cheapest gear first: ' + res.recommendations);
        Assert.isFalse(res.recommendations.contains('Helmet'), 'one gear item at most: ' + res.recommendations);

        addDraftOrder('vera@example.com', 'Lights', 90);
        res = run('vera@example.com');
        Assert.isTrue(res.recommendations.startsWith('Helmet'), 'gear on order is skipped: ' + res.recommendations);
    }

    @IsTest
    static void unknownEmail() {
        Assert.isFalse(run('nobody@example.com').found);
        Assert.isFalse(run(null).found);
    }
}
