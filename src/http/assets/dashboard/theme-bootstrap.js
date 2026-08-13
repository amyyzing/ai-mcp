(() => {
    'use strict';

    const storageKey = 'roblox-mcp-dashboard-theme';
    const knownThemes = new Set(['default', 'claude', 'chatgpt', 'github-dark', 'github-light', 'custom']);
    const customProperties = new Set([
        '--bg', '--surface', '--surface-raised', '--surface-hover', '--border', '--border-light',
        '--accent', '--blue', '--blue-dim', '--text', '--text-secondary', '--text-tertiary',
        '--topbar-bg', '--code-bg', '--overlay', '--shadow', '--shadow-soft', '--contrast-text',
        '--lift-overlay', '--media-chrome-bg', '--theme-color-scheme', '--sans', '--mono'
    ]);
    const sansFonts = {
        geist: "'Geist', -apple-system, system-ui, sans-serif",
        'ibm-plex': "'IBM Plex Sans', -apple-system, system-ui, sans-serif",
        'source-sans': "'Source Sans 3', -apple-system, system-ui, sans-serif",
        system: "-apple-system, BlinkMacSystemFont, 'Helvetica Neue', sans-serif"
    };
    const monoFonts = {
        'geist-mono': "'Geist Mono', 'SF Mono', monospace",
        'ibm-plex-mono': "'IBM Plex Mono', 'SF Mono', monospace",
        'jetbrains-mono': "'JetBrains Mono', 'SF Mono', monospace",
        'system-mono': "'SF Mono', ui-monospace, monospace"
    };
    const customFontStack = value => /^[a-z0-9 _-]{1,60}$/i.test(value || '')
        ? `'${value}', sans-serif`
        : null;

    try {
        const saved = JSON.parse(localStorage.getItem(storageKey) || '{}');
        const theme = knownThemes.has(saved.theme) ? saved.theme : 'default';
        document.documentElement.dataset.theme = theme;
        if (theme === 'custom' && saved.vars && typeof saved.vars === 'object') {
            for (const [property, value] of Object.entries(saved.vars)) {
                const validValue = property === '--theme-color-scheme'
                    ? value === 'light' || value === 'dark'
                    : typeof value === 'string' && /^#[0-9a-f]{6,8}$/i.test(value);
                if (customProperties.has(property) && validValue) {
                    document.documentElement.style.setProperty(property, value);
                }
            }
        }
        const fonts = saved.fonts && typeof saved.fonts === 'object' ? saved.fonts : {};
        const sans = sansFonts[fonts.sans]
            || (fonts.sans === 'custom' ? customFontStack(fonts.customSans) : null);
        const mono = monoFonts[fonts.mono]
            || (fonts.mono === 'custom' && /^[a-z0-9 _-]{1,60}$/i.test(fonts.customMono || '')
                ? `'${fonts.customMono}', monospace`
                : null);
        if (sans) document.documentElement.style.setProperty('--sans', sans);
        if (mono) document.documentElement.style.setProperty('--mono', mono);
        const light = theme === 'claude'
            || theme === 'github-light'
            || (theme === 'custom' && saved.vars?.['--theme-color-scheme'] === 'light');
        document.getElementById('highlightTheme').href = light
            ? '/highlight-github.min.css'
            : '/highlight-github-dark.min.css';
    } catch {
        document.documentElement.dataset.theme = 'default';
    }
})();
