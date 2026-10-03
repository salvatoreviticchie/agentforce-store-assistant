@IsTest
private class StaffAssistantActionsTest {

    @TestSetup
    static void setup() {
        System.runAs(new User(Id = UserInfo.getUserId())) { // avoids mixed DML (User + business data)
            update new User(Id = UserInfo.getUserId(), Store__c = 'Bern');
        }
        Account acc = new Account(Name = 'Customers');
        insert acc;
        insert new List<Contact>{
            new Contact(AccountId = acc.Id, FirstName = 'Lucas', LastName = 'Aebi', Email = 'lucas.a@example.com', Home_Store__c = 'Bern'),
            new Contact(AccountId = acc.Id, FirstName = 'Lucas', LastName = 'Favre', Email = 'lucas.g@example.com', Home_Store__c = 'Lausanne'),
            new Contact(AccountId = acc.Id, FirstName = 'Lea', LastName = 'Bauer', Email = 'lea@example.com', Home_Store__c = 'Munich'),
            new Contact(AccountId = acc.Id, FirstName = 'Lea', LastName = 'Roux', Email = 'lea.m@example.com', Home_Store__c = 'Lyon'),
            new Contact(AccountId = acc.Id, FirstName = 'Mia', LastName = 'Visitor', Email = 'mia@example.com', Home_Store__c = 'Bern')
        };
        Contact mia = [SELECT Id FROM Contact WHERE LastName = 'Visitor'];
        insert new List<Store_Appointment__c>{
            new Store_Appointment__c(Customer__c = mia.Id, Store__c = 'Bern', Purpose__c = 'Bike Consultation', Status__c = 'Completed',
                                        Appointment_DateTime__c = Datetime.now().addDays(-2)),
            new Store_Appointment__c(Customer__c = mia.Id, Store__c = 'Bern', Purpose__c = 'Bike Service', Status__c = 'Completed',
                                        Appointment_DateTime__c = Datetime.now().addDays(-5))
        };
        insert new Task(OwnerId = UserInfo.getUserId(), Subject = 'Call the frame supplier', ActivityDate = Date.today().addDays(-1),
                        Priority = 'High', Status = 'Not Started');
    }

    private static CreateStaffTaskAction.Result create(String subject, Date due, String name, String email, Boolean followUp) {
        CreateStaffTaskAction.Request r = new CreateStaffTaskAction.Request();
        r.subject = subject;
        r.dueDate = due;
        r.customerName = name;
        r.customerEmail = email;
        r.isFollowUp = followUp;
        return CreateStaffTaskAction.createTasks(new List<CreateStaffTaskAction.Request>{ r })[0];
    }

    // --- Get My Day ---

    @IsTest
    static void briefingIsNumberedLinesUnderSectionTitles() {
        GetMyDayAction.Result res = GetMyDayAction.getMyDay(
            new List<GetMyDayAction.Request>{ new GetMyDayAction.Request() })[0];
        Assert.areEqual('Bern', res.store);
        Assert.isNull(res.message);
        Assert.areEqual(3, res.itemCount, 'one overdue task, two visits of Mia without follow-up');
        List<String> lines = res.briefing.split('\n');
        Assert.isTrue(lines[0].startsWith('Briefing for ' + UserInfo.getName() + ', Bern store, '), lines[0]);
        Assert.areEqual('OVERDUE TASKS', lines[2]);
        Assert.isTrue(lines[3].startsWith('1. [due ') && lines[3].contains('] Call the frame supplier — High priority; Overdue by 1 day'), lines[3]);
        Assert.isTrue(res.briefing.contains('FOLLOW-UPS FROM RECENT VISITS'), res.briefing);
    }

