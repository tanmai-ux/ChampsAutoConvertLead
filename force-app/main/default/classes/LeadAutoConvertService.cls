/**
 * Converts waiting MQL Leads into a Contact and Opportunity on an existing Account.
 *
 * No Account is ever created. LeadAutoConvertAccountMatcher picks the Account:
 * the one TOS Account named like the Lead's Company, otherwise the Lead's Matched
 * Account from the Lead Assignment flow if it is a TOS Account. A Lead with no
 * usable Account, or one that fails for any other reason, is set to the review
 * status and its owner gets a Task and an email.
 *
 * Why "without sharing": this is background automation running as an integration
 * user, which may not see every Account or be able to edit queue-owned Leads.
 * Users never call it directly.
 *
 * Opportunities are inserted before conversion because
 * Opportunity_Before_Save_Naming_and_Numbering fires on create only. It numbers
 * from the Account's Highest_Opp_Sequence__c roll-up, which only moves between
 * saves, so each run takes one Lead per Account and leaves the rest waiting for
 * the next run. That keeps project numbers unique.
 */
public without sharing class LeadAutoConvertService {
    private static final String USER_ID_PREFIX = '005';
    private static final Integer OPPORTUNITY_NAME_MAX = 120;

    public enum Result {
        CONVERTED,
        NEEDS_REVIEW,
        DEFERRED,
        SKIPPED
    }

    public class Outcome {
        public Result result;
        public String message;
        public Id accountId;
        public Id contactId;
        public Id opportunityId;
    }

    /** Per-Lead working state, so the steps below stay small. A null result means still in progress. */
    private class Item {
        Lead lead;
        Outcome outcome = new Outcome();
        Id ownerId;
        Id existingContactId;
        Account account;
        String matchProblem;

        Item(Lead lead) {
            this.lead = lead;
        }

        Boolean isActive() {
            return outcome.result == null;
        }

        void review(String message) {
            outcome.result = Result.NEEDS_REVIEW;
            outcome.message = message;
        }

        void finish(Result result, String message) {
            outcome.result = result;
            outcome.message = message;
        }
    }

    private final LeadAutoConvertSelector selector = new LeadAutoConvertSelector();
    private final LeadAutoConvertNotifier notifier = new LeadAutoConvertNotifier();

    /** Lead Ids in priority order: when two Leads share an Account, the earlier one converts first. */
    public Map<Id, Outcome> convert(List<Id> leadIds, LeadAutoConvertSettings settings) {
        Map<Id, Outcome> outcomes = new Map<Id, Outcome>();
        List<Item> items = loadItems(leadIds, settings, outcomes);

        resolveAccounts(items, settings);
        resolveOwners(items, settings);
        requireAccounts(items);
        checkExistingContacts(items);
        deferSharedAccounts(items);
        createOpportunities(active(items), settings);
        convertLeads(active(items), settings);
        removeUnusedOpportunities(items);
        applyContactRecordType(items, settings);
        linkPrincipalInvestigator(items);
        flagForReview(items, settings);
        return outcomes;
    }

    /**
     * Sends waiting Leads straight to review with one reason. Used when a whole
     * run failed, for example on a governor limit, and the Lead couldn't be processed.
     */
    public void sendToReview(List<Id> leadIds, String reason, LeadAutoConvertSettings settings) {
        List<Item> items = loadItems(leadIds, settings, new Map<Id, Outcome>());
        resolveAccounts(items, settings);
        resolveOwners(items, settings);
        for (Item item : active(items)) {
            item.review(reason);
        }
        flagForReview(items, settings);
    }

    private List<Item> loadItems(List<Id> leadIds, LeadAutoConvertSettings settings, Map<Id, Outcome> outcomes) {
        Map<Id, Lead> leadsById = new Map<Id, Lead>(selector.getLeadsForUpdate(leadIds));
        List<Item> items = new List<Item>();
        for (Id leadId : leadIds) {
            Lead lead = leadsById.get(leadId);
            if (lead == null || outcomes.containsKey(leadId)) {
                continue;
            }
            Item item = new Item(lead);
            outcomes.put(leadId, item.outcome);
            if (lead.IsConverted || lead.Status != settings.pendingStatus) {
                item.finish(Result.SKIPPED, 'Lead is no longer waiting for auto-conversion.');
            }
            items.add(item);
        }
        return items;
    }

    private List<Item> active(List<Item> items) {
        List<Item> remaining = new List<Item>();
        for (Item item : items) {
            if (item.isActive()) {
                remaining.add(item);
            }
        }
        return remaining;
    }

    /** Picks each Lead's Account. Leads without one are flagged later, after their reviewer is known. */
    private void resolveAccounts(List<Item> items, LeadAutoConvertSettings settings) {
        List<Lead> leads = new List<Lead>();
        for (Item item : active(items)) {
            leads.add(item.lead);
        }
        if (leads.isEmpty()) {
            return;
        }
        Map<Id, LeadAutoConvertAccountMatcher.Result> matches = new LeadAutoConvertAccountMatcher()
            .match(leads, settings.accountRecordTypes);
        for (Item item : active(items)) {
            LeadAutoConvertAccountMatcher.Result match = matches.get(item.lead.Id);
            item.account = match.account;
            item.matchProblem = match.problem;
            item.outcome.accountId = match.account?.Id;
        }
    }

    /**
     * Converted records must be owned by a user. A queue-owned Lead goes to the
     * chosen Account's owner, who also gets the review if it fails. The fallback
     * user is used only when there is no Account or its owner is inactive.
     */
    private void resolveOwners(List<Item> items, LeadAutoConvertSettings settings) {
        Id fallbackOwnerId;
        Boolean fallbackLoaded = false;
        for (Item item : active(items)) {
            if (String.valueOf(item.lead.OwnerId).startsWith(USER_ID_PREFIX)) {
                item.ownerId = item.lead.OwnerId;
                continue;
            }
            if (item.account != null && item.account.Owner?.IsActive == true) {
                item.ownerId = item.account.OwnerId;
                continue;
            }
            if (!fallbackLoaded) {
                fallbackOwnerId = selector.getActiveUserIdByAlias(settings.fallbackOwnerAlias);
                fallbackLoaded = true;
            }
            item.ownerId = fallbackOwnerId;
            if (fallbackOwnerId == null) {
                item.review('Lead is owned by a queue and no active user has the fallback alias ' + settings.fallbackOwnerAlias + '.');
            }
        }
    }

    private void requireAccounts(List<Item> items) {
        for (Item item : active(items)) {
            if (item.account == null) {
                item.review(item.matchProblem);
            }
        }
    }

    /**
     * A Contact that already has the Lead's email is reused when it sits on the
     * chosen Account, because the Contact duplicate rule would block a second one.
     * One on a different Account goes to review.
     */
    private void checkExistingContacts(List<Item> items) {
        Map<String, Contact> contactsByEmail = loadContacts(active(items));
        for (Item item : active(items)) {
            Contact existing = String.isBlank(item.lead.Email)
                ? null
                : contactsByEmail.get(item.lead.Email.toLowerCase());
            if (existing == null) {
                continue;
            }
            if (existing.AccountId == item.outcome.accountId) {
                item.existingContactId = existing.Id;
            } else {
                item.review(
                    'A Contact with this email already exists on a different Account (' +
                    existing.AccountId +
                    ') than the matched Account (' +
                    item.outcome.accountId +
                    ').'
                );
            }
        }
    }

    private Map<String, Contact> loadContacts(List<Item> items) {
        Set<String> emails = new Set<String>();
        for (Item item : items) {
            if (String.isNotBlank(item.lead.Email)) {
                emails.add(item.lead.Email.toLowerCase());
            }
        }
        Map<String, Contact> contactsByEmail = new Map<String, Contact>();
        if (emails.isEmpty()) {
            return contactsByEmail;
        }
        for (Contact contact : selector.getContactsByEmail(emails)) {
            String key = contact.Email.toLowerCase();
            if (!contactsByEmail.containsKey(key)) {
                contactsByEmail.put(key, contact);
            }
        }
        return contactsByEmail;
    }

    /** One Lead per Account per run keeps Opportunity project numbers unique; the rest wait for the next run. */
    private void deferSharedAccounts(List<Item> items) {
        Set<Id> accountsTaken = new Set<Id>();
        for (Item item : active(items)) {
            if (accountsTaken.contains(item.outcome.accountId)) {
                item.finish(Result.DEFERRED, 'Another Lead for this Account is converting in this run.');
            } else {
                accountsTaken.add(item.outcome.accountId);
            }
        }
    }

    private void createOpportunities(List<Item> items, LeadAutoConvertSettings settings) {
        if (items.isEmpty()) {
            return;
        }
        Id recordTypeId = Schema.SObjectType.Opportunity.getRecordTypeInfosByDeveloperName()
            .get(settings.opportunityRecordType)
            .getRecordTypeId();
        Date closeDate = settings.closeDateFor(Date.today());

        List<Opportunity> opportunities = new List<Opportunity>();
        for (Item item : items) {
            opportunities.add(
                new Opportunity(
                    // The naming flow replaces this for TOS; it stays for record types the flow skips.
                    Name = (item.lead.Company + ' - MQL').left(OPPORTUNITY_NAME_MAX),
                    AccountId = item.outcome.accountId,
                    OwnerId = item.ownerId,
                    RecordTypeId = recordTypeId,
                    StageName = settings.opportunityStage,
                    CloseDate = closeDate,
                    // UpdateAmount adds to Amount and fails the save when it is blank.
                    Amount = settings.opportunityAmount,
                    LeadSource = item.lead.LeadSource,
                    Referred_By__c = item.lead.Referred_By__c
                )
            );
        }

        List<Database.SaveResult> saves = Database.insert(opportunities, false);
        for (Integer i = 0; i < saves.size(); i++) {
            if (saves[i].isSuccess()) {
                items[i].outcome.opportunityId = saves[i].getId();
            } else {
                items[i].review('The Opportunity could not be created: ' + firstError(saves[i].getErrors()));
            }
        }
    }

    private void convertLeads(List<Item> items, LeadAutoConvertSettings settings) {
        if (items.isEmpty()) {
            return;
        }
        List<Database.LeadConvert> converts = new List<Database.LeadConvert>();
        for (Item item : items) {
            Database.LeadConvert convert = new Database.LeadConvert();
            convert.setLeadId(item.lead.Id);
            convert.setConvertedStatus(settings.convertedStatus);
            convert.setAccountId(item.outcome.accountId);
            convert.setOpportunityId(item.outcome.opportunityId);
            convert.setOwnerId(item.ownerId);
            convert.setSendNotificationEmail(false);
            if (item.existingContactId != null) {
                convert.setContactId(item.existingContactId);
            }
            converts.add(convert);
        }

        List<Database.LeadConvertResult> results = Database.convertLead(converts, false);
        for (Integer i = 0; i < results.size(); i++) {
            if (results[i].isSuccess()) {
                items[i].outcome.contactId = results[i].getContactId();
                items[i].finish(Result.CONVERTED, 'Converted.');
            } else {
                items[i].review('The Lead could not be converted: ' + firstError(results[i].getErrors()));
            }
        }
    }

    /** Deletes Opportunities made for Leads that didn't convert, so nothing is left behind. */
    private void removeUnusedOpportunities(List<Item> items) {
        List<Opportunity> unused = new List<Opportunity>();
        for (Item item : items) {
            if (item.outcome.result != Result.CONVERTED && item.outcome.opportunityId != null) {
                unused.add(new Opportunity(Id = item.outcome.opportunityId));
                item.outcome.opportunityId = null;
            }
        }
        if (!unused.isEmpty()) {
            Database.delete(unused, false);
        }
    }

    /** convertLead uses the owner's default record type, which is Patient for many users. */
    private void applyContactRecordType(List<Item> items, LeadAutoConvertSettings settings) {
        Id recordTypeId = Schema.SObjectType.Contact.getRecordTypeInfosByDeveloperName()
            .get(settings.contactRecordType)
            .getRecordTypeId();

        List<Contact> contacts = new List<Contact>();
        List<Item> updated = new List<Item>();
        for (Item item : items) {
            if (item.outcome.result == Result.CONVERTED && item.existingContactId == null) {
                contacts.add(new Contact(Id = item.outcome.contactId, RecordTypeId = recordTypeId));
                updated.add(item);
            }
        }
        if (contacts.isEmpty()) {
            return;
        }
        // The Lead is already converted, so a failure here is reported, not rolled back.
        List<Database.SaveResult> saves = Database.update(contacts, false);
        for (Integer i = 0; i < saves.size(); i++) {
            if (!saves[i].isSuccess()) {
                updated[i].outcome.message = 'Converted, but the Contact record type was not set: ' + firstError(saves[i].getErrors());
            }
        }
    }

    /** The Opportunity's Principal Investigator is the Contact the Lead became. */
    private void linkPrincipalInvestigator(List<Item> items) {
        List<Opportunity> opportunities = new List<Opportunity>();
        List<Item> updated = new List<Item>();
        for (Item item : items) {
            if (item.outcome.result == Result.CONVERTED) {
                opportunities.add(
                    new Opportunity(Id = item.outcome.opportunityId, Principal_Investigator__c = item.outcome.contactId)
                );
                updated.add(item);
            }
        }
        if (opportunities.isEmpty()) {
            return;
        }
        // The Lead is already converted, so a failure here is reported, not rolled back.
        List<Database.SaveResult> saves = Database.update(opportunities, false);
        for (Integer i = 0; i < saves.size(); i++) {
            if (!saves[i].isSuccess()) {
                updated[i].outcome.message = 'Converted, but the Principal Investigator was not set: ' + firstError(saves[i].getErrors());
            }
        }
    }

    /** Sets the review status, then tells the owner. A Lead whose status can't be set stays waiting. */
    private void flagForReview(List<Item> items, LeadAutoConvertSettings settings) {
        List<Item> flagged = new List<Item>();
        List<Lead> leads = new List<Lead>();
        for (Item item : items) {
            if (item.outcome.result == Result.NEEDS_REVIEW) {
                flagged.add(item);
                leads.add(new Lead(Id = item.lead.Id, Status = settings.reviewStatus));
            }
        }
        if (leads.isEmpty()) {
            return;
        }

        List<LeadAutoConvertNotifier.Review> reviews = new List<LeadAutoConvertNotifier.Review>();
        List<Database.SaveResult> saves = Database.update(leads, false);
        for (Integer i = 0; i < saves.size(); i++) {
            Item item = flagged[i];
            if (saves[i].isSuccess()) {
                reviews.add(new LeadAutoConvertNotifier.Review(item.lead, item.ownerId, item.outcome.message));
            } else {
                item.finish(
                    Result.DEFERRED,
                    item.outcome.message + ' The review status could not be set: ' + firstError(saves[i].getErrors())
                );
            }
        }
        notifier.notify(reviews, settings);
    }

    private String firstError(List<Database.Error> errors) {
        // Validation rule messages come back HTML-encoded; the email and Task are plain text.
        return errors.isEmpty() ? 'Unknown error' : errors[0].getMessage().unescapeHtml4();
    }
}
