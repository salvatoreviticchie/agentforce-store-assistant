// One-time, idempotent demo data for Northgrade Cycles (fictional). Safe to re-run: existing
// products and customers (matched by SKU / email) are skipped.
//   sf apex run -f scripts/apex/setup-demo-data.apex -o <org>
// Creates: 10 products in the Standard Price Book, 6 customers with orders and store visits,
// and makes the running user the Bern sales associate (User.Store__c) for the Staff Assistant.
// Each persona exists to cover one rule of the agents (see README, "What I tested and why").

update new User(Id = UserInfo.getUserId(), Store__c = 'Bern');

// ---------- Catalogue ----------
Id stdPb = [SELECT Id FROM Pricebook2 WHERE IsStandard = true LIMIT 1].Id;
List<List<Object>> catalogue = new List<List<Object>>{
    // name, family, SKU, description, price (CHF)
    new List<Object>{ 'Metro 8', 'Bikes', 'NG-MET8', 'City bike, aluminium frame, 8-speed hub gears, integrated lights and rack', 1290 },
    new List<Object>{ 'Ridgeway AL', 'Bikes', 'NG-RDG-AL', 'Gravel bike, aluminium frame, 2x11 gears, 40 mm tyres', 1890 },
    new List<Object>{ 'Strada AL', 'Bikes', 'NG-STR-AL', 'Endurance road bike, aluminium frame, hydraulic disc brakes', 2190 },
    new List<Object>{ 'Ridgeway Carbon', 'Bikes', 'NG-RDG-CB', 'Carbon gravel bike, 1x12 gears, bikepacking mounts', 3490 },
    new List<Object>{ 'Strada Carbon', 'Bikes', 'NG-STR-CB', 'Carbon road bike, electronic 2x12 shifting, 8.1 kg', 4290 },
    new List<Object>{ 'Volta Tour E', 'Bikes', 'NG-VOL-E', 'Touring e-bike, 625 Wh battery, up to 120 km range', 5290 },
    new List<Object>{ 'Strada Carbon Pro', 'Bikes', 'NG-STR-PRO', 'Race carbon road bike, aero wheels, 7.4 kg', 6290 },
    new List<Object>{ 'Trail Helmet', 'Gear', 'NG-HLM', 'Ventilated helmet with integrated rear light, sizes S to L', 179 },
    new List<Object>{ 'Light Set', 'Gear', 'NG-LGT', 'USB-rechargeable front and rear lights', 89 },
    new List<Object>{ 'Frame Bag', 'Gear', 'NG-BAG', 'Waterproof 4 L frame bag', 69 }
};
Set<String> skus = new Set<String>();
for (List<Object> p : catalogue) skus.add((String) p[2]);
Set<String> existingSkus = new Set<String>();
for (Product2 p : [SELECT StockKeepingUnit FROM Product2 WHERE StockKeepingUnit IN :skus]) existingSkus.add(p.StockKeepingUnit);
List<Product2> newProducts = new List<Product2>();
Map<String, Decimal> priceBySku = new Map<String, Decimal>();
for (List<Object> p : catalogue) {
    priceBySku.put((String) p[2], (Decimal) p[4]);
    if (existingSkus.contains((String) p[2])) continue;
    newProducts.add(new Product2(Name = (String) p[0], Family = (String) p[1], ProductCode = (String) p[2],
        StockKeepingUnit = (String) p[2], Description = (String) p[3], IsActive = true));
}
insert newProducts;
List<PricebookEntry> newEntries = new List<PricebookEntry>();
for (Product2 p : newProducts) {
    newEntries.add(new PricebookEntry(Pricebook2Id = stdPb, Product2Id = p.Id, UnitPrice = priceBySku.get(p.StockKeepingUnit), IsActive = true));
}
insert newEntries;
Map<String, PricebookEntry> pbe = new Map<String, PricebookEntry>();
for (PricebookEntry e : [SELECT Id, UnitPrice, Product2.Name FROM PricebookEntry
                         WHERE Pricebook2Id = :stdPb AND Product2.StockKeepingUnit IN :skus]) {
    pbe.put(e.Product2.Name, e);
}

// ---------- Customers ----------
// first, last, home store
List<String[]> people = new List<String[]>{
    new String[]{ 'Lea', 'Fontaine', 'Lausanne' },   // Member: confirmed road bike + pending helmets (no owned/pending recommendations)
    new String[]{ 'Jonas', 'Weber', 'Munich' },      // Gold: high-value customer
    new String[]{ 'Noah', 'Brunner', 'Munich' },     // Member: order paid, not shipped yet; visits Bern today (seed)
    new String[]{ 'Mia', 'Schneider', 'Bern' },      // New: only a pending (draft) order + a collection visit
    new String[]{ 'Lucas', 'Moreau', 'Lyon' },       // Gold: collected in store; not a Bern customer (privacy test)
    new String[]{ 'Elias', 'Meier', 'Bern' }         // Gold, Bern, no contact for 90+ days (reconnect list)
};
Set<String> emails = new Set<String>();
for (String[] p : people) emails.add(p[0].toLowerCase() + '.' + p[1].toLowerCase() + '@example.com');
Set<String> existingEmails = new Set<String>();
for (Contact c : [SELECT Email FROM Contact WHERE Email IN :emails]) existingEmails.add(c.Email);