    @IsTest
    static void todaysVisitsShowBothTimeFormats() {
        Contact mia = [SELECT Id FROM Contact WHERE LastName = 'Visitor'];
        Datetime asIfGmt = Datetime.newInstanceGmt(Date.today(), Time.newInstance(15, 30, 0, 0)); // 15:30 Bern time
        insert new Store_Appointment__c(Customer__c = mia.Id, Store__c = 'Bern', Purpose__c = 'Bike Service', Status__c = 'Confirmed',
            Appointment_DateTime__c = asIfGmt.addSeconds(-TimeZone.getTimeZone('Europe/Zurich').getOffset(asIfGmt) / 1000));
        GetMyDayAction.Result res = GetMyDayAction.getMyDay(
            new List<GetMyDayAction.Request>{ new GetMyDayAction.Request() })[0];
        Assert.isTrue(res.briefing.contains('[15:30 / 3:30pm] Mia Visitor · Bike Service'), res.briefing);
    }

    @IsTest
    static void dayIsReadInCode() {
        Date today = Date.newInstance(2030, 6, 12);
        Assert.areEqual(today, GetMyDayAction.parseDay(null, today));
        Assert.areEqual(today, GetMyDayAction.parseDay(' Today ', today));
        Assert.areEqual(today.addDays(1), GetMyDayAction.parseDay('morgen', today));
        Assert.areEqual(Date.newInstance(2030, 7, 1), GetMyDayAction.parseDay('2030-07-01T00:00:00.000Z', today));
        Assert.isNull(GetMyDayAction.parseDay('next week', today));
        Assert.isNull(GetMyDayAction.parseDay('2030-13-45', today));

        GetMyDayAction.Request r = new GetMyDayAction.Request();
        r.day = 'someday';
        GetMyDayAction.Result res = GetMyDayAction.getMyDay(new List<GetMyDayAction.Request>{ r })[0];
        Assert.isNull(res.briefing);
        Assert.isTrue(res.message.contains('could not read the day'), res.message);
    }

    @IsTest
    static void anotherDayCanBeBriefed() {
        Date in30 = Date.today().addDays(30);
        GetMyDayAction.Request r = new GetMyDayAction.Request();
        r.day = String.valueOf(in30);
        GetMyDayAction.Result res = GetMyDayAction.getMyDay(new List<GetMyDayAction.Request>{ r })[0];
        Assert.isTrue(res.briefing.contains(Datetime.newInstanceGmt(in30, Time.newInstance(12, 0, 0, 0)).formatGmt('EEEE d MMMM yyyy')));
        Assert.isTrue(res.briefing.contains('Overdue by 31 days'), res.briefing);
    }

    @IsTest
    static void noStoreGivesAMessageNotABriefing() {
        System.runAs(new User(Id = UserInfo.getUserId())) {
            update new User(Id = UserInfo.getUserId(), Store__c = null);
        }
        GetMyDayAction.Result res = GetMyDayAction.getMyDay(
            new List<GetMyDayAction.Request>{ new GetMyDayAction.Request() })[0];
        Assert.areEqual(0, res.itemCount);
        Assert.isTrue(res.message.startsWith('No store is set'));
        Assert.isTrue(res.briefing.endsWith(res.message));
    }

    // --- Create Staff Task ---

    @IsTest
    static void nameMatchingSeveralCustomersPrefersMyStore() {
        CreateStaffTaskAction.Result res = create('Call Lucas about his bike service', Date.today().addDays(3), 'lucas', null, false);
        Assert.isTrue(res.success, res.message);
        Assert.areEqual('Lucas Aebi', res.customerName);
        Task t = [SELECT OwnerId, WhoId, ActivityDate, Priority, Status, WhatId FROM Task WHERE Id = :res.taskId];
        Assert.areEqual(UserInfo.getUserId(), t.OwnerId);
        Assert.areEqual([SELECT Id FROM Contact WHERE LastName = 'Aebi'].Id, t.WhoId);
        Assert.areEqual(Date.today().addDays(3), t.ActivityDate);
        Assert.areEqual('Normal', t.Priority);
        Assert.isNull(t.WhatId);
        Assert.isTrue(res.message.startsWith('Task created: "Call Lucas about his bike service", due '), res.message);
    }

