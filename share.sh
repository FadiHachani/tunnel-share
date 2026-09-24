#!/usr/bin/env bash
#
# share.sh — Expose the UI + API to the internet through one Cloudflare tunnel.
#
#   UI    (vite preview) → :5173 → tunneled
#   API   (FastAPI)      → :8010 → local only, reached via the UI's /api proxy
#   Embed (optional)     → :8001
#
# Usage:
#   APP_PASSWORD="…" ./share.sh
#   SKIP_EMBED=1 APP_PASSWORD="…" ./share.sh   # skip the embedding server
#
# Share the printed *.trycloudflare.com URL with the password. Ctrl-C stops everything.

set -euo pipefail
cd "$(dirname "$0")"

CLOUDFLARED="${CLOUDFLARED:-$HOME/.local/bin/cloudflared}"
API_PORT="${API_PORT:-8010}"
UI_PORT="${UI_PORT:-5173}"
EMBED_PORT="${EMBED_PORT:-8001}"
NLP_PORT="${NLP_PORT:-8002}"

if [[ -z "${APP_PASSWORD:-}" ]]; then
  echo "⚠️  APP_PASSWORD is not set — the app would be PUBLIC with no login."
  echo "    Run like:  APP_PASSWORD='your-password' ./share.sh"
  exit 1
fi
if (( ${#APP_PASSWORD} < 12 )); then
  echo "⚠️  APP_PASSWORD is too short (${#APP_PASSWORD} chars) — use 12 or more."
  echo "    For a random one:  APP_PASSWORD=\"$(openssl rand -base64 18 2>/dev/null || echo '…')\" ./share.sh"
  exit 1
fi
export APP_PASSWORD

if [[ -f .env ]]; then set -a; source .env; set +a; fi

PIDS=()
cleanup() {
  echo ""
  echo "🧹 Shutting down…"
  for pid in "${PIDS[@]:-}"; do kill "$pid" 2>/dev/null || true; done
  wait 2>/dev/null || true
  echo "Done. App is no longer reachable from the internet."
}
trap cleanup EXIT INT TERM

port_busy() { (ss -ltn 2>/dev/null || netstat -ltn 2>/dev/null) | grep -q ":$1 "; }

# Wait for the public URL in cloudflared's log (skipping the internal api.trycloudflare.com).
wait_for_tunnel_url() {
  local logfile="$1" tries="${2:-15}" url=""
  while (( tries-- > 0 )); do
    url=$(grep -oE 'https://[a-zA-Z0-9]+(-[a-zA-Z0-9]+)+\.trycloudflare\.com' "$logfile" 2>/dev/null \
      | grep -v '^https://api\.trycloudflare\.com$' \
      | head -n1 || true)
    [[ -n "$url" ]] && { echo "$url"; return 0; }
    grep -q 'failed to parse quick Tunnel ID' "$logfile" 2>/dev/null && return 1
    sleep 1
  done
  return 1
}

# Quick tunnels fail intermittently on Cloudflare's side; retry with backoff.
start_tunnel() {
  local local_port="$1" logfile="$2" label="$3" attempt url
  for attempt in 1 2 3 4; do
    : > "$logfile"
    "$CLOUDFLARED" tunnel --url "http://127.0.0.1:$local_port" >"$logfile" 2>&1 &
    local pid=$!
    PIDS+=("$pid")
    if url=$(wait_for_tunnel_url "$logfile" 15); then
      echo "$url"
      return 0
    fi
    kill "$pid" 2>/dev/null || true
    echo "   ⚠️  $label tunnel attempt $attempt failed, retrying…" >&2
    sleep $(( attempt * 3 ))
  done
  return 1
}

if [[ ! -x "$CLOUDFLARED" ]]; then
  echo "❌ cloudflared not found at $CLOUDFLARED. Set CLOUDFLARED=/path/to/cloudflared."
  exit 1
fi

# ── 1. Embedding server (optional) ────────────────────────────
if [[ -z "${SKIP_EMBED:-}" ]]; then
  if port_busy "$EMBED_PORT"; then
    echo "🧠 Embedding server already on :$EMBED_PORT — reusing."
  else
    echo "🧠 Starting embedding server on :$EMBED_PORT (~45s)…"
    uvicorn embedding_server:app --port "$EMBED_PORT" >/tmp/embed_server.log 2>&1 &
    PIDS+=($!)
  fi
fi

# ── 1b. NLP server (optional, started separately) ─────────────
if port_busy "$NLP_PORT"; then
  echo "🗣️  NLP server detected on :$NLP_PORT."
else
  echo "🗣️  No NLP server on :$NLP_PORT — running without it."
fi

# ── 2. API ────────────────────────────────────────────────────
if port_busy "$API_PORT"; then
  echo "❌ Port $API_PORT is in use. Set API_PORT=… to pick another."
  exit 1
fi
echo "🔌 Starting API on :$API_PORT …"
uvicorn api.main:app --port "$API_PORT" >/tmp/insights_api.log 2>&1 &
PIDS+=($!)

sleep 2

# ── 3. UI — built app only, never the dev server ──────────────
if [[ ! -d web/node_modules ]]; then
  echo "📦 Installing web dependencies (first run)…"
  (cd web && npm install)
fi
echo "🏗️  Building UI…"
npm --prefix web run build >/tmp/vite_build.log 2>&1 || {
  echo "❌ UI build failed — see /tmp/vite_build.log"
  exit 1
}
echo "🚀 Starting UI on :$UI_PORT (API proxied at /api)…"
SHARE_MODE=1 API_PORT="$API_PORT" npm --prefix web run preview -- --port "$UI_PORT" --strictPort --host 127.0.0.1 \
  >/tmp/vite.log 2>&1 &
PIDS+=($!)

sleep 4

# ── 4. Tunnel ─────────────────────────────────────────────────
echo "🌍 Opening tunnel for the UI… (URL appears below)"
echo "────────────────────────────────────────────────────────"
UI_PUBLIC_URL="$(start_tunnel "$UI_PORT" /tmp/cloudflared_ui.log "UI")" || {
  echo "❌ Could not establish the UI tunnel after several attempts. Check /tmp/cloudflared_ui.log."
  exit 1
}

echo ""
echo "✅ Share this URL + the password: $UI_PUBLIC_URL"
echo "   Password: $APP_PASSWORD"
echo "   Logs  /tmp/vite.log  /tmp/insights_api.log  /tmp/embed_server.log  /tmp/cloudflared_ui.log"
echo "   Press Ctrl-C here to stop sharing."
wait
