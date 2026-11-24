import { LightningElement, api, track } from 'lwc';
import { NavigationMixin } from 'lightning/navigation';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import { subscribe, unsubscribe, onError } from 'lightning/empApi';
import getSummary from '@salesforce/apex/NFY_CommandCenterController.getSummary';
import getStockMatrix from '@salesforce/apex/NFY_CommandCenterController.getStockMatrix';
import retryLog from '@salesforce/apex/NFY_CommandCenterController.retryLog';

const CHANNEL = '/event/NFY_Integration_Event__e';
const REFRESH_MS = 30000;
// A burst of failure events triggers one reload, not one per event.
const EVENT_RELOAD_DEBOUNCE_MS = 1500;

// Map layout: placement comes from each system's category (sales channels left, 3PL and label
// systems right, hub systems inside the hub). Only systems with at least one flow are drawn.
// Every connector is a straight horizontal line into the hub, so nothing crosses.
const NODE = { w: 230, h: 60, leftX: 16, rightX: 754, top: 52, gap: 84 };
const HUB = { x: 372, y: 52, w: 256, rowH: 76 };
const HEALTH_LABEL = { ok: 'Healthy', warning: 'Watch', error: 'Needs action', planned: 'Planned', idle: 'Idle' };
const ENTITY_WORD = {
    Order: 'orders', Inventory: 'stock', Shipment: 'shipments', Product: 'products', Inbound: 'inbound',
    'PO Receipt': 'receipts', Return: 'returns', Settlement: 'settlements'
};
const DIRECTION_WORD = { in: 'into Salesforce', out: 'out to the system', both: 'both ways', none: 'direction not set' };

const fmtInt = (n) => (n === null || n === undefined ? '0' : Number(n).toLocaleString('en-US', { maximumFractionDigits: 0 }));
const fmtMoney = (n) => '$' + Number(n || 0).toLocaleString('en-US', { maximumFractionDigits: 0 });

function ago(value) {
    if (!value) return 'never';
    const mins = Math.round((Date.now() - new Date(value).getTime()) / 60000);
    if (mins < 1) return 'just now';
    if (mins < 60) return mins + ' min ago';
    const hrs = Math.round(mins / 60);
    if (hrs < 48) return hrs + ' h ago';
    return Math.round(hrs / 24) + ' d ago';
}

export default class NfyCommandCenter extends NavigationMixin(LightningElement) {
    /** Lightning App Builder setting: "Modern" (default) or "Classic" integration map. */
    @api mapStyle = 'Modern';
    @track summary;
    reloadTimer;
    @track matrix = [];
    family = 'Footwear';
    loading = true;
    error;
    live = false;
    subscription;
    timer;
    retrying = {};

    connectedCallback() {
        this.load();
        this.loadMatrix();
        // Skip the timed refresh while the browser tab is hidden; reload as soon as it is visible again.
        this.timer = setInterval(() => {
            if (!document.hidden) this.load();
        }, REFRESH_MS);
        this.onVisible = () => {
            if (!document.hidden) this.load();
        };
        document.addEventListener('visibilitychange', this.onVisible);
        onError(() => {
            this.live = false;
        });
        subscribe(CHANNEL, -1, (msg) => this.onEvent(msg))
            .then((s) => {
                this.subscription = s;
                this.live = true;
            })
            .catch(() => {
                this.live = false;
            });
    }

    disconnectedCallback() {
        clearInterval(this.timer);
        clearTimeout(this.reloadTimer);
        if (this.onVisible) {
            document.removeEventListener('visibilitychange', this.onVisible);
        }
        if (this.subscription) {
            unsubscribe(this.subscription, () => {});
        }
    }

    onEvent(msg) {
        const p = (msg && msg.data && msg.data.payload) || {};
        // The same channel carries fulfilment instructions (Release, Cancel) for Workato; only failures are alerts.
        if (p.Severity__c && p.Severity__c !== 'Error') {
            return;
        }
        this.dispatchEvent(new ShowToastEvent({
            title: (p.System_Code__c || 'Integration') + ' sync failed',
            message: p.Message__c || 'See the sync log.',
            variant: 'error',
            mode: 'sticky'
        }));
        clearTimeout(this.reloadTimer);
        // eslint-disable-next-line @lwc/lwc/no-async-operation
        this.reloadTimer = setTimeout(() => this.load(), EVENT_RELOAD_DEBOUNCE_MS);
    }

    get useModernMap() {
        return (this.mapStyle || 'Modern') !== 'Classic';
    }

    /** "View open failures" on a map card: bring the failures panel into view. */
    handleShowFailures() {
        const panel = this.template.querySelector('.failures-card');
        if (panel) {
            panel.scrollIntoView({ behavior: 'smooth', block: 'start' });
            panel.focus({ preventScroll: true });
        }
    }

