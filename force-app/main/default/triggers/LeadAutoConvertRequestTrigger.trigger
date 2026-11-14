/**
 * Subscribes to Lead Auto Convert Requests. No logic here: the handler starts the worker.
 * Runs as the user named in the LeadAutoConvertRequestConfig subscriber config
 * (per org), or as the Automated Process user if there is none.
 */
trigger LeadAutoConvertRequestTrigger on Lead_Auto_Convert_Request__e(after insert) {
    if (Trigger.isAfter && Trigger.isInsert) {
        new LeadAutoConvertRequestHandler().afterInsert(Trigger.new);
    }
}