Map<String, Account> accounts = new Map<String, Account>();
for (String[] p : people) {
    String email = p[0].toLowerCase() + '.' + p[1].toLowerCase() + '@example.com';
    if (!existingEmails.contains(email)) accounts.put(email, new Account(Name = p[0] + ' ' + p[1] + ' (Customer)'));
}
insert accounts.values();
Map<String, Contact> contacts = new Map<String, Contact>();
for (String[] p : people) {
    String email = p[0].toLowerCase() + '.' + p[1].toLowerCase() + '@example.com';
    if (!accounts.containsKey(email)) continue;
    contacts.put(p[0], new Contact(AccountId = accounts.get(email).Id, FirstName = p[0], LastName = p[1],
        Email = email, MailingCity = p[2], Home_Store__c = p[2]));
}
insert contacts.values();

// ---------- Orders (inserted in this order so the numbers are consecutive) ----------
// customer, status, date, fulfilment details, items (product => quantity)
List<List<Object>> orderRows = new List<List<Object>>{
    new List<Object>{ 'Lea', 'Activated', Date.newInstance(2026, 8, 12), 'Shipped by courier, tracking NG-7781234560, delivered 2026-08-15', new Map<String, Integer>{ 'Strada Carbon' => 1 } },
    new List<Object>{ 'Jonas', 'Activated', Date.newInstance(2026, 9, 3), 'Shipped by courier, tracking NG-7781239911, in transit', new Map<String, Integer>{ 'Strada Carbon Pro' => 1, 'Trail Helmet' => 1 } },
    new List<Object>{ 'Noah', 'Activated', Date.newInstance(2026, 9, 18), 'Payment received, preparing for shipment', new Map<String, Integer>{ 'Strada AL' => 1 } },
    new List<Object>{ 'Mia', 'Draft', Date.newInstance(2026, 9, 22), 'Awaiting payment confirmation', new Map<String, Integer>{ 'Metro 8' => 1 } },
    new List<Object>{ 'Lucas', 'Activated', Date.newInstance(2026, 7, 30), 'Collected in the Lyon store on 2026-08-02', new Map<String, Integer>{ 'Volta Tour E' => 1 } },
    new List<Object>{ 'Lea', 'Draft', Date.newInstance(2026, 9, 24), 'Draft order created by a store advisor', new Map<String, Integer>{ 'Trail Helmet' => 2 } },
    new List<Object>{ 'Elias', 'Activated', Date.newInstance(2026, 5, 14), null, new Map<String, Integer>{ 'Strada Carbon Pro' => 1 } }
};
List<Order> orders = new List<Order>();
for (List<Object> r : orderRows) {
    Contact c = contacts.get((String) r[0]);
    if (c == null) continue;
    Order o = new Order(AccountId = c.AccountId, BillToContactId = c.Id, Pricebook2Id = stdPb,
        EffectiveDate = (Date) r[2], Status = 'Draft', Description = (String) r[3]);
    insert o; // one by one: OrderNumber follows insertion order
    orders.add(o);
    List<OrderItem> items = new List<OrderItem>();
    Map<String, Integer> lines = (Map<String, Integer>) r[4];
    for (String product : lines.keySet()) {
        PricebookEntry e = pbe.get(product);
        items.add(new OrderItem(OrderId = o.Id, PricebookEntryId = e.Id, Quantity = lines.get(product), UnitPrice = e.UnitPrice));
    }
    insert items;
    if ((String) r[1] == 'Activated') update new Order(Id = o.Id, Status = 'Activated'); // activate after the items exist
}

// ---------- Store visits (local times; the running user's time zone has the same offset) ----------
List<Store_Appointment__c> visits = new List<Store_Appointment__c>();
if (contacts.containsKey('Lucas')) visits.add(new Store_Appointment__c(Customer__c = contacts.get('Lucas').Id, Store__c = 'Lyon',
    Purpose__c = 'Bike Service', Status__c = 'Completed', Appointment_DateTime__c = Datetime.newInstance(2026, 9, 10, 11, 0, 0),
    Notes__c = 'Brake service on his Volta Tour E.'));
if (contacts.containsKey('Lea')) visits.add(new Store_Appointment__c(Customer__c = contacts.get('Lea').Id, Store__c = 'Lausanne',
    Purpose__c = 'Bike Fitting', Status__c = 'Confirmed', Appointment_DateTime__c = Datetime.newInstance(2026, 9, 30, 10, 0, 0),
    Notes__c = 'Saddle fitting on her Strada Carbon and sizing for the 2 helmets on her draft order.'));
if (contacts.containsKey('Jonas')) visits.add(new Store_Appointment__c(Customer__c = contacts.get('Jonas').Id, Store__c = 'Munich',
    Purpose__c = 'Bike Consultation', Status__c = 'Requested', Appointment_DateTime__c = Datetime.newInstance(2026, 10, 10, 15, 30, 0),
    Notes__c = 'Interested in the Volta Tour E as a gift.'));
if (contacts.containsKey('Mia')) visits.add(new Store_Appointment__c(Customer__c = contacts.get('Mia').Id, Store__c = 'Bern',
    Purpose__c = 'Collection', Status__c = 'Requested', Appointment_DateTime__c = Datetime.newInstance(2026, 10, 7, 15, 0, 0),
    Notes__c = 'Wants to collect her Metro 8 in store once payment is confirmed.'));
insert visits;

List<String> numbers = new List<String>();
for (Order o : [SELECT OrderNumber, BillToContact.FirstName, Status FROM Order WHERE Id IN :orders ORDER BY OrderNumber]) {
    numbers.add(o.OrderNumber + ' ' + o.BillToContact.FirstName + ' ' + o.Status);
}
System.debug(LoggingLevel.ERROR, 'ORDERS: ' + String.join(numbers, ' | '));
