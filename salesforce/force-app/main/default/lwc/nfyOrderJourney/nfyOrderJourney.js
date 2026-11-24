import { LightningElement, api } from 'lwc';
import { NavigationMixin } from 'lightning/navigation';
import { subscribe, unsubscribe, onError, isEmpEnabled } from 'lightning/empApi';
import getJourney from '@salesforce/apex/NFY_OrderJourneyController.getJourney';

/** Change Data Capture channel of the Integration Sync Log, written for every integration event. */
const CHANGE_CHANNEL = '/data/NFY_Sync_Log__ChangeEvent';
const POLL_MS = 30000;

const STATUS_CLASS = {
    Completed: 'ok',
    'Partially Completed': 'part',
    Processing: 'proc',
    Pending: 'wait',
    Failed: 'bad',
    'Not needed': 'skip',
    'Not available': 'skip',
    'Failed · resolved': 'skip'
};

const SYSTEMS = [
    ['TC Accounting', 'TC Accounting', 'acct'],
    ['ShipStation', 'ShipStation', 'ss'],
    ['Salesforce', 'Salesforce', 'sf'],
    ['Workato', 'Workato', 'wk'],
    ['Odoo', 'Odoo', 'odoo'],
    ['Shopify', 'Shopify', 'shop']
];

/** Colour of a system label. */
const toneOf = (name) => {
    const n = String(name || '');
    for (const [match, , tone] of SYSTEMS) {
        if (n.indexOf(match) === 0) return tone;
    }
    return 'other';
};

/** Display name of a system: drops a qualifier such as "(Commerce)". */
const labelOf = (name) => String(name || '').split(' (')[0];

/** The system an event happened in, from the start of its system name. */
const systemOf = (s) => {
    const name = String(s.systemName || '');
    for (const [match, label, tone] of SYSTEMS) {
        if (name.indexOf(match) === 0) return { label, tone };
    }
    const first = name.split(' →')[0].split(' (')[0];
    return { label: first || 'System', tone: 'other' };
};

const when = (at) =>
    at ? new Date(at).toLocaleString('en-US', { month: 'short', day: 'numeric', hour: 'numeric', minute: '2-digit' }) : '';

export default class NfyOrderJourney extends NavigationMixin(LightningElement) {
    @api recordId;
    journey;
    error;
    showMessages = false;

    /** 'live' when change events stream in, 'polling' when the fallback timer refreshes the card. */
    liveMode;
    lastLoaded;

    connectedCallback() {
        this.load();
        // The Fulfilment card on the same page signals when it changes the order.
        this.onChanged = () => this.load();
        window.addEventListener('nfyorderchanged', this.onChanged);
        this.startLive();
    }

    disconnectedCallback() {
        window.removeEventListener('nfyorderchanged', this.onChanged);
        this.stopLive();
    }

    async load() {
        try {
            this.journey = await getJourney({ recordId: this.recordId });
            this.error = undefined;
            this.lastLoaded = new Date();
        } catch (e) {
            this.error = (e && e.body && e.body.message) || 'Could not load the order journey.';
        }
    }

    /**
     * Real-time updates: every integration event (Odoo, Workato, ShipStation) writes an Integration Sync Log,
     * and Change Data Capture streams each change. The card reloads shortly after one arrives, so the history
     * always reflects what Salesforce has just recorded. Without streaming it refreshes every 30 seconds
     * while the page is visible.
     */
    async startLive() {
        try {
            const enabled = await isEmpEnabled();
            if (!enabled) throw new Error('Streaming is not available');
            onError(() => this.startPolling());
            this.subscription = await subscribe(CHANGE_CHANNEL, -1, () => this.scheduleReload());
            this.liveMode = 'live';
        } catch (e) {
            this.startPolling();
        }
    }

    startPolling() {
        if (this.pollTimer) return;
        this.liveMode = 'polling';
        // eslint-disable-next-line @lwc/lwc/no-async-operation
        this.pollTimer = setInterval(() => {
            if (!document.hidden) this.load();
        }, POLL_MS);
    }

    stopLive() {
        if (this.subscription) {
            unsubscribe(this.subscription, () => {});
            this.subscription = null;
        }
        if (this.pollTimer) {
            clearInterval(this.pollTimer);
            this.pollTimer = null;
        }
        if (this.reloadTimer) {
            clearTimeout(this.reloadTimer);
        }
    }

    /** Several logs can change in one burst (order, allocation, ShipStation); reload once after it settles. */
    scheduleReload() {
        if (this.reloadTimer) clearTimeout(this.reloadTimer);
        // eslint-disable-next-line @lwc/lwc/no-async-operation
        this.reloadTimer = setTimeout(() => this.load(), 1500);
    }

    get liveLabel() {
        if (!this.liveMode) return '';
        const at = this.lastLoaded ? ' · updated ' + this.lastLoaded.toLocaleTimeString('en-US', { hour: 'numeric', minute: '2-digit', second: '2-digit' }) : '';
        return (this.liveMode === 'live' ? 'Live' : 'Auto-refresh every 30 s') + at;
    }

