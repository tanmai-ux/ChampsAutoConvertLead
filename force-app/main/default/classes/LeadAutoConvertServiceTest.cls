@IsTest
private class LeadAutoConvertServiceTest {
    @TestSetup
    static void setup() {
        LeadAutoConvertTestData.createRunner();
    }

    private static LeadAutoConvertSettings settings() {
        return LeadAutoConvertTestData.useSettings(LeadAutoConvertTestData.settingsRecord());
    }

    private static Map<Id, LeadAutoConvertService.Outcome> convert(List<Lead> leads, LeadAutoConvertSettings settings) {
        return new LeadAutoConvertService().convert(LeadAutoConvertTestData.ids(leads), settings);
    }

    private static Lead reload(Id leadId) {
        return [
            SELECT
                IsConverted,
                Status,
                ConvertedAccountId,
                ConvertedContactId,
                ConvertedOpportunityId,
                ConvertedContact.RecordType.DeveloperName,
                ConvertedOpportunity.RecordType.DeveloperName,
                ConvertedOpportunity.StageName,
                ConvertedOpportunity.CloseDate,
                ConvertedOpportunity.Amount,
                ConvertedOpportunity.OwnerId,
                ConvertedOpportunity.Principal_Investigator__c
            FROM Lead
            WHERE Id = :leadId
        ];
    }

    private static List<Task> reviewTasks(Id leadId) {
        return [SELECT OwnerId, Subject, Description FROM Task WHERE WhoId = :leadId];
    }

    @IsTest
    static void convertsLeadOntoMatchedAccount() {
        System.runAs(LeadAutoConvertTestData.runner()) {
            Account account = LeadAutoConvertTestData.account('LAC Matched Co', 'TOS');
            insert account;
            Lead lead = LeadAutoConvertTestData.pendingLead('m1', 'Some Other Name');
            lead.Matched_Account__c = account.Id;
            LeadAutoConvertTestData.insertLeads(new List<Lead>{ lead });

            Test.startTest();
            Map<Id, LeadAutoConvertService.Outcome> outcomes = convert(new List<Lead>{ lead }, settings());
            Test.stopTest();

            Lead result = reload(lead.Id);
            Assert.areEqual(LeadAutoConvertService.Result.CONVERTED, outcomes.get(lead.Id).result, outcomes.get(lead.Id).message);
            Assert.isTrue(result.IsConverted, 'Lead should be converted');
            Assert.areEqual(LeadAutoConvertTestData.CONVERTED, result.Status, 'Lead should use the converted status');
            Assert.areEqual(account.Id, result.ConvertedAccountId, 'Should use the Matched Account');
            Assert.areEqual('General', result.ConvertedContact.RecordType.DeveloperName, 'Contact record type');
            Assert.areEqual('TOS', result.ConvertedOpportunity.RecordType.DeveloperName, 'Opportunity record type');
            Assert.areEqual('Proposed', result.ConvertedOpportunity.StageName, 'Opportunity stage');
            Assert.areEqual(1, result.ConvertedOpportunity.Amount, 'Opportunity amount');
            Assert.areEqual(settings().closeDateFor(Date.today()), result.ConvertedOpportunity.CloseDate, 'Close date');
            Assert.areEqual(result.ConvertedContactId, result.ConvertedOpportunity.Principal_Investigator__c, 'Principal Investigator is the new Contact');
            // Conversion adds a primary contact role; the org's Principal Investigator automation may add another.
            Assert.isTrue(
                [SELECT COUNT() FROM OpportunityContactRole WHERE OpportunityId = :result.ConvertedOpportunityId AND ContactId = :result.ConvertedContactId] >= 1,
                'Contact should be linked to the Opportunity'
            );
            Assert.areEqual(0, [SELECT COUNT() FROM Account WHERE Name = 'Some Other Name'], 'No Account is created');
            Assert.areEqual(0, reviewTasks(lead.Id).size(), 'No review Task for a converted Lead');
        }
    }

