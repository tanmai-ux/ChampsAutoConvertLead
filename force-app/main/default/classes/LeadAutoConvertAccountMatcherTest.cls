@IsTest
private class LeadAutoConvertAccountMatcherTest {
    private static final Set<String> TOS_TYPES = new Set<String>{ 'TOS' };

    @TestSetup
    static void setup() {
        LeadAutoConvertTestData.createRunner();
    }

    /** In-memory Lead with a fake Id, so matching rules can be checked without DML. */
    private static Lead memoryLead(Integer n, String company, Account flowAccount) {
        Lead lead = new Lead(
            Id = Lead.SObjectType.getDescribe().getKeyPrefix() + '0000000000' + String.valueOf(n).leftPad(2, '0'),
            Company = company
        );
        if (flowAccount != null) {
            lead.Matched_Account__c = flowAccount.Id;
            lead.Matched_Account__r = flowAccount;
        }
        return lead;
    }

    private static Account memoryAccount(Integer n, String name, String recordType) {
        Account account = new Account(
            Id = Account.SObjectType.getDescribe().getKeyPrefix() + '0000000000' + String.valueOf(n).leftPad(2, '0'),
            Name = name
        );
        account.putSObject('RecordType', new RecordType(DeveloperName = recordType));
        return account;
    }

    @IsTest
    static void bulkMatchesTwoHundredLeadsByCompanyNameInOneQuery() {
        System.runAs(LeadAutoConvertTestData.runner()) {
            List<Account> accounts = new List<Account>();
            for (Integer i = 0; i < 200; i++) {
                accounts.add(LeadAutoConvertTestData.account('LAC Bulk Match ' + i, 'TOS'));
            }
            insert accounts;
            List<Lead> leads = new List<Lead>();
            for (Integer i = 0; i < 200; i++) {
                leads.add(LeadAutoConvertTestData.pendingLead('bm' + i, 'LAC BULK MATCH ' + i));
            }
            LeadAutoConvertTestData.insertLeads(leads);
            List<Id> leadIds = LeadAutoConvertTestData.ids(leads);
            List<Lead> loaded = new LeadAutoConvertSelector().getLeadsForUpdate(leadIds);

            Test.startTest();
            Integer queriesBefore = Limits.getQueries();
            Map<Id, LeadAutoConvertAccountMatcher.Result> results = new LeadAutoConvertAccountMatcher().match(loaded, TOS_TYPES);
            Integer queriesUsed = Limits.getQueries() - queriesBefore;
            Test.stopTest();

            Assert.areEqual(1, queriesUsed, 'One query for the whole group');
            Assert.areEqual(200, results.size(), 'A result for every Lead');
            for (Integer i = 0; i < 200; i++) {
                LeadAutoConvertAccountMatcher.Result result = results.get(leads[i].Id);
                Assert.areEqual(accounts[i].Id, result.account.Id, 'Lead ' + i + ' matches its Account by name');
                Assert.areEqual(LeadAutoConvertAccountMatcher.BY_COMPANY_NAME, result.matchedBy, 'Matched by name');
            }
        }
    }

    @IsTest
    static void sameNamedTosAccountsFallBackToFlowMatchOrReview() {
        Account first = memoryAccount(1, 'Twin Co', 'TOS');
        Account second = memoryAccount(2, 'Twin Co', 'TOS');
        Account site = memoryAccount(3, 'Twin Co - Site', 'TOS');
        Map<String, List<Account>> byName = new Map<String, List<Account>>{
            LeadAutoConvertAccountMatcher.nameKey('Twin Co') => new List<Account>{ first, second }
        };
        Lead withFlow = memoryLead(1, 'Twin Co', site);
        Lead withoutFlow = memoryLead(2, 'Twin Co', null);

        Test.startTest();
        Map<Id, LeadAutoConvertAccountMatcher.Result> results = new LeadAutoConvertAccountMatcher()
            .matchAll(new List<Lead>{ withFlow, withoutFlow }, byName, TOS_TYPES);
        Test.stopTest();

        Assert.areEqual(site.Id, results.get(withFlow.Id).account.Id, 'Two Accounts share the name, so the flow match is used');
        Assert.areEqual(LeadAutoConvertAccountMatcher.BY_LEAD_ASSIGNMENT, results.get(withFlow.Id).matchedBy, 'Matched by the flow');
        Assert.isNull(results.get(withoutFlow.Id).account, 'No usable Account');
        Assert.isTrue(results.get(withoutFlow.Id).problem.contains('2 TOS Accounts are named "Twin Co"'), results.get(withoutFlow.Id).problem);
    }

    @IsTest
    static void unusableFlowMatchesAreExplained() {
        Account hospital = memoryAccount(4, 'Hospital Co', 'Hospital_Practice');
        Lead nonTos = memoryLead(3, 'Nobody Co', hospital);
        Lead deleted = memoryLead(4, 'Nobody Co', null);
        deleted.Matched_Account__c = memoryAccount(5, 'Gone Co', 'TOS').Id;
        Lead none = memoryLead(5, null, null);

        Test.startTest();
        Map<Id, LeadAutoConvertAccountMatcher.Result> results = new LeadAutoConvertAccountMatcher()
            .matchAll(new List<Lead>{ nonTos, deleted, none }, new Map<String, List<Account>>(), TOS_TYPES);
        Test.stopTest();

        Assert.isTrue(results.get(nonTos.Id).problem.contains('(Hospital Co) is not a TOS Account'), results.get(nonTos.Id).problem);
        Assert.isTrue(results.get(deleted.Id).problem.contains('no longer exists'), results.get(deleted.Id).problem);
        Assert.isTrue(results.get(none.Id).problem.contains('found no matching Account'), results.get(none.Id).problem);
        for (LeadAutoConvertAccountMatcher.Result result : results.values()) {
            Assert.isNull(result.account, 'No Account when nothing usable matched');
        }
    }
}
