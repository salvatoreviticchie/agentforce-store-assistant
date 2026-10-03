/**
 * Customer 360 profiles, bulk-safe: shared by the customer-facing Store Assistant (Get Customer Profile)
 * and the associate-facing My Day briefing.
 * Grounding:
 *  - Data Cloud  : lifetime value from the Calculated Insight on the Unified Individual
 *                  (Contact -> IndividualIdentityLink -> Unified Individual -> insight), one query per call.
 *                  The insight only counts confirmed (Activated) orders.
 *  - Salesforce  : owned products, pending orders, upcoming appointments, catalogue for recommendations
 * If Data Cloud has no row (no confirmed purchases) or is unavailable, figures are computed from
 * confirmed CRM orders and the data source says which case applied.
 * Recommendations are rule-based (deterministic) so an LLM only phrases them, never invents products.
 * Sharing is inherited: the Store Assistant runs it without sharing (agent user), My Day with sharing (associate).
 */
public inherited sharing class CustomerProfileService {

    @TestVisible private static final String INSIGHT = 'Customer_Value__cio';
    public static final Decimal GOLD_THRESHOLD = 5000;

    public static final String SOURCE_DATA_CLOUD = 'Data Cloud unified profile (Calculated Insight)';
    public static final String SOURCE_CRM_NO_ROW = 'Salesforce CRM (no confirmed purchases in Data Cloud)';
    public static final String SOURCE_CRM_ERROR = 'Salesforce CRM (Data Cloud unavailable)';

    /** Data Cloud rows to return in unit tests (ConnectApi is not available there): contactId -> [spend, count, lastDate]. */
    @TestVisible private static Map<Id, List<Object>> insightRowsForTest = new Map<Id, List<Object>>();
    @TestVisible private static Boolean simulateDataCloudError = false;

    public class LifetimeValue {
        public Decimal spend;
        public Integer orderCount;
        public String lastOrderDate;
        public String tier;
        public String source;
    }

    public class Profile {
        public Id contactId;
        public String firstName;
        public String name;
        public LifetimeValue value;
        public List<String> ownedProducts = new List<String>();
        public List<String> pendingOrderNumbers = new List<String>();
        public List<String> upcomingAppointments = new List<String>();
        /** "Name (CHF price) - description - reason", best first, at most 3. */
        public List<String> recommendations = new List<String>();
    }

    /** What the CRM orders say about one customer. */
    private class OrderSummary {
        Set<Id> ownedIds = new Set<Id>();
        Set<Id> pendingIds = new Set<Id>();
        List<String> owned = new List<String>();
        List<String> pendingOrderNumbers = new List<String>();
        Decimal spend = 0;
        Integer orders = 0;
        Date last;
    }

    public static String tierFor(Decimal spend) {
        return spend >= GOLD_THRESHOLD ? 'Gold' : (spend > 0 ? 'Member' : 'New');
    }

    /** Full profiles for the given customers. Unknown Ids are simply absent from the result. */
    public static Map<Id, Profile> getProfiles(Set<Id> contactIds) {
        Map<Id, Profile> profiles = new Map<Id, Profile>();
        if (contactIds == null || contactIds.isEmpty()) return profiles;

        Map<Id, OrderSummary> orders = summarizeOrders(contactIds);
        Map<Id, LifetimeValue> values = lifetimeValues(contactIds, orders);
        List<PricebookEntry> catalogue = catalogue();

        for (Contact c : [SELECT Id, FirstName, Name FROM Contact WHERE Id IN :contactIds]) {
            OrderSummary s = orders.get(c.Id);
            Profile p = new Profile();
            p.contactId = c.Id;
            p.firstName = c.FirstName;
            p.name = c.Name;
            p.value = values.get(c.Id);
            p.ownedProducts = s.owned;
            p.pendingOrderNumbers = s.pendingOrderNumbers;
            p.recommendations = recommend(catalogue, s.ownedIds, s.pendingIds, p.value.spend, p.value.orderCount);
            profiles.put(c.Id, p);
        }

        for (Store_Appointment__c a : [SELECT Customer__c, Store__c, Purpose__c, Appointment_DateTime__c, Status__c
                                          FROM Store_Appointment__c
                                          WHERE Customer__c IN :profiles.keySet() AND Appointment_DateTime__c >= :Datetime.now()
                                            AND Status__c != 'Cancelled'
                                          ORDER BY Appointment_DateTime__c]) {
            List<String> visits = profiles.get(a.Customer__c).upcomingAppointments;
            if (visits.size() < 3) {
                visits.add(a.Purpose__c + ' in ' + a.Store__c + ' on '
                    + a.Appointment_DateTime__c.format('d MMM yyyy HH:mm', 'Europe/Zurich') + ' (' + a.Status__c + ')');
            }
        }
        return profiles;
    }

    /** Lifetime value and tier only (no catalogue work): cheap enough to scan a store's customers. */
    public static Map<Id, LifetimeValue> getLifetimeValues(Set<Id> contactIds) {
        if (contactIds == null || contactIds.isEmpty()) return new Map<Id, LifetimeValue>();
        return lifetimeValues(contactIds, summarizeOrders(contactIds));
    }

    private static Map<Id, OrderSummary> summarizeOrders(Set<Id> contactIds) {
        Map<Id, OrderSummary> byCustomer = new Map<Id, OrderSummary>();
        for (Id cid : contactIds) byCustomer.put(cid, new OrderSummary());
        for (Order o : [SELECT BillToContactId, OrderNumber, Status, EffectiveDate,
                               (SELECT Product2Id, Product2.Name, TotalPrice FROM OrderItems)
                        FROM Order WHERE BillToContactId IN :contactIds ORDER BY EffectiveDate DESC]) {
            OrderSummary s = byCustomer.get(o.BillToContactId);
            if (o.Status != 'Activated') { // drafts are not purchases, but the customer is already getting these items
                s.pendingOrderNumbers.add(o.OrderNumber);
                for (OrderItem oi : o.OrderItems) s.pendingIds.add(oi.Product2Id);
                continue;
            }
            s.orders++;
            if (s.last == null) s.last = o.EffectiveDate;
            for (OrderItem oi : o.OrderItems) {
                s.spend += oi.TotalPrice;
                if (s.ownedIds.add(oi.Product2Id)) s.owned.add(oi.Product2.Name);
            }
        }
        return byCustomer;
    }

    /** Data Cloud first, CRM orders as fallback, per customer. */
    private static Map<Id, LifetimeValue> lifetimeValues(Set<Id> contactIds, Map<Id, OrderSummary> orders) {
        Map<Id, List<Object>> rows = new Map<Id, List<Object>>();
        Boolean dataCloudError = false;
        try {
            rows = queryInsight(contactIds);
        } catch (Exception e) {
            dataCloudError = true;
            System.debug(LoggingLevel.WARN, 'Data Cloud query failed, using CRM: ' + e.getMessage());
        }
        Map<Id, LifetimeValue> values = new Map<Id, LifetimeValue>();
        for (Id cid : contactIds) {
            LifetimeValue v = new LifetimeValue();
            List<Object> row = rows.get(cid);
            if (row != null) {
                v.spend = toDecimal(row[0]).setScale(0);
                v.orderCount = toDecimal(row[1]).intValue();
                v.lastOrderDate = row[2] == null ? null : String.valueOf(row[2]).left(10);
                v.source = SOURCE_DATA_CLOUD;
            } else {
                OrderSummary s = orders.get(cid);
                v.spend = s.spend;
                v.orderCount = s.orders;
                v.lastOrderDate = s.last == null ? null : String.valueOf(s.last);
                v.source = dataCloudError ? SOURCE_CRM_ERROR : SOURCE_CRM_NO_ROW;
            }
            v.tier = tierFor(v.spend);
            values.put(cid, v);
        }
        return values;
    }

    /** Lifetime value from the Calculated Insight, joined through the identity link table: contactId -> [spend, count, lastDate]. */
    private static Map<Id, List<Object>> queryInsight(Set<Id> contactIds) {
        if (Test.isRunningTest()) {
            if (simulateDataCloudError) throw new CalloutException('Simulated Data Cloud outage');
            return insightRowsForTest;
        }
        List<String> quoted = new List<String>();
        for (Id cid : contactIds) quoted.add('\'' + String.escapeSingleQuotes(cid) + '\'');
        ConnectApi.CdpQueryInput qi = new ConnectApi.CdpQueryInput();
        qi.sql = 'SELECT l.SourceRecordId__c, ci.lifetime_spend__c, ci.order_count__c, ci.last_order_date__c FROM ' + INSIGHT + ' ci '
               + 'JOIN IndividualIdentityLink__dlm l ON ci.customer_id__c = l.UnifiedRecordId__c '
               + 'WHERE l.SourceRecordId__c IN (' + String.join(quoted, ',') + ')';
        ConnectApi.CdpQueryOutputV2 out = ConnectApi.CdpQuery.queryAnsiSqlV2(qi);
        Map<Id, List<Object>> byContact = new Map<Id, List<Object>>();
        for (Object r : (List<Object>) JSON.deserializeUntyped(JSON.serialize(out.data))) {
            List<Object> row = (List<Object>) r;
            byContact.put((Id) String.valueOf(row[0]), new List<Object>{ row[1], row[2], row[3] });
        }
        return byContact;
    }

    private static List<PricebookEntry> catalogue() {
        Id stdPricebook = Test.isRunningTest() ? Test.getStandardPricebookId()
            : [SELECT Id FROM Pricebook2 WHERE IsStandard = true LIMIT 1].Id;
        return [SELECT Product2Id, Product2.Name, Product2.Family, Product2.Description, UnitPrice
                FROM PricebookEntry
                WHERE Pricebook2Id = :stdPricebook AND IsActive = true AND Product2.IsActive = true
                  AND Product2.Family IN ('Bikes', 'Gear')
                ORDER BY UnitPrice, Product2.Name];
    }

    /**
     * Rules: a bike owner gets ONE piece of gear they do not have yet (the most affordable); then bikes
     * not owned, closest in price to the average confirmed order (new customers get the entry-level bikes).
     * Anything owned or in a pending order is excluded.
     */
    private static List<String> recommend(List<PricebookEntry> catalogue, Set<Id> ownedIds, Set<Id> pendingIds,
                                          Decimal spend, Integer orders) {
        Set<Id> excluded = new Set<Id>(ownedIds);
        excluded.addAll(pendingIds);
        Boolean ownsBike = false;
        for (PricebookEntry p : catalogue) {
            if (p.Product2.Family == 'Bikes' && ownedIds.contains(p.Product2Id)) ownsBike = true;
        }
        List<String> recs = new List<String>();
        if (ownsBike) {
            for (PricebookEntry p : catalogue) { // sorted by price: the first eligible item is the most affordable
                if (p.Product2.Family == 'Gear' && !excluded.contains(p.Product2Id)) {
                    recs.add(line(p, 'goes with the bike already owned'));
                    break;
                }
            }
        }
        Decimal target = (spend != null && spend > 0 && orders != null && orders > 0) ? spend / orders : 0;
        List<PricebookEntry> bikes = new List<PricebookEntry>();
        for (PricebookEntry p : catalogue) {
            if (p.Product2.Family == 'Bikes' && !excluded.contains(p.Product2Id)) bikes.add(p);
        }
        // simple selection sort by distance to target price (tiny catalogue)
        while (!bikes.isEmpty() && recs.size() < 3) {
            Integer best = 0;
            for (Integer i = 1; i < bikes.size(); i++) {
                if (Math.abs(bikes[i].UnitPrice - target) < Math.abs(bikes[best].UnitPrice - target)) best = i;
            }
            recs.add(line(bikes[best], target > 0 ? 'in the same range as previous purchases' : 'a good first bike'));
            bikes.remove(best);
        }
        return recs;
    }

    private static String line(PricebookEntry p, String reason) {
        return p.Product2.Name + ' (CHF ' + p.UnitPrice.setScale(0).format() + ') - ' + p.Product2.Description + ' - ' + reason;
    }

    private static Decimal toDecimal(Object o) {
        return o == null ? 0 : Decimal.valueOf(String.valueOf(o));
    }
}
