import { LightningElement, api } from 'lwc';
import { NavigationMixin } from 'lightning/navigation';
import { cardModel, connectorModel } from 'c/nfyStatus';

const HIDE_DELAY_MS = 150;

/**
 * One system on the integration map. Hover or keyboard focus shows the system's flows;
 * selecting the card opens the system record (Ctrl/Cmd-click opens it in a new tab).
 */
export default class NfySystemCard extends NavigationMixin(LightningElement) {
    /** A system row from NFY_CommandCenterController.getSummary. */
    @api system;
    /** True when the map is one column (narrow region or phone): the card shows its line summary and a flows toggle. */
    @api compact = false;
    @api dimmed = false;
    /** Open the flow list upwards (for cards in the lower half of the map). */
    @api popUp = false;

    url;
    popoverOpen = false;
    hideTimer;

    connectedCallback() {
        if (this.system && this.system.id) {
            this[NavigationMixin.GenerateUrl]({
                type: 'standard__recordPage',
                attributes: { recordId: this.system.id, actionName: 'view' }
            }).then((u) => {
                this.url = u;
            });
        }
    }

    disconnectedCallback() {
        clearTimeout(this.hideTimer);
    }

    get model() {
        return cardModel(this.system || {});
    }

    get connector() {
        return connectorModel(this.system || {});
    }

    get wrapClass() {
        return 'wrap' + (this.dimmed ? ' dim' : '') + (this.compact ? ' compact' : '');
    }

    get cardClass() {
        return 'card s-' + this.model.status + (this.popoverOpen ? ' active' : '');
    }

    get errClass() {
        return this.model.hasOpenErrors ? 'err' : '';
    }

    get cardAria() {
        const m = this.model;
        return m.name + ', ' + m.statusLabel + '. ' + m.flowsLive + ' flows live, ' + m.openErrors + ' ' + m.openErrorsLabel + '. Open system.';
    }

    get popClass() {
        if (this.compact) return 'pop inline';
        return 'pop ' + (this.system && this.system.placement === 'right' ? 'to-left' : 'to-right') + (this.popUp ? ' up' : '');
    }

    get popAria() {
        return this.model.name + ' flows';
    }

    get flowCountLabel() {
        const n = this.model.flows.length;
        return n === 1 ? '1 flow' : n + ' flows';
    }

    get openErrorsBadge() {
        return this.model.openErrors + ' ' + this.model.openErrorsLabel;
    }

    get showFlowLine() {
        return this.compact;
    }

    get flowArrow() {
        const c = this.connector;
        if (c.arrowLeft && c.arrowRight) return '↔';
        return '→';
    }

    get arrowClass() {
        return 'arrow s-' + this.connector.status;
    }

    get flowSummary() {
        const c = this.connector;
        return c.entities ? c.label + ' · ' + c.entities : c.label;
    }

    get popoverOpenText() {
        return this.popoverOpen ? 'true' : 'false';
    }

    get toggleLabel() {
        return (this.popoverOpen ? 'Hide ' : 'Show ') + this.flowCountLabel;
    }

    get hasFlows() {
        return this.model.flows.length > 0;
    }

    show() {
        clearTimeout(this.hideTimer);
        if (this.hasFlows) this.popoverOpen = true;
    }

    hideSoon() {
        clearTimeout(this.hideTimer);
        // eslint-disable-next-line @lwc/lwc/no-async-operation
        this.hideTimer = setTimeout(() => {
            this.popoverOpen = false;
        }, HIDE_DELAY_MS);
    }

    handleEnter() {
        if (!this.compact) this.show();
    }

    handleLeave() {
        if (!this.compact) this.hideSoon();
    }

    handleFocusIn() {
        if (!this.compact) this.show();
    }

    handleFocusOut() {
        if (this.compact) return;
        // Stay open while focus moves into the flow list; close once it leaves the card.
        // eslint-disable-next-line @lwc/lwc/no-async-operation
        setTimeout(() => {
            if (!this.template.activeElement) this.hideSoon();
        }, 0);
    }

    handleKeyDown(event) {
        if (event.key === 'Escape' && this.popoverOpen) {
            this.popoverOpen = false;
            event.stopPropagation();
        }
    }

    handleToggle() {
        this.popoverOpen = !this.popoverOpen;
    }

    handleOpen(event) {
        if (!this.system || !this.system.id) return;
        // Let the browser handle Ctrl/Cmd/Shift-click so the record opens in a new tab or window.
        if (event.ctrlKey || event.metaKey || event.shiftKey || event.button === 1) return;
        event.preventDefault();
        this[NavigationMixin.Navigate]({
            type: 'standard__recordPage',
            attributes: { recordId: this.system.id, actionName: 'view' }
        });
    }

    handleShowFailures() {
        this.popoverOpen = false;
        this.dispatchEvent(new CustomEvent('showfailures', { detail: { code: this.system ? this.system.code : null } }));
    }
}