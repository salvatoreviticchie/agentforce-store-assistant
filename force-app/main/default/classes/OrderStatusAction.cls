/**
 * Agentforce action: look up a customer's order status.
 * The customer must give the order number AND the email on the order (simple identity check),
 * so the agent never reveals an order to someone who only guessed a number.
 * Runs without sharing because the agent user has no record access of its own;
 * the email match is the access control.
 */
public without sharing class OrderStatusAction {

    public class Request {
        @InvocableVariable(label='Order Number' description='Order number given by the customer, e.g. 00000101 or 101' required=true)
        public String orderNumber;
        @InvocableVariable(label='Customer Email' description='Email address the customer used for the order, used to verify identity' required=true)
        public String email;
    }

    public class Result {
        @InvocableVariable(label='Found' description='True only if the order exists and the email matches')
        public Boolean found;
        @InvocableVariable(label='Order Number') public String orderNumber;
        @InvocableVariable(label='Status' description='Processing (not yet confirmed) or Confirmed') public String status;
        @InvocableVariable(label='Order Date') public Date orderDate;
        @InvocableVariable(label='Total Amount (CHF)') public Decimal totalAmount;
        @InvocableVariable(label='Items' description='Products and quantities on the order') public String items;
        @InvocableVariable(label='Fulfilment Details' description='Shipping, tracking, payment or collection details') public String fulfilmentDetails;
        @InvocableVariable(label='Message' description='Short explanation the agent can share with the customer') public String message;
    }

    @InvocableMethod(label='Get Order Status'
        description='Returns the status, items and shipping or tracking details of a customer order. Requires the order number and the email address on the order; returns found = false if they do not match.')
    public static List<Result> getStatus(List<Request> requests) {
        // Bulk-safe: collect all order numbers, query once
        Set<String> numbers = new Set<String>();
        for (Request req : requests) {
            String n = normalize(req.orderNumber);
            if (n != null) numbers.add(n);
        }
        Map<String, Order> byNumber = new Map<String, Order>();
        for (Order o : [SELECT OrderNumber, Status, EffectiveDate, TotalAmount, Description, BillToContact.Email,
                               (SELECT Quantity, Product2.Name FROM OrderItems)
                        FROM Order WHERE OrderNumber IN :numbers]) {
            byNumber.put(o.OrderNumber, o);
        }

        List<Result> results = new List<Result>();
        for (Request req : requests) {
            results.add(buildResult(byNumber.get(normalize(req.orderNumber)), req.email));
        }
        return results;
    }

    private static Result buildResult(Order o, String email) {
        Result res = new Result();
        res.found = false;
        Boolean emailMatches = o != null && o.BillToContact != null && String.isNotBlank(email)
            && email.trim().equalsIgnoreCase(o.BillToContact.Email);
        if (!emailMatches) {
            // Same message whether the order is missing or the email is wrong: no information leak
            res.message = 'No order matches that order number and email address.';
            return res;
        }
        List<String> lines = new List<String>();
        for (OrderItem oi : o.OrderItems) {
            lines.add(Integer.valueOf(oi.Quantity) + ' x ' + oi.Product2.Name);
        }
        res.found = true;
        res.orderNumber = o.OrderNumber;
        res.status = o.Status == 'Activated' ? 'Confirmed' : 'Processing';
        res.orderDate = o.EffectiveDate;
        res.totalAmount = o.TotalAmount;
        res.items = String.join(lines, ', ');
        res.fulfilmentDetails = o.Description;
        res.message = 'Order ' + o.OrderNumber + ' is ' + res.status.toLowerCase() + '.';
        return res;
    }

    /** Accepts "101", "#00000101", "order 101" and returns the 8-digit OrderNumber format. */
    @TestVisible
    private static String normalize(String raw) {
        if (String.isBlank(raw)) return null;
        String digits = raw.replaceAll('[^0-9]', '');
        return String.isBlank(digits) ? null : digits.leftPad(8, '0');
    }
}