    @IsTest
    static void ambiguousNameOutsideMyStoreAsksWhichOne() {
        CreateStaffTaskAction.Result res = create('Send the catalogue', Date.today(), 'Lea', null, false);
        Assert.isFalse(res.success);
        Assert.areEqual('Several customers match "Lea": Lea Bauer, Lea Roux. Which one?', res.message);
        Assert.areEqual(1, [SELECT COUNT() FROM Task], 'nothing created');
    }

    @IsTest
    static void customerByEmailAndHighPriority() {
        CreateStaffTaskAction.Request r = new CreateStaffTaskAction.Request();
        r.subject = 'Send Lea the brochure';
        r.dueDate = Date.today();
        r.customerEmail = 'LEA.M@example.com ';
        r.priority = 'high';
        CreateStaffTaskAction.Result res = CreateStaffTaskAction.createTasks(new List<CreateStaffTaskAction.Request>{ r })[0];
        Assert.isTrue(res.success, res.message);
        Assert.areEqual('Lea Roux', res.customerName);
        Assert.isTrue(res.message.endsWith(', about Lea Roux, high priority.'), res.message);
    }

    @IsTest
    static void followUpLinksToLatestVisitAndClearsMyDay() {
        CreateStaffTaskAction.Result res = create('Thank Mia for her visit', Date.today().addDays(1), 'Mia Visitor', null, true);
        Assert.isTrue(res.success, res.message);
        Assert.isTrue(res.message.endsWith('Linked to the customer\'s latest visit as its follow-up.'), res.message);
        Store_Appointment__c latest = [SELECT Id FROM Store_Appointment__c ORDER BY Appointment_DateTime__c DESC LIMIT 1];
        Assert.areEqual(latest.Id, [SELECT WhatId FROM Task WHERE Id = :res.taskId].WhatId);

        MyDayService.MyDay day = MyDayService.forCurrentUser();
        Assert.areEqual(1, day.section('FOLLOW_UP').items.size(), 'only the older visit still needs a follow-up');
    }

    @IsTest
    static void followUpWithoutRecentVisitIsStillCreated() {
        CreateStaffTaskAction.Result res = create('Check in with Lucas', Date.today(), 'Lucas Aebi', null, true);
        Assert.isTrue(res.success, res.message);
        Assert.isTrue(res.message.contains('so it is not linked to a visit'), res.message);
    }

    @IsTest
    static void taskWithoutCustomer() {
        CreateStaffTaskAction.Result res = create('Order a helmet sample', Date.today().addDays(2), null, null, null);
        Assert.isTrue(res.success, res.message);
        Assert.isNull(res.customerName);
        Assert.isNull([SELECT WhoId FROM Task WHERE Id = :res.taskId].WhoId);
    }

    @IsTest
    static void invalidRequestsAreExplainedNotCreated() {
        Assert.areEqual('The due date must be today or later.', create('Too late', Date.today().addDays(-1), null, null, false).message);
        Assert.areEqual('The due date must be today or later.', create('No date', null, null, null, false).message);
        Assert.areEqual('The task needs a subject: what should be done?', create(' ', Date.today(), null, null, false).message);
        Assert.areEqual('No customer found matching "Zoe". Could you give the full name or email?', create('Call Zoe', Date.today(), 'Zoe', null, false).message);
        Assert.areEqual('No customer found with the email zoe@example.com.', create('Call Zoe', Date.today(), null, 'zoe@example.com', false).message);
        Assert.areEqual('A follow-up needs a customer: which customer is it about?', create('Follow up', Date.today(), null, null, true).message);
        Assert.areEqual(1, [SELECT COUNT() FROM Task], 'nothing created');
    }