    get liveCls() {
        return 'jx-h-live' + (this.liveMode === 'live' ? ' jx-h-live-on' : '');
    }

    get hasJourney() {
        return this.journey && this.journey.orderNumber;
    }

    get originLabel() {
        return this.journey.originSystem || this.journey.channel;
    }

    get currentStage() {
        return this.journey ? this.journey.stages[this.journey.stageIndex] : null;
    }

    get stages() {
        return this.journey ? this.journey.stages.map((s) => ({ label: s, value: s })) : [];
    }

    /** The eight lifecycle stages, always in business order; each stage carries its own real timestamp. */
    get lifecycle() {
        if (!this.journey || !this.journey.lifecycle) return [];
        return this.journey.lifecycle.map((s) => {
            const tone = STATUS_CLASS[s.status] || 'wait';
            return {
                ...s,
                cls: 'jx-stage jx-st-' + tone,
                badgeCls: 'jx-badge jx-b-' + tone,
                when: when(s.at),
                hasItems: s.items && s.items.length > 0,
                items: (s.items || []).map((it, i) => ({
                    ...it,
                    key: s.key + '-' + i,
                    when: when(it.at),
                    cls: 'jx-item jx-i-' + (it.status || 'ok')
                }))
            };
        });
    }

    get hasMessages() {
        return this.journey && this.journey.steps && this.journey.steps.length > 0;
    }

    get historyCount() {
        return this.journey.steps.length;
    }

    get messagesLabel() {
        return this.showMessages ? 'Hide history' : 'Show history';
    }

    get showMessagesAria() {
        return this.showMessages ? 'true' : 'false';
    }

    toggleMessages() {
        this.showMessages = !this.showMessages;
    }

    /**
     * Order history grouped by day, in the order the server returned it (lifecycle step, then real time).
     * Each event gets a system label, its own time column, an optional note and its record references.
     */
    get historyDays() {
        if (!this.journey) return [];
        const days = [];
        this.journey.steps.forEach((s, i) => {
            const d = s.at ? new Date(s.at) : null;
            const dayLabel = d
                ? d.toLocaleDateString('en-US', { weekday: 'short', month: 'short', day: 'numeric', year: 'numeric' })
                : 'Date not recorded';
            let day = days.length ? days[days.length - 1] : null;
            if (!day || day.label !== dayLabel) {
                day = { key: 'd' + i, label: dayLabel, events: [] };
                days.push(day);
            }
            const sys = systemOf(s);
            const failed = String(s.statusLabel || s.status || '').indexOf('Failed') === 0;
            const route = (s.route && s.route.length ? s.route : [sys.label]).map((name, r) => ({
                key: 'r' + r,
                label: labelOf(name),
                arrow: r > 0,
                cls: 'jx-h-chip jx-h-' + toneOf(name)
            }));
            const refs = (s.refs || []).map((f, r) => ({
                key: 'f' + r,
                label: f.label,
                recordId: f.recordId,
                title: f.kind === 'log' ? 'Open the integration log' : 'Open the record',
                cls: 'jx-h-ref' + (f.kind === 'log' ? ' jx-h-ref-log' : '')
            }));
            const label = s.statusLabel || (s.status === 'Success' ? 'Completed' : s.status);
            day.events.push({
                key: (s.recordId || s.kind) + '-' + i,
                time: d ? d.toLocaleTimeString('en-US', { hour: 'numeric', minute: '2-digit' }) : '',
                seconds: d ? ':' + String(d.getSeconds()).padStart(2, '0') : '',
                route,
                title: s.title,
                detail: s.detail,
                note: s.note,
                statusLabel: label,
                statusCls: 'jx-h-status jx-h-s-' + (STATUS_CLASS[label] || (failed ? 'bad' : 'wait')),
                refs,
                job: s.job,
                hasRefs: refs.length > 0 || !!s.job,
                cls: 'jx-h-item jx-h-t-' + toneOf(s.route && s.route.length ? s.route[0] : sys.label) + (failed ? ' jx-h-bad' : '')
            });
        });
        return days;
    }

    get lines() {
        if (!this.journey) return [];
        return this.journey.lines.map((l, i) => ({
            ...l,
            key: 'l' + i,
            ordered: l.ordered || 0,
            allocated: l.inventory ? l.allocated || 0 : '–',
            shortQty: l.inventory ? l.short || 0 : '–',
            shortCls: 'num' + (l.inventory && l.short > 0 ? ' short' : ''),
            shipped: l.inventory ? l.shipped || 0 : '–',
            shipFrom: l.shipFrom || '–',
            status: l.stockStatus || ''
        }));
    }

    navigate(event) {
        const id = event.currentTarget.dataset.id;
        if (id) {
            this[NavigationMixin.Navigate]({ type: 'standard__recordPage', attributes: { recordId: id, actionName: 'view' } });
        }
    }
}