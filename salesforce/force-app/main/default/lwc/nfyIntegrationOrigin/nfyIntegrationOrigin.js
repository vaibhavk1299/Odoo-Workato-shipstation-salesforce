import { LightningElement, api, track } from 'lwc';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import { notifyRecordUpdateAvailable } from 'lightning/uiRecordApi';
import getOrigin from '@salesforce/apex/NFY_IntegrationOriginController.getOrigin';
import getLog from '@salesforce/apex/NFY_IntegrationOriginController.getLog';
import retryLog from '@salesforce/apex/NFY_IntegrationOriginController.retryLog';

const LOG_COLUMNS = [
    { label: 'Log', fieldName: 'url', type: 'url', typeAttributes: { label: { fieldName: 'name' }, target: '_self' }, initialWidth: 110 },
    { label: 'System', fieldName: 'systemName' },
    { label: 'Event', fieldName: 'eventType' },
    { label: 'Status', fieldName: 'status', cellAttributes: { class: { fieldName: 'statusClass' } } },
    { label: 'Operation', fieldName: 'operation' },
    { label: 'Transport', fieldName: 'transport' },
    { label: 'Received', fieldName: 'receivedAt', type: 'date', typeAttributes: { month: 'short', day: 'numeric', hour: '2-digit', minute: '2-digit' } },
    { label: 'Attempts', fieldName: 'attempts', type: 'number', initialWidth: 90 },
    { label: 'Error', fieldName: 'error', wrapText: true }
];

export default class NfyIntegrationOrigin extends LightningElement {
    @api recordId;
    @api variant = 'card';
    @track origin;
    @track log;
    error;
    loading = true;
    retrying = false;
    columns = LOG_COLUMNS;

    connectedCallback() {
        this.load();
    }

    get isCard() {
        return this.variant !== 'log' && this.variant !== 'event';
    }
    get isLog() {
        return this.variant === 'log';
    }
    get isEvent() {
        return this.variant === 'event';
    }

    async load() {
        this.loading = true;
        this.error = undefined;
        try {
            if (this.isEvent) {
                this.log = await getLog({ logId: this.recordId });
            } else {
                this.origin = await getOrigin({ recordId: this.recordId });
            }
        } catch (e) {
            this.error = this.message(e);
        }
        this.loading = false;
    }

    message(e) {
        return (e && e.body && e.body.message) || (e && e.message) || 'Something went wrong.';
    }

    get integrated() {
        return this.origin && this.origin.integrated;
    }
    get lastStatusClass() {
        return this.badgeClass(this.origin && this.origin.lastStatus);
    }
    badgeClass(status) {
        if (status === 'Success') return 'slds-badge slds-theme_success';
        if (status === 'Failed') return 'slds-badge slds-theme_error';
        return 'slds-badge';
    }
    get lastLogUrl() {
        return this.origin && this.origin.lastLogId ? '/' + this.origin.lastLogId : null;
    }
    get hasSystemIds() {
        return this.origin && this.origin.systemIds && this.origin.systemIds.length > 0;
    }
    get logRows() {
        const rows = (this.origin && this.origin.logs) || [];
        return rows.map((r) => ({
            ...r,
            statusClass: r.status === 'Failed' ? 'slds-text-color_error' : r.status === 'Success' ? 'slds-text-color_success' : ''
        }));
    }
    get logCount() {
        return this.logRows.length;
    }
    get logTitle() {
        return 'Integration Log (' + this.logCount + ')';
    }
    get hasLogs() {
        return this.logCount > 0;
    }

    get sourceButtonLabel() {
        return 'Open in ' + ((this.origin && this.origin.sourceSystem) || 'source');
    }
    openSource() {
        window.open(this.origin.sourceUrl, '_blank');
    }
    openJob() {
        window.open(this.origin.workatoJobUrl, '_blank');
    }
    openEventJob() {
        window.open(this.log.jobUrl, '_blank');
    }

    get eventStatusClass() {
        return this.badgeClass(this.log && this.log.status);
    }
    get canRetry() {
        return this.log && this.log.status !== 'Success' && this.log.status !== 'Duplicate skipped' && !this.retrying;
    }
    get retryDisabled() {
        return !this.canRetry;
    }
    get resolvedText() {
        return this.log && this.log.resolved ? 'Yes' : 'No';
    }

    async handleRetry() {
        this.retrying = true;
        try {
            const r = await retryLog({ logId: this.recordId });
            this.dispatchEvent(new ShowToastEvent({
                title: r.success ? 'Retry succeeded' : 'Retry failed',
                message: (r.logName ? r.logName + ': ' : '') + (r.message || r.status),
                variant: r.success ? 'success' : 'error'
            }));
            await notifyRecordUpdateAvailable([{ recordId: this.recordId }]);
            await this.load();
        } catch (e) {
            this.dispatchEvent(new ShowToastEvent({ title: 'Retry not possible', message: this.message(e), variant: 'error' }));
        }
        this.retrying = false;
    }
}