    @IsTest
    static void closeDateIsEndOfThisMonthForFirstThreeWeeksOtherwiseEndOfNextMonth() {
        LeadAutoConvertSettings rules = settings();

        Test.startTest();
        Date firstDay = rules.closeDateFor(Date.newInstance(2026, 11, 1));
        Date cutoffDay = rules.closeDateFor(Date.newInstance(2026, 11, 21));
        Date dayAfterCutoff = rules.closeDateFor(Date.newInstance(2026, 11, 22));
        Date decemberLate = rules.closeDateFor(Date.newInstance(2026, 12, 28));
        Date januaryLate = rules.closeDateFor(Date.newInstance(2028, 1, 31));
        Test.stopTest();

        Assert.areEqual(Date.newInstance(2026, 11, 30), firstDay, 'Day 1 closes this month');
        Assert.areEqual(Date.newInstance(2026, 11, 30), cutoffDay, 'Day 21 still closes this month');
        Assert.areEqual(Date.newInstance(2026, 12, 31), dayAfterCutoff, 'Day 22 closes next month');
        Assert.areEqual(Date.newInstance(2027, 1, 31), decemberLate, 'Late December rolls into the next year');
        Assert.areEqual(Date.newInstance(2028, 2, 29), januaryLate, 'Leap-year February end');
    }

    @IsTest
    static void flagsLeadWithNoMatchingAccountAndTellsOwner() {
        User owner = LeadAutoConvertTestData.runner();
        System.runAs(owner) {
            Lead lead = LeadAutoConvertTestData.pendingLead('r1', 'LAC No Match Co');
            LeadAutoConvertTestData.insertLeads(new List<Lead>{ lead });

            Test.startTest();
            Map<Id, LeadAutoConvertService.Outcome> outcomes = convert(new List<Lead>{ lead }, settings());
            Test.stopTest();

            Lead result = reload(lead.Id);
            Assert.areEqual(LeadAutoConvertService.Result.NEEDS_REVIEW, outcomes.get(lead.Id).result, 'Should need review');
            Assert.isFalse(result.IsConverted, 'Lead should stay unconverted');
            Assert.areEqual(LeadAutoConvertTestData.REVIEW, result.Status, 'Lead should be flagged for review');
            Assert.areEqual(0, [SELECT COUNT() FROM Account WHERE Name = 'LAC No Match Co'], 'No placeholder Account');
            Assert.areEqual(0, [SELECT COUNT() FROM Opportunity], 'No Opportunity');

            List<Task> tasks = reviewTasks(lead.Id);
            Assert.areEqual(1, tasks.size(), 'One review Task');
            Assert.areEqual(owner.Id, tasks[0].OwnerId, 'Task goes to the Lead owner');
            Assert.isTrue(tasks[0].Description.contains('no matching Account'), 'Task explains why: ' + tasks[0].Description);
            Assert.isTrue(tasks[0].Description.contains(String.valueOf(lead.Id)), 'Task links to the Lead');
            Assert.areEqual(1, LeadAutoConvertNotifier.emailsQueued, 'Owner is emailed');
        }
    }

    @IsTest
    static void reviewEmailIsCopiedToCcAddresses() {
        System.runAs(LeadAutoConvertTestData.runner()) {
            Lead lead = LeadAutoConvertTestData.pendingLead('cc1', 'LAC Copy Co');
            LeadAutoConvertTestData.insertLeads(new List<Lead>{ lead });
            Lead_Auto_Convert_Setting__mdt record = LeadAutoConvertTestData.settingsRecord();
            record.Review_Email_Cc__c = 'ops@example.com; lead.review@example.com';

            Test.startTest();
            convert(new List<Lead>{ lead }, LeadAutoConvertTestData.useSettings(record));
            Test.stopTest();

            Assert.areEqual(1, LeadAutoConvertNotifier.lastEmails.size(), 'One review email');
            Assert.areEqual(
                new List<String>{ 'ops@example.com', 'lead.review@example.com' },
                LeadAutoConvertNotifier.lastEmails[0].getCcAddresses(),
                'Both CC addresses get a copy'
            );
        }
    }

    @IsTest
    static void reviewEmailHasNoCcByDefault() {
        System.runAs(LeadAutoConvertTestData.runner()) {
            Lead lead = LeadAutoConvertTestData.pendingLead('cc2', 'LAC No Copy Co');
            LeadAutoConvertTestData.insertLeads(new List<Lead>{ lead });

            Test.startTest();
            convert(new List<Lead>{ lead }, settings());
            Test.stopTest();

            List<String> cc = LeadAutoConvertNotifier.lastEmails[0].getCcAddresses();
            Assert.isTrue(cc == null || cc.isEmpty(), 'No CC when the setting is blank');
        }
    }

