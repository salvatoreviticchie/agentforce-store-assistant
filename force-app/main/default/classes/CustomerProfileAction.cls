/**
 * Agentforce action: 360° customer profile for personalised advice (Bike Advisor).
 * Thin wrapper: looks the customer up by email and flattens CustomerProfileService's profile
 * into text outputs for the agent. Grounding and recommendation rules live in the service.
 * Runs without sharing (the Store Assistant's agent user looks up any customer by email); the service
 * inherits that, while the associate-facing My Day calls the same service with sharing.
 */
public without sharing class CustomerProfileAction {

    public class Request {
        @InvocableVariable(label='Customer Email' description='Email address of the customer' required=true)
        public String email;
    }

    public class Result {
        @InvocableVariable(label='Found' description='True if the customer exists') public Boolean found;
        @InvocableVariable(label='First Name') public String firstName;
        @InvocableVariable(label='Customer Tier' description='Gold, Member or New') public String tier;
        @InvocableVariable(label='Lifetime Spend (CHF)' description='Confirmed purchases only') public Decimal lifetimeSpend;
        @InvocableVariable(label='Order Count' description='Confirmed orders only') public Integer orderCount;
        @InvocableVariable(label='Last Order Date' description='Date of the last confirmed order') public String lastOrderDate;
        @InvocableVariable(label='Owned Products' description='Products the customer has bought') public String ownedProducts;
        @InvocableVariable(label='Upcoming Appointments' description='Future store visits') public String upcomingAppointments;
        @InvocableVariable(label='Recommendations' description='Up to 3 suggested products with price and reason') public String recommendations;
        @InvocableVariable(label='Data Source' description='Where the value figures came from') public String dataSource;
        @InvocableVariable(label='Message') public String message;
    }

    @InvocableMethod(label='Get Customer Profile'
        description='Returns a customer 360 profile (tier, lifetime spend, owned bikes, upcoming visits) from Data Cloud and Salesforce, plus up to 3 product recommendations grounded in the catalogue. Requires the customer email.')
    public static List<Result> getProfile(List<Request> requests) {
        List<Result> results = new List<Result>();
        for (Request r : requests) results.add(build(r.email)); // agents call one at a time
        return results;
    }

    private static Result build(String email) {
        Result res = new Result();
        res.found = false;
        List<Contact> cs = String.isBlank(email) ? new List<Contact>()
            : [SELECT Id FROM Contact WHERE Email = :email.trim() LIMIT 1];
        if (cs.isEmpty()) {
            res.message = 'No customer found with that email address.';
            return res;
        }
        CustomerProfileService.Profile p =
            CustomerProfileService.getProfiles(new Set<Id>{ cs[0].Id }).get(cs[0].Id);
        res.found = true;
        res.firstName = p.firstName;
        res.tier = p.value.tier;
        res.lifetimeSpend = p.value.spend;
        res.orderCount = p.value.orderCount;
        res.lastOrderDate = p.value.lastOrderDate;
        res.dataSource = p.value.source;
        res.ownedProducts = p.ownedProducts.isEmpty() ? 'None yet' : String.join(p.ownedProducts, ', ');
        res.upcomingAppointments = p.upcomingAppointments.isEmpty() ? 'None' : String.join(p.upcomingAppointments, '; ');
        res.recommendations = p.recommendations.isEmpty() ? 'No recommendations available' : String.join(p.recommendations, ' | ');
        res.message = 'Profile loaded for ' + p.firstName + ' (' + res.tier + ' customer).';
        return res;
    }
}
