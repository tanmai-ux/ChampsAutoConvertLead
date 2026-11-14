@IsTest
private class LeadAutoConvertWorkerTest {
    @TestSetup
    static void setup() {
        LeadAutoConvertTestData.createRunner();
    }

    private static Integer countWaiting() {
        return [SELECT COUNT() FROM Lead WHERE Status = :LeadAutoConvertTestData.PENDING];
    }

    @IsTest
    static void startQueuesOnlyOneWorker() {
        System.runAs(LeadAutoConvertTestData.runner()) {
            LeadAutoConvertTestData.useSettings(LeadAutoConvertTestData.settingsRecord());
            Lead lead = LeadAutoConvertTestData.pendingLead('w1', 'LAC Worker Start Co');
            LeadAutoConvertTestData.insertLeads(new List<Lead>{ lead });

            Test.startTest();
            Id first = LeadAutoConvertWorker.start();
            Id second = LeadAutoConvertWorker.start();
            Integer jobsQueued = Limits.getQueueableJobs();
            Test.stopTest();

            Assert.isNotNull(first, 'First start queues a worker');
            Assert.isNull(second, 'Second start sees the queued worker');
            Assert.areEqual(1, jobsQueued, 'Only one worker job');
            Assert.areEqual(
                LeadAutoConvertTestData.REVIEW,
                [SELECT Status FROM Lead WHERE Id = :lead.Id].Status,
                'Worker ran and flagged the unmatched Lead'
            );
        }
    }

    @IsTest
    static void requestHandlerStartsOneWorker() {
        System.runAs(LeadAutoConvertTestData.runner()) {
            LeadAutoConvertTestData.useSettings(LeadAutoConvertTestData.settingsRecord());
            LeadAutoConvertTestData.insertLeads(new List<Lead>{ LeadAutoConvertTestData.pendingLead('rh1', 'LAC Request Co') });
            List<Lead_Auto_Convert_Request__e> requests = new List<Lead_Auto_Convert_Request__e>{
                new Lead_Auto_Convert_Request__e(Source__c = 'Flow'),
                new Lead_Auto_Convert_Request__e(Source__c = 'Hourly check')
            };

            Test.startTest();
            new LeadAutoConvertRequestHandler().afterInsert(requests);
            new LeadAutoConvertRequestHandler().afterInsert(new List<Lead_Auto_Convert_Request__e>());
            Integer jobsQueued = Limits.getQueueableJobs();
            Test.stopTest();

            Assert.areEqual(1, jobsQueued, 'Two requests start one worker');
        }
    }

    @IsTest
    static void publishedRequestIsDeliveredToTheSubscriber() {
        System.runAs(LeadAutoConvertTestData.runner()) {
            Test.startTest();
            LeadAutoConvertWorker.requestStart('Flow');
            Test.getEventBus().deliver();
            Test.stopTest();

            Assert.areEqual(1, LeadAutoConvertWorker.requestsPublished, 'Request published');
            List<EventBusSubscriber> subscribers = [
                SELECT Position, LastError
                FROM EventBusSubscriber
                WHERE Topic = 'Lead_Auto_Convert_Request__e' AND Type = 'ApexTrigger'
            ];
            Assert.areEqual(1, subscribers.size(), 'The request trigger subscribes to the event');
            Assert.isTrue(subscribers[0].Position >= 1, 'The trigger received the request');
            Assert.isNull(subscribers[0].LastError, 'The trigger handled it without error');
        }
    }

    @IsTest
    static void startDoesNothingWhenOffOrNothingWaiting() {
        System.runAs(LeadAutoConvertTestData.runner()) {
            Lead_Auto_Convert_Setting__mdt off = LeadAutoConvertTestData.settingsRecord();
            off.Active__c = false;

            Test.startTest();
            LeadAutoConvertTestData.useSettings(LeadAutoConvertTestData.settingsRecord());
            Id nothingWaiting = LeadAutoConvertWorker.start();
            LeadAutoConvertTestData.insertLeads(new List<Lead>{ LeadAutoConvertTestData.pendingLead('w2', 'LAC Worker Off Co') });
            LeadAutoConvertTestData.useSettings(off);
            Id switchedOff = LeadAutoConvertWorker.start();
            Integer jobsQueued = Limits.getQueueableJobs();
            Test.stopTest();

            Assert.isNull(nothingWaiting, 'No worker when no Leads are waiting');
            Assert.isNull(switchedOff, 'No worker when auto-conversion is off');
            Assert.areEqual(0, jobsQueued, 'No jobs queued');
        }
    }