    @IsTest
    static void convertsOntoAccountNamedLikeCompanyWhenFlowFoundNoAccount() {
        System.runAs(LeadAutoConvertTestData.runner()) {
            Account account = LeadAutoConvertTestData.account('LAC Same Name Co', 'TOS');
            insert account;
            Lead lead = LeadAutoConvertTestData.pendingLead('s1', 'lac same name co');
            LeadAutoConvertTestData.insertLeads(new List<Lead>{ lead });

            Test.startTest();
            convert(new List<Lead>{ lead }, settings());
            Test.stopTest();

            Lead result = reload(lead.Id);
            Assert.isTrue(result.IsConverted, 'Company name matches the Account name, ignoring case');
            Assert.areEqual(account.Id, result.ConvertedAccountId, 'Converted onto the Account with that name');
        }
    }

    @IsTest
    static void companyNameMatchWinsOverFlowMatch() {
        System.runAs(LeadAutoConvertTestData.runner()) {
            Account named = LeadAutoConvertTestData.account('LAC Global Co', 'TOS');
            Account site = LeadAutoConvertTestData.account('LAC Global Co - Site', 'TOS');
            insert new List<Account>{ named, site };
            Lead lead = LeadAutoConvertTestData.pendingLead('s2', 'LAC Global Co');
            lead.Matched_Account__c = site.Id;
            LeadAutoConvertTestData.insertLeads(new List<Lead>{ lead });

            Test.startTest();
            convert(new List<Lead>{ lead }, settings());
            Test.stopTest();

            Assert.areEqual(named.Id, reload(lead.Id).ConvertedAccountId, 'The Account named like the Company wins');
        }
    }

    @IsTest
    static void companyNameMatchingOnlyNonTosAccountIsFlagged() {
        System.runAs(LeadAutoConvertTestData.runner()) {
            Account hospital = LeadAutoConvertTestData.account('LAC Hospital Co', 'Hospital_Practice');
            insert hospital;
            Lead lead = LeadAutoConvertTestData.pendingLead('s5', 'LAC Hospital Co');
            LeadAutoConvertTestData.insertLeads(new List<Lead>{ lead });

            Test.startTest();
            Map<Id, LeadAutoConvertService.Outcome> outcomes = convert(new List<Lead>{ lead }, settings());
            Test.stopTest();

            Assert.areEqual(LeadAutoConvertTestData.REVIEW, reload(lead.Id).Status, 'Only TOS Accounts count');
            Assert.isTrue(outcomes.get(lead.Id).message.contains('No TOS Account matches'), outcomes.get(lead.Id).message);
            Assert.areEqual(0, [SELECT COUNT() FROM Opportunity WHERE AccountId = :hospital.Id], 'No Opportunity on a non-TOS Account');
        }
    }

    @IsTest
    static void contactOnDifferentAccountIsFlagged() {
        System.runAs(LeadAutoConvertTestData.runner()) {
            Account matched = LeadAutoConvertTestData.account('LAC Matched Conflict Co', 'TOS');
            Account other = LeadAutoConvertTestData.account('LAC Other Conflict Co', 'TOS');
            insert new List<Account>{ matched, other };
            Lead lead = LeadAutoConvertTestData.pendingLead('c2', 'LAC Matched Conflict Co');
            Contact contact = new Contact(
                LastName = 'Existing',
                Email = lead.Email,
                AccountId = other.Id,
                RecordTypeId = Schema.SObjectType.Contact.getRecordTypeInfosByDeveloperName()
                    .get('General')
                    .getRecordTypeId()
            );
            Database.DMLOptions allowDuplicates = new Database.DMLOptions();
            allowDuplicates.DuplicateRuleHeader.allowSave = true;
            Assert.isTrue(Database.insert(contact, allowDuplicates).isSuccess(), 'Contact setup');
            Assert.isTrue(Database.insert(lead, allowDuplicates).isSuccess(), 'Lead setup');
            update new Lead(
                Id = lead.Id,
                Status = LeadAutoConvertTestData.PENDING,
                OwnerId = UserInfo.getUserId(),
                Matched_Account__c = matched.Id
            );

            Test.startTest();
            Map<Id, LeadAutoConvertService.Outcome> outcomes = convert(new List<Lead>{ lead }, settings());
            Test.stopTest();

            Assert.areEqual(LeadAutoConvertService.Result.NEEDS_REVIEW, outcomes.get(lead.Id).result, 'Conflict needs a person');
            Assert.isTrue(outcomes.get(lead.Id).message.contains('different Account'), outcomes.get(lead.Id).message);
            Assert.isFalse(reload(lead.Id).IsConverted, 'Lead should stay unconverted');
        }
    }

