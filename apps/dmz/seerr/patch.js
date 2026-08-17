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

// === Patch 3: login disclaimer on the sign-in page ===
// Injects a disclaimer paragraph into the login card (both client + SSR
// chunks so React hydration stays consistent). Chunk filenames are hashed
// and change on image updates, so discover them dynamically.
const DISCLAIMER_TEXT =
  'Sign in with your MySweetPea account (Authentik SSO). Use the same username and password as Vaultwarden, AFFiNE, and the other services.';

function patchLoginChunk(filePath) {
  let src = fs.readFileSync(filePath, 'utf8');
  if (src.includes('Authentik SSO')) {
    console.log('PATCH 3 (login disclaimer) ALREADY APPLIED: ' + filePath);
    return true;
  }
  // Only touch chunks that are the actual login page (has the i18n key)
  if (!src.includes('signinheader')) return false;
  const anchor = 'px-10 py-8",children:[';
  const idx = src.indexOf(anchor);
  if (idx === -1) return false;
  const after = src.slice(idx + anchor.length, idx + anchor.length + 60);
  const m = after.match(/\(0,([a-zA-Z_$][\w$]*)\.jsx\)\(/);
  if (!m) return false;
  const h = m[1];
  const disclaimer = `(0,${h}.jsx)("p",{className:"mb-4 text-center text-sm text-gray-400",children:"${DISCLAIMER_TEXT}"}),`;
  src = src.slice(0, idx + anchor.length) + disclaimer + src.slice(idx + anchor.length);
  fs.writeFileSync(filePath, src);
  console.log('PATCH 3 (login disclaimer) OK: ' + filePath);
  return true;
}

let patchedAny = false;
const clientChunksDir = '/app/.next/static/chunks/';
if (fs.existsSync(clientChunksDir)) {
  for (const f of fs.readdirSync(clientChunksDir)) {
    if (f.endsWith('.js') && patchLoginChunk(clientChunksDir + f)) patchedAny = true;
  }
}
const ssrChunksDir = '/app/.next/server/chunks/ssr/';
if (fs.existsSync(ssrChunksDir)) {
  for (const f of fs.readdirSync(ssrChunksDir)) {
    if (f.endsWith('.js') && patchLoginChunk(ssrChunksDir + f)) patchedAny = true;
  }
}
if (!patchedAny) {
  console.log('PATCH 3 (login disclaimer) PATTERN NOT FOUND');
  process.exit(1);
}
