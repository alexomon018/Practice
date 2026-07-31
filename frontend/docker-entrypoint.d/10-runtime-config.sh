#!/bin/sh
# ---------------------------------------------------------------------------
# Runtime configuration injection for a static frontend.
#
# WHY: a browser has no process.env. Bundlers substitute VITE_* variables at
# BUILD time, which bakes them into the image -- forcing a separate image per
# environment and breaking "build once, promote the same artifact".
#
# Instead we ship one env-agnostic bundle and write a tiny config.js here, at
# container start, from whatever environment variables were supplied.
#
# WHY THIS DIRECTORY: the official nginx image's entrypoint runs every
# executable *.sh in /docker-entrypoint.d/ (numerically ordered) before it
# execs nginx. So we get an init hook without overriding ENTRYPOINT ourselves.
# ---------------------------------------------------------------------------
set -eu

TARGET=/usr/share/nginx/html/config.js


API_BASE_URL="${API_BASE_URL:-/api}"
APP_TITLE="${APP_TITLE:-Docker Practice Shop}"
BUILT_AT="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

cat > "$TARGET" <<EOF
window.__APP_CONFIG__ = {
  apiBaseUrl: "${API_BASE_URL}",
  appTitle: "${APP_TITLE}",
  builtAt: "${BUILT_AT}"
};
EOF

# Goes to stdout, so `docker compose logs frontend` proves the injection ran
# and shows exactly which values landed. Never echo secrets here -- anything
# reaching the browser is public by definition, which is also why NO secret
# should ever be passed to a frontend container in the first place.
echo "[entrypoint] wrote $TARGET (apiBaseUrl=${API_BASE_URL}, appTitle=${APP_TITLE})"
