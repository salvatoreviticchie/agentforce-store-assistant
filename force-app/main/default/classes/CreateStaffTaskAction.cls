/**
 * Agentforce action (Staff Assistant): "Remind me to call Lucas on Friday".
 * Creates a Task owned by the signed-in associate, about a customer found by email or name.
 * The agent resolves the date ("Friday") and confirms the details with the associate before calling.
 * Follow-ups are linked to the customer's latest completed visit in the associate's store
 * (Task.WhatId), which is what clears the visit from My Day's follow-up section.
 *
 * Customer lookup (CustomerFinder): any customer the associate can see, because writing a
 * reminder about a customer is not reading another store's data.
 */
public with sharing class CreateStaffTaskAction {

    public class Request {
        @InvocableVariable(label='Subject' description='What to do, as a short imperative, e.g. "Call Lucas Moreau about his bike service"' required=true)
        public String subject;
        @InvocableVariable(label='Due Date' description='Date the task is due, resolved from the associate\'s words (e.g. "on Friday" becomes the coming Friday). Today or later.' required=true)
        public Date dueDate;
        @InvocableVariable(label='Customer Name' description='Optional. Full or partial name of the customer the task is about, e.g. "Lucas" or "Lucas Moreau"')
        public String customerName;
        @InvocableVariable(label='Customer Email' description='Optional. Customer email address; use it instead of the name when the associate gives it')
        public String customerEmail;
        @InvocableVariable(label='Priority' description='Optional. High or Normal (default Normal)')
        public String priority;
        @InvocableVariable(label='Is Follow-up' description='Optional. True when the task follows up a visit that already took place; links it to the customer\'s latest completed visit')
        public Boolean isFollowUp;
    }

    public class Result {
        @InvocableVariable(label='Success' description='True if the task was created') public Boolean success;
        @InvocableVariable(label='Task Id') public String taskId;
        @InvocableVariable(label='Customer Name' description='The customer the task was linked to') public String customerName;
        @InvocableVariable(label='Message' description='What happened, or what the agent must clarify with the associate') public String message;
    }

    @InvocableMethod(label='Create Staff Task'
        description='Creates a reminder task for the signed-in sales associate, optionally about a customer (found by name or email) and optionally as a follow-up to the customer\'s latest visit. Only call it after the associate has confirmed the subject, customer and due date.')
    public static List<Result> createTasks(List<Request> requests) {
        Id me = UserInfo.getUserId();
        Date today = Date.today();
        String myStore = [SELECT Store__c FROM User WHERE Id = :me].Store__c;
        List<String> names = new List<String>(), emails = new List<String>();
        for (Request r : requests) {
            names.add(r.customerName);
            emails.add(r.customerEmail);
        }
        List<CustomerFinder.Match> lookups = CustomerFinder.find(names, emails, myStore, false);

        // Latest completed visit in my store (last FOLLOW_UP_DAYS days) per customer, for follow-ups
        Set<Id> followUpCustomers = new Set<Id>();
        for (Integer n = 0; n < requests.size(); n++) {
            CustomerFinder.Match l = lookups[n];
            if (requests[n].isFollowUp == true && l.customer != null) followUpCustomers.add(l.customer.Id);
        }
        Map<Id, Store_Appointment__c> lastVisit = new Map<Id, Store_Appointment__c>();
        if (!followUpCustomers.isEmpty()) {
            for (Store_Appointment__c a : [SELECT Id, Customer__c, Appointment_DateTime__c FROM Store_Appointment__c
                                              WHERE Customer__c IN :followUpCustomers AND Store__c = :myStore
                                                AND Status__c = 'Completed'
                                                AND Appointment_DateTime__c >= :Datetime.newInstance(today.addDays(-MyDayService.FOLLOW_UP_DAYS - 1), Time.newInstance(0, 0, 0, 0))
                                              ORDER BY Appointment_DateTime__c DESC]) {
                if (!lastVisit.containsKey(a.Customer__c)) lastVisit.put(a.Customer__c, a);
            }
        }

        List<Result> results = new List<Result>();
        Map<Integer, Task> toInsert = new Map<Integer, Task>();
        for (Integer n = 0; n < requests.size(); n++) {
            Request r = requests[n];
            CustomerFinder.Match l = lookups[n];
            Result res = new Result();
            res.success = false;
            results.add(res);

            if (String.isBlank(r.subject)) { res.message = 'The task needs a subject: what should be done?'; continue; }
            if (r.dueDate == null || r.dueDate < today) { res.message = 'The due date must be today or later.'; continue; }
            if (l.problem != null) { res.message = l.problem; continue; }
            if (r.isFollowUp == true && l.customer == null) { res.message = 'A follow-up needs a customer: which customer is it about?'; continue; }

            Task t = new Task(OwnerId = me, Subject = r.subject.trim(), ActivityDate = r.dueDate, Status = 'Not Started',
                              Priority = 'High'.equalsIgnoreCase(r.priority) ? 'High' : 'Normal',
                              Description = 'Created by the Staff Assistant');
            if (l.customer != null) {
                t.WhoId = l.customer.Id;
                res.customerName = l.customer.Name;
            }
            if (r.isFollowUp == true && lastVisit.containsKey(l.customer.Id)) t.WhatId = lastVisit.get(l.customer.Id).Id;
            toInsert.put(n, t);
        }
        insert toInsert.values();

        for (Integer n : toInsert.keySet()) {
            Task t = toInsert.get(n);
            Result res = results[n];
            res.success = true;
            res.taskId = t.Id;
            res.message = 'Task created: "' + t.Subject + '", due '
                + Datetime.newInstanceGmt(t.ActivityDate, Time.newInstance(12, 0, 0, 0)).formatGmt('EEEE d MMMM')
                + (res.customerName == null ? '' : ', about ' + res.customerName)
                + (t.Priority == 'High' ? ', high priority' : '') + '.';
            if (requests[n].isFollowUp == true) {
                res.message += t.WhatId != null ? ' Linked to the customer\'s latest visit as its follow-up.'
                    : ' No completed visit in the last ' + MyDayService.FOLLOW_UP_DAYS + ' days was found, so it is not linked to a visit.';
            }
        }
        return results;
    }
}
