// DEFAULTS ONLY -- overwritten inside the container at startup by
// docker-entrypoint.d/10-runtime-config.sh, which renders it from env vars.
//
// Keeping this file in public/ means `npm run dev` works too, and the bundle
// never has to be rebuilt just because a URL changed.
window.__APP_CONFIG__ = {
  apiBaseUrl: '/api',
  appTitle: 'Docker Practice Shop (dev defaults)',
  builtAt: 'local-dev',
};
