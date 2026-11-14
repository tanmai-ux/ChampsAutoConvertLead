/**
 * Hourly safety net: restarts the auto-convert worker if Leads are waiting and
 * no worker is queued or running (for example after a failed job).
 *
 * Schedule it once from Anonymous Apex: LeadAutoConvertScheduler.scheduleHourly();
 * Setup's Schedule Apex page can't schedule hourly jobs.
 */
public with sharing class LeadAutoConvertScheduler implements Schedulable {
    public static final String JOB_NAME = 'Lead Auto-Convert hourly check';
    private static final String EVERY_HOUR = '0 0 * * * ?';

    /**
     * Sends a request instead of starting the worker, so it doesn't run as whoever
     * scheduled this job. The subscriber checks whether any Leads are waiting.
     */
    public void execute(SchedulableContext context) {
        if (LeadAutoConvertSettings.get().active) {
            LeadAutoConvertWorker.requestStart('Hourly check');
        }
    }

    public static Id scheduleHourly() {
        return scheduleHourly(JOB_NAME);
    }

    /**
     * Tests pass their own name: scheduled jobs are visible to tests, so reusing
     * JOB_NAME would fail every test run (and deploy) while the real job is scheduled.
     */
    @TestVisible
    private static Id scheduleHourly(String jobName) {
        return System.schedule(jobName, EVERY_HOUR, new LeadAutoConvertScheduler());
    }
}
