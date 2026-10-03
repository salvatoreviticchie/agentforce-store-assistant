/**
 * Agentforce action (Staff Assistant): "What should I do today?"
 * Flattens MyDayService's briefing into numbered text lines, already in priority order,
 * so the agent only phrases them. The briefing is always for the signed-in associate's own
 * store: there is no customer or store input.
 */
public with sharing class GetMyDayAction {

    public class Request {
        @InvocableVariable(label='Day'
            description='Optional. The day to brief as a date in yyyy-MM-dd format (e.g. 2026-10-04), or "tomorrow". Leave empty for today.')
        public String day;
    }

    public class Result {
        @InvocableVariable(label='Briefing' description='The prioritised briefing: a header line, then one numbered line per item under section titles, in the order to present them')
        public String briefing;
        @InvocableVariable(label='Store' description='The associate\'s store')
        public String store;
        @InvocableVariable(label='Item Count' description='Number of numbered items in the briefing')
        public Integer itemCount;
        @InvocableVariable(label='Message' description='Set when there is no briefing, e.g. nothing planned or no store on the user')
        public String message;
    }

    @InvocableMethod(label='Get My Day'
        description='Returns the signed-in sales associate\'s prioritised briefing for their own store: overdue tasks, appointments with customer briefs, actions needed before upcoming visits, tasks due, follow-ups from recent visits, Gold customers to reconnect with, and tasks coming up this week.')
    public static List<Result> getMyDay(List<Request> requests) {
        // The planner sends an empty list when the agent fills none of the (optional) inputs: that means today
        if (requests == null || requests.isEmpty()) requests = new List<Request>{ new Request() };
        List<Result> results = new List<Result>();
        for (Request r : requests) {
            Date day = parseDay(r == null ? null : r.day, Date.today());
            if (day == null) {
                Result res = new Result();
                res.itemCount = 0;
                res.message = 'I could not read the day "' + r.day + '". Please give a date such as 2026-10-04, or say today or tomorrow.';
                results.add(res);
            } else {
                results.add(toResult(MyDayService.build(UserInfo.getUserId(), day)));
            }
        }
        return results;
    }

    /**
     * The day is text, not a Date input: when the model sends "today" or "tomorrow" to a Date input, the
     * platform fails before Apex runs. Here empty/today/tomorrow (EN, DE, FR) and ISO dates are read in code;
     * anything else returns null so the action can say so.
     */
    @TestVisible
    private static Date parseDay(String value, Date today) {
        String v = value == null ? '' : value.trim().toLowerCase();
        if (v == '' || v == 'today' || v == 'heute' || v == 'aujourd\'hui') return today;
        if (v == 'tomorrow' || v == 'morgen' || v == 'demain') return today.addDays(1);
        if (Pattern.matches('\\d{4}-\\d{2}-\\d{2}.*', v)) {
            try {
                return Date.valueOf(v.left(10));
            } catch (Exception e) {
                return null;
            }
        }
        return null;
    }

    private static Result toResult(MyDayService.MyDay day) {
        Result res = new Result();
        res.store = day.store;
        res.message = day.message;
        res.itemCount = 0;
        List<String> lines = new List<String>{
            'Briefing for ' + day.associateName + (day.store == null ? '' : ', ' + day.store + ' store')
                + ', ' + Datetime.newInstanceGmt(day.today, Time.newInstance(12, 0, 0, 0)).formatGmt('EEEE d MMMM yyyy') + '.'
        };
        String tz = MyDayService.timeZoneFor(day.store);
        for (MyDayService.Section s : day.sections) {
            lines.add('');
            lines.add(s.title.toUpperCase());
            for (MyDayService.Item i : s.items) {
                List<String> extra = new List<String>(i.details);
                for (MyDayService.LinkedTask t : i.tasks) extra.add('Open task: ' + t.subject);
                lines.add(i.priority + '. ' + (i.timeLabel == null ? '' : '[' + label(s.key, i, tz) + '] ') + i.headline
                    + (extra.isEmpty() ? '' : ' — ' + String.join(extra, '; ')));
                res.itemCount++;
            }
        }
        if (day.message != null) lines.add(day.message);
        res.briefing = String.join(lines, '\n');
        return res;
    }

    /** Today's visits also get the 12-hour form ("15:00 / 3pm") so "my 3pm" matches as text, without time arithmetic. */
    private static String label(String sectionKey, MyDayService.Item i, String tz) {
        if (sectionKey != 'TODAY' || i.startTime == null) return i.timeLabel;
        String minutes = i.startTime.format('mm', tz);
        return i.timeLabel + ' / ' + i.startTime.format('h', tz) + (minutes == '00' ? '' : ':' + minutes)
            + i.startTime.format('a', tz).toLowerCase();
    }
}
