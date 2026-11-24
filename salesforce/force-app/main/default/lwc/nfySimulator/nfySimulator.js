import { LightningElement, track } from 'lwc';
import { NavigationMixin } from 'lightning/navigation';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import shopifyOrder from '@salesforce/apex/NFY_SimulatorController.shopifyOrder';
import resendLastOrder from '@salesforce/apex/NFY_SimulatorController.resendLastOrder';
import shipFrom from '@salesforce/apex/NFY_SimulatorController.shipFrom';
import fbaInboundPlan from '@salesforce/apex/NFY_SimulatorController.fbaInboundPlan';
import fbaInboundShipped from '@salesforce/apex/NFY_SimulatorController.fbaInboundShipped';
import fbaInboundReceived from '@salesforce/apex/NFY_SimulatorController.fbaInboundReceived';
import amazonOrder from '@salesforce/apex/NFY_SimulatorController.amazonOrder';
import amazonReturn from '@salesforce/apex/NFY_SimulatorController.amazonReturn';
import b2bOrder from '@salesforce/apex/NFY_SimulatorController.b2bOrder';
import factoryPo from '@salesforce/apex/NFY_SimulatorController.factoryPo';
import receivePo from '@salesforce/apex/NFY_SimulatorController.receivePo';
import onboardNetherlands from '@salesforce/apex/NFY_SimulatorController.onboardNetherlands';
import euOrder from '@salesforce/apex/NFY_SimulatorController.euOrder';
import shipStationFailure from '@salesforce/apex/NFY_SimulatorController.shipStationFailure';
import runOrderSyncFor from '@salesforce/apex/NFY_SimulatorController.runOrderSyncFor';
import retry from '@salesforce/apex/NFY_SimulatorController.retry';
import stockSnapshot from '@salesforce/apex/NFY_SimulatorController.stockSnapshot';
import settlement from '@salesforce/apex/NFY_SimulatorController.settlement';
import shortfallOrder from '@salesforce/apex/NFY_SimulatorController.shortfallOrder';
import stockArrives from '@salesforce/apex/NFY_SimulatorController.stockArrives';

const STATE_KEY = 'nfySimulatorState';

export default class NfySimulator extends NavigationMixin(LightningElement) {
    @track state = {};
    @track feed = [];
    busy = false;

    connectedCallback() {
        try {
            const saved = window.sessionStorage.getItem(STATE_KEY);
            if (saved) this.state = JSON.parse(saved);
        } catch (e) {
            this.state = {};
        }
    }

    save(patch) {
        this.state = { ...this.state, ...patch };
        try {
            window.sessionStorage.setItem(STATE_KEY, JSON.stringify(this.state));
        } catch (e) {
            // Session storage is a convenience; the scenes still run without it.
        }
    }

    // ------------------------------------------------------------------ scenes and their steps

