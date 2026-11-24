import { LightningElement, api } from 'lwc';
import { connectorModel } from 'c/nfyStatus';

/** The line between a system card and the integration hub: event label, direction arrows, data types. */
export default class NfyFlowConnector extends LightningElement {
    /** A system row from NFY_CommandCenterController.getSummary (needs placement, direction, stage, health, jobs24h, entities). */
    @api system;
    @api dimmed = false;

    get model() {
        return this.system ? connectorModel(this.system) : { label: '', entities: '', ariaLabel: '' };
    }

    get rootClass() {
        const m = this.model;
        return 'conn s-' + (m.status || 'idle') + (m.dashed ? ' dashed' : '') + (this.dimmed ? ' dim' : '');
    }
}