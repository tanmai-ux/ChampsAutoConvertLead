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

    private static List<Lead> loadLeads(List<Lead> leads) {
        return new LeadAutoConvertSelector().getLeadsForUpdate(LeadAutoConvertTestData.ids(leads));
    }

    @IsTest
    static void cleanKeyIgnoresCasePunctuationAndLegalSuffixes() {
        Test.startTest();
        String pfizer = LeadAutoConvertAccountMatcher.cleanKey('Pfizer, Inc.');
        String pfizerUpper = LeadAutoConvertAccountMatcher.cleanKey('PFIZER');
        String lilly = LeadAutoConvertAccountMatcher.cleanKey('Eli Lilly and Company');
        String bayer = LeadAutoConvertAccountMatcher.cleanKey('Bayer AG');
        String jackson = LeadAutoConvertAccountMatcher.cleanKey('The Jackson Laboratory');
        String ampersand = LeadAutoConvertAccountMatcher.cleanKey('Smith & Nephew plc');
        String onlySuffix = LeadAutoConvertAccountMatcher.cleanKey('Inc.');
        String blank = LeadAutoConvertAccountMatcher.cleanKey('  ');
        Test.stopTest();

        Assert.areEqual('pfizer', pfizer, 'Punctuation and Inc are ignored');
        Assert.areEqual(pfizer, pfizerUpper, 'Case is ignored');
        Assert.areEqual(LeadAutoConvertAccountMatcher.cleanKey('Eli Lilly'), lilly, 'Trailing "and Company" is ignored');
        Assert.areEqual('bayer', bayer, 'AG is ignored');
        Assert.areEqual(LeadAutoConvertAccountMatcher.cleanKey('Jackson Laboratory'), jackson, 'Leading "The" is ignored');
        Assert.areEqual(LeadAutoConvertAccountMatcher.cleanKey('Smith and Nephew'), ampersand, '"&" equals "and"');
        Assert.areEqual('inc', onlySuffix, 'A name that is only a suffix is kept');
        Assert.areEqual('', blank, 'Blank stays blank');
    }

    @IsTest
    static void bulkMatchesTwoHundredLeadsByNameInTwoQueries() {
        System.runAs(LeadAutoConvertTestData.runner()) {
            List<Account> accounts = new List<Account>();
            for (Integer i = 0; i < 200; i++) {
                accounts.add(LeadAutoConvertTestData.account('LAC Bulk Match ' + i, 'TOS'));
            }
            insert accounts;
            List<Lead> leads = new List<Lead>();
            for (Integer i = 0; i < 200; i++) {
                // Half exact (different case), half needing cleaning.
                String company = Math.mod(i, 2) == 0 ? 'LAC BULK MATCH ' + i : 'LAC Bulk Match ' + i + ', Inc.';
                leads.add(LeadAutoConvertTestData.pendingLead('bm' + i, company));
            }
            LeadAutoConvertTestData.insertLeads(leads);
            List<Lead> loaded = loadLeads(leads);

            Test.startTest();
            Integer queriesBefore = Limits.getQueries();
            Map<Id, LeadAutoConvertAccountMatcher.Result> results = new LeadAutoConvertAccountMatcher().match(loaded, TOS_TYPES);
            Integer queriesUsed = Limits.getQueries() - queriesBefore;
            Test.stopTest();

            Assert.areEqual(2, queriesUsed, 'Two queries for the whole group');
            for (Integer i = 0; i < 200; i++) {
                LeadAutoConvertAccountMatcher.Result result = results.get(leads[i].Id);
                Assert.areEqual(accounts[i].Id, result.account?.Id, 'Lead ' + i + ' matches its Account: ' + result.problem);
                Assert.areEqual(
                    Math.mod(i, 2) == 0 ? LeadAutoConvertAccountMatcher.BY_COMPANY_NAME : LeadAutoConvertAccountMatcher.BY_CLEANED_NAME,
                    result.matchedBy,
                    'Lead ' + i + ' match type'
                );
            }
        }
    }

    @IsTest
    static void aliasPointsToItsAccount() {
        System.runAs(LeadAutoConvertTestData.runner()) {
            Account target = LeadAutoConvertTestData.account('LAC Bristol Full Name Squibb', 'TOS');
            insert target;
            Lead lead = LeadAutoConvertTestData.pendingLead('al1', 'L.A.C.B.M.S.');
            LeadAutoConvertTestData.insertLeads(new List<Lead>{ lead });
            LeadAutoConvertAccountMatcher.aliasOverride = new Map<String, String>{
                LeadAutoConvertAccountMatcher.cleanKey('LACBMS') => 'LAC Bristol Full Name Squibb'
            };

            Test.startTest();
            LeadAutoConvertAccountMatcher.Result result = new LeadAutoConvertAccountMatcher()
                .match(loadLeads(new List<Lead>{ lead }), TOS_TYPES)
                .get(lead.Id);
            Test.stopTest();

            Assert.areEqual(target.Id, result.account?.Id, 'Alias resolves to the named Account: ' + result.problem);
            Assert.areEqual(LeadAutoConvertAccountMatcher.BY_ALIAS, result.matchedBy, 'Matched by alias');
        }
    }

    @IsTest
    static void aliasToMissingAccountIsExplained() {
        Lead lead = memoryLead(1, 'Abbrev Co', null);
        Map<String, String> aliases = new Map<String, String>{
            LeadAutoConvertAccountMatcher.cleanKey('Abbrev') => 'Nobody Has This Name'
        };

        Test.startTest();
        LeadAutoConvertAccountMatcher.Result result = new LeadAutoConvertAccountMatcher()
            .matchAll(new List<Lead>{ lead }, new LeadAutoConvertAccountMatcher.Candidates(), aliases, TOS_TYPES)
            .get(lead.Id);
        Test.stopTest();

        Assert.isNull(result.account, 'No usable Account');
        Assert.isTrue(result.problem.contains('points to "Nobody Has This Name", which is not exactly one TOS Account'), result.problem);
    }

    @IsTest
    static void exactNameWinsOverCleanedName() {
        Account exact = memoryAccount(1, 'Acme Bio', 'TOS');
        Account cleanedTwin = memoryAccount(2, 'Acme Bio, Inc.', 'TOS');
        LeadAutoConvertAccountMatcher.Candidates candidates = new LeadAutoConvertAccountMatcher.Candidates();
        candidates.byExactName.put(LeadAutoConvertAccountMatcher.nameKey('Acme Bio'), new List<Account>{ exact });
        candidates.byCleanName.put(LeadAutoConvertAccountMatcher.cleanKey('Acme Bio'), new List<Account>{ exact, cleanedTwin });
        Lead lead = memoryLead(2, 'ACME BIO', null);

        Test.startTest();
        LeadAutoConvertAccountMatcher.Result result = new LeadAutoConvertAccountMatcher()
            .matchAll(new List<Lead>{ lead }, candidates, new Map<String, String>(), TOS_TYPES)
            .get(lead.Id);
        Test.stopTest();

        Assert.areEqual(exact.Id, result.account.Id, 'The exact name wins even though two Accounts match when cleaned');
        Assert.areEqual(LeadAutoConvertAccountMatcher.BY_COMPANY_NAME, result.matchedBy, 'Matched by exact name');
    }

    @IsTest
    static void ambiguousNamesFallBackToFlowMatchOrReview() {
        Account first = memoryAccount(1, 'Twin Co', 'TOS');
        Account second = memoryAccount(2, 'Twin Co', 'TOS');
        Account cleanA = memoryAccount(3, 'Clean Twin Inc', 'TOS');
        Account cleanB = memoryAccount(4, 'Clean Twin, LLC', 'TOS');
        Account site = memoryAccount(5, 'Twin Co - Site', 'TOS');
        LeadAutoConvertAccountMatcher.Candidates candidates = new LeadAutoConvertAccountMatcher.Candidates();
        candidates.byExactName.put(LeadAutoConvertAccountMatcher.nameKey('Twin Co'), new List<Account>{ first, second });
        candidates.byCleanName.put(LeadAutoConvertAccountMatcher.cleanKey('Clean Twin'), new List<Account>{ cleanA, cleanB });
        Lead withFlow = memoryLead(1, 'Twin Co', site);
        Lead withoutFlow = memoryLead(2, 'Twin Co', null);
        Lead cleanedTwins = memoryLead(3, 'CLEAN TWIN', null);

        Test.startTest();
        Map<Id, LeadAutoConvertAccountMatcher.Result> results = new LeadAutoConvertAccountMatcher()
            .matchAll(new List<Lead>{ withFlow, withoutFlow, cleanedTwins }, candidates, new Map<String, String>(), TOS_TYPES);
        Test.stopTest();

        Assert.areEqual(site.Id, results.get(withFlow.Id).account.Id, 'Two Accounts share the name, so the flow match is used');
        Assert.areEqual(LeadAutoConvertAccountMatcher.BY_LEAD_ASSIGNMENT, results.get(withFlow.Id).matchedBy, 'Matched by the flow');
        Assert.isNull(results.get(withoutFlow.Id).account, 'No usable Account');
        Assert.isTrue(results.get(withoutFlow.Id).problem.contains('2 TOS Accounts are named "Twin Co"'), results.get(withoutFlow.Id).problem);
        Assert.isNull(results.get(cleanedTwins.Id).account, 'Two cleaned matches are ambiguous');
        Assert.isTrue(
            results.get(cleanedTwins.Id).problem.contains('2 TOS Accounts match "CLEAN TWIN" when Inc, LLC and punctuation are ignored'),
            results.get(cleanedTwins.Id).problem
        );
    }

    @IsTest
    static void nonTosAccountsAreNeverMatchedByName() {
        System.runAs(LeadAutoConvertTestData.runner()) {
            insert LeadAutoConvertTestData.account('LAC Hospital Clean Co', 'Hospital_Practice');
            Lead lead = LeadAutoConvertTestData.pendingLead('nt1', 'LAC Hospital Clean Co, Inc.');
            LeadAutoConvertTestData.insertLeads(new List<Lead>{ lead });

            Test.startTest();
            LeadAutoConvertAccountMatcher.Result result = new LeadAutoConvertAccountMatcher()
                .match(loadLeads(new List<Lead>{ lead }), TOS_TYPES)
                .get(lead.Id);
            Test.stopTest();

            Assert.isNull(result.account, 'A Hospital Account is not used even when the cleaned name matches');
            Assert.isTrue(result.problem.contains('No TOS Account matches'), result.problem);
        }
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
            .matchAll(
                new List<Lead>{ nonTos, deleted, none },
                new LeadAutoConvertAccountMatcher.Candidates(),
                new Map<String, String>(),
                TOS_TYPES
            );
        Test.stopTest();

        Assert.isTrue(results.get(nonTos.Id).problem.contains('(Hospital Co) is not a TOS Account'), results.get(nonTos.Id).problem);
        Assert.isTrue(results.get(deleted.Id).problem.contains('no longer exists'), results.get(deleted.Id).problem);
        Assert.isTrue(results.get(none.Id).problem.startsWith('The Lead has no Company'), results.get(none.Id).problem);
        for (LeadAutoConvertAccountMatcher.Result result : results.values()) {
            Assert.isNull(result.account, 'No Account when nothing usable matched');
        }
    }
}