    @IsTest
    static void reusesExistingContactWithSameEmail() {
        System.runAs(LeadAutoConvertTestData.runner()) {
            Account account = LeadAutoConvertTestData.account('LAC Contact Co', 'TOS');
            insert account;
            Lead lead = LeadAutoConvertTestData.pendingLead('c1', 'LAC Different Co');
            Contact contact = new Contact(
                LastName = 'Existing',
                Email = lead.Email,
                AccountId = account.Id,
                RecordTypeId = Schema.SObjectType.Contact.getRecordTypeInfosByDeveloperName()
                    .get('General')
                    .getRecordTypeId()
            );
            Database.DMLOptions allowDuplicates = new Database.DMLOptions();
            allowDuplicates.DuplicateRuleHeader.allowSave = true;
            Assert.isTrue(Database.insert(contact, allowDuplicates).isSuccess(), 'Contact setup');
            Assert.isTrue(Database.insert(lead, allowDuplicates).isSuccess(), 'Lead setup');
            update new Lead(
                Id = lead.Id,
                Status = LeadAutoConvertTestData.PENDING,
                OwnerId = UserInfo.getUserId(),
                Matched_Account__c = account.Id
            );

            Test.startTest();
            convert(new List<Lead>{ lead }, settings());
            Test.stopTest();

            Lead result = reload(lead.Id);
            Assert.areEqual(contact.Id, result.ConvertedContactId, 'Should reuse the existing Contact');
            Assert.areEqual(account.Id, result.ConvertedAccountId, 'Should use that Contact\'s Account');
        }
    }

    @IsTest
    static void queueOwnedLeadConvertsToMatchedAccountOwner() {
        User owner = LeadAutoConvertTestData.accountOwner();
        System.runAs(LeadAutoConvertTestData.runner()) {
            Group queue = [SELECT Id FROM Group WHERE DeveloperName = 'California_Leads' AND Type = 'Queue' LIMIT 1];
            Account account = LeadAutoConvertTestData.account('LAC Queue Co', 'TOS');
            account.OwnerId = owner.Id;
            insert account;
            Lead lead = LeadAutoConvertTestData.pendingLead('q1', 'LAC Queue Co');
            lead.OwnerId = queue.Id;
            lead.Matched_Account__c = account.Id;
            LeadAutoConvertTestData.insertLeads(new List<Lead>{ lead });

            Test.startTest();
            convert(new List<Lead>{ lead }, settings());
            Test.stopTest();

            Lead result = reload(lead.Id);
            Assert.isTrue(result.IsConverted, 'Lead should be converted');
            Assert.areEqual(
                owner.Id,
                [SELECT OwnerId FROM Contact WHERE Id = :result.ConvertedContactId].OwnerId,
                'Contact goes to the Account owner'
            );
            Assert.areEqual(
                owner.Id,
                [SELECT OwnerId FROM Opportunity WHERE Id = :result.ConvertedOpportunityId].OwnerId,
                'Opportunity goes to the Account owner'
            );
        }
    }

    @IsTest
    static void queueOwnedLeadReviewGoesToMatchedAccountOwner() {
        User owner = LeadAutoConvertTestData.accountOwner();
        System.runAs(LeadAutoConvertTestData.runner()) {
            Group queue = [SELECT Id FROM Group WHERE DeveloperName = 'California_Leads' AND Type = 'Queue' LIMIT 1];
            Account matched = LeadAutoConvertTestData.account('LAC Queue Review Co', 'TOS');
            matched.OwnerId = owner.Id;
            Account other = LeadAutoConvertTestData.account('LAC Queue Review Other Co', 'TOS');
            insert new List<Account>{ matched, other };
            Lead lead = LeadAutoConvertTestData.pendingLead('q3', 'LAC Queue Review Co');
            insert new Contact(
                LastName = 'Existing',
                Email = lead.Email,
                AccountId = other.Id,
                RecordTypeId = Schema.SObjectType.Contact.getRecordTypeInfosByDeveloperName()
                    .get('General')
                    .getRecordTypeId()
            );
            lead.OwnerId = queue.Id;
            lead.Matched_Account__c = matched.Id;
            LeadAutoConvertTestData.insertLeads(new List<Lead>{ lead });

            Test.startTest();
            convert(new List<Lead>{ lead }, settings());
            Test.stopTest();

            Lead result = reload(lead.Id);
            List<Task> tasks = reviewTasks(lead.Id);
            Assert.isFalse(result.IsConverted, 'Lead should stay unconverted');
            Assert.areEqual(LeadAutoConvertTestData.REVIEW, result.Status, 'Lead should be flagged for review');
            Assert.areEqual(1, tasks.size(), 'One review Task');
            Assert.areEqual(owner.Id, tasks[0].OwnerId, 'Account owner reviews a queue-owned Lead');
        }
    }

