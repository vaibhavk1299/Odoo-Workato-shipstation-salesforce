/**
 * Sends hand-entered orders to fulfilment in the background, one per job, after they are activated.
 * Started by NFY_OrderTrigger.
 */
public without sharing class NFY_FulfilmentJob implements Queueable {
    private List<Id> orderIds;

    public NFY_FulfilmentJob(List<Id> orderIds) {
        this.orderIds = orderIds;
    }

    public void execute(QueueableContext ctx) {
        Id next = orderIds.remove(0);
        NFY_OrderFulfilmentController.sendFromStored(next);
        if (!orderIds.isEmpty() && !Test.isRunningTest()) {
            System.enqueueJob(new NFY_FulfilmentJob(orderIds));
        }
    }
}