    async load() {
        try {
            this.summary = await getSummary();
            this.error = undefined;
        } catch (e) {
            this.error = (e && e.body && e.body.message) || 'Could not load the command center.';
        } finally {
            this.loading = false;
        }
    }

    async loadMatrix() {
        try {
            this.matrix = await getStockMatrix({ family: this.family });
        } catch (e) {
            this.matrix = [];
        }
    }

    handleRefresh() {
        this.loading = true;
        this.load();
        this.loadMatrix();
    }

    handleFamily(event) {
        this.family = event.target.value;
        this.loadMatrix();
    }

    get familyOptions() {
        return ['Footwear', 'Apparel', 'Accessories'].map((f) => ({ label: f, value: f }));
    }

    get asOf() {
        return this.summary ? new Date(this.summary.asOf).toLocaleTimeString('en-US', { hour: 'numeric', minute: '2-digit' }) : '';
    }

    get liveLabel() {
        return this.live ? 'Live: failures appear here as they happen' : 'Refreshing every 30 seconds';
    }

    get liveClass() {
        return this.live ? 'live-dot on' : 'live-dot';
    }

    // ------------------------------------------------------------------ KPIs

    get kpis() {
        if (!this.summary) return [];
        return this.summary.kpis.map((k) => ({
            ...k,
            display: fmtInt(k.value),
            cls: 'kpi tone-' + (k.tone || 'neutral')
        }));
    }

    // ------------------------------------------------------------------ system map

    get systemsByCode() {
        const m = {};
        (this.summary ? this.summary.systems : []).forEach((s) => {
            m[s.code] = s;
        });
        return m;
    }

    /** Systems drawn on one side of the map: those placed there by category that have flows. */
    side(placement) {
        return (this.summary ? this.summary.systems : []).filter((s) => s.placement === placement && s.stage !== 'unmapped');
    }

    get mapRows() {
        return Math.max(3, this.side('left').length, this.side('right').length);
    }

    // Arrowhead pointing left or right, tip at (x, y).
    arrow(x, y, pointsRight) {
        const d = pointsRight ? -7 : 7;
        return `${x},${y} ${x + d},${y - 4} ${x + d},${y + 4}`;
    }

    get mapNodes() {
        const hubH = this.mapRows * NODE.gap - (NODE.gap - NODE.h);
        const place = (list, side) => {
            // Centre a shorter column against the hub.
            const offset = (hubH - (list.length * NODE.gap - (NODE.gap - NODE.h))) / 2;
            return list.map((s, i) => {
                const x = side === 'left' ? NODE.leftX : NODE.rightX;
                const y = NODE.top + offset + i * NODE.gap;
                const cy = y + NODE.h / 2;
                const planned = s.stage === 'planned';
                const x1 = side === 'left' ? x + NODE.w : HUB.x + HUB.w;
                const x2 = side === 'left' ? HUB.x : x;
                // "In" means data travels from the system towards the hub; "out" the reverse.
                const towardHubRight = side === 'left';
                const showIn = s.direction === 'in' || s.direction === 'both';
                const showOut = s.direction === 'out' || s.direction === 'both';
                const hubEnd = side === 'left' ? x2 : x1;
                const sysEnd = side === 'left' ? x1 : x2;
                let metric;
                if (planned) metric = 'planned';
                else if (s.stage === 'idle') metric = 'no events in 24 h';
                else metric = s.jobs24h + ' events' + (s.failed24h > 0 ? ' · ' + s.failed24h + ' failed' : '');
                const words = (s.entities || []).map((e) => ENTITY_WORD[e] || e.toLowerCase());
                const things = words.join(', ');
                // The line between a node and the hub fits about 22 characters.
                const short = things.length <= 22 ? things : words.slice(0, 2).join(', ') + ' +' + (words.length - 2);
                const flowLines = (s.flowList || []).map((f) =>
                    (f.active ? '● ' : '○ ') + f.name + ' (' + (f.mode || 'mode not set') + (f.recipeId ? ', recipe ' + f.recipeId : '') + ')');
                let detail;
                if (planned) detail = (s.mode || '') + ' · planned';
                else if (s.stage === 'idle') detail = s.mode + ' · last event ' + ago(s.lastSync);
                else detail = s.mode + ' · last event ' + ago(s.lastSync);
                return {
                    code: s.code,
                    id: s.id,
                    name: s.name,
                    x, y, w: NODE.w, h: NODE.h,
                    accentX: x,
                    tx: x + 16,
                    ty1: y + 25,
                    ty2: y + 44,
                    sx: x + NODE.w - 14,
                    detail,
                    status: HEALTH_LABEL[s.health] || '',
                    tooltip: s.name + ': ' + (things || 'no entities') + ', ' + DIRECTION_WORD[s.direction] + '\n' + flowLines.join('\n'),
                    x1, x2, cy,
                    lx: (x1 + x2) / 2,
                    ly: cy - 7,
                    ly2: cy + 15,
                    metric,
                    flowLabel: short,
                    showIn,
                    showOut,
                    inPoints: showIn ? this.arrow(hubEnd, cy, towardHubRight) : '',
                    outPoints: showOut ? this.arrow(sysEnd, cy, !towardHubRight) : '',
                    nodeCls: 'map-node',
                    accentCls: 'map-accent h-' + s.health,
                    statusCls: 'map-status h-' + s.health,
                    edgeCls: 'map-edge' + (planned ? ' planned' : '') + (s.health === 'error' ? ' alert' : ''),
                    arrowCls: 'map-arrow' + (planned ? ' planned' : '') + (s.health === 'error' ? ' alert' : ''),
                    // Red only while a failure is still open; resolved failures stay visible in amber.
                    metricCls: 'map-metric' + (planned ? '' : (s.openErrors > 0 ? ' alert' : (s.failed24h > 0 ? ' warn' : '')))
                };
            });
        };
        return [...place(this.side('left'), 'left'), ...place(this.side('right'), 'right')];
    }

