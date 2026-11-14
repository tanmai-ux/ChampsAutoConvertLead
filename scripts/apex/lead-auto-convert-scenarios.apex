// Lead auto-convert scenario test data for champsDev. Every record is named "ACT ..." so it's easy to find and delete.
String tag = String.valueOf(Datetime.now().getTime()).right(5);
Id tosAcct = Schema.SObjectType.Account.getRecordTypeInfosByDeveloperName().get('TOS').getRecordTypeId();
Id hospAcct = Schema.SObjectType.Account.getRecordTypeInfosByDeveloperName().get('Hospital_Practice').getRecordTypeId();
Id tosLead = Schema.SObjectType.Lead.getRecordTypeInfosByDeveloperName().get('TOS_Lead_Record_Type').getRecordTypeId();
Id posLead = Schema.SObjectType.Lead.getRecordTypeInfosByDeveloperName().get('POS_Record_Type').getRecordTypeId();
Id generalContact = Schema.SObjectType.Contact.getRecordTypeInfosByDeveloperName().get('General').getRecordTypeId();
Id accountOwner = [SELECT Id FROM User WHERE Name = 'Earl Major' AND IsActive = TRUE LIMIT 1].Id;

Map<String, Account> accts = new Map<String, Account>{
    'nameMatch'    => new Account(Name = 'ACT Name Match ' + tag, RecordTypeId = tosAcct, Account_Number__c = '99' + tag.right(2) + '1'),
    'flowOnly'     => new Account(Name = 'ACT Flow Only ' + tag, RecordTypeId = tosAcct, Website = 'https://actflow' + tag + '.com', Account_Number__c = '99' + tag.right(2) + '2'),
    'nameWins'     => new Account(Name = 'ACT Name Wins ' + tag, RecordTypeId = tosAcct, Account_Number__c = '99' + tag.right(2) + '3'),
    'nameWinsSite' => new Account(Name = 'ACT Name Wins Site ' + tag, RecordTypeId = tosAcct, Website = 'https://actsite' + tag + '.com', Account_Number__c = '99' + tag.right(2) + '4'),
    'hospName'     => new Account(Name = 'ACT Hospital ' + tag, RecordTypeId = hospAcct),
    'hospFlow'     => new Account(Name = 'ACT Hospital Domain ' + tag, RecordTypeId = hospAcct, Website = 'https://acthosp' + tag + '.com'),
    'queue'        => new Account(Name = 'ACT Queue Owner ' + tag, RecordTypeId = tosAcct, OwnerId = accountOwner, Account_Number__c = '99' + tag.right(2) + '5'),
    'reuse'        => new Account(Name = 'ACT Contact Reuse ' + tag, RecordTypeId = tosAcct, Account_Number__c = '99' + tag.right(2) + '6'),
    'conflict'     => new Account(Name = 'ACT Contact Conflict ' + tag, RecordTypeId = tosAcct, Account_Number__c = '99' + tag.right(2) + '7'),
    'conflictOther'=> new Account(Name = 'ACT Other Company ' + tag, RecordTypeId = tosAcct, Account_Number__c = '99' + tag.right(2) + '8'),
    'shared'       => new Account(Name = 'ACT Shared ' + tag, RecordTypeId = tosAcct, Account_Number__c = '99' + tag.right(2) + '9'),
    'cleanTarget'  => new Account(Name = 'ACT Clean Target ' + tag, RecordTypeId = tosAcct, Account_Number__c = '98' + tag.right(2) + '1'),
    'theTarget'    => new Account(Name = 'ACT The Target ' + tag, RecordTypeId = tosAcct, Account_Number__c = '98' + tag.right(2) + '2')
};
insert accts.values();

String reuseEmail = 'act.reuse.' + tag + '@gmail.com';
String conflictEmail = 'act.conflict.' + tag + '@gmail.com';
insert new List<Contact>{
    new Contact(FirstName = 'ACT', LastName = 'Existing Reuse ' + tag, Email = reuseEmail, AccountId = accts.get('reuse').Id, RecordTypeId = generalContact),
    new Contact(FirstName = 'ACT', LastName = 'Existing Elsewhere ' + tag, Email = conflictEmail, AccountId = accts.get('conflictOther').Id, RecordTypeId = generalContact)
};

