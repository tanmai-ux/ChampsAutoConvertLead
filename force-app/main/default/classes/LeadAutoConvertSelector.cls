/**
 * SOQL for Lead auto-conversion. Inherits the caller's sharing so it reads
 * the same records the background conversion acts on.
 */
public inherited sharing class LeadAutoConvertSelector {
    private static final List<String> OPEN_JOB_STATUSES = new List<String>{
        'Holding',
        'Queued',
        'Preparing',
        'Processing'
    };

    /** Oldest first, so Leads convert in the order they arrived. */
    public List<Lead> getPendingLeads(String pendingStatus, Integer maxLeads) {
        return [
            SELECT Id
            FROM Lead
            WHERE Status = :pendingStatus AND IsConverted = FALSE
            ORDER BY CreatedDate ASC, Id ASC
            LIMIT :maxLeads
        ];
    }

    public Integer countPendingLeads(String pendingStatus) {
        return [SELECT COUNT() FROM Lead WHERE Status = :pendingStatus AND IsConverted = FALSE];
    }

    /**
     * Locks the Leads, so if two workers ever overlap the second waits and then
     * sees them as already converted instead of converting them twice.
     * Locking queries can't use ORDER BY, so callers keep their own order.
     */
    public List<Lead> getLeadsForUpdate(List<Id> leadIds) {
        return [
            SELECT
                Id,
                FirstName,
                LastName,
                Company,
                Email,
                Status,
                OwnerId,
                IsConverted,
                LeadSource,
                Referred_By__c,
                Matched_Account__c,
                Matched_Account__r.Name,
                Matched_Account__r.RecordType.DeveloperName,
                Matched_Account__r.OwnerId,
                Matched_Account__r.Owner.IsActive
            FROM Lead
            WHERE Id IN :leadIds
            FOR UPDATE
        ];
    }

    /** Name comparison in SOQL ignores case. */
    public List<Account> getAccountsByName(Set<String> names, Set<String> recordTypes) {
        return [
            SELECT Id, Name, OwnerId, Owner.IsActive, RecordType.DeveloperName
            FROM Account
            WHERE Name IN :names AND RecordType.DeveloperName IN :recordTypes
        ];
    }

    /**
     * Candidates for cleaned-name matching: TOS Accounts whose Name starts with any of
     * the patterns (for example "pfizer%"). Capped so a very common first word can't
     * exhaust the query row limit.
     */
    public List<Account> getAccountsByNamePrefix(List<String> patterns, Set<String> recordTypes) {
        return [
            SELECT Id, Name, OwnerId, Owner.IsActive, RecordType.DeveloperName
            FROM Account
            WHERE Name LIKE :patterns AND RecordType.DeveloperName IN :recordTypes
            LIMIT 2000
        ];
    }

    /** Oldest first, so the longest-standing Contact wins when an email repeats. */
    public List<Contact> getContactsByEmail(Set<String> emails) {
        return [
            SELECT Id, Email, AccountId
            FROM Contact
            WHERE Email IN :emails
            ORDER BY CreatedDate ASC
        ];
    }

    public Id getActiveUserIdByAlias(String alias) {
        List<User> users = [
            SELECT Id
            FROM User
            WHERE Alias = :alias AND IsActive = TRUE
            LIMIT 1
        ];
        return users.isEmpty() ? null : users[0].Id;
    }

    public Id getOrgWideEmailAddressId(String address) {
        List<OrgWideEmailAddress> addresses = [
            SELECT Id
            FROM OrgWideEmailAddress
            WHERE Address = :address
            LIMIT 1
        ];
        return addresses.isEmpty() ? null : addresses[0].Id;
    }

    public Boolean hasOpenJob(String apexClassName) {
        return [
            SELECT COUNT()
            FROM AsyncApexJob
            WHERE JobType = 'Queueable' AND ApexClass.Name = :apexClassName AND Status IN :OPEN_JOB_STATUSES
        ] > 0;
    }
}