    @IsTest
    static void queueOwnedLeadWithNoMatchGoesToFallbackUser() {
        User fallback = LeadAutoConvertTestData.runner();
        System.runAs(fallback) {
            Group queue = [SELECT Id FROM Group WHERE DeveloperName = 'California_Leads' AND Type = 'Queue' LIMIT 1];
            Lead lead = LeadAutoConvertTestData.pendingLead('q4', 'LAC Queue No Match Co');
            lead.OwnerId = queue.Id;
            LeadAutoConvertTestData.insertLeads(new List<Lead>{ lead });

            Test.startTest();
            convert(new List<Lead>{ lead }, settings());
            Test.stopTest();

            List<Task> tasks = reviewTasks(lead.Id);
            Assert.areEqual(LeadAutoConvertTestData.REVIEW, reload(lead.Id).Status, 'Lead should be flagged for review');
            Assert.areEqual(1, tasks.size(), 'One review Task');
            Assert.areEqual(fallback.Id, tasks[0].OwnerId, 'Fallback user reviews when there is no Account owner');
        }
    }

    @IsTest
    static void queueOwnedLeadWithoutFallbackUserIsFlagged() {
        System.runAs(LeadAutoConvertTestData.runner()) {
            Group queue = [SELECT Id FROM Group WHERE DeveloperName = 'California_Leads' AND Type = 'Queue' LIMIT 1];
            Lead lead = LeadAutoConvertTestData.pendingLead('q2', 'LAC Queue Fail Co');
            lead.OwnerId = queue.Id;
            LeadAutoConvertTestData.insertLeads(new List<Lead>{ lead });
            Lead_Auto_Convert_Setting__mdt record = LeadAutoConvertTestData.settingsRecord();
            record.Fallback_Owner_Alias__c = 'nobodyxx';

            Test.startTest();
            Map<Id, LeadAutoConvertService.Outcome> outcomes = convert(
                new List<Lead>{ lead },
                LeadAutoConvertTestData.useSettings(record)
            );
            Test.stopTest();

            Lead result = reload(lead.Id);
            Assert.isFalse(result.IsConverted, 'Lead should stay unconverted');
            Assert.areEqual(LeadAutoConvertTestData.REVIEW, result.Status, 'Lead should be flagged for review');
            Assert.isTrue(outcomes.get(lead.Id).message.contains('nobodyxx'), 'Reason names the missing alias');
            Assert.areEqual(0, reviewTasks(lead.Id).size(), 'No user to give a Task to');
        }
    }

    @IsTest
    static void patientAccountIsFlaggedNotConverted() {
        System.runAs(LeadAutoConvertTestData.runner()) {
            Account patient = LeadAutoConvertTestData.account('LAC Patient', 'Patient');
            insert patient;
            Lead lead = LeadAutoConvertTestData.pendingLead('n1', 'LAC Patient Lead Co');
            lead.Matched_Account__c = patient.Id;
            LeadAutoConvertTestData.insertLeads(new List<Lead>{ lead });

            Test.startTest();
            convert(new List<Lead>{ lead }, settings());
            Test.stopTest();

            Lead result = reload(lead.Id);
            Assert.isFalse(result.IsConverted, 'Lead should stay unconverted');
            Assert.areEqual(LeadAutoConvertTestData.REVIEW, result.Status, 'Lead should be flagged for review');
            Assert.isTrue(reviewTasks(lead.Id)[0].Description.contains('is not a TOS Account'), 'Task explains why');
            Assert.areEqual(0, [SELECT COUNT() FROM Opportunity WHERE AccountId = :patient.Id], 'No Opportunity on a Patient Account');
        }
    }