    get scenes() {
        const s = this.state;
        return [
            {
                id: 'S2', title: 'Shopify order to cash', systems: 'Shopify → Workato → Salesforce + TC → ShipMonk / ShipStation',
                note: s.shopify ? 'Current order ' + s.shopify : 'Shopify ranks ShipMonk PA1; the youth size is not stocked there, so that line falls back to Main.',
                steps: [
                    { key: 's2a', label: '1 · New Shopify order', run: 'shopifyOrder' },
                    { key: 's2b', label: '2 · ShipMonk ships PA1 lines', run: 'shipPa1', disabled: !s.shopify },
                    { key: 's2c', label: '3 · ShipStation label at Main', run: 'shipMainShopify', disabled: !s.shopify },
                    { key: 's2d', label: 'Send the same order again', run: 'resend', disabled: !s.shopify, variant: 'neutral' }
                ]
            },
            {
                id: 'S3', title: 'Amazon FBA inbound, sale and return', systems: 'Main → Amazon FBA · SP-API',
                note: s.inbound ? 'FBA inbound ' + s.inbound + (s.amazon ? ' · order ' + s.amazon : '') : '240 pairs of Evolution 8 from Main; Amazon will receive 237.',
                steps: [
                    { key: 's3a', label: '1 · Create FBA inbound plan', run: 'fbaPlan' },
                    { key: 's3b', label: '2 · Amazon: shipped', run: 'fbaShipped', disabled: !s.inbound },
                    { key: 's3c', label: '3 · Amazon: received 237', run: 'fbaReceived', disabled: !s.inbound },
                    { key: 's3d', label: '4 · FBA marketplace order', run: 'amazonOrder' },
                    { key: 's3e', label: '5 · Amazon ships it', run: 'amazonShips', disabled: !s.amazon },
                    { key: 's3f', label: '6 · Shopify order via MCF', run: 'mcfOrder' },
                    { key: 's3g', label: '7 · Return, sellable', run: 'returnSellable', disabled: !s.amazonShipped, variant: 'neutral' },
                    { key: 's3h', label: '8 · Return, damaged', run: 'returnDamaged', disabled: !s.amazonShipped, variant: 'neutral' }
                ]
            },
            {
                id: 'S4', title: 'Team order through ShipStation and Customwear', systems: 'Salesforce rep order → TC → ShipStation + decorator',
                note: s.b2b ? 'Current order ' + s.b2b : '12 pairs from Main, 12 decorated jackets from Customwear, 24 pairs of Rival 9 direct from the factory. To enter one by hand instead, create an Order and use its Fulfilment card.',
                steps: [
                    { key: 's4a', label: '1 · Rep enters team order', run: 'b2bOrder' },
                    { key: 's4b', label: '2 · ShipStation label at Main', run: 'shipMainB2b', disabled: !s.b2b },
                    { key: 's4c', label: '3 · Customwear ships jackets', run: 'shipCustomwear', disabled: !s.b2b },
                    { key: 's4d', label: '4 · Factory ships direct', run: 'shipFactory', disabled: !s.b2b }
                ]
            },
            {
                id: 'S5', title: 'Factory PO to two warehouses', systems: 'TC Purchase Order → container → Main + ShipMonk NV3',
                note: s.po ? 'Current PO ' + s.po : '1,000 pairs on the water; 600 land at Main and 400 at ShipMonk NV3.',
                steps: [
                    { key: 's5a', label: '1 · Create PO and container', run: 'factoryPo' },
                    { key: 's5b', label: '2 · Receive 600 Main + 400 NV3', run: 'receivePo', disabled: !s.po }
                ]
            },
            {
                id: 'S6', title: 'Plug in the Netherlands 3PL (Odoo)', systems: '3PL template → Odoo → TC',
                note: s.nl ? (s.eu ? 'EU order ' + s.eu : 'NL 3PL is live. Send an EU order.') : 'One click creates the system, warehouse, locations and six standard flows.',
                steps: [
                    { key: 's6a', label: '1 · Onboard NL 3PL from template', run: 'onboard', disabled: !!s.nl },
                    { key: 's6b', label: '2 · EU webstore order', run: 'euOrder', disabled: !s.nl },
                    { key: 's6c', label: '3 · Odoo ships it', run: 'odooShips', disabled: !s.eu }
                ]
            },
            {
                id: 'S7', title: 'Failure, alert, retry, reconcile', systems: 'ShipStation → Workato → Salesforce',
                note: s.failed ? 'Failed log for ' + s.failedOrder : 'ShipStation reports a label for an order the daily Shopify sync has not delivered yet.',
                steps: [
                    { key: 's7a', label: '1 · ShipStation shipment arrives', run: 'fail' },
                    { key: 's7b', label: '2 · Late Shopify order sync runs', run: 'lateSync', disabled: !s.failed },
                    { key: 's7c', label: '3 · Retry the failed sync', run: 'retry', disabled: !s.failed },
                    { key: 's7d', label: 'ShipMonk PA1 stock count', run: 'snapshot', variant: 'neutral' }
                ]
            },
            {
                id: 'S9', title: 'Stock shortfall and backorder', systems: 'Salesforce rep order → TC stock check → PO receipt → automatic assignment',
                note: s.short ? 'Current order ' + s.short : 'A team order for 40 more pairs than ShipMonk NV3 holds, ship-from fixed to NV3: part is assigned, 40 are backordered until stock arrives.',
                steps: [
                    { key: 's9a', label: '1 · Team order larger than stock', run: 'shortfallOrder' },
                    { key: 's9b', label: '2 · ShipMonk ships what is assigned', run: 'shipShortNv3', disabled: !s.short },
                    { key: 's9c', label: '3 · Stock arrives at NV3 (PO receipt)', run: 'stockArrives', disabled: !s.short },
                    { key: 's9d', label: '4 · ShipMonk ships the rest', run: 'shipShortNv3', disabled: !s.short }
                ]
            },
            {
                id: 'S8', title: 'Settlements to GL', systems: 'Amazon settlement / Shopify payout → TC cash receipt + fees journal',
                note: 'Clears the last 14 days of marketplace billings, posts fees, and flags one sale with no billing in Salesforce.',
                steps: [
                    { key: 's8a', label: 'Amazon settlement report', run: 'amazonSettlement' },
                    { key: 's8b', label: 'Shopify payout', run: 'shopifyPayout' }
                ]
            }
        ].map((scene) => ({
            ...scene,
            steps: scene.steps.map((st) => ({ ...st, variant: st.variant || 'brand-outline', disabled: this.busy || !!st.disabled }))
        }));
    }

