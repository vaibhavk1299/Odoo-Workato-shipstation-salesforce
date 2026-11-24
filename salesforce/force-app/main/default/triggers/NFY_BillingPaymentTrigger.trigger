/**
 * Copies the payment state of TC billings to their Order (NFY_PaymentStatusService).
 * Fires on every billing save, including the re-save caused by the Received_Amount__c roll-up
 * when cash is applied or unapplied. Leaves the TC billing logic untouched.
 */
trigger NFY_BillingPaymentTrigger on TC_Billing__c (after insert, after update, after delete, after undelete) {
    NFY_PaymentStatusService.refreshForBillings(Trigger.isDelete ? null : Trigger.new, Trigger.isInsert || Trigger.isUndelete ? null : Trigger.oldMap);
}