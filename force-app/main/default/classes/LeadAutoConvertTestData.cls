/** Shared fixtures for the Lead auto-convert tests. */
@IsTest
public class LeadAutoConvertTestData {
    public static final String FALLBACK_ALIAS = 'lacfall';
    public static final String PENDING = 'Auto-Convert Pending';
    public static final String REVIEW = 'Needs Manual Review';
    public static final String CONVERTED = 'Qualified';

    /** Tests run as this user: Deny_Coastal_Cloud_ac_from_creating_opp blocks the deploy user. */
    public static final String ACCOUNT_OWNER_ALIAS = 'lacacct';

    public static void createRunner() {
        Profile admin = [SELECT Id FROM Profile WHERE Name = 'System Administrator' LIMIT 1];
        insert new List<User>{
            testUser(admin.Id, FALLBACK_ALIAS, 'fallback'),
            testUser(admin.Id, ACCOUNT_OWNER_ALIAS, 'acctowner')
        };
    }

    private static User testUser(Id profileId, String alias, String key) {
        return new User(
            FirstName = 'Auto',
            LastName = 'Convert ' + key,
            Alias = alias,
            Email = 'lac.' + key + '@example.com',
            Username = 'lac.' + key + '.' + System.currentTimeMillis() + '@example.com',
            ProfileId = profileId,
            TimeZoneSidKey = 'America/New_York',
            LocaleSidKey = 'en_US',
            EmailEncodingKey = 'UTF-8',
            LanguageLocaleKey = 'en_US'
        );
    }

    /** A second active user, so tests can tell the Account owner apart from the fallback user. */
    public static User accountOwner() {
        return [SELECT Id FROM User WHERE Alias = :ACCOUNT_OWNER_ALIAS LIMIT 1];
    }

    public static User runner() {
        return [SELECT Id FROM User WHERE Alias = :FALLBACK_ALIAS LIMIT 1];
    }

    public static Lead_Auto_Convert_Setting__mdt settingsRecord() {
        return new Lead_Auto_Convert_Setting__mdt(
            Active__c = true,
            Pending_Status__c = PENDING,
            Review_Status__c = REVIEW,
            Converted_Status__c = CONVERTED,
            Contact_Record_Type__c = 'General',
            Opportunity_Record_Type__c = 'TOS',
            Opportunity_Stage__c = 'Proposed',
            Opportunity_Amount__c = 1,
            Close_Date_Cutoff_Day__c = 21,
            Fallback_Owner_Alias__c = FALLBACK_ALIAS,
            Leads_Per_Run__c = 10
        );
    }

    public static LeadAutoConvertSettings useSettings(Lead_Auto_Convert_Setting__mdt record) {
        LeadAutoConvertSettings.testRecord = record;
        return LeadAutoConvertSettings.get();
    }

    /** A waiting Lead owned by the running user. HubSpot stage is left blank so the real flow ignores it. */
    public static Lead pendingLead(String key, String company) {
        return new Lead(
            FirstName = 'Test',
            LastName = 'Lead' + key,
            Company = company,
            Email = 'lac.' + key + '@lac-test-' + key + '.example.com',
            Status = PENDING,
            OwnerId = UserInfo.getUserId(),
            RecordTypeId = Schema.SObjectType.Lead.getRecordTypeInfosByDeveloperName()
                .get('TOS_Lead_Record_Type')
                .getRecordTypeId()
        );
    }

    public static Account account(String name, String recordType) {
        return new Account(
            Name = name,
            RecordTypeId = Schema.SObjectType.Account.getRecordTypeInfosByDeveloperName()
                .get(recordType)
                .getRecordTypeId()
        );
    }

    /** Lead Assignment runs on create and may change owner, Matched Account or Status, so the test's values are written back. */
    public static void insertLeads(List<Lead> leads) {
        List<Lead> intended = leads.deepClone(false, false, false);
        insert leads;
        List<Lead> pins = new List<Lead>();
        for (Integer i = 0; i < leads.size(); i++) {
            pins.add(
                new Lead(
                    Id = leads[i].Id,
                    OwnerId = intended[i].OwnerId,
                    Matched_Account__c = intended[i].Matched_Account__c,
                    Status = intended[i].Status
                )
            );
        }
        update pins;
    }

    public static List<Id> ids(List<Lead> leads) {
        List<Id> leadIds = new List<Id>();
        for (Lead lead : leads) {
            leadIds.add(lead.Id);
        }
        return leadIds;
    }
}
