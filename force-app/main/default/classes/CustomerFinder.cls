/**
 * Finds customers by email (exact) or name (partial, case-insensitive) for the Staff Assistant actions.
 * Bulk: one query for all emails, one for all names, one for the store scope.
 *
 * When a name matches several customers, the one from the associate's store wins; otherwise the
 * caller gets a question to ask back, naming the candidates.
 * With onlyMyStore, customers are limited to the associate's store: its own customers
 * (Home_Store__c) and customers who have had or booked a visit there.
 */
public inherited sharing class CustomerFinder {

    public class Match {
        public Contact customer;
        /** Set instead of customer when the lookup failed: a sentence the agent can say back. */
        public String problem;
    }

    /** names[i] / emails[i] describe the i-th lookup; an email wins over a name; both blank means "no customer". */
    public static List<Match> find(List<String> names, List<String> emails, String myStore, Boolean onlyMyStore) {
        Set<String> emailSet = new Set<String>();
        List<String> namePatterns = new List<String>();
        for (Integer n = 0; n < names.size(); n++) {
            if (String.isNotBlank(emails[n])) emailSet.add(emails[n].trim().toLowerCase());
            else if (String.isNotBlank(names[n])) namePatterns.add('%' + names[n].trim() + '%');
        }
        List<Contact> byEmail = emailSet.isEmpty() ? new List<Contact>()
            : [SELECT Id, Name, FirstName, Email, Home_Store__c FROM Contact WHERE Email IN :emailSet];
        List<Contact> byName = namePatterns.isEmpty() ? new List<Contact>()
            : [SELECT Id, Name, FirstName, Email, Home_Store__c FROM Contact WHERE Name LIKE :namePatterns ORDER BY Name LIMIT 200];

        Set<Id> inScope = null; // null = any customer
        if (onlyMyStore) {
            inScope = new Set<Id>();
            Set<Id> candidates = new Set<Id>();
            for (Contact c : byEmail) candidates.add(c.Id);
            for (Contact c : byName) candidates.add(c.Id);
            for (Contact c : byEmail) if (myStore != null && c.Home_Store__c == myStore) inScope.add(c.Id);
            for (Contact c : byName) if (myStore != null && c.Home_Store__c == myStore) inScope.add(c.Id);
            if (!candidates.isEmpty() && myStore != null) {
                for (Store_Appointment__c a : [SELECT Customer__c FROM Store_Appointment__c
                                                  WHERE Store__c = :myStore AND Customer__c IN :candidates]) inScope.add(a.Customer__c);
            }
        }
        String scopeLabel = onlyMyStore ? 'customer of the ' + myStore + ' store' : 'customer';

        List<Match> matches = new List<Match>();
        for (Integer n = 0; n < names.size(); n++) {
            Match m = new Match();
            if (String.isNotBlank(emails[n])) {
                String email = emails[n].trim();
                for (Contact c : byEmail) {
                    if (c.Email.equalsIgnoreCase(email) && (inScope == null || inScope.contains(c.Id))) m.customer = c;
                }
                if (m.customer == null) {
                    m.problem = onlyMyStore ? 'No ' + scopeLabel + ' has the email ' + email + '.'
                                               : 'No customer found with the email ' + email + '.';
                }
            } else if (String.isNotBlank(names[n])) {
                String name = names[n].trim();
                List<Contact> all = new List<Contact>(), mine = new List<Contact>();
                for (Contact c : byName) {
                    if (!c.Name.toLowerCase().contains(name.toLowerCase())) continue;
                    if (inScope != null && !inScope.contains(c.Id)) continue;
                    all.add(c);
                    if (myStore != null && c.Home_Store__c == myStore) mine.add(c);
                }
                if (all.size() == 1) m.customer = all[0];
                else if (mine.size() == 1) m.customer = mine[0];
                else if (all.isEmpty()) {
                    m.problem = onlyMyStore ? 'No ' + scopeLabel + ' matches "' + name + '".'
                                               : 'No customer found matching "' + name + '". Could you give the full name or email?';
                } else {
                    List<String> candidateNames = new List<String>();
                    for (Contact c : all) candidateNames.add(c.Name);
                    m.problem = 'Several customers match "' + name + '": ' + String.join(candidateNames, ', ') + '. Which one?';
                }
            }
            matches.add(m);
        }
        return matches;
    }
}
