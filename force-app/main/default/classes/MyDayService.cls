/**
 * "What should I do today?" for a sales associate: a ranked briefing for THEIR store.
 * Code decides what is true and in which order; the Staff Assistant agent and the My Day LWC
 * only render it, so the chat and the card always agree.
 *
 * Privacy: the store always comes from the associate's own User.Store__c. There is no
 * parameter to ask for another store's data.
 *
 * Sections, in priority order (empty sections are left out):
 *  1. OVERDUE      my open tasks due before today (oldest first, High priority first)
 *  2. TODAY        today's appointments in my store, with the customer brief and today's tasks for that customer
 *  3. PRE_VISIT    upcoming Collection visits (next 7 days) where the customer still has an unconfirmed order
 *  4. DUE_TODAY    tasks due today that are not about a customer in sections 2-3
 *  5. FOLLOW_UP    visits completed in the last 7 days with no Task related to the appointment yet
 *  6. RECONNECT  Gold customers of my store with no task, event or visit in the last 90 days
 *  7. UPCOMING     my tasks due in the next 7 days
 */
public with sharing class MyDayService {

    public static final Integer PRE_VISIT_DAYS = 7;
    public static final Integer FOLLOW_UP_DAYS = 7;
    public static final Integer UPCOMING_TASK_DAYS = 7;
    public static final Integer DORMANT_DAYS = 90;

    private static final Map<String, String> STORE_TIMEZONES = new Map<String, String>{
        'Lausanne' => 'Europe/Zurich', 'Bern' => 'Europe/Zurich',
        'Lyon' => 'Europe/Paris', 'Munich' => 'Europe/Berlin'
    };

    public class MyDay {
        @AuraEnabled public String associateName;
        @AuraEnabled public String store;
        @AuraEnabled public Date today;
        @AuraEnabled public String message;
        @AuraEnabled public List<Section> sections = new List<Section>();

        public Section section(String key) {
            for (Section s : sections) if (s.key == key) return s;
            return null;
        }
    }

    public class Section {
        @AuraEnabled public String key;
        @AuraEnabled public String title;
        @AuraEnabled public List<Item> items = new List<Item>();
        Section(String key, String title) { this.key = key; this.title = title; }
    }

    public class Item {
        /** 1 = first thing to do, numbered across the whole briefing. */
        @AuraEnabled public Integer priority;
        /** TASK, APPOINTMENT or CUSTOMER: tells the UI which record recordId is. */
        @AuraEnabled public String type;
        @AuraEnabled public Id recordId;
        @AuraEnabled public Id customerId;
        @AuraEnabled public String customerName;
        @AuraEnabled public Datetime startTime;
        /** Store-local time or date, e.g. "15:00", "Wed 7 Oct 15:00", "due Wed 30 Sep". Not repeated in headline. */
        @AuraEnabled public String timeLabel;
        @AuraEnabled public String headline;
        @AuraEnabled public List<String> details = new List<String>();
        /** Open tasks due today that are about this item's customer. */
        @AuraEnabled public List<LinkedTask> tasks = new List<LinkedTask>();
    }

    public class LinkedTask {
        @AuraEnabled public Id taskId;
        @AuraEnabled public String subject;
        LinkedTask(Task t) { taskId = t.Id; subject = t.Subject; }
    }

    /** Time zone of a store (Europe/Zurich when unknown). */
    public static String timeZoneFor(String store) {
        return STORE_TIMEZONES.containsKey(store) ? STORE_TIMEZONES.get(store) : 'Europe/Zurich';
    }

    /** Briefing for the running user, today in their time zone. */
    public static MyDay forCurrentUser() {
        return build(UserInfo.getUserId(), Date.today());
    }

    /** today is injected so tests (and a "plan tomorrow" feature) don't depend on the clock. */
    public static MyDay build(Id userId, Date today) {
        User u = [SELECT Name, Store__c FROM User WHERE Id = :userId];
        MyDay day = new MyDay();
        day.associateName = u.Name;
        day.store = u.Store__c;
        day.today = today;
        if (String.isBlank(u.Store__c) || !STORE_TIMEZONES.containsKey(u.Store__c)) {
            day.message = 'No store is set on your user, so there is no briefing. Ask your administrator to fill in Store on your user record.';
            return day;
        }
        String tz = STORE_TIMEZONES.get(u.Store__c);
        Datetime dayStart = startOfDay(today, tz);
        Datetime dayEnd = startOfDay(today.addDays(1), tz);

        // --- My open tasks (overdue, today, this week) ---
        List<Task> overdue = new List<Task>(), dueToday = new List<Task>(), upcoming = new List<Task>();
        for (Task t : [SELECT Id, Subject, ActivityDate, Priority, WhoId, Who.Name FROM Task
                       WHERE OwnerId = :userId AND IsClosed = false AND ActivityDate != null
                         AND ActivityDate <= :today.addDays(UPCOMING_TASK_DAYS)]) {
            if (t.ActivityDate < today) overdue.add(t);
            else if (t.ActivityDate == today) dueToday.add(t);
            else upcoming.add(t);
        }
        for (List<Task> ts : new List<List<Task>>{ overdue, dueToday, upcoming }) ts.sort(new TaskOrder());

        // --- My store's appointments: last week (follow-ups), today, next week (pre-visit) ---
        List<Store_Appointment__c> todays = new List<Store_Appointment__c>();
        List<Store_Appointment__c> collections = new List<Store_Appointment__c>();
        Map<Id, Store_Appointment__c> completed = new Map<Id, Store_Appointment__c>();
        for (Store_Appointment__c a : [SELECT Id, Customer__c, Customer__r.Name, Purpose__c, Status__c, Appointment_DateTime__c, Notes__c
                                          FROM Store_Appointment__c
                                          WHERE Store__c = :u.Store__c AND Status__c != 'Cancelled'
                                            AND Appointment_DateTime__c >= :startOfDay(today.addDays(-FOLLOW_UP_DAYS), tz)
                                            AND Appointment_DateTime__c < :startOfDay(today.addDays(PRE_VISIT_DAYS + 1), tz)
                                          ORDER BY Appointment_DateTime__c]) {
            if (a.Appointment_DateTime__c >= dayStart && a.Appointment_DateTime__c < dayEnd) todays.add(a);
            else if (a.Appointment_DateTime__c >= dayEnd && a.Purpose__c == 'Collection' && a.Customer__c != null) collections.add(a);
            else if (a.Appointment_DateTime__c < dayStart && a.Status__c == 'Completed') completed.put(a.Id, a);
        }

        // One bulk profile call for every customer we need to brief
        Set<Id> customerIds = new Set<Id>();
        for (Store_Appointment__c a : todays) if (a.Customer__c != null) customerIds.add(a.Customer__c);
        for (Store_Appointment__c a : collections) customerIds.add(a.Customer__c);
        Map<Id, CustomerProfileService.Profile> profiles = CustomerProfileService.getProfiles(customerIds);

        // Today's tasks about a customer who is coming in go with that customer, the rest stay in "Due today"
        Map<Id, List<Task>> todayTasksByCustomer = new Map<Id, List<Task>>();
        for (Task t : dueToday) {
            if (t.WhoId == null) continue;
            if (!todayTasksByCustomer.containsKey(t.WhoId)) todayTasksByCustomer.put(t.WhoId, new List<Task>());
            todayTasksByCustomer.get(t.WhoId).add(t);
        }
        Set<Id> mergedCustomers = new Set<Id>();

        Section sOverdue = new Section('OVERDUE', 'Overdue tasks');
        for (Task t : overdue) {
            Item i = taskItem(t);
            i.timeLabel = 'due ' + dateLabel(t.ActivityDate);
            Integer late = t.ActivityDate.daysBetween(today);
            i.details.add('Overdue by ' + late + (late == 1 ? ' day' : ' days'));
            sOverdue.items.add(i);
        }

        Section sToday = new Section('TODAY', 'Today\'s appointments');
        for (Store_Appointment__c a : todays) {
            Item i = appointmentItem(a);
            i.timeLabel = a.Appointment_DateTime__c.format('HH:mm', tz);
            i.headline = (a.Customer__c == null ? 'Walk-in' : a.Customer__r.Name) + ' · ' + a.Purpose__c;
            if (a.Status__c == 'Requested') i.details.add('Not yet confirmed with the customer');
            addCustomerBrief(i, profiles.get(a.Customer__c));
            CustomerProfileService.Profile p = profiles.get(a.Customer__c);
            if (p != null && !p.pendingOrderNumbers.isEmpty()) {
                i.details.add('Unconfirmed order ' + String.join(p.pendingOrderNumbers, ', ') + ': check payment');
            }
            if (String.isNotBlank(a.Notes__c)) i.details.add('Notes: ' + a.Notes__c);
            attachTasks(i, todayTasksByCustomer, mergedCustomers);
            sToday.items.add(i);
        }

        Section sPreVisit = new Section('PRE_VISIT', 'Before upcoming visits');
        for (Store_Appointment__c a : collections) {
            CustomerProfileService.Profile p = profiles.get(a.Customer__c);
            if (p == null || p.pendingOrderNumbers.isEmpty()) continue;
            Item i = appointmentItem(a);
            i.timeLabel = a.Appointment_DateTime__c.format('EEE d MMM HH:mm', tz);
            i.headline = a.Customer__r.Name + ' · Collection';
            i.details.add('Order ' + String.join(p.pendingOrderNumbers, ', ')
                + ' is not confirmed yet: make sure payment is settled before the collection');
            attachTasks(i, todayTasksByCustomer, mergedCustomers);
            sPreVisit.items.add(i);
        }

        Section sDueToday = new Section('DUE_TODAY', 'Due today');
        for (Task t : dueToday) {
            if (t.WhoId != null && mergedCustomers.contains(t.WhoId)) continue;
            Item i = taskItem(t);
            i.timeLabel = 'today';
            sDueToday.items.add(i);
        }

        Section sFollowUp = new Section('FOLLOW_UP', 'Follow-ups from recent visits');
        if (!completed.isEmpty()) {
            Set<Id> followedUp = new Set<Id>();
            for (Task t : [SELECT WhatId FROM Task WHERE WhatId IN :completed.keySet()]) followedUp.add(t.WhatId);
            for (Store_Appointment__c a : completed.values()) {
                if (followedUp.contains(a.Id) || a.Customer__c == null) continue;
                Item i = appointmentItem(a);
                i.timeLabel = a.Appointment_DateTime__c.format('EEE d MMM', tz);
                i.headline = a.Customer__r.Name + ' · ' + a.Purpose__c + ' visit on ' + i.timeLabel;
                i.details.add('No follow-up yet: thank the customer or plan the next step');
                sFollowUp.items.add(i);
            }
        }

        Section sReconnect = new Section('RECONNECT', 'Customers to reconnect with');
        sReconnect.items.addAll(dormantGoldCustomers(u.Store__c, today, tz));

        Section sUpcoming = new Section('UPCOMING', 'Coming up this week');
        for (Task t : upcoming) {
            Item i = taskItem(t);
            i.timeLabel = dateLabel(t.ActivityDate);
            sUpcoming.items.add(i);
        }

        Integer priority = 0;
        for (Section s : new List<Section>{ sOverdue, sToday, sPreVisit, sDueToday, sFollowUp, sReconnect, sUpcoming }) {
            if (s.items.isEmpty()) continue;
            for (Item i : s.items) i.priority = ++priority;
            day.sections.add(s);
        }
        if (day.sections.isEmpty()) day.message = 'Nothing planned for ' + u.Store__c + ' today.';
        return day;
    }

    /** Gold customers (Data Cloud lifetime value, CRM fallback) of my store with no contact in DORMANT_DAYS. */
    private static List<Item> dormantGoldCustomers(String store, Date today, String tz) {
        Map<Id, Contact> mine = new Map<Id, Contact>([SELECT Id, Name FROM Contact WHERE Home_Store__c = :store LIMIT 2000]);
        Map<Id, CustomerProfileService.LifetimeValue> values = CustomerProfileService.getLifetimeValues(mine.keySet());
        Set<Id> gold = new Set<Id>();
        for (Id cid : values.keySet()) if (values.get(cid).tier == 'Gold') gold.add(cid);
        if (gold.isEmpty()) return new List<Item>();

        Date cutoff = today.addDays(-DORMANT_DAYS);
        Set<Id> contacted = new Set<Id>();
        for (Task t : [SELECT WhoId FROM Task WHERE WhoId IN :gold AND ActivityDate >= :cutoff]) contacted.add(t.WhoId);
        for (Event e : [SELECT WhoId FROM Event WHERE WhoId IN :gold AND ActivityDate >= :cutoff]) contacted.add(e.WhoId);
        for (Store_Appointment__c a : [SELECT Customer__c FROM Store_Appointment__c
                                          WHERE Customer__c IN :gold AND Status__c != 'Cancelled'
                                            AND Appointment_DateTime__c >= :startOfDay(cutoff, tz)]) contacted.add(a.Customer__c);

        List<Item> items = new List<Item>();
        for (Id cid : gold) {
            if (contacted.contains(cid)) continue;
            CustomerProfileService.LifetimeValue v = values.get(cid);
            Item i = new Item();
            i.type = 'CUSTOMER';
            i.recordId = cid;
            i.customerId = cid;
            i.customerName = mine.get(cid).Name;
            i.headline = i.customerName + ' · Gold customer';
            i.details.add('Lifetime spend CHF ' + v.spend.setScale(0).format()
                + (v.lastOrderDate == null ? '' : ' · last purchase ' + v.lastOrderDate));
            i.details.add('No visit, task or event in the last ' + DORMANT_DAYS + ' days');
            items.add(i);
        }
        items.sort(new SpendOrder(values));
        return items;
    }

    private static Item taskItem(Task t) {
        Item i = new Item();
        i.type = 'TASK';
        i.recordId = t.Id;
        i.headline = t.Subject;
        if (t.WhoId != null) {
            i.customerId = t.WhoId;
            i.customerName = t.Who.Name;
        }
        if (t.Priority == 'High') i.details.add('High priority');
        return i;
    }

    private static Item appointmentItem(Store_Appointment__c a) {
        Item i = new Item();
        i.type = 'APPOINTMENT';
        i.recordId = a.Id;
        i.customerId = a.Customer__c;
        i.customerName = a.Customer__c == null ? null : a.Customer__r.Name;
        i.startTime = a.Appointment_DateTime__c;
        return i;
    }

    /** Tier, what they own and the top 2 suggestions (names and prices only). */
    private static void addCustomerBrief(Item i, CustomerProfileService.Profile p) {
        if (p == null) return;
        i.details.add(p.value.tier + ' customer · owns ' + (p.ownedProducts.isEmpty() ? 'nothing yet' : String.join(p.ownedProducts, ', ')));
        List<String> suggest = new List<String>();
        for (String rec : p.recommendations) {
            if (suggest.size() == 2) break;
            suggest.add(rec.substringBefore(' - '));
        }
        if (!suggest.isEmpty()) i.details.add('Suggest: ' + String.join(suggest, ', '));
    }

    private static void attachTasks(Item i, Map<Id, List<Task>> todayTasksByCustomer, Set<Id> mergedCustomers) {
        if (i.customerId == null || mergedCustomers.contains(i.customerId) || !todayTasksByCustomer.containsKey(i.customerId)) return;
        for (Task t : todayTasksByCustomer.get(i.customerId)) i.tasks.add(new LinkedTask(t));
        mergedCustomers.add(i.customerId);
    }

    private static String dateLabel(Date d) {
        return Datetime.newInstanceGmt(d, Time.newInstance(12, 0, 0, 0)).formatGmt('EEE d MMM');
    }

    /** Midnight of a store-local date, as the GMT instant stored in Salesforce. */
    public static Datetime startOfDay(Date d, String tzId) {
        Datetime asIfGmt = Datetime.newInstanceGmt(d, Time.newInstance(0, 0, 0, 0));
        return asIfGmt.addSeconds(-TimeZone.getTimeZone(tzId).getOffset(asIfGmt) / 1000);
    }

    /** Oldest first; on the same day High priority first, then by subject. */
    private class TaskOrder implements Comparator<Task> {
        public Integer compare(Task a, Task b) {
            if (a.ActivityDate != b.ActivityDate) return a.ActivityDate < b.ActivityDate ? -1 : 1;
            Boolean aHigh = a.Priority == 'High', bHigh = b.Priority == 'High';
            if (aHigh != bHigh) return aHigh ? -1 : 1;
            return String.valueOf(a.Subject).compareTo(String.valueOf(b.Subject));
        }
    }

    /** Highest lifetime spend first. */
    private class SpendOrder implements Comparator<Item> {
        private Map<Id, CustomerProfileService.LifetimeValue> values;
        SpendOrder(Map<Id, CustomerProfileService.LifetimeValue> values) { this.values = values; }
        public Integer compare(Item a, Item b) {
            Decimal sa = values.get(a.customerId).spend, sb = values.get(b.customerId).spend;
            return sa == sb ? 0 : (sa > sb ? -1 : 1);
        }
    }
}