    @IsTest
    static void bulkRequestsUseOneInsert() {
        List<CreateStaffTaskAction.Request> rs = new List<CreateStaffTaskAction.Request>();
        for (Integer i = 0; i < 100; i++) {
            CreateStaffTaskAction.Request r = new CreateStaffTaskAction.Request();
            r.subject = 'Task ' + i;
            r.dueDate = Date.today();
            r.customerName = Math.mod(i, 2) == 0 ? 'Aebi' : null;
            r.customerEmail = Math.mod(i, 3) == 0 ? 'mia@example.com' : null;
            rs.add(r);
        }
        Test.startTest();
        List<CreateStaffTaskAction.Result> results = CreateStaffTaskAction.createTasks(rs);
        Assert.isTrue(Limits.getQueries() <= 4, 'fixed number of queries: ' + Limits.getQueries());
        Assert.areEqual(1, Limits.getDmlStatements());
        Test.stopTest();
        for (CreateStaffTaskAction.Result r : results) Assert.isTrue(r.success, r.message);
        Assert.areEqual(101, [SELECT COUNT() FROM Task]);
    }

    // --- Get Customer Brief ---

    private static GetCustomerBriefAction.Result brief(String name, String email) {
        GetCustomerBriefAction.Request r = new GetCustomerBriefAction.Request();
        r.customerName = name;
        r.customerEmail = email;
        return GetCustomerBriefAction.getBriefs(new List<GetCustomerBriefAction.Request>{ r })[0];
    }

    @IsTest
    static void briefShowsTierVisitsTasksAndSuggestions() {
        Contact mia = [SELECT Id FROM Contact WHERE LastName = 'Visitor'];
        insert new Task(OwnerId = UserInfo.getUserId(), WhoId = mia.Id, Subject = 'Send Mia the brochure', ActivityDate = Date.today());
        GetCustomerBriefAction.Result res = brief('mia', null);
        Assert.isTrue(res.found, 'not found: ' + res.message);
        Assert.areEqual('Mia Visitor', res.customerName);
        List<String> lines = res.brief.split('\n');
        Assert.areEqual('Mia Visitor · mia@example.com · home store Bern', lines[0]);
        Assert.isTrue(lines[1].startsWith('Tier: New · lifetime spend CHF 0 · 0 confirmed orders'), lines[1]);
        Assert.areEqual('Owns: nothing yet', lines[2]);
        Assert.areEqual('Unconfirmed orders: none', lines[3]);
        Assert.isTrue(lines[4].startsWith('Recent visits in Bern: Bike Consultation on ') && lines[4].contains('; Bike Service on '), lines[4]);
        Assert.areEqual('Upcoming visits: none', lines[5]);
        Assert.isTrue(lines[6].startsWith('My open tasks about this customer: Send Mia the brochure (due '), lines[6]);
        Assert.areEqual('Suggestions: none', lines[7], 'no catalogue in this test');
    }

    @IsTest
    static void visitorsOfMyStoreAreInScope() {
        Contact lea = [SELECT Id FROM Contact WHERE LastName = 'Bauer'];
        insert new Store_Appointment__c(Customer__c = lea.Id, Store__c = 'Bern', Purpose__c = 'Bike Consultation', Status__c = 'Confirmed',
                                           Appointment_DateTime__c = Datetime.now().addDays(1));
        GetCustomerBriefAction.Result res = brief('Lea', null);
        Assert.isTrue(res.found, 'Lea Bauer visits Bern, Lea Roux does not: ' + res.message);
        Assert.areEqual('Lea Bauer', res.customerName);
        Assert.isTrue(res.brief.contains('home store Munich'));
    }

    @IsTest
    static void customersOfOtherStoresAreNotBriefed() {
        Assert.areEqual('No customer of the Bern store matches "Favre".', brief('Favre', null).message);
        Assert.areEqual('No customer of the Bern store has the email lucas.g@example.com.', brief(null, 'lucas.g@example.com').message);
        GetCustomerBriefAction.Result lucas = brief('Lucas', null);
        Assert.areEqual('Lucas Aebi', lucas.customerName, 'the Lausanne Lucas is out of scope, so there is no ambiguity');
        Assert.isFalse(brief('Lea', null).found, 'neither Lea is a customer or visitor of Bern');
    }

