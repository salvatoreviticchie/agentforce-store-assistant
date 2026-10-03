@IsTest
private class MyDayServiceTest {

    // A fixed "today" (a Wednesday in summer time) proves the service never reads the clock
    private static final Date TODAY = Date.newInstance(2030, 6, 12);

    /**
     * The running user is a Bern associate. Every rule has a record that must show up and a
     * record that must not (other store, cancelled, closed, too far, already followed up...).
     */
    @TestSetup
    static void setup() {
        System.runAs(new User(Id = UserInfo.getUserId())) { // avoids mixed DML (User + business data)
            update new User(Id = UserInfo.getUserId(), Store__c = 'Bern');
        }
        Account acc = new Account(Name = 'Customers');
        insert acc;
        Map<String, Contact> c = new Map<String, Contact>();
        for (String[] row : new List<String[]>{
                new String[]{ 'Zara', 'Bern' }, new String[]{ 'Ivo', 'Bern' }, new String[]{ 'Paul', 'Bern' },
                new String[]{ 'Fiona', 'Bern' }, new String[]{ 'Gina', 'Bern' }, new String[]{ 'Victor', 'Bern' },
                new String[]{ 'Rita', 'Bern' }, new String[]{ 'Hugo', 'Lausanne' }, new String[]{ 'Gert', 'Lausanne' } }) {
            c.put(row[0], new Contact(AccountId = acc.Id, FirstName = row[0], LastName = 'Test',
                                      Email = row[0].toLowerCase() + '@example.com', Home_Store__c = row[1]));
        }
        insert c.values();

        List<Product2> prods = new List<Product2>{
            new Product2(Name = 'Bike A', Family = 'Bikes', Description = 'A', IsActive = true),
            new Product2(Name = 'Bike B', Family = 'Bikes', Description = 'B', IsActive = true),
            new Product2(Name = 'Helmet', Family = 'Gear', Description = 'S', IsActive = true)
        };
        insert prods;
        Id pb = Test.getStandardPricebookId();
        List<PricebookEntry> pbes = new List<PricebookEntry>{
            new PricebookEntry(Pricebook2Id = pb, Product2Id = prods[0].Id, UnitPrice = 6000, IsActive = true),
            new PricebookEntry(Pricebook2Id = pb, Product2Id = prods[1].Id, UnitPrice = 1800, IsActive = true),
            new PricebookEntry(Pricebook2Id = pb, Product2Id = prods[2].Id, UnitPrice = 150, IsActive = true)
        };
        insert pbes;

        // Gold purchases (CHF 6,000) for Victor, Rita (Bern) and Hugo (Lausanne); Paul and Ivo have unpaid drafts
        List<Order> orders = new List<Order>();
        for (String name : new List<String>{ 'Victor', 'Rita', 'Hugo', 'Paul', 'Ivo' }) {
            orders.add(new Order(AccountId = acc.Id, BillToContactId = c.get(name).Id, Pricebook2Id = pb,
                                 EffectiveDate = TODAY.addDays(-200), Status = 'Draft'));
        }
        insert orders;
        List<OrderItem> items = new List<OrderItem>();
        for (Integer i = 0; i < 3; i++) items.add(new OrderItem(OrderId = orders[i].Id, PricebookEntryId = pbes[0].Id, Quantity = 1, UnitPrice = 6000));
        items.add(new OrderItem(OrderId = orders[3].Id, PricebookEntryId = pbes[1].Id, Quantity = 1, UnitPrice = 1800));
        items.add(new OrderItem(OrderId = orders[4].Id, PricebookEntryId = pbes[2].Id, Quantity = 1, UnitPrice = 150));
        insert items;
        for (Integer i = 0; i < 3; i++) orders[i].Status = 'Activated';
        update new List<Order>{ orders[0], orders[1], orders[2] };

        Store_Appointment__c ginaVisit = appt(c.get('Gina'), 'Bern', 'Bike Consultation', 'Completed', TODAY.addDays(-3), 14);
        insert new List<Store_Appointment__c>{
            appt(c.get('Zara'), 'Bern', 'Bike Consultation', 'Confirmed', TODAY, 15),       // today (inserted first, shown second)
            appt(c.get('Ivo'), 'Bern', 'Bike Service', 'Requested', TODAY, 11),         // today, not confirmed yet
            appt(c.get('Ivo'), 'Bern', 'Bike Service', 'Cancelled', TODAY, 10),         // cancelled: hidden
            appt(c.get('Gert'), 'Lausanne', 'Bike Consultation', 'Confirmed', TODAY, 12),       // other store: hidden
            appt(c.get('Paul'), 'Bern', 'Collection', 'Requested', TODAY.addDays(3), 14), // pre-visit (unpaid draft)
            appt(c.get('Zara'), 'Bern', 'Collection', 'Requested', TODAY.addDays(4), 14),  // collection, nothing unpaid: hidden
            appt(c.get('Fiona'), 'Bern', 'Bike Consultation', 'Completed', TODAY.addDays(-2), 16),  // needs a follow-up
            ginaVisit,                                                               // already followed up
            appt(c.get('Rita'), 'Bern', 'Bike Service', 'Completed', TODAY.addDays(-30), 10)    // recent contact for Rita
        };

        Id me = UserInfo.getUserId();
        insert new List<Task>{
            task(me, null, 'Overdue normal', TODAY.addDays(-1), 'Normal', 'Not Started'),
            task(me, null, 'Oldest overdue', TODAY.addDays(-3), 'Normal', 'Not Started'),
            task(me, null, 'Overdue high', TODAY.addDays(-1), 'High', 'Not Started'),
            task(me, c.get('Zara').Id, 'Prepare a test ride for Zara', TODAY, 'Normal', 'Not Started'),
            task(me, c.get('Paul').Id, 'Confirm payment for Paul', TODAY, 'High', 'Not Started'),
            task(me, null, 'Window display', TODAY, 'Normal', 'Not Started'),
            task(me, null, 'Already done', TODAY, 'Normal', 'Completed'),
            task(me, null, 'Upcoming soon', TODAY.addDays(2), 'Normal', 'Not Started'),
            task(me, null, 'Too far away', TODAY.addDays(10), 'Normal', 'Not Started'),
            new Task(OwnerId = me, WhatId = ginaVisit.Id, Subject = 'Thank-you call', ActivityDate = TODAY.addDays(-1), Status = 'Completed')
        };
    }

