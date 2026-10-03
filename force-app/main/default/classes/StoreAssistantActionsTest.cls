@IsTest
private class StoreAssistantActionsTest {

    @TestSetup
    static void setup() {
        Account acc = new Account(Name = 'Test Customer');
        insert acc;
        Contact c = new Contact(FirstName = 'Test', LastName = 'Customer', Email = 'test.customer@example.com', AccountId = acc.Id);
        insert c;

        Product2 p = new Product2(Name = 'Test Bike', IsActive = true);
        insert p;
        PricebookEntry pbe = new PricebookEntry(Pricebook2Id = Test.getStandardPricebookId(), Product2Id = p.Id, UnitPrice = 5000, IsActive = true);
        insert pbe;
        Order o = new Order(AccountId = acc.Id, BillToContactId = c.Id, EffectiveDate = Date.today(), Status = 'Draft',
                            Pricebook2Id = Test.getStandardPricebookId(), Description = 'Shipped, tracking TEST123');
        insert o;
        insert new OrderItem(OrderId = o.Id, PricebookEntryId = pbe.Id, Quantity = 1, UnitPrice = 5000);
    }

    // ---------- order status ----------

    @IsTest
    static void orderFoundWithMatchingEmail() {
        String num = [SELECT OrderNumber FROM Order LIMIT 1].OrderNumber;
        OrderStatusAction.Request req = new OrderStatusAction.Request();
        req.orderNumber = String.valueOf(Integer.valueOf(num)); // e.g. "101" without leading zeros
        req.email = 'TEST.customer@example.com';                   // case-insensitive

        OrderStatusAction.Result res = OrderStatusAction.getStatus(new List<OrderStatusAction.Request>{ req })[0];

        Assert.isTrue(res.found);
        Assert.areEqual('Processing', res.status);
        Assert.areEqual('1 x Test Bike', res.items);
        Assert.areEqual('Shipped, tracking TEST123', res.fulfilmentDetails);
    }

    @IsTest
    static void orderHiddenWhenEmailDoesNotMatch() {
        OrderStatusAction.Request req = new OrderStatusAction.Request();
        req.orderNumber = [SELECT OrderNumber FROM Order LIMIT 1].OrderNumber;
        req.email = 'someone.else@example.com';

        OrderStatusAction.Result res = OrderStatusAction.getStatus(new List<OrderStatusAction.Request>{ req })[0];

        Assert.isFalse(res.found);
        Assert.isNull(res.status, 'No order details may leak');
    }

    @IsTest
    static void normalizesOrderNumbers() {
        Assert.areEqual('00000101', OrderStatusAction.normalize('#101'));
        Assert.areEqual('00000101', OrderStatusAction.normalize('order 00000101'));
        Assert.isNull(OrderStatusAction.normalize('abc'));
        Assert.isNull(OrderStatusAction.normalize(null));
    }

    // ---------- appointments ----------

    private static Date nextWeekday() {
        Date d = Date.today().addDays(14);
        while (Datetime.newInstanceGmt(d, Time.newInstance(12, 0, 0, 0)).formatGmt('u') == '7') d = d.addDays(1);
        return d;
    }

    private static StoreAppointmentAction.Result book(String email, String store, Date d, String t) {
        StoreAppointmentAction.Request req = new StoreAppointmentAction.Request();
        req.email = email;
        req.store = store;
        req.purpose = 'Bike Consultation';
        req.appointmentDate = d;
        req.appointmentTime = t;
        req.notes = 'Test booking';
        return StoreAppointmentAction.book(new List<StoreAppointmentAction.Request>{ req })[0];
    }

    @IsTest
    static void booksFreeSlot() {
        StoreAppointmentAction.Result res = book('test.customer@example.com', 'Lausanne', nextWeekday(), '14:30');
        Assert.isTrue(res.success, res.message);
        Assert.isNotNull(res.appointmentNumber);
        Store_Appointment__c a = [SELECT Status__c, Store__c FROM Store_Appointment__c LIMIT 1];
        Assert.areEqual('Requested', a.Status__c);
        Assert.areEqual('Lausanne', a.Store__c);
    }

    @IsTest
    static void suggestsNextSlotWhenTaken() {
        Date d = nextWeekday();
        Assert.isTrue(book('test.customer@example.com', 'Bern', d, '11:00').success);
        StoreAppointmentAction.Result second = book('test.customer@example.com', 'Bern', d, '11:30');
        Assert.isFalse(second.success);
        Assert.areEqual('12:00', second.suggestedTime);
        // A different store at the same time is fine
        Assert.isTrue(book('test.customer@example.com', 'Lyon', d, '11:00').success);
    }

    @IsTest
    static void rejectsInvalidRequests() {
        Date d = nextWeekday();
        Assert.isFalse(book('unknown@example.com', 'Lausanne', d, '14:00').success, 'unknown customer');
        Assert.isFalse(book('test.customer@example.com', 'Vienna', d, '14:00').success, 'unknown store');
        Assert.isFalse(book('test.customer@example.com', 'Lausanne', d, '09:00').success, 'before opening');
        Assert.isFalse(book('test.customer@example.com', 'Lausanne', d, '18:30').success, 'too late');
        Assert.isFalse(book('test.customer@example.com', 'Lausanne', d, '14:15').success, 'not a half-hour slot');
        Assert.isFalse(book('test.customer@example.com', 'Lausanne', Date.today().addDays(-1), '14:00').success, 'past');
        Date sunday = Date.today().addDays(14);
        while (Datetime.newInstanceGmt(sunday, Time.newInstance(12, 0, 0, 0)).formatGmt('u') != '7') sunday = sunday.addDays(1);
        Assert.isFalse(book('test.customer@example.com', 'Lausanne', sunday, '14:00').success, 'sunday');
        Assert.areEqual(0, [SELECT COUNT() FROM Store_Appointment__c]);
    }

    @IsTest
    static void convertsLocalTimeToGmt() {
        // 14:00 in Lausanne on 1 July (CEST, UTC+2) is 12:00 GMT
        Datetime gmt = StoreAppointmentAction.toGmt(Date.newInstance(2030, 7, 1), 14, 0, 'Europe/Zurich');
        Assert.areEqual('12:00', gmt.formatGmt('HH:mm'));
    }
}
