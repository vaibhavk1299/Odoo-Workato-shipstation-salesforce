import { LightningElement, api } from 'lwc';
import { NavigationMixin } from 'lightning/navigation';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import { notifyRecordUpdateAvailable } from 'lightning/uiRecordApi';
import getContext from '@salesforce/apex/NFY_OrderFulfilmentController.getContext';
import saveShipFrom from '@salesforce/apex/NFY_OrderFulfilmentController.saveShipFrom';
import activate from '@salesforce/apex/NFY_OrderFulfilmentController.activate';
import send from '@salesforce/apex/NFY_OrderFulfilmentController.send';
import recordShipment from '@salesforce/apex/NFY_OrderFulfilmentController.recordShipment';

// The Order Journey card on the same page listens for this and reloads.
const CHANGED = 'nfyorderchanged';
const POLL_MS = 3000;
const POLL_LIMIT = 30;

const fmt = (n) => Number(n || 0).toLocaleString('en-US', { maximumFractionDigits: 0 });

// Stock status → pill colour.
function pill(status) {
    const tone = {
        'Fully assigned': 'ok',
        'Partially assigned': 'warn',
        'No stock': 'bad',
        'Factory drop-ship': 'info',
        'Billed only': 'muted',
        'Billed, not shipped': 'muted',
        'Nothing to reserve': 'muted'
    }[status] || 'muted';
    return 'pill p-' + tone;
}

export default class NfySendToFulfilment extends NavigationMixin(LightningElement) {
    @api recordId;
    ctx;
    error;
    busy = false;
    lastMessage;
    polls = 0;
    timer;

    connectedCallback() {
        this.load();
    }

    disconnectedCallback() {
        clearTimeout(this.timer);
    }

    async load() {
        try {
            const wasSent = this.ctx && this.ctx.sent;
            this.ctx = await getContext({ orderId: this.recordId });
            this.error = undefined;
            if (this.ctx.sent && !wasSent && this.polls > 0) {
                this.changed();
            }
            this.schedulePoll();
        } catch (e) {
            this.error = (e && e.body && e.body.message) || 'Could not load the order.';
        }
    }

    // While an activated order is being sent in the background, check again every few seconds.
    schedulePoll() {
        clearTimeout(this.timer);
        if (this.isSending && this.polls < POLL_LIMIT) {
            this.polls += 1;
            // eslint-disable-next-line @lwc/lwc/no-async-operation
            this.timer = setTimeout(() => this.load(), POLL_MS);
        }
    }

    // ------------------------------------------------------------------ states

    get ready() {
        return !!this.ctx;
    }

    get isDraft() {
        return this.ctx && !this.ctx.sent && this.ctx.status !== 'Activated';
    }

    get isFailed() {
        return this.ctx && !this.ctx.sent && this.ctx.status === 'Activated' && this.ctx.lastLogStatus === 'Failed';
    }

    get isSending() {
        return this.ctx && !this.ctx.sent && this.ctx.status === 'Activated' && this.ctx.lastLogStatus !== 'Failed';
    }

    get isSent() {
        return this.ctx && this.ctx.sent;
    }

    get sendingTooLong() {
        return this.isSending && this.polls >= POLL_LIMIT;
    }

    get hasLines() {
        return this.ctx && this.ctx.lines.length > 0;
    }

    get hasUnstocked() {
        return this.ctx && this.ctx.lines.some((l) => !l.stocked && !l.isFreight);
    }

    get lines() {
        if (!this.ctx) return [];
        return this.ctx.lines.map((l) => {
            const counted = l.stocked && !l.isFreight && l.willAssign !== undefined && l.willAssign !== null;
            return {
                ...l,
                pickable: l.stocked && !l.isFreight,
                fixedNote: l.isFreight ? 'Billed, not shipped' : 'Not stocked by Nfinity · billed only',
                qty: fmt(l.quantity),
                availableLabel: counted ? fmt(l.available) : '–',
                assignLabel: counted ? fmt(l.willAssign) : '–',
                shortLabel: counted ? fmt(l.shortQty) : '–',
                shortCls: 'num' + (counted && l.shortQty > 0 ? ' short' : ''),
                pillCls: pill(l.stockStatus)
            };
        });
    }