Lead[] leads = new Lead[]{};
List<String> keys = new List<String>{
    'S1 name match', 'S2 flow match only', 'S3 name beats flow', 'S4 no match', 'S5 name matches non-TOS only',
    'S6 flow matched non-TOS', 'S7 queue-owned', 'S8 reuse contact', 'S9 contact on other account',
    'S10a shared account', 'S10b shared account', 'S11 not MQL', 'S12 POS lead',
    'S20 cleaned name', 'S21 alias', 'S22 The and LLC'
};
List<String[]> spec = new List<String[]>{
    // company, email, state, recordType, hubspot stage
    new String[]{ accts.get('nameMatch').Name, 'act.s1.' + tag + '@gmail.com', 'New York', 'TOS', 'MQL / Contact' },
    new String[]{ 'ACT Unlisted Company ' + tag, 'act.s2@actflow' + tag + '.com', 'New York', 'TOS', 'MQL / Contact' },
    new String[]{ accts.get('nameWins').Name, 'act.s3@actsite' + tag + '.com', 'New York', 'TOS', 'MQL / Contact' },
    new String[]{ 'ACT Nobody ' + tag, 'act.s4.' + tag + '@gmail.com', 'New York', 'TOS', 'MQL / Contact' },
    new String[]{ accts.get('hospName').Name, 'act.s5.' + tag + '@gmail.com', 'New York', 'TOS', 'MQL / Contact' },
    new String[]{ 'ACT Unlisted Hospital ' + tag, 'act.s6@acthosp' + tag + '.com', 'New York', 'TOS', 'MQL / Contact' },
    new String[]{ accts.get('queue').Name, 'act.s7.' + tag + '@gmail.com', 'California', 'TOS', 'MQL / Contact' },
    new String[]{ accts.get('reuse').Name, reuseEmail, 'New York', 'TOS', 'MQL / Contact' },
    new String[]{ accts.get('conflict').Name, conflictEmail, 'New York', 'TOS', 'MQL / Contact' },
    new String[]{ accts.get('shared').Name, 'act.s10a.' + tag + '@gmail.com', 'New York', 'TOS', 'MQL / Contact' },
    new String[]{ accts.get('shared').Name, 'act.s10b.' + tag + '@gmail.com', 'New York', 'TOS', 'MQL / Contact' },
    new String[]{ accts.get('nameMatch').Name, 'act.s11.' + tag + '@gmail.com', 'New York', 'TOS', null },
    new String[]{ accts.get('nameMatch').Name, 'act.s12.' + tag + '@gmail.com', 'New York', 'POS', 'MQL / Contact' },
    new String[]{ accts.get('cleanTarget').Name.toLowerCase() + ', Inc.', 'act.s20.' + tag + '@gmail.com', 'New York', 'TOS', 'MQL / Contact' },
    // Uses the sandbox-only alias record "ACT Alias 89466" -> "ACT Flow Only 89466".
    new String[]{ 'ACT ALIAS 89466', 'act.s21.' + tag + '@gmail.com', 'New York', 'TOS', 'MQL / Contact' },
    new String[]{ 'The ' + accts.get('theTarget').Name + ' LLC', 'act.s22.' + tag + '@gmail.com', 'New York', 'TOS', 'MQL / Contact' }
};
for (Integer i = 0; i < spec.size(); i++) {
    String[] s = spec[i];
    leads.add(new Lead(
        FirstName = 'ACT', LastName = keys[i] + ' ' + tag, Company = s[0], Email = s[1],
        State = s[2], Country = 'United States',
        RecordTypeId = s[3] == 'TOS' ? tosLead : posLead,
        HubSpot_Lifecycle_Stage__c = s[4]
    ));
}
insert leads;

Map<String, Object> out = new Map<String, Object>{ 'tag' => tag };
Map<String, Id> leadIds = new Map<String, Id>();
for (Integer i = 0; i < leads.size(); i++) { leadIds.put(keys[i], leads[i].Id); }
Map<String, Id> acctIds = new Map<String, Id>();
for (String k : accts.keySet()) { acctIds.put(k, accts.get(k).Id); }
out.put('leads', leadIds);
out.put('accounts', acctIds);
System.debug('SCENARIOS=' + JSON.serialize(out));