    @IsTest
    static void bulkWorkerConvertsOneGroupAndChainsWhileLeadsRemain() {
        System.runAs(LeadAutoConvertTestData.runner()) {
            LeadAutoConvertTestData.useSettings(LeadAutoConvertTestData.settingsRecord());
            List<Account> accounts = new List<Account>();
            for (Integer i = 0; i < 200; i++) {
                accounts.add(LeadAutoConvertTestData.account('LAC Worker Bulk ' + i, 'TOS'));
            }
            insert accounts;
            List<Lead> leads = new List<Lead>();
            for (Integer i = 0; i < 200; i++) {
                Lead lead = LeadAutoConvertTestData.pendingLead('wb' + i, 'LAC Worker Bulk Lead ' + i);
                lead.Matched_Account__c = accounts[i].Id;
                leads.add(lead);
            }
            LeadAutoConvertTestData.insertLeads(leads);

            Test.startTest();
            new LeadAutoConvertWorker().execute(null);
            Test.stopTest();

            Assert.areEqual(10, [SELECT COUNT() FROM Lead WHERE IsConverted = TRUE], 'One run converts Leads Per Run');
            Assert.areEqual(190, countWaiting(), 'The rest keep waiting');
            Assert.areEqual(10, [SELECT COUNT() FROM Opportunity], 'One Opportunity per converted Lead');
            Assert.isNotNull(LeadAutoConvertWorker.chainedRunSize, 'Worker queues the next run');
        }
    }

    @IsTest
    static void workerStopsWhenNothingIsLeft() {
        System.runAs(LeadAutoConvertTestData.runner()) {
            LeadAutoConvertTestData.useSettings(LeadAutoConvertTestData.settingsRecord());
            LeadAutoConvertTestData.insertLeads(new List<Lead>{ LeadAutoConvertTestData.pendingLead('w3', 'LAC Worker Last Co') });

            Test.startTest();
            new LeadAutoConvertWorker().execute(null);
            Test.stopTest();

            Assert.areEqual(0, countWaiting(), 'Nothing left waiting');
            Assert.isNull(LeadAutoConvertWorker.chainedRunSize, 'No next run');
        }
    }

    @IsTest
    static void failedRunRetriesSameLeadsInSmallerGroups() {
        System.runAs(LeadAutoConvertTestData.runner()) {
            LeadAutoConvertTestData.useSettings(LeadAutoConvertTestData.settingsRecord());
            Lead lead = LeadAutoConvertTestData.pendingLead('fh1', 'LAC Failure Co');
            LeadAutoConvertTestData.insertLeads(new List<Lead>{ lead });

            Test.startTest();
            new LeadAutoConvertWorker.RunFailureHandler(new List<Id>{ lead.Id }, 10).handleFailure('Too many SOQL queries');
            Test.stopTest();

            Assert.areEqual(5, LeadAutoConvertWorker.chainedRunSize, 'Retries with half the group size');
            Assert.areEqual(1, countWaiting(), 'Lead is still waiting for the retry');
        }
    }

    @IsTest
    static void singleLeadThatKeepsFailingGoesToReview() {
        System.runAs(LeadAutoConvertTestData.runner()) {
            LeadAutoConvertTestData.useSettings(LeadAutoConvertTestData.settingsRecord());
            Lead failing = LeadAutoConvertTestData.pendingLead('fh2', 'LAC Failure One Co');
            Lead other = LeadAutoConvertTestData.pendingLead('fh3', 'LAC Failure Two Co');
            LeadAutoConvertTestData.insertLeads(new List<Lead>{ failing, other });

            Test.startTest();
            new LeadAutoConvertWorker.RunFailureHandler(new List<Id>{ failing.Id }, 1).handleFailure('Too many SOQL queries');
            Test.stopTest();

            Lead result = [SELECT Status FROM Lead WHERE Id = :failing.Id];
            Task task = [SELECT Description FROM Task WHERE WhoId = :failing.Id];
            Assert.areEqual(LeadAutoConvertTestData.REVIEW, result.Status, 'Failing Lead goes to review');
            Assert.isTrue(task.Description.contains('Too many SOQL queries'), 'Owner is told why');
            Assert.areEqual(1, countWaiting(), 'The other Lead keeps waiting');
            Assert.areEqual(0, LeadAutoConvertWorker.chainedRunSize, 'Worker continues at the normal size');
        }
    }

