/**
 * Shared view logic for the integration map: one place that turns a system's health and stage
 * into a status, and a system into the card, connector and flow-list models the map draws.
 * Pure functions only (no DOM, no Apex), so they are easy to unit test.
 */

export const STATUS = {
    healthy: { key: 'healthy', label: 'Healthy' },
    needsAction: { key: 'needsAction', label: 'Needs action' },
    watch: { key: 'watch', label: 'Watch' },
    idle: { key: 'idle', label: 'Idle' },
    planned: { key: 'planned', label: 'Planned' }
};

/** Display order of the status filters. */
export const STATUS_ORDER = ['healthy', 'needsAction', 'watch', 'idle', 'planned'];

const HEALTH_TO_STATUS = { ok: 'healthy', error: 'needsAction', warning: 'watch', idle: 'idle', planned: 'planned' };

const ENTITY_WORD = {
    Order: 'orders', Inventory: 'stock', Shipment: 'shipments', Product: 'products', Inbound: 'inbound',
    'PO Receipt': 'receipts', Return: 'returns', Settlement: 'settlements', Payment: 'payments'
};

/** Status key for a system row from NFY_CommandCenterController (health: ok | warning | error | planned | idle). */
export function statusOf(system) {
    if (!system) return 'idle';
    if (system.stage === 'planned') return 'planned';
    return HEALTH_TO_STATUS[system.health] || 'idle';
}

export function statusLabel(key) {
    return (STATUS[key] || STATUS.idle).label;
}

export function entityWord(entity) {
    if (!entity) return '';
    return ENTITY_WORD[entity] || String(entity).toLowerCase();
}

/** "orders, products", or the first two plus "+N" when the full list is long (same rule as the classic map). */
export function entitySummary(entities) {
    const words = (entities || []).map(entityWord).filter((w) => w);
    const all = words.join(', ');
    if (all.length <= 22 || words.length <= 2) return all;
    return words.slice(0, 2).join(', ') + ' +' + (words.length - 2);
}

/** Relative time, matching the rest of the Command Center. */
export function ago(value, now) {
    if (!value) return 'never';
    const mins = Math.round(((now || Date.now()) - new Date(value).getTime()) / 60000);
    if (mins < 1) return 'just now';
    if (mins < 60) return mins + ' min ago';
    const hrs = Math.round(mins / 60);
    if (hrs < 48) return hrs + ' h ago';
    return Math.round(hrs / 24) + ' d ago';
}

/** Two-letter code for the card tile: ShipMonk -> SM, Global-e -> GE, Shopify -> SH. */
export function monogram(name) {
    const first = String(name || '').trim().split(/\s+/)[0] || '';
    const letters = first.replace(/[^A-Za-z-]/g, '');
    const marks = [];
    for (let i = 0; i < letters.length; i++) {
        const c = letters[i];
        if (i === 0 || (c >= 'A' && c <= 'Z') || letters[i - 1] === '-') {
            if (c !== '-') marks.push(c);
        }
    }
    const code = marks.length >= 2 ? marks.slice(0, 2).join('') : letters.replace(/-/g, '').slice(0, 2);
    return code.toUpperCase() || '?';
}

/** The label on a connector line. */
export function connectorLabel(system) {
    const status = statusOf(system);
    if (status === 'planned') return 'Planned';
    if (system.stage === 'idle' || !system.jobs24h) return 'No events · 24 h';
    const events = system.jobs24h === 1 ? '1 event' : system.jobs24h + ' events';
    return events + ' · 24 h' + (system.failed24h > 0 ? ' · ' + system.failed24h + ' failed' : '');
}

/**
 * Which arrowheads a connector shows. "in" means data travels from the system into Salesforce (towards the hub).
 * For a system on the left the hub is to the right; on the right the hub is to the left.
 */
export function arrowsOf(direction, placement) {
    const toHub = direction === 'in' || direction === 'both';
    const fromHub = direction === 'out' || direction === 'both';
    const hubOnRight = placement !== 'right';
    return {
        left: hubOnRight ? fromHub : toHub,
        right: hubOnRight ? toHub : fromHub
    };
}

const DIRECTION_WORD = { in: 'into Salesforce', out: 'out to the system', both: 'both ways', none: 'direction not set' };

export function directionWord(direction) {
    return DIRECTION_WORD[direction] || DIRECTION_WORD.none;
}

/** Everything the system card shows. */
export function cardModel(system, now) {
    const status = statusOf(system);
    const open = system.openErrors || 0;
    return {
        id: system.id,
        code: system.code,
        name: system.name,
        status,
        statusLabel: statusLabel(status),
        monogram: monogram(system.name),
        mode: system.mode || 'Mode not set',
        lastEvent: 'Last event ' + ago(system.lastSync, now),
        flowsLive: (system.flows || 0) + '/' + (system.totalFlows || 0),
        failureRate: status === 'planned' ? '–' : (system.failureRate7d || 0) + '%',
        openErrors: open,
        openErrorsLabel: open === 1 ? 'open error' : 'open errors',
        hasOpenErrors: open > 0,
        flows: (system.flowList || []).map((f, i) => ({
            key: (f.recipeId || f.name || 'flow') + '-' + i,
            name: f.name,
            detail: [f.recipeId ? 'Recipe ' + f.recipeId : null, f.mode].filter((x) => x).join(' · ') || 'No recipe yet',
            live: !!f.active,
            statusLabel: f.active ? 'Live' : 'Planned'
        }))
    };
}

/** Everything the connector shows. */
export function connectorModel(system) {
    const status = statusOf(system);
    const arrows = arrowsOf(system.direction, system.placement);
    const label = connectorLabel(system);
    const entities = entitySummary(system.entities);
    return {
        status,
        label,
        entities,
        arrowLeft: arrows.left,
        arrowRight: arrows.right,
        dashed: status === 'planned',
        ariaLabel: system.name + ': ' + label + ', ' + (entities || 'no data types') + ', ' + directionWord(system.direction)
    };
}

/** Grid rows for one column: a shorter column is centred against the taller one, as on the classic map. */
export function rowsFor(count, totalRows) {
    const offset = Math.max(0, Math.floor((totalRows - count) / 2));
    const rows = [];
    for (let i = 0; i < count; i++) rows.push(offset + i + 1);
    return rows;
}

/** Hub figures from all systems (same arithmetic as the classic map). */
export function hubModel(systems) {
    const list = systems || [];
    const events = list.reduce((a, s) => a + (s.jobs24h || 0), 0);
    const recipes = list.reduce((a, s) => a + (s.recipes || 0), 0);
    const plannedFlows = list.reduce((a, s) => a + ((s.totalFlows || 0) - (s.flows || 0)), 0);
    const live = [];
    list.filter((s) => s.flows > 0).forEach((s) =>
        (s.flowList || []).filter((f) => f.active).forEach((f) => {
            const w = entityWord(f.entity);
            if (w && live.indexOf(w) === -1) live.push(w);
        }));
    const byCode = {};
    list.forEach((s) => {
        byCode[s.code] = s;
    });
    return {
        events,
        recipes,
        plannedFlows,
        entities: live.map((w) => w.charAt(0).toUpperCase() + w.slice(1)),
        workatoId: byCode.WORKATO ? byCode.WORKATO.id : null,
        salesforceId: byCode.SALESFORCE ? byCode.SALESFORCE.id : null
    };
}