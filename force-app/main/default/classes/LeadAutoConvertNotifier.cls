/**
 * Tells a Lead's owner that an MQL Lead needs manual review: a Task on the Lead,
 * which keeps the reason, and an email. Text comes from Custom Labels so an admin
 * can change the wording.
 *
 * Why "without sharing": called from background automation, which may be running
 * as a user who can't see the Lead or create Tasks for its owner.
 */
public without sharing class LeadAutoConvertNotifier {
    /** The last emails handed to Messaging, for tests: sandboxes may block delivery. */
    @TestVisible
    private static List<Messaging.SingleEmailMessage> lastEmails = new List<Messaging.SingleEmailMessage>();

    public class Review {
        public Lead lead;
        public Id recipientId;
        public String reason;

        public Review(Lead lead, Id recipientId, String reason) {
            this.lead = lead;
            this.recipientId = recipientId;
            this.reason = reason;
        }
    }

    private final LeadAutoConvertSelector selector = new LeadAutoConvertSelector();

    /** A review with no user to tell (a queue-owned Lead and no fallback user) is flagged by its Status only. */
    public void notify(List<Review> reviews, LeadAutoConvertSettings settings) {
        List<Task> tasks = new List<Task>();
        List<Messaging.SingleEmailMessage> emails = new List<Messaging.SingleEmailMessage>();
        Id orgWideAddressId = String.isBlank(settings.orgWideEmailAddress)
            ? null
            : selector.getOrgWideEmailAddressId(settings.orgWideEmailAddress);
        String baseUrl = URL.getOrgDomainUrl().toExternalForm();

        for (Review review : reviews) {
            if (review.recipientId == null) {
                continue;
            }
            String leadName = String.isBlank(review.lead.FirstName)
                ? review.lead.LastName
                : review.lead.FirstName + ' ' + review.lead.LastName;
            String subject = String.format(Label.Lead_Auto_Convert_Review_Subject, new List<Object>{ leadName });
            String body = String.format(
                Label.Lead_Auto_Convert_Review_Body,
                new List<Object>{ leadName, review.lead.Company, review.reason, baseUrl + '/' + review.lead.Id }
            );

            tasks.add(
                new Task(
                    OwnerId = review.recipientId,
                    WhoId = review.lead.Id,
                    Subject = subject.left(255),
                    Description = body,
                    ActivityDate = Date.today()
                )
            );
            emails.add(buildEmail(review.recipientId, subject, body, orgWideAddressId, settings.reviewCcAddresses));
        }

        if (!tasks.isEmpty()) {
            Database.insert(tasks, false);
        }
        send(emails);
    }

    /**
     * Sent to a user Id, which doesn't count against the daily single-email limit.
     * CC addresses from the settings do count.
     */
    private Messaging.SingleEmailMessage buildEmail(
        Id recipientId,
        String subject,
        String body,
        Id orgWideAddressId,
        List<String> ccAddresses
    ) {
        Messaging.SingleEmailMessage email = new Messaging.SingleEmailMessage();
        email.setTargetObjectId(recipientId);
        if (!ccAddresses.isEmpty()) {
            email.setCcAddresses(ccAddresses);
        }
        email.setSaveAsActivity(false);
        email.setSubject(subject);
        email.setPlainTextBody(body);
        if (orgWideAddressId != null) {
            email.setOrgWideEmailAddressId(orgWideAddressId);
        }
        return email;
    }

    private void send(List<Messaging.SingleEmailMessage> emails) {
        if (emails.isEmpty()) {
            return;
        }
        lastEmails = emails;
        try {
            Messaging.sendEmail(emails, false);
        } catch (Exception e) {
            // Email can be switched off (often in sandboxes). The Task and Lead Status
            // still flag the Lead, so this must not stop the conversion run.
            System.debug(LoggingLevel.WARN, 'Lead auto-convert review email not sent: ' + e.getMessage());
        }
    }
}