    private static Store_Appointment__c appt(Contact c, String store, String purpose, String status, Date d, Integer hour) {
        Datetime asIfGmt = Datetime.newInstanceGmt(d, Time.newInstance(hour, 0, 0, 0)); // hour in Bern time
        Datetime local = asIfGmt.addSeconds(-TimeZone.getTimeZone('Europe/Zurich').getOffset(asIfGmt) / 1000);
        return new Store_Appointment__c(Customer__c = c.Id, Store__c = store, Purpose__c = purpose,
                                           Status__c = status, Appointment_DateTime__c = local);
    }

    private static Task task(Id owner, Id whoId, String subject, Date d, String priority, String status) {
        return new Task(OwnerId = owner, WhoId = whoId, Subject = subject, ActivityDate = d, Priority = priority, Status = status);
    }

    /** Amounts follow the running user's locale (e.g. 6,000 or 6’000), like the briefing itself. */
    private static String chf(Decimal amount) {
        return 'CHF ' + amount.format();
    }

    private static MyDayService.MyDay run() {
        return MyDayService.build(UserInfo.getUserId(), TODAY);
    }

    private static List<String> headlines(MyDayService.MyDay day, String key) {
        List<String> out = new List<String>();
        MyDayService.Section s = day.section(key);
        if (s != null) for (MyDayService.Item i : s.items) out.add(i.headline);
        return out;
    }

