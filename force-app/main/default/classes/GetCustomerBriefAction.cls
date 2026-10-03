/**
 * Agentforce action (Staff Assistant): "Prepare me for my 3pm" / "Tell me about Mia Schneider".
 * The customer can also be named by the time of today's visit ("my 3pm", "15 Uhr"): Apex parses the
 * time and finds the visit, so the model never has to match times itself.
 * Internal customer brief for the signed-in associate: tier and lifetime spend (Data Cloud first,
 * CRM fallback), what the customer owns and has on order, visits, the associate's open tasks about
 * the customer and what to suggest. Unlike the Store Assistant's Get Customer Profile, tier and spend are
 * meant to be shown: the reader is staff.
 *
 * Privacy: only customers of the associate's own store (CustomerFinder, onlyMyStore).
 */
public with sharing class GetCustomerBriefAction {

    private static final Integer RECENT_VISIT_DAYS = 90;

    public class Request {
        @InvocableVariable(label='Customer Name' description='Full or partial name of the customer, e.g. "Mia" or "Mia Schneider"')
        public String customerName;
        @InvocableVariable(label='Customer Email' description='Customer email address; use it instead of the name when the associate gives it')
        public String customerEmail;
        @InvocableVariable(label='Visit Time' description='Time of today\'s visit, exactly as the associate said it (e.g. "3pm", "15:00", "15 Uhr"), when they refer to a visit by its time instead of the customer\'s name')
        public String visitTime;
    }

    public class Result {
        @InvocableVariable(label='Found' description='True if a customer of the associate\'s store was found') public Boolean found;
        @InvocableVariable(label='Customer Name') public String customerName;
        @InvocableVariable(label='Brief' description='The customer brief, one fact per line, to summarise for the associate') public String brief;
        @InvocableVariable(label='Message' description='When not found: what to say or ask the associate') public String message;
    }

    @InvocableMethod(label='Get Customer Brief'
        description='Returns an internal brief on one customer of the signed-in associate\'s store, found by name or email: contact details, tier and lifetime spend, owned products, unconfirmed orders, recent and upcoming visits, the associate\'s open tasks about the customer and what to suggest.')
    public static List<Result> getBriefs(List<Request> requests) {
        String myStore = [SELECT Store__c FROM User WHERE Id = :UserInfo.getUserId()].Store__c;
        List<String> names = new List<String>(), emails = new List<String>();
        for (Request r : requests) {
            names.add(r.customerName);
            emails.add(r.customerEmail);
        }
        List<CustomerFinder.Match> matches = String.isBlank(myStore)
            ? new List<CustomerFinder.Match>() : CustomerFinder.find(names, emails, myStore, true);
        if (!String.isBlank(myStore)) resolveVisitTimes(requests, matches, myStore);

        Set<Id> customerIds = new Set<Id>();
        for (CustomerFinder.Match m : matches) if (m.customer != null) customerIds.add(m.customer.Id);
        Map<Id, CustomerProfileService.Profile> profiles = CustomerProfileService.getProfiles(customerIds);

        Map<Id, List<String>> visits = new Map<Id, List<String>>();
        Map<Id, List<String>> tasks = new Map<Id, List<String>>();
        if (!customerIds.isEmpty()) {
            for (Store_Appointment__c a : [SELECT Customer__c, Purpose__c, Status__c, Appointment_DateTime__c, Notes__c
                                              FROM Store_Appointment__c
                                              WHERE Customer__c IN :customerIds AND Store__c = :myStore AND Status__c = 'Completed'
                                                AND Appointment_DateTime__c >= :Datetime.now().addDays(-RECENT_VISIT_DAYS)
                                              ORDER BY Appointment_DateTime__c DESC]) {
                add(visits, a.Customer__c, a.Purpose__c + ' on ' + a.Appointment_DateTime__c.format('EEE d MMM', MyDayService.timeZoneFor(myStore))
                    + (String.isBlank(a.Notes__c) ? '' : ' (notes: ' + a.Notes__c + ')'));
            }
            for (Task t : [SELECT WhoId, Subject, ActivityDate FROM Task
                           WHERE WhoId IN :customerIds AND OwnerId = :UserInfo.getUserId() AND IsClosed = false
                           ORDER BY ActivityDate NULLS LAST]) {
                add(tasks, t.WhoId, t.Subject + (t.ActivityDate == null ? '' : ' (due ' + t.ActivityDate.format() + ')'));
            }
        }

        List<Result> results = new List<Result>();
        for (Integer n = 0; n < requests.size(); n++) {
            Result res = new Result();
            res.found = false;
            results.add(res);
            if (String.isBlank(myStore)) {
                res.message = 'No store is set on your user, so I can\'t look up customers. Ask your administrator to fill in Store on your user record.';
                continue;
            }
            CustomerFinder.Match m = matches[n];
            if (m.customer == null) {
                res.message = m.problem != null ? m.problem : 'Which customer? Please give a name or an email address.';
                continue;
            }
            CustomerProfileService.Profile p = profiles.get(m.customer.Id);
            CustomerProfileService.LifetimeValue v = p.value;
            res.found = true;
            res.customerName = p.name;
            List<String> lines = new List<String>{
                p.name + ' · ' + m.customer.Email + ' · home store ' + (m.customer.Home_Store__c == null ? 'not set' : m.customer.Home_Store__c),
                'Tier: ' + v.tier + ' · lifetime spend CHF ' + v.spend.setScale(0).format() + ' · ' + v.orderCount
                    + (v.orderCount == 1 ? ' confirmed order' : ' confirmed orders')
                    + (v.lastOrderDate == null ? '' : ' · last purchase ' + v.lastOrderDate) + ' (source: ' + v.source + ')',
                'Owns: ' + (p.ownedProducts.isEmpty() ? 'nothing yet' : String.join(p.ownedProducts, ', ')),
                'Unconfirmed orders: ' + (p.pendingOrderNumbers.isEmpty() ? 'none' : String.join(p.pendingOrderNumbers, ', ')),
                'Recent visits in ' + myStore + ': ' + join(visits.get(p.contactId)),
                'Upcoming visits: ' + join(p.upcomingAppointments),
                'My open tasks about this customer: ' + join(tasks.get(p.contactId)),
                'Suggestions: ' + join(p.recommendations)
            };
            res.brief = String.join(lines, '\n');
        }
        return results;
    }

    /** For requests naming only a time: the customer of today's visit at exactly that time in my store. */
    private static void resolveVisitTimes(List<Request> requests, List<CustomerFinder.Match> matches, String myStore) {
        List<Integer> byTime = new List<Integer>();
        for (Integer n = 0; n < requests.size(); n++) {
            Request r = requests[n];
            if (String.isBlank(r.customerName) && String.isBlank(r.customerEmail) && String.isNotBlank(r.visitTime)) byTime.add(n);
        }
        if (byTime.isEmpty()) return;

        String tz = MyDayService.timeZoneFor(myStore);
        Date today = Date.today();
        List<Store_Appointment__c> todays = [SELECT Customer__c, Customer__r.Id, Customer__r.Name, Customer__r.FirstName, Customer__r.Email, Customer__r.Home_Store__c,
                                                       Purpose__c, Appointment_DateTime__c
                                                FROM Store_Appointment__c
                                                WHERE Store__c = :myStore AND Status__c != 'Cancelled' AND Customer__c != null
                                                  AND Appointment_DateTime__c >= :MyDayService.startOfDay(today, tz)
                                                  AND Appointment_DateTime__c < :MyDayService.startOfDay(today.addDays(1), tz)
                                                ORDER BY Appointment_DateTime__c];
        List<String> visitList = new List<String>();
        for (Store_Appointment__c a : todays) {
            visitList.add(a.Appointment_DateTime__c.format('HH:mm', tz) + ' ' + a.Customer__r.Name + ' (' + a.Purpose__c + ')');
        }
        String visits = todays.isEmpty() ? 'There are no visits in ' + myStore + ' today.'
                                         : 'Today\'s visits: ' + String.join(visitList, ', ') + '. Which one should I prepare?';

        for (Integer n : byTime) {
            CustomerFinder.Match m = new CustomerFinder.Match();
            matches[n] = m;
            String hhmm = parseTime(requests[n].visitTime);
            if (hhmm == null) {
                m.problem = 'I could not read the time "' + requests[n].visitTime.trim() + '". ' + visits;
                continue;
            }
            for (Store_Appointment__c a : todays) {
                if (a.Appointment_DateTime__c.format('HH:mm', tz) == hhmm) {
                    m.customer = a.Customer__r;
                    break;
                }
            }
            if (m.customer == null) m.problem = 'There is no visit at ' + hhmm + ' today. ' + visits;
        }
    }

    /**
     * "3pm", "3:30 pm", "15:00", "15.30", "15h", "15 Uhr", "15" -> "HH:mm". A bare hour from 1 to 7 is read
     * as afternoon (stores open 10:00-19:00). Returns null when there is no time in the text.
     */
    @TestVisible
    private static String parseTime(String text) {
        if (String.isBlank(text)) return null;
        Matcher m = Pattern.compile('(?i)(\\d{1,2})(?:[:.h](\\d{2}))?\\s*(a\\.?m\\.?|p\\.?m\\.?|uhr|h)?').matcher(text);
        if (!m.find()) return null;
        Integer hour = Integer.valueOf(m.group(1));
        Integer minute = m.group(2) == null ? 0 : Integer.valueOf(m.group(2));
        String suffix = m.group(3) == null ? '' : m.group(3).toLowerCase().replace('.', '');
        if (suffix == 'pm' && hour < 12) hour += 12;
        else if (suffix == 'am' && hour == 12) hour = 0;
        else if (suffix == '' && hour >= 1 && hour <= 7) hour += 12;
        if (hour > 23 || minute > 59) return null;
        return String.valueOf(hour).leftPad(2, '0') + ':' + String.valueOf(minute).leftPad(2, '0');
    }

    private static void add(Map<Id, List<String>> m, Id key, String value) {
        if (!m.containsKey(key)) m.put(key, new List<String>());
        m.get(key).add(value);
    }

    private static String join(List<String> values) {
        return values == null || values.isEmpty() ? 'none' : String.join(values, '; ');
    }
}
