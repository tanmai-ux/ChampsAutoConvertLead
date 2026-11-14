/**
 * Picks the Account a waiting Lead converts onto. "TOS Account" means one of the
 * record types in the settings. In this order, stopping at the first that applies:
 *   1. Exact name: the one TOS Account whose Name equals the Lead's Company (ignoring case).
 *   2. Alias: the Company is listed in Lead_Auto_Convert_Account_Alias__mdt and points to one TOS Account.
 *   3. Cleaned name: names match once case, punctuation, "&"/"and", a leading "The" and legal
 *      suffixes such as Inc, LLC, Ltd, Corp, GmbH and AG are ignored ("Pfizer, Inc." = "PFIZER").
 *   4. The Lead's Matched Account from the Lead Assignment flow, if it is a TOS Account.
 *   5. Otherwise no Account, with the reason, so the Lead goes to review.
 * A step that finds more than one TOS Account is ambiguous: later name steps are skipped
 * and only the flow's match can still be used.
 *
 * Two queries for the whole group, whatever its size: exact names (plus alias targets),
 * and candidates that start with the Company's first word for the cleaned comparison.
 * Cleaning happens in Apex, so no Account field or data change is needed.
 */
public inherited sharing class LeadAutoConvertAccountMatcher {
    public static final String BY_COMPANY_NAME = 'Company name';
    public static final String BY_ALIAS = 'Account alias';
    public static final String BY_CLEANED_NAME = 'Company name, ignoring Inc, LLC and punctuation';
    public static final String BY_LEAD_ASSIGNMENT = 'Lead Assignment flow';

    /** Trailing words dropped when cleaning a name. "and" covers names like "Eli Lilly and Company". */
    private static final Set<String> SUFFIXES = new Set<String>{
        'inc', 'incorporated', 'llc', 'llp', 'lp', 'ltd', 'limited', 'corp', 'corporation',
        'co', 'company', 'plc', 'gmbh', 'ag', 'sa', 'nv', 'bv', 'srl', 'pty', 'and'
    };
    private static final Integer MIN_PREFIX_LENGTH = 2;

    /** Lets tests supply aliases; custom metadata records can't be inserted in tests. Keys are cleaned. */
    @TestVisible
    private static Map<String, String> aliasOverride;

    public class Result {
        /** Has Id, Name, OwnerId and Owner.IsActive. Null when nothing usable matched. */
        public Account account;
        public String matchedBy;
        public String problem;
    }

    /** Accounts found for a group of Leads, indexed two ways. */
    @TestVisible
    private class Candidates {
        @TestVisible
        Map<String, List<Account>> byExactName = new Map<String, List<Account>>();
        @TestVisible
        Map<String, List<Account>> byCleanName = new Map<String, List<Account>>();
    }

    private final LeadAutoConvertSelector selector = new LeadAutoConvertSelector();

    /** Leads must include Company, Matched_Account__c and Matched_Account__r Name, RecordType, OwnerId, Owner.IsActive. */
    public Map<Id, Result> match(List<Lead> leads, Set<String> accountRecordTypes) {
        Map<String, String> aliases = aliases();
        return matchAll(leads, loadCandidates(leads, aliases, accountRecordTypes), aliases, accountRecordTypes);
    }

    /** Separate from the queries so tests can cover Account names that duplicate rules won't let them insert. */
    @TestVisible
    private Map<Id, Result> matchAll(
        List<Lead> leads,
        Candidates candidates,
        Map<String, String> aliases,
        Set<String> accountRecordTypes
    ) {
        Map<Id, Result> results = new Map<Id, Result>();
        for (Lead lead : leads) {
            results.put(lead.Id, matchOne(lead, candidates, aliases, accountRecordTypes));
        }
        return results;
    }

    private Candidates loadCandidates(List<Lead> leads, Map<String, String> aliases, Set<String> accountRecordTypes) {
        Set<String> exactNames = new Set<String>();
        Set<String> prefixes = new Set<String>();
        for (Lead lead : leads) {
            if (String.isBlank(lead.Company)) {
                continue;
            }
            exactNames.add(lead.Company.trim());
            String aliasTarget = aliases.get(cleanKey(lead.Company));
            if (aliasTarget != null) {
                exactNames.add(aliasTarget);
            }
            String firstWord = firstWord(lead.Company);
            if (firstWord != null && firstWord.length() >= MIN_PREFIX_LENGTH) {
                prefixes.add(firstWord + '%');
                prefixes.add('the ' + firstWord + '%');
            }
        }

        Candidates candidates = new Candidates();
        if (!exactNames.isEmpty()) {
            for (Account account : selector.getAccountsByName(exactNames, accountRecordTypes)) {
                addTo(candidates.byExactName, nameKey(account.Name), account);
            }
        }
        if (!prefixes.isEmpty()) {
            for (Account account : selector.getAccountsByNamePrefix(new List<String>(prefixes), accountRecordTypes)) {
                addTo(candidates.byCleanName, cleanKey(account.Name), account);
            }
        }
        return candidates;
    }

    private Result matchOne(
        Lead lead,
        Candidates candidates,
        Map<String, String> aliases,
        Set<String> accountRecordTypes
    ) {
        Result result = new Result();
        String nameProblem = nameProblem(lead, candidates, aliases, result);
        if (result.account != null) {
            return result;
        }

        String flowProblem = flowProblem(lead, accountRecordTypes);
        if (flowProblem == null) {
            result.account = lead.Matched_Account__r;
            result.matchedBy = BY_LEAD_ASSIGNMENT;
            return result;
        }
        result.problem = nameProblem + ', and ' + flowProblem;
        return result;
    }

    /**
     * Runs the name steps (exact, alias, cleaned). Sets result.account on a match;
     * otherwise returns why no name step could be used.
     */
    private String nameProblem(Lead lead, Candidates candidates, Map<String, String> aliases, Result result) {
        if (String.isBlank(lead.Company)) {
            return 'The Lead has no Company';
        }
        String company = lead.Company.trim();

        List<Account> exact = candidates.byExactName.get(nameKey(company));
        if (exact != null && exact.size() == 1) {
            return found(result, exact[0], BY_COMPANY_NAME);
        }
        if (exact != null) {
            return exact.size() + ' TOS Accounts are named "' + company + '"';
        }

        String clean = cleanKey(company);
        String aliasTarget = aliases.get(clean);
        if (aliasTarget != null) {
            List<Account> aliased = candidates.byExactName.get(nameKey(aliasTarget));
            if (aliased != null && aliased.size() == 1) {
                return found(result, aliased[0], BY_ALIAS);
            }
            return 'The alias for "' + company + '" points to "' + aliasTarget + '", which is not exactly one TOS Account';
        }

        List<Account> cleaned = String.isBlank(clean) ? null : candidates.byCleanName.get(clean);
        if (cleaned != null && cleaned.size() == 1) {
            return found(result, cleaned[0], BY_CLEANED_NAME);
        }
        if (cleaned != null) {
            return cleaned.size() + ' TOS Accounts match "' + company + '" when Inc, LLC and punctuation are ignored';
        }
        return 'No TOS Account matches "' + company + '" by name or alias';
    }

    private String found(Result result, Account account, String matchedBy) {
        result.account = account;
        result.matchedBy = matchedBy;
        return null;
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

    /** Active aliases keyed by cleaned alias text, pointing at an exact Account Name. */
    private static Map<String, String> aliases() {
        if (aliasOverride != null) {
            return aliasOverride;
        }
        Map<String, String> aliases = new Map<String, String>();
        for (Lead_Auto_Convert_Account_Alias__mdt alias : Lead_Auto_Convert_Account_Alias__mdt.getAll().values()) {
            String key = cleanKey(alias.Alias__c);
            if (alias.Active__c && String.isNotBlank(key) && String.isNotBlank(alias.Account_Name__c)) {
                aliases.put(key, alias.Account_Name__c.trim());
            }
        }
        return aliases;
    }

    private static void addTo(Map<String, List<Account>> index, String key, Account account) {
        if (String.isBlank(key)) {
            return;
        }
        if (!index.containsKey(key)) {
            index.put(key, new List<Account>());
        }
        index.get(key).add(account);
    }

    @TestVisible
    private static String nameKey(String name) {
        return name.trim().toLowerCase();
    }

    /** Lowercase words without punctuation, a leading "the" or trailing legal suffixes. */
    private static List<String> words(String name) {
        List<String> words = new List<String>();
        if (String.isBlank(name)) {
            return words;
        }
        String spaced = name.toLowerCase().replace('&', ' and ').replaceAll('[^\\p{L}\\p{N}]+', ' ').trim();
        for (String word : spaced.split(' ')) {
            if (String.isNotBlank(word)) {
                words.add(word);
            }
        }
        if (words.size() > 1 && words[0] == 'the') {
            words.remove(0);
        }
        while (words.size() > 1 && SUFFIXES.contains(words[words.size() - 1])) {
            words.remove(words.size() - 1);
        }
        return words;
    }

    /** "Pfizer, Inc." and "PFIZER" both give "pfizer". Blank when nothing is left. */
    @TestVisible
    private static String cleanKey(String name) {
        return String.join(words(name), '');
    }

    private static String firstWord(String name) {
        List<String> words = words(name);
        return words.isEmpty() ? null : words[0];
    }
}
