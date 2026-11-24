import { LightningElement, api } from 'lwc';
import { NavigationMixin } from 'lightning/navigation';
import { STATUS_ORDER, statusOf, statusLabel, rowsFor, hubModel } from 'c/nfyStatus';

/** Below this width the map becomes one column: sales channels, hub, fulfilment. */
const COMPACT_BELOW_PX = 980;

/**
 * Command Center integration map: sales channels on the left, the integration hub in the middle,
 * fulfilment on the right. Placement, mode, direction, status and counts all come from
 * NFY_CommandCenterController.getSummary, passed in by c-nfy-command-center.
 */
export default class NfyIntegrationMap extends NavigationMixin(LightningElement) {
    /** System rows from getSummary().systems. */
    @api systems = [];
    /** Time of the last refresh, already formatted (for example "3:40 PM"). */
    @api asOf;
    /** True while the live event channel is connected. */
    @api live = false;

    filter = 'all';
    compact = false;
    resizeObserver;

    renderedCallback() {
        if (this.resizeObserver || typeof ResizeObserver === 'undefined') return;
        const root = this.template.querySelector('section');
        if (!root) return;
        this.resizeObserver = new ResizeObserver((entries) => {
            const width = entries && entries[0] ? entries[0].contentRect.width : root.clientWidth;
            const next = width > 0 && width < COMPACT_BELOW_PX;
            if (next !== this.compact) this.compact = next;
        });
        this.resizeObserver.observe(root);
    }

    disconnectedCallback() {
        if (this.resizeObserver) {
            this.resizeObserver.disconnect();
            this.resizeObserver = null;
        }
    }

    get wide() {
        return !this.compact;
    }

    get rootClass() {
        return 'map-card' + (this.compact ? ' compact' : '');
    }

    /** Systems drawn on one side: those placed there by category that have flows (same rule as the classic map). */
    side(placement) {
        return (this.systems || []).filter((s) => s.placement === placement && s.stage !== 'unmapped');
    }

    get shown() {
        return [...this.side('left'), ...this.side('right')];
    }

    get hasSystems() {
        return this.shown.length > 0;
    }

    get rowCount() {
        return Math.max(3, this.side('left').length, this.side('right').length);
    }

    items(placement, cardCol, connCol) {
        const list = this.side(placement);
        const rows = rowsFor(list.length, this.rowCount);
        return list.map((s, i) => {
            // Row 1 holds the zone headers, so systems start on row 2.
            const row = rows[i] + 1;
            const dimmed = this.filter !== 'all' && statusOf(s) !== this.filter;
            return {
                key: 'card-' + s.code,
                connKey: 'conn-' + s.code,
                system: s,
                dimmed,
                // Cards in the lower half open their flow list upwards so it stays on screen.
                popUp: rows[i] > this.rowCount / 2,
                cardStyle: this.compact ? '' : 'grid-column:' + cardCol + ';grid-row:' + row,
                connStyle: 'grid-column:' + connCol + ';grid-row:' + row
            };
        });
    }

    get leftItems() {
        return this.items('left', 1, 2);
    }

    get rightItems() {
        return this.items('right', 5, 4);
    }

    get mapStyle() {
        if (this.compact) return 'grid-template-columns:minmax(0,1fr)';
        return 'grid-template-columns:minmax(220px,300px) minmax(96px,1fr) minmax(250px,340px) minmax(96px,1fr) minmax(220px,300px);' +
            'grid-template-rows:auto repeat(' + this.rowCount + ',minmax(118px,auto))';
    }

    zoneSpan() {
        return 'grid-row:1 / ' + (this.rowCount + 2);
    }

    get leftZoneStyle() {
        return 'grid-column:1;' + this.zoneSpan();
    }

    get rightZoneStyle() {
        return 'grid-column:5;' + this.zoneSpan();
    }

    get leftHeadStyle() {
        return this.compact ? '' : 'grid-column:1;grid-row:1';
    }

    get rightHeadStyle() {
        return this.compact ? '' : 'grid-column:5;grid-row:1';
    }

    get hubHeadStyle() {
        return this.compact ? '' : 'grid-column:3;grid-row:1';
    }

    get hubStyle() {
        return this.compact ? '' : 'grid-column:3;grid-row:2 / ' + (this.rowCount + 2);
    }

    countLabel(n) {
        return n === 1 ? '1 system' : n + ' systems';
    }

    get leftCountLabel() {
        return this.countLabel(this.side('left').length);
    }

    get rightCountLabel() {
        return this.countLabel(this.side('right').length);
    }

    get hub() {
        return hubModel(this.systems);
    }

    get hasHubEntities() {
        return this.hub.entities.length > 0;
    }

    get filters() {
        const counts = {};
        this.shown.forEach((s) => {
            const k = statusOf(s);
            counts[k] = (counts[k] || 0) + 1;
        });
        const all = { key: 'all', label: 'All ' + this.shown.length, pressed: this.filter === 'all' ? 'true' : 'false', dotClass: null };
        return [all, ...STATUS_ORDER.map((k) => ({
            key: k,
            label: statusLabel(k) + ' ' + (counts[k] || 0),
            pressed: this.filter === k ? 'true' : 'false',
            dotClass: 'fdot s-' + k
        }))];
    }

    get liveText() {
        return (this.live ? 'Live' : 'Refreshing every 30 seconds') + (this.asOf ? ' · updated ' + this.asOf : '');
    }

    get liveDotClass() {
        return 'live-dot' + (this.live ? ' on' : '');
    }

    handleFilter(event) {
        const key = event.currentTarget.dataset.key;
        // Selecting the active filter again clears it.
        this.filter = key === this.filter ? 'all' : key;
    }

    handleRefresh() {
        this.dispatchEvent(new CustomEvent('refresh'));
    }

    handleShowFailures(event) {
        this.dispatchEvent(new CustomEvent('showfailures', { detail: event.detail }));
    }

    handleNavigate(event) {
        const id = event.currentTarget.dataset.id;
        if (!id) return;
        this[NavigationMixin.Navigate]({ type: 'standard__recordPage', attributes: { recordId: id, actionName: 'view' } });
    }
}