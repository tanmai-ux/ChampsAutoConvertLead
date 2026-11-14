/**
 * The single background job that works through Leads waiting for auto-conversion.
 *
 * Only one runs at a time. Each run takes a small group of waiting Leads, oldest
 * first, then queues the next run while Leads are still waiting. A 500-Lead import
 * becomes a chain of jobs instead of one job per Lead. If the chain stops, the
 * hourly LeadAutoConvertScheduler starts it again.
 *
 * If a run fails outright (for example on a governor limit), everything it did is
 * rolled back and RunFailureHandler retries the same Leads in groups half the size.
 * A single Lead that still fails goes to review, so one bad Lead can't block the rest.
 *
 * It is started through requestStart, so it runs as the Automated Process user.
 *
 * Why "without sharing": it must see every waiting Lead whoever owns it.
 */
public without sharing class LeadAutoConvertWorker implements Queueable {
    private static final String CLASS_NAME = 'LeadAutoConvertWorker';

    /** Apex tests can't chain queueable jobs, so tests check the requested size instead. */
    @TestVisible
    private static Boolean chainingEnabled = !Test.isRunningTest();
    @TestVisible
    private static Integer chainedRunSize;

    /** Null means use Leads Per Run from the settings. */
    private final Integer runSize;

    public LeadAutoConvertWorker() {
        this(null);
    }

    @TestVisible
    private LeadAutoConvertWorker(Integer runSize) {
        this.runSize = runSize;
    }

    /** How many start requests were published, for tests. */
    @TestVisible
    private static Integer requestsPublished = 0;

    /**
     * Asks for a worker by publishing a Lead Auto Convert Request instead of
     * starting one here. Its subscriber runs as the Automated Process user, so the
     * conversion never runs as the user who created the Lead or scheduled the check.
     * The request is sent after the current transaction commits.
     */
    public static void requestStart(String source) {
        Database.SaveResult result = EventBus.publish(new Lead_Auto_Convert_Request__e(Source__c = source));
        if (result.isSuccess()) {
            requestsPublished++;
        } else {
            // The hourly check sends another request, so waiting Leads aren't lost.
            System.debug(LoggingLevel.WARN, 'Lead auto-convert request not published: ' + result.getErrors()[0].getMessage());
        }
    }

    /** Starts a worker unless auto-conversion is off, nothing is waiting, or one is already queued or running. */
    public static Id start() {
        LeadAutoConvertSettings settings = LeadAutoConvertSettings.get();
        if (!settings.active || Limits.getQueueableJobs() >= Limits.getLimitQueueableJobs()) {
            return null;
        }
        LeadAutoConvertSelector selector = new LeadAutoConvertSelector();
        if (selector.countPendingLeads(settings.pendingStatus) == 0 || selector.hasOpenJob(CLASS_NAME)) {
            return null;
        }
        return System.enqueueJob(new LeadAutoConvertWorker());
    }

    public void execute(QueueableContext context) {
        LeadAutoConvertSettings settings = LeadAutoConvertSettings.get();
        if (!settings.active) {
            return;
        }
        Integer size = runSize != null ? runSize : settings.leadsPerRun;
        LeadAutoConvertSelector selector = new LeadAutoConvertSelector();
        List<Id> leadIds = new List<Id>();
        for (Lead lead : selector.getPendingLeads(settings.pendingStatus, size)) {
            leadIds.add(lead.Id);
        }
        if (leadIds.isEmpty()) {
            return;
        }
        if (context != null) {
            System.attachFinalizer(new RunFailureHandler(leadIds, size));
        }

        Map<Id, LeadAutoConvertService.Outcome> outcomes = new LeadAutoConvertService().convert(leadIds, settings);

        // Chaining only after progress stops a Lead that can never leave the
        // waiting status from looping; the hourly check retries it instead.
        if (madeProgress(outcomes.values()) && selector.countPendingLeads(settings.pendingStatus) > 0) {
            chain(runSize);
        }
    }

    private Boolean madeProgress(List<LeadAutoConvertService.Outcome> outcomes) {
        for (LeadAutoConvertService.Outcome outcome : outcomes) {
            if (
                outcome.result == LeadAutoConvertService.Result.CONVERTED ||
                outcome.result == LeadAutoConvertService.Result.NEEDS_REVIEW
            ) {
                return true;
            }
        }
        return false;
    }

    private static void chain(Integer nextRunSize) {
        chainedRunSize = nextRunSize == null ? 0 : nextRunSize;
        if (chainingEnabled) {
            System.enqueueJob(new LeadAutoConvertWorker(nextRunSize));
        }
    }

    /** Runs in its own transaction after a worker run, and only acts if that run failed. */
    @TestVisible
    private class RunFailureHandler implements Finalizer {
        private final List<Id> leadIds;
        private final Integer runSize;

        @TestVisible
        RunFailureHandler(List<Id> leadIds, Integer runSize) {
            this.leadIds = leadIds;
            this.runSize = runSize;
        }

        public void execute(FinalizerContext context) {
            if (context.getResult() != ParentJobResult.UNHANDLED_EXCEPTION) {
                return;
            }
            handleFailure(context.getException() == null ? 'Unknown error' : context.getException().getMessage());
        }

        @TestVisible
        private void handleFailure(String error) {
            if (runSize > 1) {
                // Likely too much work for one run: retry the same oldest Leads in smaller groups.
                chain(Math.max(1, runSize / 2));
                return;
            }
            LeadAutoConvertSettings settings = LeadAutoConvertSettings.get();
            new LeadAutoConvertService().sendToReview(leadIds, 'Automatic conversion failed: ' + error, settings);
            if (new LeadAutoConvertSelector().countPendingLeads(settings.pendingStatus) > 0) {
                chain(null);
            }
        }
    }
}