    @IsTest
    static void sectionsComeInPriorityOrderAndItemsAreNumbered() {
        Test.startTest();
        MyDayService.MyDay day = run();
        Test.stopTest();

        Assert.areEqual('Bern', day.store);
        Assert.isNull(day.message);
        List<String> keys = new List<String>();
        for (MyDayService.Section s : day.sections) keys.add(s.key);
        Assert.areEqual(new List<String>{ 'OVERDUE', 'TODAY', 'PRE_VISIT', 'DUE_TODAY', 'FOLLOW_UP', 'RECONNECT', 'UPCOMING' }, keys);

        Integer expected = 1;
        for (MyDayService.Section s : day.sections) {
            for (MyDayService.Item i : s.items) Assert.areEqual(expected++, i.priority, 'priorities run 1..n across sections');
        }
    }

    @IsTest
    static void overdueTasksOldestFirstThenHighPriority() {
        MyDayService.MyDay day = run();
        Assert.areEqual(new List<String>{ 'Oldest overdue', 'Overdue high', 'Overdue normal' }, headlines(day, 'OVERDUE'));
        MyDayService.Item oldest = day.section('OVERDUE').items[0];
        Assert.areEqual('TASK', oldest.type);
        Assert.areEqual('due Sun 9 Jun', oldest.timeLabel);
        Assert.isTrue(oldest.details.contains('Overdue by 3 days'), String.valueOf(oldest.details));
    }

    @IsTest
    static void todayShowsOnlyMyStoreInTimeOrderWithCustomerBrief() {
        MyDayService.MyDay day = run();
        Assert.areEqual(new List<String>{ 'Ivo Test · Bike Service', 'Zara Test · Bike Consultation' }, headlines(day, 'TODAY'),
            'no cancelled visit, no Lausanne visit, sorted by local time');

        MyDayService.Item ivo = day.section('TODAY').items[0];
        Assert.areEqual('11:00', ivo.timeLabel, 'store-local time');
        Assert.isTrue(ivo.details.contains('Not yet confirmed with the customer'));
        Assert.isTrue(ivo.details.contains('New customer · owns nothing yet'), String.valueOf(ivo.details));
        String ivoOrder = [SELECT OrderNumber FROM Order WHERE BillToContact.FirstName = 'Ivo'].OrderNumber;
        Assert.isTrue(ivo.details.contains('Unconfirmed order ' + ivoOrder + ': check payment'), String.valueOf(ivo.details));

        MyDayService.Item zara = day.section('TODAY').items[1];
        Assert.areEqual('APPOINTMENT', zara.type);
        Assert.areEqual(1, zara.tasks.size(), 'Zara\'s task for today is merged into her visit');
        Assert.areEqual('Prepare a test ride for Zara', zara.tasks[0].subject);
        Assert.isTrue(String.join(zara.details, '\n').contains('Suggest: Bike B (' + chf(1800) + '), Bike A (' + chf(6000) + ')'), String.valueOf(zara.details));
    }

    @IsTest
    static void unpaidOrderBeforeCollectionTakesTheTaskAlong() {
        MyDayService.MyDay day = run();
        Assert.areEqual(1, day.section('PRE_VISIT').items.size(), 'Zara\'s collection has nothing unpaid');
        MyDayService.Item paul = day.section('PRE_VISIT').items[0];
        Assert.areEqual('Paul Test · Collection', paul.headline);
        Assert.areEqual('Sat 15 Jun 14:00', paul.timeLabel);
        Assert.isTrue(paul.details[0].contains('is not confirmed yet'), paul.details[0]);
        Assert.areEqual('Confirm payment for Paul', paul.tasks[0].subject);

        Assert.areEqual(new List<String>{ 'Window display' }, headlines(day, 'DUE_TODAY'),
            'merged and completed tasks are not repeated in Due today');
    }

    @IsTest
    static void followUpOnlyForVisitsWithoutATask() {
        MyDayService.MyDay day = run();
        Assert.areEqual(new List<String>{ 'Fiona Test · Bike Consultation visit on Mon 10 Jun' }, headlines(day, 'FOLLOW_UP'),
            'Gina already has a follow-up task; Rita\'s visit is older than a week');
    }

