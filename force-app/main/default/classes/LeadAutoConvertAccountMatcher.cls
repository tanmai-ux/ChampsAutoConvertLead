/**
 * Picks the Account a waiting Lead converts onto, in this order:
 *   1. The one TOS Account whose Name equals the Lead's Company (ignoring case).
 *   2. Otherwise the Lead's Matched Account from the Lead Assignment flow, if it is a TOS Account.
 *   3. Otherwise no Account, with the reason, so the Lead goes to review.
 * "TOS Account" means one of the record types in the settings.
 *
 * One query for the whole group, whatever its size.
 */
public inherited sharing class LeadAutoConvertAccountMatcher {
    public static final String BY_COMPANY_NAME = 'Company name';
    public static final String BY_LEAD_ASSIGNMENT = 'Lead Assignment flow';

    public class Result {
        /** Has Id, OwnerId and Owner.IsActive. Null when nothing usable matched. */
        public Account account;
        public String matchedBy;
        public String problem;
    }

    private final LeadAutoConvertSelector selector = new LeadAutoConvertSelector();

    /** Leads must include Company, Matched_Account__c and Matched_Account__r RecordType, OwnerId, Owner.IsActive. */
    public Map<Id, Result> match(List<Lead> leads, Set<String> accountRecordTypes) {
        return matchAll(leads, loadAccountsByName(leads, accountRecordTypes), accountRecordTypes);
    }

    /** Separate from the query so tests can cover Account names that duplicate rules won't let them insert. */
    @TestVisible
    private Map<Id, Result> matchAll(
        List<Lead> leads,
        Map<String, List<Account>> accountsByName,
        Set<String> accountRecordTypes
    ) {
        Map<Id, Result> results = new Map<Id, Result>();
        for (Lead lead : leads) {
            results.put(lead.Id, matchOne(lead, accountsByName, accountRecordTypes));
        }
        return results;
    }

    private Map<String, List<Account>> loadAccountsByName(List<Lead> leads, Set<String> accountRecordTypes) {
        Set<String> names = new Set<String>();
        for (Lead lead : leads) {
            if (String.isNotBlank(lead.Company)) {
                names.add(lead.Company.trim());
            }
        }
        Map<String, List<Account>> accountsByName = new Map<String, List<Account>>();
        if (names.isEmpty()) {
            return accountsByName;
        }
        for (Account account : selector.getAccountsByName(names, accountRecordTypes)) {
            String key = nameKey(account.Name);
            if (!accountsByName.containsKey(key)) {
                accountsByName.put(key, new List<Account>());
            }
            accountsByName.get(key).add(account);
        }
        return accountsByName;
    }

    private Result matchOne(Lead lead, Map<String, List<Account>> accountsByName, Set<String> accountRecordTypes) {
        Result result = new Result();
        List<Account> named = String.isBlank(lead.Company) ? null : accountsByName.get(nameKey(lead.Company));
        if (named != null && named.size() == 1) {
            result.account = named[0];
            result.matchedBy = BY_COMPANY_NAME;
            return result;
        }

        String flowProblem = flowProblem(lead, accountRecordTypes);
        if (flowProblem == null) {
            result.account = lead.Matched_Account__r;
            result.matchedBy = BY_LEAD_ASSIGNMENT;
            return result;
        }

        String nameProblem = String.isBlank(lead.Company)
            ? 'The Lead has no Company'
            : named == null
                ? 'No TOS Account is named "' + lead.Company + '"'
                : named.size() + ' TOS Accounts are named "' + lead.Company + '"';
        result.problem = nameProblem + ', and ' + flowProblem;
        return result;
    }

    /** Null when the flow's Matched Account can be used. */
    private String flowProblem(Lead lead, Set<String> accountRecordTypes) {
        if (lead.Matched_Account__c == null) {
            return 'the Lead Assignment flow found no matching Account.';
        }
        if (lead.Matched_Account__r == null) {
            return 'the Account the Lead Assignment flow matched no longer exists.';
        }
        if (!accountRecordTypes.contains(lead.Matched_Account__r.RecordType?.DeveloperName)) {
            return 'the Account the Lead Assignment flow matched (' + lead.Matched_Account__r.Name + ') is not a TOS Account.';
        }
        return null;
    }

    @TestVisible
    private static String nameKey(String name) {
        return name.trim().toLowerCase();
    }
}
