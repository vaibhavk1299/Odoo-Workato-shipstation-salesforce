import { LightningElement, api } from 'lwc';
import { statusLabel } from 'c/nfyStatus';

/** One status pill used everywhere on the integration map: Healthy, Needs action, Watch, Idle, Planned. */
export default class NfyStatusBadge extends LightningElement {
    /** healthy | needsAction | watch | idle | planned */
    @api status = 'idle';
    /** Optional text instead of the status name (for example "2 open errors" or "Live"). */
    @api label;

    get text() {
        return this.label || statusLabel(this.status);
    }

    get badgeClass() {
        return 'badge s-' + (this.status || 'idle');
    }
}