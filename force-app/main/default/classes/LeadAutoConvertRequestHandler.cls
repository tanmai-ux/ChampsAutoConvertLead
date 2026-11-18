/**
 * Handles Lead Auto Convert Requests. Any number of requests in one batch start
 * at most one worker, because the worker itself checks for a job already running.
 *
 * Runs as the user in the PlatformEventSubscriberConfig (API User), so the worker
 * and every job it chains also run as that user, whoever created the Lead.
 */
public with sharing class LeadAutoConvertRequestHandler {
    public void afterInsert(List<Lead_Auto_Convert_Request__e> requests) {
        if (requests.isEmpty()) {
            return;
        }
        LeadAutoConvertWorker.start();
    }
}
