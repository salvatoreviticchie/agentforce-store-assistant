@IsTest
private class MyDayControllerTest {

    @TestSetup
    static void setup() {
        System.runAs(new User(Id = UserInfo.getUserId())) { // avoids mixed DML (User + business data)
            update new User(Id = UserInfo.getUserId(), Store__c = 'Bern');
        }
        insert new Task(OwnerId = UserInfo.getUserId(), Subject = 'Window display', ActivityDate = Date.today(), Status = 'Not Started');
    }

    @IsTest
    static void cardGetsTheSameBriefingAsTheAgent() {
        MyDayService.MyDay day = MyDayController.getMyDay();
        Assert.areEqual('Bern', day.store);
        Assert.areEqual('Window display', day.section('DUE_TODAY').items[0].headline);
    }

    @IsTest
    static void doneCompletesMyTask() {
        Task t = [SELECT Id FROM Task LIMIT 1];
        MyDayController.completeTask(t.Id);
        Assert.isTrue([SELECT IsClosed FROM Task WHERE Id = :t.Id].IsClosed);
        Assert.isNull(MyDayController.getMyDay().section('DUE_TODAY'), 'gone from the briefing');
    }

    @IsTest
    static void cannotCompleteSomeoneElsesOrAClosedTask() {
        Task t = [SELECT Id FROM Task LIMIT 1];
        MyDayController.completeTask(t.Id);
        try {
            MyDayController.completeTask(t.Id); // already closed
            Assert.fail('expected an error');
        } catch (AuraHandledException e) {
            Assert.areEqual('This task is not one of your open tasks.', e.getMessage());
        }
    }
}
