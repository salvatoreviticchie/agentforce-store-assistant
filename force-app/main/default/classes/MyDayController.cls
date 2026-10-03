/**
 * Controller for the "My Day" Lightning Web Component: the same briefing as the Staff Assistant's
 * Get My Day action (MyDayService), rendered as cards without an LLM.
 */
public with sharing class MyDayController {

    @AuraEnabled(cacheable=true)
    public static MyDayService.MyDay getMyDay() {
        return MyDayService.forCurrentUser();
    }

    /** Quick action "Done": only the associate's own open tasks can be completed from the card. */
    @AuraEnabled
    public static void completeTask(Id taskId) {
        List<Task> tasks = [SELECT Id FROM Task WHERE Id = :taskId AND OwnerId = :UserInfo.getUserId() AND IsClosed = false];
        if (tasks.isEmpty()) {
            String msg = 'This task is not one of your open tasks.';
            AuraHandledException e = new AuraHandledException(msg);
            e.setMessage(msg);
            throw e;
        }
        tasks[0].Status = 'Completed';
        update tasks;
    }
}
