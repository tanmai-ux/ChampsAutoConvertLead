/**
 * Flow action: marks new MQL Leads as waiting for auto-conversion, then makes
 * sure the worker is running. The Lead Auto Convert flow decides which Leads
 * qualify; this class only queues them.
 *
 * Why "without sharing": Lead Assignment may already have moved the Lead to a
 * queue that the running user can't edit.
 */
public without sharing class LeadAutoConvertQueueAction {
    public class Request {
        @InvocableVariable(label='Lead Id' required=true)
        public Id leadId;
    }

    @InvocableMethod(
        label='Queue Lead for Auto-Convert'
        description='Sets the Lead to the pending status and asks for the auto-convert worker, which runs as the integration user.'
        category='Lead'
    )
    public static void queue(List<Request> requests) {
        LeadAutoConvertSettings settings = LeadAutoConvertSettings.get();
        if (!settings.active) {
            return;
        }
        Map<Id, Lead> leads = new Map<Id, Lead>();
        for (Request request : requests) {
            leads.put(request.leadId, new Lead(Id = request.leadId, Status = settings.pendingStatus));
        }
        for (Database.SaveResult save : Database.update(leads.values(), false)) {
            if (!save.isSuccess()) {
                System.debug(LoggingLevel.WARN, 'Lead not queued for auto-convert: ' + save.getErrors()[0].getMessage());
            }
        }
        LeadAutoConvertWorker.requestStart('Flow');
    }
}
