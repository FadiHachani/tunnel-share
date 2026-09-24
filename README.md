# tunnel-share

Share a local web app (Vite frontend + any backend API) with anyone on the internet: one command, one URL, password-protected. Your machine stays the server. Nothing is deployed and no account is needed.

It uses [Cloudflare quick tunnels](https://developers.cloudflare.com/cloudflare-one/connections/connect-networks/do-more-with-tunnels/trycloudflare/) (`*.trycloudflare.com`), which are free and need no Cloudflare login.

```
Browser ──https──▶ Cloudflare ──tunnel──▶ vite preview (127.0.0.1:5173)
                                               │  /api/* proxied
                                               ▼
                                          your API (127.0.0.1:8010)
```

## Why this instead of just `cloudflared tunnel --url localhost:5173`?

Tunnelling `vite dev` directly is the common approach, and it's risky:

- **The dev server serves your raw source code** to anyone with the link, and it has had several [file-read vulnerabilities](https://github.com/vitejs/vite/security/advisories). This script tunnels **`vite preview`** instead, which serves only the compiled `dist/`.
- **Only one public URL.** The API binds to `127.0.0.1` and is reached only through the UI's `/api` proxy, so it's never exposed on its own and there's no CORS to set up.
- **A password is required.** The script refuses to start without `APP_PASSWORD` (12+ characters).
- **Security headers:** `nosniff`, `X-Frame-Options: DENY`, and `Referrer-Policy: no-referrer` so the tunnel URL doesn't leak to outside links.
- **Handles Cloudflare's flaky quick-tunnel creation** with retries and backoff.
- **Cleans up.** Ctrl-C kills every process and closes the tunnel.

## Requirements

- [`cloudflared`](https://developers.cloudflare.com/cloudflare-one/connections/connect-networks/downloads/) on your PATH (or set `CLOUDFLARED=/path/to/cloudflared`)
- Node + npm, and a Vite app (default folder: `web/`)
- Any backend that listens on `127.0.0.1:$API_PORT` (FastAPI, Express, Flask…)
- Linux or macOS (bash)

## Setup

### 1. Configure Vite

In `vite.config.ts`:

```ts
import { defineConfig } from 'vite'

const apiProxy = {
  '/api': {
    target: `http://127.0.0.1:${process.env.API_PORT ?? 8010}`,
    changeOrigin: true,
  },
}

export default defineConfig({
  server: { proxy: apiProxy },          // local dev (npm run dev)
  preview: {                            // what gets shared
    // The tunnel hostname is random each run, so it can't be allowlisted.
    // Only relaxed when share.sh sets SHARE_MODE.
    allowedHosts: process.env.SHARE_MODE ? true : undefined,
    proxy: apiProxy,
    headers: {
      'X-Content-Type-Options': 'nosniff',
      'X-Frame-Options': 'DENY',
      'Referrer-Policy': 'no-referrer',
    },
  },
})
```

Your frontend should call **relative** paths (`fetch('/api/…')`), not `http://localhost:8010/…`.

### 2. Make your API check the password

The script only sets the `APP_PASSWORD` environment variable. **Your API is what enforces it.** Reject any request that doesn't carry the password, for example in an `X-App-Password` header that your frontend sends after a login screen.

<details>
<summary>FastAPI example (with brute-force rate limiting)</summary>

```python
import hmac, os, time
from fastapi import FastAPI, Request
from fastapi.responses import JSONResponse

app = FastAPI()
APP_PASSWORD = os.environ.get("APP_PASSWORD", "")
MAX_FAILURES, WINDOW = 10, 15 * 60
failures: dict[str, list[float]] = {}

@app.middleware("http")
async def require_password(request: Request, call_next):
    if APP_PASSWORD and request.url.path.startswith("/api/") and request.method != "OPTIONS":
        # Behind the tunnel every request comes from 127.0.0.1;
        # Cloudflare sets the real client IP in CF-Connecting-IP.
        key = request.headers.get("cf-connecting-ip") or request.client.host
        now = time.monotonic()
        recent = [t for t in failures.get(key, []) if now - t < WINDOW]
        if len(recent) >= MAX_FAILURES:
            return JSONResponse({"detail": "Too many attempts"}, status_code=429)
        supplied = request.headers.get("x-app-password", "")
        if not hmac.compare_digest(supplied.encode(), APP_PASSWORD.encode()):
            failures[key] = recent + [now]
            return JSONResponse({"detail": "Password required"}, status_code=401)
        failures.pop(key, None)
    return await call_next(request)
```

</details>

### 3. Run it

```bash
chmod +x share.sh
APP_PASSWORD="$(openssl rand -base64 18)" ./share.sh
```

It builds the UI, starts the API and the preview server, opens the tunnel, and prints:

```
✅ Share this URL + the password: https://calm-river-early-dawn.trycloudflare.com
   Password: …
```

Send both to whoever needs access. Press **Ctrl-C** to stop sharing. The URL stops working right away, and each run gets a new one.

## Configuration

All settings are optional environment variables:

| Variable       | Default                                                   | What it does                              |
|----------------|-----------------------------------------------------------|-------------------------------------------|
| `APP_PASSWORD` | *(required, 12+ chars)*                                   | Password your API checks                  |
| `API_CMD`      | `uvicorn api.main:app --host 127.0.0.1 --port $API_PORT`  | Command that starts your backend          |
| `API_PORT`     | `8010`                                                    | Backend port (local only)                 |
| `UI_PORT`      | `5173`                                                    | Preview server port                       |
| `WEB_DIR`      | `web`                                                     | Folder containing the Vite app            |
| `CLOUDFLARED`  | found on PATH                                             | Path to the `cloudflared` binary          |
| `LOG_DIR`      | `$TMPDIR` or `/tmp`                                       | Where the four log files go               |

A `.env` file next to the script is loaded automatically, so your API sees its database URLs, keys and so on.

Examples:

```bash
# Node backend
API_CMD="node server.js" APP_PASSWORD="…" ./share.sh

# Frontend lives in ./frontend
WEB_DIR=frontend APP_PASSWORD="…" ./share.sh
```

## Security notes

- **The link alone isn't enough.** Anyone with the URL can load the page shell, but no data without the password, as long as your API enforces it (step 2).
- **Your machine is the server.** It has to stay on and connected while you share, and traffic goes through Cloudflare.
- Quick tunnels are for **demos and short-term sharing**, not production. For something long-lived, use a [named tunnel](https://developers.cloudflare.com/cloudflare-one/connections/connect-networks/get-started/) with [Cloudflare Access](https://developers.cloudflare.com/cloudflare-one/policies/access/) in front.
- **Never commit `.env`.** Add it to `.gitignore`.
- Consider hiding detailed error messages (stack traces, SQL) from API responses while sharing.

## Troubleshooting

| Symptom | Fix |
|---|---|
| `Blocked request. This host is not allowed` | `preview.allowedHosts` is missing from `vite.config.ts` (step 1) |
| Page loads but API calls fail | The frontend calls `localhost:…` instead of relative `/api/…`, or `preview.proxy` is missing |
| `failed to parse quick Tunnel ID` | A Cloudflare hiccup; the script retries automatically |
| `Port … is in use` | Something is already on that port; set `API_PORT` / `UI_PORT` |
| Build fails | See `share_build.log` in `$LOG_DIR` |

## License

MIT
