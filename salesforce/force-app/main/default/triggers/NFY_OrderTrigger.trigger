/**
 * An order entered by hand goes to fulfilment automatically when it is activated.
 * Orders the Integration API creates already have an external order ID and are skipped,
 * as are the service's own updates while it processes an event.
 */
trigger NFY_OrderTrigger on Order (after update) {
    if (NFY_IntegrationService.processing) {
        return;
    }
    List<Id> toSend = new List<Id>();
    for (Order o : Trigger.new) {
        Order old = Trigger.oldMap.get(o.Id);
        if (o.Status == 'Activated' && old.Status != 'Activated' && o.NFY_TC_Sales_Order__c == null && o.NFY_External_Order_Id__c == null) {
            toSend.add(o.Id);
        }
    }
    if (!toSend.isEmpty() && Limits.getQueueableJobs() < Limits.getLimitQueueableJobs()) {
        System.enqueueJob(new NFY_FulfilmentJob(toSend));
    }
}