    @IsTest
    static void workerDoesNothingWhenOff() {
        System.runAs(LeadAutoConvertTestData.runner()) {
            Lead_Auto_Convert_Setting__mdt off = LeadAutoConvertTestData.settingsRecord();
            off.Active__c = false;
            LeadAutoConvertTestData.useSettings(off);
            LeadAutoConvertTestData.insertLeads(new List<Lead>{ LeadAutoConvertTestData.pendingLead('w4', 'LAC Worker Idle Co') });

            Test.startTest();
            new LeadAutoConvertWorker().execute(null);
            Test.stopTest();

            Assert.areEqual(1, countWaiting(), 'Lead is left waiting');
        }
    }

    @IsTest
    static void bulkQueueActionMarksLeadsWaitingAndStartsOneWorker() {
        System.runAs(LeadAutoConvertTestData.runner()) {
            LeadAutoConvertTestData.useSettings(LeadAutoConvertTestData.settingsRecord());
            List<Lead> leads = new List<Lead>();
            for (Integer i = 0; i < 200; i++) {
                Lead lead = LeadAutoConvertTestData.pendingLead('qa' + i, 'LAC Queue Action ' + i);
                lead.Status = 'Not Contacted/New';
                leads.add(lead);
            }
            LeadAutoConvertTestData.insertLeads(leads);
            List<LeadAutoConvertQueueAction.Request> requests = new List<LeadAutoConvertQueueAction.Request>();
            for (Lead lead : leads) {
                LeadAutoConvertQueueAction.Request request = new LeadAutoConvertQueueAction.Request();
                request.leadId = lead.Id;
                requests.add(request);
            }

            Test.startTest();
            LeadAutoConvertQueueAction.queue(requests);
            Integer waiting = countWaiting();
            Integer jobsQueued = Limits.getQueueableJobs();
            Test.stopTest();

            Assert.areEqual(200, waiting, 'Every Lead is marked waiting');
            Assert.areEqual(1, LeadAutoConvertWorker.requestsPublished, 'One start request for the whole group');
            Assert.areEqual(0, jobsQueued, 'The worker is not started as the flow user');
        }
    }

    @IsTest
    static void queueActionDoesNothingWhenOff() {
        System.runAs(LeadAutoConvertTestData.runner()) {
            Lead_Auto_Convert_Setting__mdt off = LeadAutoConvertTestData.settingsRecord();
            off.Active__c = false;
            LeadAutoConvertTestData.useSettings(off);
            Lead lead = LeadAutoConvertTestData.pendingLead('qa-off', 'LAC Queue Off Co');
            lead.Status = 'Not Contacted/New';
            LeadAutoConvertTestData.insertLeads(new List<Lead>{ lead });
            LeadAutoConvertQueueAction.Request request = new LeadAutoConvertQueueAction.Request();
            request.leadId = lead.Id;

            Test.startTest();
            LeadAutoConvertQueueAction.queue(new List<LeadAutoConvertQueueAction.Request>{ request });
            Test.stopTest();

            Assert.areEqual('Not Contacted/New', [SELECT Status FROM Lead WHERE Id = :lead.Id].Status, 'Status unchanged');
            Assert.areEqual(0, LeadAutoConvertWorker.requestsPublished, 'No start request');
        }
    }

    @IsTest
    static void hourlyCheckRequestsWorkerAndCanBeScheduled() {
        System.runAs(LeadAutoConvertTestData.runner()) {
            LeadAutoConvertTestData.useSettings(LeadAutoConvertTestData.settingsRecord());
            LeadAutoConvertTestData.insertLeads(new List<Lead>{ LeadAutoConvertTestData.pendingLead('h1', 'LAC Hourly Co') });

            Test.startTest();
            new LeadAutoConvertScheduler().execute(null);
            Integer jobsQueued = Limits.getQueueableJobs();
            Integer requests = LeadAutoConvertWorker.requestsPublished;
            Id scheduledId = LeadAutoConvertScheduler.scheduleHourly('Lead Auto-Convert hourly check (test)');
            // The real job may already be scheduled in this org; either outcome shows the default name is used.
            try {
                Assert.isNotNull(LeadAutoConvertScheduler.scheduleHourly(), 'Scheduled under the default name');
            } catch (AsyncException alreadyScheduled) {
                Assert.isTrue(
                    alreadyScheduled.getMessage().contains(LeadAutoConvertScheduler.JOB_NAME),
                    'Only fails because the real job already exists: ' + alreadyScheduled.getMessage()
                );
            }
            Test.stopTest();

            Assert.areEqual(1, requests, 'Hourly check sends a start request');
            Assert.areEqual(0, jobsQueued, 'The worker is not started as the scheduling user');
            Assert.areEqual(
                '0 0 * * * ?',
                [SELECT CronExpression FROM CronTrigger WHERE Id = :scheduledId].CronExpression,
                'Scheduled every hour'
            );
        }
    }
}
