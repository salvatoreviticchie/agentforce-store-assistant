import { LightningElement, wire } from 'lwc';
import { NavigationMixin } from 'lightning/navigation';
import { refreshApex } from '@salesforce/apex';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import LOCALE from '@salesforce/i18n/locale';
import getMyDay from '@salesforce/apex/MyDayController.getMyDay';
import completeTask from '@salesforce/apex/MyDayController.completeTask';

// Same briefing as the Staff Assistant's "Get My Day": MyDayService decides content and order,
// this component only renders it (no LLM, works even when Agentforce is unavailable).
const SECTION_STYLE = {
    OVERDUE: 'section section_overdue',
    TODAY: 'section section_today',
    PRE_VISIT: 'section section_attention'
};

export default class MyDayBriefing extends NavigationMixin(LightningElement) {
    day;
    error;
    busy = false;
    wiredResult;

    @wire(getMyDay)
    wiredDay(result) {
        this.wiredResult = result;
        if (result.data) {
            this.day = result.data;
            this.error = undefined;
        } else if (result.error) {
            this.error = result.error.body?.message || 'The briefing could not be loaded.';
            this.day = undefined;
        }
    }

    get loading() {
        return !this.day && !this.error;
    }

    get subtitle() {
        if (!this.day) return '';
        const date = new Date(`${this.day.today}T12:00:00`).toLocaleDateString(LOCALE, {
            weekday: 'long', day: 'numeric', month: 'long'
        });
        return this.day.store ? `${this.day.store} · ${date}` : date;
    }

    get message() {
        return this.day?.message;
    }

    /** View model: the template cannot call functions, so flags and keys are computed here. */
    get sections() {
        return (this.day?.sections || []).map((s) => ({
            key: s.key,
            title: s.title,
            count: s.items.length,
            cssClass: SECTION_STYLE[s.key] || 'section',
            items: s.items.map((i) => ({
                ...i,
                key: `${s.key}-${i.recordId}`,
                isTask: i.type === 'TASK',
                showCustomer: !!i.customerId && i.type !== 'CUSTOMER',
                details: (i.details || []).map((text, n) => ({ key: n, text })),
                tasks: i.tasks || []
            }))
        }));
    }

    handleRefresh() {
        this.busy = true;
        refreshApex(this.wiredResult).finally(() => {
            this.busy = false;
        });
    }

    handleOpenRecord(event) {
        event.preventDefault();
        this.navigateTo(event.currentTarget.dataset.id);
    }

    handleOpenCustomer(event) {
        this.navigateTo(event.currentTarget.dataset.id);
    }

    navigateTo(recordId) {
        this[NavigationMixin.Navigate]({
            type: 'standard__recordPage',
            attributes: { recordId, actionName: 'view' }
        });
    }

    async handleDone(event) {
        const taskId = event.currentTarget.dataset.id;
        this.busy = true;
        try {
            await completeTask({ taskId });
            this.dispatchEvent(new ShowToastEvent({ title: 'Task completed', variant: 'success' }));
            await refreshApex(this.wiredResult);
        } catch (e) {
            this.dispatchEvent(new ShowToastEvent({
                title: 'Could not complete the task',
                message: e.body?.message,
                variant: 'error'
            }));
        } finally {
            this.busy = false;
        }
    }
}
