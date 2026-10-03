// Deletes the My Day demo seed created by seed-my-day.apex (keep the notes list in sync with it).
//   sf apex run -f scripts/apex/cleanup-my-day.apex -o agentforce-dev
// Seed appointments are recognised by their exact notes (no visible marker in the briefing);
// seed tasks by their Description. Long text can't be filtered in SOQL, so both are checked in Apex.
Set<String> seedNotes = new Set<String>{
    'Helmet sizing for the 2 helmets on her pending order.',
    'Looking for a gravel bike to go with his Strada AL.',
    'Chose the Metro 8; collection booked for 7 Oct once payment is confirmed.'
};
List<SObject> seed = new List<SObject>();
for (Task t : [SELECT Id, Description FROM Task WHERE OwnerId = :UserInfo.getUserId()]) {
    if (t.Description != null && t.Description.startsWith('[SEED]')) seed.add(t);
}
for (Store_Appointment__c a : [SELECT Id, Notes__c FROM Store_Appointment__c]) {
    if (seedNotes.contains(a.Notes__c)) seed.add(a);
}
delete seed;
System.debug('Deleted ' + seed.size() + ' seed records');