    @IsTest
    static void briefNeedsACustomerAndAStore() {
        Assert.areEqual('Which customer? Please give a name or an email address.', brief(null, null).message);
        System.runAs(new User(Id = UserInfo.getUserId())) {
            update new User(Id = UserInfo.getUserId(), Store__c = null);
        }
        Assert.isTrue(brief('Mia', null).message.startsWith('No store is set on your user'));
    }

    // --- Get Customer Brief by visit time ---

    private static GetCustomerBriefAction.Result briefAt(String visitTime) {
        GetCustomerBriefAction.Request r = new GetCustomerBriefAction.Request();
        r.visitTime = visitTime;
        return GetCustomerBriefAction.getBriefs(new List<GetCustomerBriefAction.Request>{ r })[0];
    }

    private static void visitTodayAt(String lastName, Integer hour, String store) {
        Contact c = [SELECT Id FROM Contact WHERE LastName = :lastName];
        Datetime asIfGmt = Datetime.newInstanceGmt(Date.today(), Time.newInstance(hour, 0, 0, 0)); // store-local hour
        insert new Store_Appointment__c(Customer__c = c.Id, Store__c = store, Purpose__c = 'Bike Service', Status__c = 'Confirmed',
            Appointment_DateTime__c = asIfGmt.addSeconds(-TimeZone.getTimeZone('Europe/Zurich').getOffset(asIfGmt) / 1000));
    }

    @IsTest
    static void visitTimeFindsTodaysCustomerInAnyFormat() {
        visitTodayAt('Visitor', 15, 'Bern');
        visitTodayAt('Favre', 15, 'Lausanne'); // same time, other store: never picked
        for (String t : new List<String>{ '3pm', 'my 3 PM', '15:00', '15 Uhr', '15h', '3' }) {
            GetCustomerBriefAction.Result res = briefAt(t);
            Assert.isTrue(res.found, t + ': ' + res.message);
            Assert.areEqual('Mia Visitor', res.customerName, t);
        }
    }

    @IsTest
    static void noVisitAtThatTimeListsTodaysVisits() {
        visitTodayAt('Visitor', 15, 'Bern');
        visitTodayAt('Aebi', 11, 'Bern');
        Assert.areEqual('There is no visit at 16:00 today. Today\'s visits: 11:00 Lucas Aebi (Bike Service), 15:00 Mia Visitor (Bike Service). Which one should I prepare?',
                        briefAt('4pm').message);
        Assert.isTrue(briefAt('after lunch').message.startsWith('I could not read the time "after lunch". Today\'s visits:'));
    }

    @IsTest
    static void noVisitsTodayAtAll() {
        Assert.areEqual('There is no visit at 15:00 today. There are no visits in Bern today.', briefAt('3pm').message);
    }

    @IsTest
    static void timeParser() {
        Map<String, String> cases = new Map<String, String>{
            '3pm' => '15:00', '3:30 p.m.' => '15:30', '12 pm' => '12:00', '12am' => '00:00', '10 am' => '10:00',
            '15.30' => '15:30', '15h30' => '15:30', '10' => '10:00', '7' => '19:00', '25:00' => null, 'soon' => null, '' => null
        };
        for (String input : cases.keySet()) {
            Assert.areEqual(cases.get(input), GetCustomerBriefAction.parseTime(input), input);
        }
    }

    @IsTest
    static void getMyDayWithoutAnyInputMeansToday() {
        List<GetMyDayAction.Result> results = GetMyDayAction.getMyDay(new List<GetMyDayAction.Request>());
        Assert.areEqual(1, results.size());
        Assert.isTrue(results[0].briefing.contains('Call the frame supplier'), results[0].briefing);
    }
}