    @IsTest
    static void reconnectWithDormantGoldCustomersOfMyStore() {
        MyDayService.MyDay day = run();
        Assert.areEqual(new List<String>{ 'Victor Test · Gold customer' }, headlines(day, 'RECONNECT'),
            'Rita was seen 30 days ago, Hugo belongs to Lausanne, the others are not Gold');
        Assert.isTrue(day.section('RECONNECT').items[0].details[0].startsWith('Lifetime spend ' + chf(6000)), day.section('RECONNECT').items[0].details[0]);
    }

    @IsTest
    static void dataCloudLifetimeValueCanMakeACustomerGold() {
        // Fiona has no CRM purchases, but the unified profile (other channels) says CHF 12,000
        Contact fiona = [SELECT Id FROM Contact WHERE FirstName = 'Fiona'];
        delete [SELECT Id FROM Store_Appointment__c WHERE Customer__c = :fiona.Id]; // no recent contact
        CustomerProfileService.insightRowsForTest.put(fiona.Id, new List<Object>{ 12000, 2, '2029-11-03 00:00:00.000 UTC' });

        MyDayService.MyDay day = run();
        Assert.areEqual(new List<String>{ 'Fiona Test · Gold customer', 'Victor Test · Gold customer' }, headlines(day, 'RECONNECT'),
            'highest lifetime spend first');
        Assert.areEqual('Lifetime spend ' + chf(12000) + ' · last purchase 2029-11-03', day.section('RECONNECT').items[0].details[0]);
    }

    @IsTest
    static void upcomingTasksWithinAWeekOnly() {
        MyDayService.MyDay day = run();
        Assert.areEqual(new List<String>{ 'Upcoming soon' }, headlines(day, 'UPCOMING'));
        Assert.areEqual('Fri 14 Jun', day.section('UPCOMING').items[0].timeLabel);
    }

    @IsTest
    static void anotherStoreSeesItsOwnDayOnly() {
        System.runAs(new User(Id = UserInfo.getUserId())) {
            update new User(Id = UserInfo.getUserId(), Store__c = 'Lausanne');
        }
        MyDayService.MyDay day = run();
        Assert.areEqual(new List<String>{ 'Gert Test · Bike Consultation' }, headlines(day, 'TODAY'));
        Assert.areEqual(new List<String>{ 'Hugo Test · Gold customer' }, headlines(day, 'RECONNECT'));
        Assert.isNull(day.section('PRE_VISIT'));
        Assert.isNull(day.section('FOLLOW_UP'));
    }

    @IsTest
    static void noStoreMeansNoBriefing() {
        System.runAs(new User(Id = UserInfo.getUserId())) {
            update new User(Id = UserInfo.getUserId(), Store__c = null);
        }
        MyDayService.MyDay day = MyDayService.forCurrentUser();
        Assert.isTrue(day.sections.isEmpty());
        Assert.isTrue(day.message.startsWith('No store is set on your user'));
    }

    @IsTest
    static void quietDayHasAFriendlyMessage() {
        // Five years earlier: every task and visit is still far in the future, only Victor counts as dormant
        // (Rita's visits on record are in the future, which also counts as being in contact)
        MyDayService.MyDay day = MyDayService.build(UserInfo.getUserId(), TODAY.addYears(-5));
        Assert.areEqual(1, day.sections.size());
        Assert.areEqual(new List<String>{ 'Victor Test · Gold customer' }, headlines(day, 'RECONNECT'));
        List<Contact> mine = [SELECT Id FROM Contact WHERE Home_Store__c = 'Bern'];
        for (Contact c : mine) c.Home_Store__c = null;
        update mine;
        day = MyDayService.build(UserInfo.getUserId(), TODAY.addYears(-5));
        Assert.isTrue(day.sections.isEmpty());
        Assert.areEqual('Nothing planned for Bern today.', day.message);
    }
}