    @IsTest
    static void failedConversionIsFlaggedAndRemovesItsOpportunity() {
        System.runAs(LeadAutoConvertTestData.runner()) {
            Account account = LeadAutoConvertTestData.account('LAC Rollback Co', 'TOS');
            insert account;
            Lead lead = LeadAutoConvertTestData.pendingLead('f1', 'LAC Rollback Co');
            lead.Matched_Account__c = account.Id;
            LeadAutoConvertTestData.insertLeads(new List<Lead>{ lead });
            Lead_Auto_Convert_Setting__mdt record = LeadAutoConvertTestData.settingsRecord();
            record.Converted_Status__c = 'Not A Real Status';

            Test.startTest();
            convert(new List<Lead>{ lead }, LeadAutoConvertTestData.useSettings(record));
            Test.stopTest();

            Lead result = reload(lead.Id);
            Assert.isFalse(result.IsConverted, 'Lead should stay unconverted');
            Assert.areEqual(LeadAutoConvertTestData.REVIEW, result.Status, 'Lead should be flagged for review');
            Assert.areEqual(0, [SELECT COUNT() FROM Opportunity WHERE AccountId = :account.Id], 'Unused Opportunity removed');
        }
    }

    @IsTest
    static void leadNoLongerWaitingIsSkipped() {
        System.runAs(LeadAutoConvertTestData.runner()) {
            Account account = LeadAutoConvertTestData.account('LAC Skip Co', 'TOS');
            insert account;
            Lead lead = LeadAutoConvertTestData.pendingLead('k1', 'LAC Skip Co');
            lead.Status = LeadAutoConvertTestData.REVIEW;
            LeadAutoConvertTestData.insertLeads(new List<Lead>{ lead });

            Test.startTest();
            Map<Id, LeadAutoConvertService.Outcome> outcomes = convert(new List<Lead>{ lead }, settings());
            Test.stopTest();

            Assert.areEqual(LeadAutoConvertService.Result.SKIPPED, outcomes.get(lead.Id).result, 'Should be skipped');
            Assert.isFalse(reload(lead.Id).IsConverted, 'Lead should stay unconverted');
            Assert.areEqual(0, reviewTasks(lead.Id).size(), 'No second review Task');
        }
    }

    @IsTest
    static void secondLeadOnSameAccountWaitsForNextRun() {
        System.runAs(LeadAutoConvertTestData.runner()) {
            Account account = LeadAutoConvertTestData.account('LAC Shared Co', 'TOS');
            insert account;
            Lead first = LeadAutoConvertTestData.pendingLead('d1', 'LAC Shared Co');
            Lead second = LeadAutoConvertTestData.pendingLead('d2', 'LAC Shared Co');
            first.Matched_Account__c = account.Id;
            second.Matched_Account__c = account.Id;
            LeadAutoConvertTestData.insertLeads(new List<Lead>{ first, second });

            Test.startTest();
            Map<Id, LeadAutoConvertService.Outcome> outcomes = convert(new List<Lead>{ first, second }, settings());
            Test.stopTest();

            Assert.areEqual(LeadAutoConvertService.Result.CONVERTED, outcomes.get(first.Id).result, outcomes.get(first.Id).message);
            Assert.areEqual(LeadAutoConvertService.Result.DEFERRED, outcomes.get(second.Id).result, 'Second Lead waits');
            Assert.areEqual(LeadAutoConvertTestData.PENDING, reload(second.Id).Status, 'Second Lead is still waiting');
            Assert.areEqual(1, [SELECT COUNT() FROM Opportunity WHERE AccountId = :account.Id], 'One Opportunity per run per Account');
        }
    }

    @IsTest
    static void bulkFlagsTwoHundredUnmatchedLeads() {
        System.runAs(LeadAutoConvertTestData.runner()) {
            List<Lead> leads = new List<Lead>();
            for (Integer i = 0; i < 200; i++) {
                leads.add(LeadAutoConvertTestData.pendingLead('b' + i, 'LAC Bulk Unmatched ' + i));
            }
            LeadAutoConvertTestData.insertLeads(leads);
            List<Id> leadIds = LeadAutoConvertTestData.ids(leads);

            Test.startTest();
            convert(leads, settings());
            Test.stopTest();

            Assert.areEqual(
                200,
                [SELECT COUNT() FROM Lead WHERE Id IN :leadIds AND Status = :LeadAutoConvertTestData.REVIEW],
                'All Leads flagged for review'
            );
            Assert.areEqual(200, [SELECT COUNT() FROM Task WHERE WhoId IN :leadIds], 'One Task per Lead');
            Assert.areEqual(200, LeadAutoConvertNotifier.emailsQueued, 'One email per Lead');
            Assert.areEqual(0, [SELECT COUNT() FROM Account WHERE Name LIKE 'LAC Bulk Unmatched%'], 'No Accounts created');
        }
    }
}