    get hasFeed() {
        return this.feed.length > 0;
    }

    // ------------------------------------------------------------------ actions

    async handleStep(event) {
        const run = event.currentTarget.dataset.run;
        const label = event.currentTarget.label;
        this.busy = true;
        try {
            await this.actions()[run]();
        } catch (e) {
            const message = (e && e.body && e.body.message) || (e && e.message) || 'Something went wrong.';
            this.push({ label, results: [{ success: false, status: 'Error', message }] });
        } finally {
            this.busy = false;
        }
    }

    actions() {
        const s = this.state;
        return {
            shopifyOrder: async () => this.record('New Shopify order', await shopifyOrder({ withStockout: true }), (r) => this.save({ shopify: r.reference })),
            shipPa1: async () => this.record('ShipMonk PA1 ships ' + s.shopify, await shipFrom({ orderNumber: s.shopify, shipFromCode: 'SM-PA1' })),
            shipMainShopify: async () => this.record('ShipStation label at Main for ' + s.shopify, await shipFrom({ orderNumber: s.shopify, shipFromCode: 'MAIN' })),
            resend: async () => this.record('Shopify re-sends ' + s.shopify, await resendLastOrder()),
            fbaPlan: async () => this.record('FBA inbound plan', await fbaInboundPlan({ sku: '840386208702', qty: 240 }), (r) => this.save({ inbound: r.reference })),
            fbaShipped: async () => this.record('Amazon: ' + s.inbound + ' shipped', await fbaInboundShipped({ inboundId: s.inbound })),
            fbaReceived: async () => this.record('Amazon: ' + s.inbound + ' received', await fbaInboundReceived({ inboundId: s.inbound, shortBy: 3 })),
            amazonOrder: async () => this.record('Amazon FBA order', await amazonOrder({ mcf: false }), (r) => this.save({ amazon: r.reference, amazonShipped: false })),
            amazonShips: async () => this.record('Amazon ships ' + s.amazon, await shipFrom({ orderNumber: s.amazon, shipFromCode: 'FBA-US' }), () => this.save({ amazonShipped: true })),
            mcfOrder: async () => {
                const r = await amazonOrder({ mcf: true });
                this.record('Shopify order fulfilled by MCF', r);
                if (r.results[0].success) {
                    this.record('Amazon MCF ships ' + r.reference, await shipFrom({ orderNumber: r.reference, shipFromCode: 'FBA-US' }));
                }
            },
            returnSellable: async () => this.record('Amazon return (sellable)', await amazonReturn({ condition: 'Sellable' })),
            returnDamaged: async () => this.record('Amazon return (damaged)', await amazonReturn({ condition: 'Unfulfillable' })),
            b2bOrder: async () => this.record('Rep enters team order', await b2bOrder(), (r) => this.save({ b2b: r.reference })),
            shipMainB2b: async () => this.record('ShipStation label at Main for ' + s.b2b, await shipFrom({ orderNumber: s.b2b, shipFromCode: 'MAIN' })),
            shipCustomwear: async () => this.record('Customwear ships ' + s.b2b, await shipFrom({ orderNumber: s.b2b, shipFromCode: 'CUSTOMWEAR' })),
            shipFactory: async () => this.record('Factory ships ' + s.b2b + ' direct', await shipFrom({ orderNumber: s.b2b, shipFromCode: 'FACTORY' })),
            factoryPo: async () => this.record('Factory PO and container', await factoryPo(), (r) => this.save({ po: r.reference })),
            receivePo: async () => this.record('Container received for ' + s.po, await receivePo({ poNumber: s.po })),
            onboard: async () => this.record('Onboard NL 3PL (Odoo)', await onboardNetherlands(), () => this.save({ nl: true })),
            euOrder: async () => this.record('EU webstore order', await euOrder(), (r) => this.save({ eu: r.reference })),
            odooShips: async () => this.record('Odoo ships ' + s.eu, await shipFrom({ orderNumber: s.eu, shipFromCode: 'NL-ODOO' })),
            fail: async () => this.record('ShipStation shipment arrives', await shipStationFailure(), (r) => this.save({ failed: r.results[0].logId, failedOrder: r.reference })),
            lateSync: async () => this.record('Late Shopify sync for ' + s.failedOrder, await runOrderSyncFor({ orderNumber: s.failedOrder })),
            retry: async () => this.record('Retry ' + s.failedOrder, await retry({ logId: s.failed }), (r) => { if (r.results[0].success) this.save({ failed: null }); }),
            snapshot: async () => this.record('ShipMonk PA1 stock count', await stockSnapshot({ warehouseCode: 'SM-PA1' })),
            shortfallOrder: async () => this.record('Team order larger than stock', await shortfallOrder(), (r) => this.save({ short: r.reference })),
            shipShortNv3: async () => this.record('ShipMonk NV3 ships ' + s.short, await shipFrom({ orderNumber: s.short, shipFromCode: 'SM-NV3' })),
            stockArrives: async () => this.record('Stock arrives for ' + s.short, await stockArrives({ orderNumber: s.short })),
            amazonSettlement: async () => this.record('Amazon settlement report', await settlement({ source: 'AMAZON' })),
            shopifyPayout: async () => this.record('Shopify payout', await settlement({ source: 'SHOPIFY' }))
        };
    }

