const POLL_INTERVAL_MS = 1500;
const RECONNECT_GRACE_MS = 90_000;
const ACTIVE_STATES = new Set(['running', 'restarting']);

export function createUpdateSettings({ $, dashboardApiFetch, showToast }) {
    const button = $('settingsUpdateBtn');
    const restartButton = $('settingsRestartBtn');
    const status = $('settingsUpdateStatus');
    if (!button || !restartButton || !status) return;

    let pollTimer = null;
    let operationInProgress = false;
    let activeAction = 'update';
    let disconnectStartedAt = 0;
    let lastState = 'idle';
    let hasRendered = false;

    function render(update) {
        const state = typeof update?.state === 'string' ? update.state : 'idle';
        const message = typeof update?.message === 'string'
            ? update.message
            : 'Ready to check for updates.';
        const available = update?.available !== false;
        activeAction = update?.operation === 'restart' ? 'restart' : 'update';
        status.textContent = message;
        status.dataset.state = state;
        operationInProgress = ACTIVE_STATES.has(state);
        disconnectStartedAt = 0;
        button.disabled = !available || ACTIVE_STATES.has(state);
        restartButton.disabled = !available || ACTIVE_STATES.has(state);
        button.textContent = !available
            ? 'Unavailable'
            : ACTIVE_STATES.has(state) && activeAction === 'update' && state === 'running'
            ? 'Updating…'
            : ACTIVE_STATES.has(state) && activeAction === 'update' && state === 'restarting'
                ? 'Restarting…'
                : 'Update now';
        restartButton.textContent = !available
            ? 'Unavailable'
            : ACTIVE_STATES.has(state) && activeAction === 'restart'
                ? 'Restarting…'
                : 'Restart server';

        if (hasRendered && lastState !== state && state === 'complete') {
            showToast(message, 'success', 5000);
        } else if (hasRendered && lastState !== state && state === 'failed') {
            showToast(message, 'error', 6000);
        }
        lastState = state;
        hasRendered = true;
        return state;
    }

    function stopPolling() {
        if (pollTimer !== null) {
            clearTimeout(pollTimer);
            pollTimer = null;
        }
    }

    async function refresh() {
        try {
            const response = await dashboardApiFetch('/api/update', { cache: 'no-store' });
            if (!response.ok) throw new Error(`Update status failed (${response.status})`);
            const state = render(await response.json());
            if (ACTIVE_STATES.has(state)) {
                schedulePoll();
            } else {
                stopPolling();
            }
        } catch {
            if (operationInProgress) disconnectStartedAt ||= Date.now();
            if (disconnectStartedAt && Date.now() - disconnectStartedAt < RECONNECT_GRACE_MS) {
                status.textContent = 'Waiting for the updated server to restart…';
                status.dataset.state = 'restarting';
                button.disabled = true;
                restartButton.disabled = true;
                if (activeAction === 'update') button.textContent = 'Restarting…';
                else restartButton.textContent = 'Restarting…';
                schedulePoll();
                return;
            }
            stopPolling();
            status.textContent = 'Could not reach the update service.';
            status.dataset.state = 'failed';
            button.disabled = false;
            restartButton.disabled = false;
            button.textContent = 'Try again';
            restartButton.textContent = 'Restart server';
        }
    }

    function schedulePoll() {
        stopPolling();
        pollTimer = setTimeout(() => {
            pollTimer = null;
            void refresh();
        }, POLL_INTERVAL_MS);
    }

    async function startOperation(action) {
        activeAction = action;
        button.disabled = true;
        restartButton.disabled = true;
        status.textContent = action === 'restart' ? 'Starting the server restart…' : 'Starting the automatic update…';
        status.dataset.state = action === 'restart' ? 'restarting' : 'running';
        operationInProgress = true;
        disconnectStartedAt = 0;
        try {
            const response = await dashboardApiFetch('/api/update', {
                method: 'POST',
                headers: { 'Content-Type': 'application/json' },
                body: JSON.stringify({ action }),
            });
            const data = await response.json();
            if (!response.ok) throw new Error(data.error || 'Server operation could not be started.');
            render(data);
            schedulePoll();
        } catch (error) {
            operationInProgress = false;
            disconnectStartedAt = 0;
            render({
                state: 'failed',
                message: error instanceof Error ? error.message : 'Server operation could not be started.',
            });
        }
    }

    button.addEventListener('click', () => void startOperation('update'));
    restartButton.addEventListener('click', () => void startOperation('restart'));

    window.addEventListener('beforeunload', stopPolling, { once: true });
    void refresh();
}
