const fs = require('fs');

// === Patch 1: library-toggle guard (fork bug — plain GET wipes enabled state) ===
const settingsPath = '/app/dist/routes/settings/index.js';
let src = fs.readFileSync(settingsPath, 'utf8');

const old = `    const enabledLibraries = req.query.enable
        ? req.query.enable.split(',')
        : [];
    settings.jellyfin.libraries = settings.jellyfin.libraries.map((library) => ({
        ...library,
        enabled: enabledLibraries.includes(library.id),
    }));
    await settings.save();`;

const neu = `    if (req.query.enable) {
        const enabledLibraries = req.query.enable.split(',');
        settings.jellyfin.libraries = settings.jellyfin.libraries.map((library) => ({
            ...library,
            enabled: enabledLibraries.includes(library.id),
        }));
    }
    await settings.save();`;

if (src.includes(old)) {
  src = src.replace(old, neu);
  fs.writeFileSync(settingsPath, src);
  console.log('PATCH 1 (library toggle) OK');
} else if (src.includes('if (req.query.enable) {')) {
  console.log('PATCH 1 (library toggle) ALREADY APPLIED');
} else {
  console.log('PATCH 1 (library toggle) PATTERN NOT FOUND');
  process.exit(1);
}

// === Patch 2: buildUrl baseUrl normalization (double-slash bug) ===
// Seerr's settings UI writes baseUrl "/" for Radarr/Sonarr. buildUrl then
// produces http://host:port//api/v3 (double slash) → GET returns the HTML
// SPA shell (queue parse crash) and POST /command returns 405. Normalize
// baseUrl so "/" and "/foo/" both become "" / "foo".
const basePath = '/app/dist/api/servarr/base.js';
let bsrc = fs.readFileSync(basePath, 'utf8');

const bold = `    static buildUrl(settings, path) {
        return \`\${settings.useSsl ? 'https' : 'http'}://\${settings.hostname}:\${settings.port}\${settings.baseUrl ?? ''}\${path}\`;
    }`;

const bneu = `    static buildUrl(settings, path) {
        const baseUrl = (settings.baseUrl ?? '').replace(/^\\/+|\\/+$/g, '');
        return \`\${settings.useSsl ? 'https' : 'http'}://\${settings.hostname}:\${settings.port}\${baseUrl ? '/' + baseUrl : ''}\${path}\`;
    }`;

if (bsrc.includes(bold)) {
  bsrc = bsrc.replace(bold, bneu);
  fs.writeFileSync(basePath, bsrc);
  console.log('PATCH 2 (buildUrl baseUrl) OK');
} else if (bsrc.includes("const baseUrl = (settings.baseUrl ?? '').replace")) {
  console.log('PATCH 2 (buildUrl baseUrl) ALREADY APPLIED');
} else {
  console.log('PATCH 2 (buildUrl baseUrl) PATTERN NOT FOUND');
  process.exit(1);
}
