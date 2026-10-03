/**
 * Agentforce action: book a store appointment for an existing customer.
 * Business rules enforced in code (not left to the LLM):
 *  - customer must exist (matched by email)
 *  - store and purpose must be valid values
 *  - opening hours Mon-Sat 10:00-19:00 local store time, slots on the hour or half hour, 1 hour long
 *  - no double booking at the same store; if taken, the next free slot that day is suggested
 * New appointments are created with Status = Requested so a store advisor confirms them.
 */
public without sharing class StoreAppointmentAction {

    private static final Map<String, String> STORE_TIMEZONES = new Map<String, String>{
        'Lausanne' => 'Europe/Zurich', 'Bern' => 'Europe/Zurich',
        'Lyon' => 'Europe/Paris', 'Munich' => 'Europe/Berlin'
    };
    private static final Set<String> PURPOSES = new Set<String>{ 'Bike Consultation', 'Bike Service', 'Bike Fitting', 'Collection' };
    private static final Integer OPEN_HOUR = 10;
    private static final Integer LAST_START_HOUR = 18; // last slot starts 18:00, store closes 19:00

    public class Request {
        @InvocableVariable(label='Customer Email' description='Email address of the existing customer' required=true)
        public String email;
        @InvocableVariable(label='Store' description='One of: Lausanne, Bern, Lyon, Munich' required=true)
        public String store;
        @InvocableVariable(label='Purpose' description='One of: Bike Consultation, Bike Service, Bike Fitting, Collection' required=true)
        public String purpose;
        @InvocableVariable(label='Appointment Date' description='Requested date of the visit' required=true)
        public Date appointmentDate;
        @InvocableVariable(label='Appointment Time' description='Requested start time in 24h HH:mm format, local store time, e.g. 14:30' required=true)
        public String appointmentTime;
        @InvocableVariable(label='Notes' description='Optional details from the customer, e.g. which bike they are interested in')
        public String notes;
    }

    public class Result {
        @InvocableVariable(label='Success' description='True if the appointment request was created') public Boolean success;
        @InvocableVariable(label='Appointment Number') public String appointmentNumber;
        @InvocableVariable(label='Booked Slot' description='Date and local time of the booked slot') public String bookedSlot;
        @InvocableVariable(label='Suggested Alternative Time' description='Next free time that day (HH:mm) if the requested slot was taken') public String suggestedTime;
        @InvocableVariable(label='Message' description='Explanation the agent can share with the customer') public String message;
    }

    @InvocableMethod(label='Book Store Appointment'
        description='Creates a store appointment request for an existing customer after checking opening hours and availability. If the slot is taken it returns the next free time instead of booking.')
    public static List<Result> book(List<Request> requests) {
        List<Result> results = new List<Result>();
        for (Request req : requests) { // agents call this one request at a time
            results.add(bookOne(req));
        }
        return results;
    }

    private static Result bookOne(Request req) {
        Result res = new Result();
        res.success = false;

        List<Contact> customers = String.isBlank(req.email) ? new List<Contact>()
            : [SELECT Id, FirstName FROM Contact WHERE Email = :req.email.trim() LIMIT 1];
        if (customers.isEmpty()) {
            return fail(res, 'No customer found with that email address. Ask for the email used for previous orders, or offer to have an advisor get in touch.');
        }
        if (!STORE_TIMEZONES.containsKey(req.store)) {
            return fail(res, 'Unknown store. Available stores: Lausanne, Bern, Lyon, Munich.');
        }
        if (!PURPOSES.contains(req.purpose)) {
            return fail(res, 'Unknown purpose. Choose Bike Consultation, Bike Service, Bike Fitting or Collection.');
        }
        if (req.appointmentDate == null) {
            return fail(res, 'Please provide a date for the visit.');
        }
        Integer[] hm = parseTime(req.appointmentTime);
        if (hm == null) {
            return fail(res, 'Please provide the time as HH:mm on the hour or half hour, for example 14:30.');
        }
        if (isSunday(req.appointmentDate)) {
            return fail(res, 'Our stores are closed on Sundays. Opening hours are Monday to Saturday, 10:00 to 19:00.');
        }
        if (hm[0] < OPEN_HOUR || hm[0] > LAST_START_HOUR || (hm[0] == LAST_START_HOUR && hm[1] > 0)) {
            return fail(res, 'Appointments can start between 10:00 and 18:00 (store closes at 19:00).');
        }

        String tz = STORE_TIMEZONES.get(req.store);
        Datetime startGmt = toGmt(req.appointmentDate, hm[0], hm[1], tz);
        if (startGmt <= Datetime.now()) {
            return fail(res, 'That time is in the past. Please choose a future date and time.');
        }

        // All active appointments at this store on that day
        Datetime dayStart = toGmt(req.appointmentDate, 0, 0, tz);
        Datetime dayEnd = dayStart.addDays(1);
        List<Store_Appointment__c> sameDay = [
            SELECT Appointment_DateTime__c FROM Store_Appointment__c
            WHERE Store__c = :req.store AND Status__c != 'Cancelled'
              AND Appointment_DateTime__c >= :dayStart AND Appointment_DateTime__c < :dayEnd];

        if (!isFree(startGmt, sameDay)) {
            res.suggestedTime = nextFreeTime(req.appointmentDate, hm[0], hm[1], tz, sameDay);
            return fail(res, res.suggestedTime == null
                ? 'That slot is taken and there are no later slots free that day. Please suggest another day.'
                : 'That slot is taken. The next free time that day is ' + res.suggestedTime + '.');
        }

        Store_Appointment__c appt = new Store_Appointment__c(
            Customer__c = customers[0].Id,
            Store__c = req.store,
            Purpose__c = req.purpose,
            Appointment_DateTime__c = startGmt,
            Status__c = 'Requested',
            Notes__c = req.notes
        );
        insert appt;

        res.success = true;
        res.appointmentNumber = [SELECT Name FROM Store_Appointment__c WHERE Id = :appt.Id].Name;
        res.bookedSlot = formatLocal(req.appointmentDate, hm[0], hm[1]) + ' (' + req.store + ' time)';
        res.message = 'Appointment ' + res.appointmentNumber + ' requested for ' + res.bookedSlot
            + '. A store advisor will confirm it shortly.';
        return res;
    }

    // ---------- helpers ----------

    private static Result fail(Result res, String message) {
        res.success = false;
        res.message = message;
        return res;
    }

    /** "14:30" -> [14, 30]; only :00 and :30 are allowed. */
    @TestVisible
    private static Integer[] parseTime(String value) {
        if (String.isBlank(value) || !Pattern.matches('\\d{1,2}:\\d{2}', value.trim())) return null;
        String[] parts = value.trim().split(':');
        Integer h = Integer.valueOf(parts[0]);
        Integer m = Integer.valueOf(parts[1]);
        if (h > 23 || (m != 0 && m != 30)) return null;
        return new Integer[]{ h, m };
    }

    private static Boolean isSunday(Date d) {
        return Datetime.newInstanceGmt(d, Time.newInstance(12, 0, 0, 0)).formatGmt('u') == '7';
    }

    /** Converts a local store date/time to the GMT instant stored in Salesforce. */
    @TestVisible
    private static Datetime toGmt(Date d, Integer h, Integer m, String tzId) {
        Datetime asIfGmt = Datetime.newInstanceGmt(d, Time.newInstance(h, m, 0, 0));
        Integer offsetMs = TimeZone.getTimeZone(tzId).getOffset(asIfGmt);
        return asIfGmt.addSeconds(-offsetMs / 1000);
    }

    /** Appointments last one hour: a slot is free if no other appointment starts within 60 minutes of it. */
    private static Boolean isFree(Datetime candidate, List<Store_Appointment__c> existing) {
        for (Store_Appointment__c a : existing) {
            Long diffMs = Math.abs(a.Appointment_DateTime__c.getTime() - candidate.getTime());
            if (diffMs < 60 * 60 * 1000) return false;
        }
        return true;
    }

    private static String nextFreeTime(Date d, Integer h, Integer m, String tz, List<Store_Appointment__c> existing) {
        Integer minutes = h * 60 + m + 30;
        while (minutes <= LAST_START_HOUR * 60) {
            Integer ch = minutes / 60;
            Integer cm = Math.mod(minutes, 60);
            if (isFree(toGmt(d, ch, cm, tz), existing)) {
                return String.valueOf(ch).leftPad(2, '0') + ':' + String.valueOf(cm).leftPad(2, '0');
            }
            minutes += 30;
        }
        return null;
    }

    private static String formatLocal(Date d, Integer h, Integer m) {
        return Datetime.newInstanceGmt(d, Time.newInstance(h, m, 0, 0)).formatGmt('EEEE d MMMM yyyy \'at\' HH:mm');
    }
}