    record(label, sceneResult, onSuccess) {
        this.push({ label, results: sceneResult.results, recordId: sceneResult.recordId });
        const ok = sceneResult.results.length > 0 && sceneResult.results.every((r) => r.success);
        if (ok && onSuccess) onSuccess(sceneResult);
        const first = sceneResult.results[0] || {};
        this.dispatchEvent(new ShowToastEvent({
            title: label + (ok ? '' : ': ' + (first.status || 'failed')),
            message: first.message || '',
            variant: ok ? (first.status === 'Duplicate skipped' ? 'info' : 'success') : 'error'
        }));
        return sceneResult;
    }

    push(entry) {
        const at = new Date().toLocaleTimeString('en-US', { hour: 'numeric', minute: '2-digit', second: '2-digit' });
        const items = (entry.results || []).map((r, i) => ({
            key: entry.label + at + i,
            status: r.status || (r.success ? 'Success' : 'Failed'),
            pill: 'pill ' + (r.status === 'Duplicate skipped' ? 'p-info' : (r.success ? 'p-ok' : 'p-bad')),
            message: r.message,
            logId: r.logId,
            logName: r.logName,
            recordId: r.recordId,
            recordName: r.recordName,
            hasRecord: !!r.recordId,
            hasLog: !!r.logId
        }));
        this.feed = [{ key: entry.label + at, label: entry.label, at, items }, ...this.feed].slice(0, 30);
    }

    handleClear() {
        this.feed = [];
        this.save({ shopify: null, amazon: null, amazonShipped: false, inbound: null, b2b: null, po: null, eu: null, failed: null, failedOrder: null, short: null });
    }

    navigate(event) {
        const id = event.currentTarget.dataset.id;
        if (id) {
            this[NavigationMixin.Navigate]({ type: 'standard__recordPage', attributes: { recordId: id, actionName: 'view' } });
        }
    }
}