    get mapAriaLabel() {
        const names = (p) => this.side(p).map((s) => s.name + ' (' + (HEALTH_LABEL[s.health] || s.health) + ')').join(', ');
        return 'Integration map. Sales channels: ' + names('left') + '. Fulfilment: ' + names('right') + '. All connect through Workato to the Salesforce Integration API.';
    }

    get mapHeight() {
        return NODE.top + this.mapRows * NODE.gap - (NODE.gap - NODE.h) + 34;
    }

    get mapViewBox() {
        return '0 0 1000 ' + this.mapHeight;
    }

    get hub() {
        const systems = this.summary ? this.summary.systems : [];
        const by = this.systemsByCode;
        const total = systems.reduce((a, s) => a + s.jobs24h, 0);
        const recipes = systems.reduce((a, s) => a + (s.recipes || 0), 0);
        const plannedFlows = systems.reduce((a, s) => a + ((s.totalFlows || 0) - (s.flows || 0)), 0);
        // What Salesforce actually receives today: entities of the live flows.
        const live = new Set();
        systems.filter((s) => s.flows > 0).forEach((s) => (s.flowList || []).filter((f) => f.active).forEach((f) => live.add(ENTITY_WORD[f.entity] || f.entity)));
        const wk = by.WORKATO;
        const sf = by.SALESFORCE;
        const rows = [
            { key: 'wk', id: wk && wk.id, title: 'Workato', sub: recipes + ' live recipes · ' + plannedFlows + ' planned flows' },
            { key: 'api', id: null, title: 'Integration API', sub: total + ' events in the last 24 h' },
            { key: 'sf', id: sf && sf.id, title: 'Salesforce + TC Accounting', sub: live.size ? [...live].join(' · ') : 'nothing live yet' }
        ];
        const nodesH = this.mapRows * NODE.gap - (NODE.gap - NODE.h);
        const rowH = Math.max(HUB.rowH, nodesH / rows.length);
        return {
            x: HUB.x,
            y: HUB.y,
            w: HUB.w,
            h: rowH * rows.length,
            cx: HUB.x + HUB.w / 2,
            x2: HUB.x + HUB.w,
            rows: rows.map((r, i) => ({
                ...r,
                ty1: HUB.y + i * rowH + rowH / 2 - 6,
                ty2: HUB.y + i * rowH + rowH / 2 + 14,
                divider: i > 0,
                dy: HUB.y + i * rowH
            }))
        };
    }

    get mapHeaders() {
        return { y: 30, left: NODE.leftX, mid: HUB.x + HUB.w / 2, right: NODE.rightX + NODE.w };
    }

    get mapFootY() {
        return this.mapHeight - 8;
    }

    get healthRows() {
        if (!this.summary) return [];
        return this.summary.systems.map((s) => ({
            ...s,
            modeLabel: s.mode || '–',
            flowsLabel: s.flows + ' of ' + s.totalFlows,
            directionLabel: s.stage === 'unmapped' ? '–' : { in: 'In', out: 'Out', both: 'In + out', none: '–' }[s.direction],
            last: ago(s.lastSync),
            rate: s.health === 'planned' ? '–' : s.failureRate7d + '%',
            pillCls: 'pill h-' + s.health,
            pillLabel: s.stage === 'unmapped' ? 'No flows' : HEALTH_LABEL[s.health] || s.health
        }));
    }

    // ------------------------------------------------------------------ orders and stock

    get channelRows() {
        if (!this.summary) return [];
        return this.summary.channels
            .slice()
            .sort((a, b) => b.last30 - a.last30)
            .map((c) => ({ ...c, revenue: fmtMoney(c.revenue30) }));
    }