    get soLines() {
        if (!this.ctx) return [];
        return this.ctx.soLines.map((l) => ({
            ...l,
            requestedLabel: fmt(l.requested),
            assignedLabel: fmt(l.assigned),
            shortLabel: fmt(l.shortQty),
            shippedLabel: fmt(l.shipped),
            shortCls: 'num' + (l.shortQty > 0 ? ' short' : ''),
            pillCls: pill(l.stockStatus)
        }));
    }

    get summary() {
        if (!this.ctx || !this.ctx.stockStatus) return '';
        if (this.ctx.stockStatus === 'Nothing to reserve') return 'Nothing on this order is reserved from stock.';
        return fmt(this.ctx.unitsAssigned) + ' of ' + fmt(this.ctx.unitsRequested) + ' units assigned' +
            (this.ctx.unitsShort > 0 ? ' · ' + fmt(this.ctx.unitsShort) + ' short (backordered)' : '');
    }

    get summaryCls() {
        return pill(this.ctx && this.ctx.stockStatus);
    }

    get pending() {
        if (!this.ctx) return [];
        return this.ctx.pending.map((p) => ({
            ...p,
            label: 'Record shipment from ' + p.name + ' (' + Number(p.units).toLocaleString('en-US') + ' units)'
        }));
    }

    get hasPending() {
        return this.pending.length > 0;
    }

    get statusLine() {
        return this.ctx ? 'TC Sales Order ' + this.ctx.salesOrderName + ' · ' + (this.ctx.fulfilmentStatus || '') + ' · ' + this.ctx.externalOrderId : '';
    }

    // ------------------------------------------------------------------ actions

    async handleDefault(event) {
        await this.save(event.detail.value, {});
    }

    async handleLine(event) {
        await this.save(null, { [event.target.dataset.id]: event.detail.value });
    }

    async save(defaultShipFrom, lineShipFroms) {
        try {
            await saveShipFrom({ orderId: this.recordId, defaultShipFrom, lineShipFroms });
            this.ctx = await getContext({ orderId: this.recordId });
        } catch (e) {
            this.toast('Could not save the ship-from', (e && e.body && e.body.message) || '', 'error');
        }
    }

    async handleActivate() {
        this.busy = true;
        try {
            await activate({ orderId: this.recordId, defaultShipFrom: null, lineShipFroms: {} });
            this.toast('Order activated', 'Sending it to fulfilment now.', 'success');
            this.polls = 0;
            notifyRecordUpdateAvailable([{ recordId: this.recordId }]);
            await this.load();
        } catch (e) {
            this.toast('Could not activate the order', (e && e.body && e.body.message) || '', 'error');
        } finally {
            this.busy = false;
        }
    }

    async handleRetry() {
        this.busy = true;
        try {
            const r = await send({ orderId: this.recordId, defaultShipFrom: null, lineShipFroms: {} });
            await this.afterResult('Sent to fulfilment', r);
        } catch (e) {
            this.toast('Could not send', (e && e.body && e.body.message) || '', 'error');
        } finally {
            this.busy = false;
        }
    }

    async handleShip(event) {
        this.busy = true;
        try {
            const r = await recordShipment({ orderId: this.recordId, shipFromCode: event.currentTarget.dataset.code });
            await this.afterResult('Shipment recorded', r);
        } catch (e) {
            this.toast('Could not record the shipment', (e && e.body && e.body.message) || '', 'error');
        } finally {
            this.busy = false;
        }
    }

    async afterResult(title, r) {
        this.lastMessage = r.message;
        this.toast(r.success ? title : title + ': failed', r.message, r.success ? 'success' : 'error');
        await this.load();
        this.changed();
    }

    changed() {
        notifyRecordUpdateAvailable([{ recordId: this.recordId }]);
        window.dispatchEvent(new CustomEvent(CHANGED, { detail: { recordId: this.recordId } }));
    }

    toast(title, message, variant) {
        this.dispatchEvent(new ShowToastEvent({ title, message, variant }));
    }

    openSalesOrder() {
        this[NavigationMixin.Navigate]({ type: 'standard__recordPage', attributes: { recordId: this.ctx.salesOrderId, actionName: 'view' } });
    }

    openLog() {
        this[NavigationMixin.Navigate]({ type: 'standard__recordPage', attributes: { recordId: this.ctx.lastLogId, actionName: 'view' } });
    }
}