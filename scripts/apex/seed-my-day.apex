// Demo seed for the My Day briefing of the running user (Bern associate). Re-runnable:
// removes the previous seed first, and every date is relative to the day you run it.
//   sf apex run -f scripts/apex/seed-my-day.apex -o agentforce-dev
// Times use the running user's time zone (Europe/Berlin = same offset as Bern, Lausanne, Lyon and Munich).
// Real data it builds on: Mia Schneider's Bern collection on 7 Oct with order 00000110 unpaid.

// Seed appointments are recognised by their exact notes (no visible marker in the briefing);
// seed tasks by their Description. Long text can't be filtered in SOQL, so both are checked in Apex.
Set<String> seedNotes = new Set<String>{
    'Helmet sizing for the 2 helmets on her pending order.',
    'Looking for a gravel bike to go with his Strada AL.',
    'Chose the Metro 8; collection booked for 7 Oct once payment is confirmed.'
};
List<SObject> old = new List<SObject>();
for (Task t : [SELECT Id, Description FROM Task WHERE OwnerId = :UserInfo.getUserId()]) {
    if (t.Description != null && t.Description.startsWith('[SEED]')) old.add(t);
}
for (Store_Appointment__c a : [SELECT Id, Notes__c FROM Store_Appointment__c]) {
    if (seedNotes.contains(a.Notes__c)) old.add(a);
}
delete old;

Map<String, Id> customer = new Map<String, Id>();
for (Contact c : [SELECT Id, Email FROM Contact WHERE Email LIKE '%@example.com']) customer.put(c.Email.substringBefore('.'), c.Id);
Date today = Date.today();
Id me = UserInfo.getUserId();

// Appointments: two visits today, one completed visit with no follow-up yet
Store_Appointment__c mia = new Store_Appointment__c(Customer__c = customer.get('mia'), Store__c = 'Bern',
    Purpose__c = 'Bike Consultation', Status__c = 'Completed', Appointment_DateTime__c = Datetime.newInstance(today.addDays(-3), Time.newInstance(14, 0, 0, 0)),
    Notes__c = 'Chose the Metro 8; collection booked for 7 Oct once payment is confirmed.');
insert new List<Store_Appointment__c>{
    new Store_Appointment__c(Customer__c = customer.get('lea'), Store__c = 'Bern', Purpose__c = 'Bike Fitting', Status__c = 'Confirmed',
        Appointment_DateTime__c = Datetime.newInstance(today, Time.newInstance(11, 0, 0, 0)),
        Notes__c = 'Helmet sizing for the 2 helmets on her pending order.'),
    new Store_Appointment__c(Customer__c = customer.get('noah'), Store__c = 'Bern', Purpose__c = 'Bike Consultation', Status__c = 'Confirmed',
        Appointment_DateTime__c = Datetime.newInstance(today, Time.newInstance(15, 0, 0, 0)),
        Notes__c = 'Looking for a gravel bike to go with his Strada AL.'),
    mia
};

// Tasks: 1 overdue, 3 due today (linked to today's visit, to Mia's upcoming collection, standalone), 2 upcoming
String m = '[SEED] My Day demo data';
insert new List<Task>{
    new Task(OwnerId = me, WhoId = customer.get('jonas'), Subject = 'Call Jonas Weber back about helmet sizes', ActivityDate = today.addDays(-2), Priority = 'High', Status = 'Not Started', Description = m),
    new Task(OwnerId = me, WhoId = customer.get('noah'), Subject = 'Prepare a gravel test ride for Noah Brunner', ActivityDate = today, Priority = 'Normal', Status = 'Not Started', Description = m),
    new Task(OwnerId = me, WhoId = customer.get('mia'), Subject = 'Confirm payment for order 00000110', ActivityDate = today, Priority = 'High', Status = 'Not Started', Description = m),
    new Task(OwnerId = me, Subject = 'Update the window display with the Ridgeway AL', ActivityDate = today, Priority = 'Normal', Status = 'Not Started', Description = m),
    new Task(OwnerId = me, Subject = 'Order spare inner tubes for the workshop', ActivityDate = today.addDays(2), Priority = 'Normal', Status = 'Not Started', Description = m),
    new Task(OwnerId = me, WhoId = customer.get('lea'), Subject = 'Send Lea Fontaine the care guide for her new helmets', ActivityDate = today.addDays(5), Priority = 'Normal', Status = 'Not Started', Description = m)
};
System.debug('Seeded 3 appointments and 6 tasks for ' + UserInfo.getName() + ' on ' + today.format());