    get stockRows() {
        if (!this.summary) return [];
        const rows = this.summary.stock.filter((s) => s.physical && (s.available > 0 || s.inTransit > 0 || s.type === '3PL'));
        const max = Math.max(1, ...rows.map((r) => r.available + r.inTransit));
        return rows.map((r) => ({
            ...r,
            availableLabel: fmtInt(r.available),
            transitLabel: r.inTransit ? '+' + fmtInt(r.inTransit) + ' in transit' : '',
            rankLabel: r.rank ? '#' + r.rank : '',
            barStyle: 'width:' + Math.round((100 * r.available) / max) + '%',
            transitStyle: 'width:' + Math.round((100 * r.inTransit) / max) + '%'
        }));
    }

    get fieldStock() {
        if (!this.summary) return 0;
        const f = this.summary.stock.find((s) => s.code === 'FIELD');
        return f ? fmtInt(f.available) : 0;
    }

    /** One column per warehouse that holds stock for this family, plus its in-transit column when used. */
    get matrixColumns() {
        const present = new Set();
        this.matrix.forEach((r) => Object.keys(r).forEach((k) => {
            if (Number(r[k]) !== 0) present.add(k);
        }));
        const cols = [];
        (this.summary ? this.summary.stock : []).forEach((w) => {
            if (present.has(w.code)) cols.push({ code: w.code, label: w.name, muted: !w.physical });
            if (present.has(w.code + '-TRANSIT')) cols.push({ code: w.code + '-TRANSIT', label: w.name + ' in transit', transit: true });
        });
        return cols;
    }

    get matrixRows() {
        const cols = this.matrixColumns;
        return this.matrix.map((r) => ({
            key: r.productId,
            name: r.name,
            sku: r.sku,
            cells: cols.map((c) => {
                const v = Number(r[c.code] || 0);
                return { key: c.code, value: fmtInt(v), cls: 'num' + (v === 0 ? ' zero' : '') + (c.transit ? ' transit' : '') + (c.muted ? ' muted' : '') };
            })
        }));
    }

    // ------------------------------------------------------------------ failures, inbound, close

    get failures() {
        if (!this.summary) return [];
        return this.summary.failures.map((f) => ({
            ...f,
            when: ago(f.receivedAt),
            busy: !!this.retrying[f.id]
        }));
    }

    get hasFailures() {
        return this.failures.length > 0;
    }

    get inbound() {
        if (!this.summary) return [];
        return this.summary.inbound.map((i) => ({
            ...i,
            unitsLabel: fmtInt(i.units),
            when: i.eta ? 'ETA ' + new Date(i.eta + 'T12:00:00').toLocaleDateString('en-US', { month: 'short', day: 'numeric' }) : (i.shippedDate ? 'Shipped ' + new Date(i.shippedDate + 'T12:00:00').toLocaleDateString('en-US', { month: 'short', day: 'numeric' }) : i.status),
            pillCls: 'pill ' + (i.status === 'Working' ? 'h-planned' : 'h-ok')
        }));
    }

    get closeItems() {
        if (!this.summary) return [];
        const c = this.summary.close;
        return [
            { key: 'u', label: 'Billings not posted', value: c.unpostedBillings },
            { key: 'a', label: 'Marketplace billings awaiting payout', value: c.awaitingSettlement },
            { key: 's', label: 'Settlements with unmatched amounts', value: c.settlementExceptions },
            { key: 'r', label: 'Stock mismatches open', value: c.openRecons },
            { key: 'e', label: 'Sync errors open', value: c.openErrors }
        ].map((i) => ({ ...i, cls: 'close-row' + (i.value > 0 ? ' attention' : '') }));
    }

    async handleRetry(event) {
        const id = event.currentTarget.dataset.id;
        this.retrying = { ...this.retrying, [id]: true };
        try {
            const r = await retryLog({ logId: id });
            this.dispatchEvent(new ShowToastEvent({
                title: r.success ? 'Retry succeeded' : 'Retry failed again',
                message: r.message,
                variant: r.success ? 'success' : 'error'
            }));
        } catch (e) {
            this.dispatchEvent(new ShowToastEvent({ title: 'Retry failed', message: (e && e.body && e.body.message) || '', variant: 'error' }));
        }
        this.retrying = { ...this.retrying, [id]: false };
        this.load();
    }

    navigate(event) {
        const id = event.currentTarget.dataset.id;
        if (!id) return;
        this[NavigationMixin.Navigate]({ type: 'standard__recordPage', attributes: { recordId: id, actionName: 'view' } });
    }

    openList(event) {
        const obj = event.currentTarget.dataset.object;
        this[NavigationMixin.Navigate]({ type: 'standard__objectPage', attributes: { objectApiName: obj, actionName: 'list' }, state: { filterName: 'Recent' } });
    }
}