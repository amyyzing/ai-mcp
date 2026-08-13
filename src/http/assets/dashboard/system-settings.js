const STARTUP_POLL_INTERVAL_MS = 1200;
const STARTUP_RECONNECT_GRACE_MS = 90_000;

export function createSystemSettings({ $, dashboardApiFetch, showToast }) {
    const startupToggle = $('settingsSystemStartup');
    const startupStatus = $('settingsSystemStartupStatus');
    const skillButton = $('settingsInstallSkillBtn');
    const skillStatus = $('settingsInstallSkillStatus');
    if (!startupToggle || !startupStatus || !skillButton || !skillStatus) {
        return { refresh: async () => {} };
    }

    let startupTimer = null;
    let desiredStartup = null;
    let reconnectStartedAt = 0;
    let skillInstalled = false;

    function stopStartupPolling() {
        if (startupTimer !== null) {
            clearTimeout(startupTimer);
            startupTimer = null;
        }
    }

    function scheduleStartupPoll() {
        stopStartupPolling();
        startupTimer = setTimeout(() => {
            startupTimer = null;
            void refresh();
        }, STARTUP_POLL_INTERVAL_MS);
    }

    function render(data) {
        const startup = data?.startup || {};
        const operation = data?.startupOperation || {};
        const operationRunning = operation.state === 'running';
        const operationFailed = operation.state === 'failed';
        const effectiveEnabled = desiredStartup === null
            ? startup.enabled === true
            : desiredStartup;

        startupToggle.checked = effectiveEnabled;
        startupToggle.disabled = startup.supported === false || operationRunning;
        startupStatus.dataset.state = operationFailed ? 'failed' : operationRunning ? 'running' : 'idle';
        startupStatus.textContent = startup.supported === false
            ? 'Automatic startup is not supported on this platform.'
            : operationRunning
                ? operation.message || 'Changing startup preference…'
                : operationFailed
                    ? operation.error || operation.message || 'Startup preference could not be changed.'
                    : startup.enabled
                        ? `Enabled with ${startup.manager || 'the native service manager'}.`
                        : 'Disabled. An AI harness starts the server when needed.';

        if (
            desiredStartup !== null &&
            !operationRunning &&
            !operationFailed &&
            startup.enabled === desiredStartup
        ) {
            const enabled = desiredStartup;
            desiredStartup = null;
            reconnectStartedAt = 0;
            showToast(
                enabled
                    ? 'Roblox MCP will start with your computer'
                    : 'Automatic startup disabled',
                'success'
            );
        } else if (operationFailed && desiredStartup !== null) {
            desiredStartup = null;
            reconnectStartedAt = 0;
            startupToggle.checked = startup.enabled === true;
            showToast(startupStatus.textContent, 'error', 6000);
        }

        const skill = data?.skill || {};
        const targets = Array.isArray(skill.targets) ? skill.targets : [];
        const targetNames = targets.map(target => target.harnessName).filter(Boolean);
        skillButton.disabled = skill.available !== true;
        skillButton.textContent = skillInstalled ? 'Reinstall skill' : 'Install skill';
        skillStatus.dataset.state = skill.error ? 'failed' : 'idle';
        skillStatus.textContent = skill.error
            ? skill.error
            : targetNames.length
                ? `Available for ${targetNames.join(', ')}.`
                : 'No compatible AI harnesses detected.';

        if (operationRunning || desiredStartup !== null) scheduleStartupPoll();
        else stopStartupPolling();
    }

    async function refresh() {
        try {
            const response = await dashboardApiFetch('/api/setup-settings', { cache: 'no-store' });
            const data = await response.json();
            if (!response.ok) throw new Error(data.error || 'Setup settings could not be loaded.');
            reconnectStartedAt = 0;
            render(data);
        } catch (error) {
            if (desiredStartup !== null) {
                reconnectStartedAt ||= Date.now();
                if (Date.now() - reconnectStartedAt < STARTUP_RECONNECT_GRACE_MS) {
                    startupStatus.textContent = 'Waiting for the server to restart…';
                    startupStatus.dataset.state = 'running';
                    startupToggle.disabled = true;
                    scheduleStartupPoll();
                    return;
                }
            }
            stopStartupPolling();
            startupStatus.textContent = error instanceof Error
                ? error.message
                : 'Setup settings could not be loaded.';
            startupStatus.dataset.state = 'failed';
            startupToggle.disabled = false;
        }
    }

    startupToggle.addEventListener('change', async () => {
        desiredStartup = startupToggle.checked;
        startupToggle.disabled = true;
        startupStatus.dataset.state = 'running';
        startupStatus.textContent = desiredStartup
            ? 'Enabling startup with your computer…'
            : 'Disabling startup with your computer…';
        try {
            const response = await dashboardApiFetch('/api/setup-settings', {
                method: 'POST',
                headers: { 'Content-Type': 'application/json' },
                body: JSON.stringify({
                    action: 'set-startup',
                    enabled: desiredStartup,
                }),
            });
            const data = await response.json();
            if (!response.ok) throw new Error(data.error || 'Startup preference could not be changed.');
            scheduleStartupPoll();
        } catch (error) {
            desiredStartup = null;
            startupToggle.checked = !startupToggle.checked;
            startupToggle.disabled = false;
            startupStatus.dataset.state = 'failed';
            startupStatus.textContent = error instanceof Error
                ? error.message
                : 'Startup preference could not be changed.';
            showToast(startupStatus.textContent, 'error', 6000);
        }
    });

    skillButton.addEventListener('click', async () => {
        skillButton.disabled = true;
        skillButton.textContent = 'Installing…';
        skillStatus.dataset.state = 'running';
        skillStatus.textContent = 'Installing the Roblox MCP skill…';
        try {
            const response = await dashboardApiFetch('/api/setup-settings', {
                method: 'POST',
                headers: { 'Content-Type': 'application/json' },
                body: JSON.stringify({ action: 'install-skill' }),
            });
            const data = await response.json();
            if (!response.ok) throw new Error(data.error || 'Skill installation failed.');
            skillInstalled = true;
            skillButton.textContent = 'Reinstall skill';
            skillStatus.dataset.state = 'complete';
            skillStatus.textContent = `Installed for ${(data.targetNames || []).join(', ')}.`;
            showToast('Roblox MCP skill installed', 'success');
        } catch (error) {
            skillButton.textContent = skillInstalled ? 'Reinstall skill' : 'Install skill';
            skillStatus.dataset.state = 'failed';
            skillStatus.textContent = error instanceof Error
                ? error.message
                : 'Skill installation failed.';
            showToast(skillStatus.textContent, 'error', 6000);
        } finally {
            skillButton.disabled = false;
        }
    });

    window.addEventListener('beforeunload', stopStartupPolling, { once: true });
    void refresh();
    return { refresh };
}
