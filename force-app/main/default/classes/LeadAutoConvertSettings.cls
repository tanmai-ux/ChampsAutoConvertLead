/**
 * Auto-conversion settings, read from the Default record of
 * Lead_Auto_Convert_Setting__mdt so an admin can change them without a deployment.
 * A missing record means auto-conversion is off.
 */
public inherited sharing class LeadAutoConvertSettings {
    private static final String RECORD_NAME = 'Default';
    private static final Integer DEFAULT_CLOSE_DATE_CUTOFF_DAY = 21;
    private static final Decimal DEFAULT_OPPORTUNITY_AMOUNT = 1;
    private static final Integer DEFAULT_LEADS_PER_RUN = 10;
    private static final Set<String> DEFAULT_ACCOUNT_RECORD_TYPES = new Set<String>{ 'TOS' };

    /** Lets tests supply settings without depending on the deployed record. */
    @TestVisible
    private static Lead_Auto_Convert_Setting__mdt testRecord;

    public Boolean active = false;
    public String pendingStatus;
    public String reviewStatus;
    public String convertedStatus;
    public String contactRecordType;
    public String opportunityRecordType;
    public String opportunityStage;
    public String fallbackOwnerAlias;
    public String orgWideEmailAddress;
    public List<String> reviewCcAddresses = new List<String>();
    /** Account record types (developer names) a Lead may convert onto. */
    public Set<String> accountRecordTypes = new Set<String>(DEFAULT_ACCOUNT_RECORD_TYPES);
    public Integer closeDateCutoffDay = DEFAULT_CLOSE_DATE_CUTOFF_DAY;
    public Decimal opportunityAmount = DEFAULT_OPPORTUNITY_AMOUNT;
    public Integer leadsPerRun = DEFAULT_LEADS_PER_RUN;

    public static LeadAutoConvertSettings get() {
        return new LeadAutoConvertSettings(
            testRecord != null ? testRecord : Lead_Auto_Convert_Setting__mdt.getInstance(RECORD_NAME)
        );
    }

    private LeadAutoConvertSettings(Lead_Auto_Convert_Setting__mdt record) {
        if (record == null) {
            return;
        }
        active = record.Active__c == true;
        pendingStatus = record.Pending_Status__c;
        reviewStatus = record.Review_Status__c;
        convertedStatus = record.Converted_Status__c;
        contactRecordType = record.Contact_Record_Type__c;
        opportunityRecordType = record.Opportunity_Record_Type__c;
        opportunityStage = record.Opportunity_Stage__c;
        fallbackOwnerAlias = record.Fallback_Owner_Alias__c;
        orgWideEmailAddress = record.Org_Wide_Email_Address__c;
        reviewCcAddresses = splitList(record.Review_Email_Cc__c);
        if (String.isNotBlank(record.Account_Record_Types__c)) {
            accountRecordTypes = new Set<String>(splitList(record.Account_Record_Types__c));
        }
        if (record.Close_Date_Cutoff_Day__c != null && record.Close_Date_Cutoff_Day__c >= 1) {
            closeDateCutoffDay = record.Close_Date_Cutoff_Day__c.intValue();
        }
        if (record.Opportunity_Amount__c != null) {
            opportunityAmount = record.Opportunity_Amount__c;
        }
        if (record.Leads_Per_Run__c != null && record.Leads_Per_Run__c >= 1) {
            leadsPerRun = record.Leads_Per_Run__c.intValue();
        }
    }

    /** Splits a comma, semicolon or space separated setting into trimmed values. */
    private static List<String> splitList(String value) {
        List<String> values = new List<String>();
        if (String.isBlank(value)) {
            return values;
        }
        for (String part : value.split('[,;\\s]+')) {
            if (String.isNotBlank(part)) {
                values.add(part.trim());
            }
        }
        return values;
    }

    /**
     * Opportunity close date: created on or before the cutoff day (the first three
     * weeks by default) closes at the end of this month, otherwise at the end of next month.
     */
    public Date closeDateFor(Date createdOn) {
        Date month = createdOn.day() <= closeDateCutoffDay ? createdOn : createdOn.addMonths(1);
        return Date.newInstance(month.year(), month.month(), Date.daysInMonth(month.year(), month.month()));
    }
}
