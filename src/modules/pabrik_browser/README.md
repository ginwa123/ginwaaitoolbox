# Pabrik Browser

Anti-bot bypass scraping API using CloakBrowser - a stealth Chromium browser that bypasses Cloudflare Turnstile, reCAPTCHA v3, FingerprintJS, and other anti-bot detection systems.

## Features

- **Full JavaScript rendering** - Handles React, Vue, Angular, and other JS-heavy sites
- **Anti-bot bypass** - CloakBrowser uses real Chromium with 58 source-level patches
- **Human-like behavior** - Optional mouse/keyboard/scroll simulation
- **Proxy support** - Residential proxies with geoip/locale auto-detection
- **Screenshot capture** - Full page or viewport screenshots
- **Batch scraping** - Concurrent URL scraping with configurable parallelism

## Installation

```bash
bun install
```

## Running

```bash
# Default port 3000
bun run index.ts

# Custom port
bun run index.ts 8080
```

## API Endpoints

### Health Check

```
GET /health
```

Response:
```json
{
  "status": "ok",
  "service": "pabrik-browser",
  "version": "1.0.0",
  "timestamp": "2025-01-20T00:00:00.000Z"
}
```

### Scrape URL

```
POST /scrape
Content-Type: application/json

{
  "url": "https://example.com",
  "humanize": true,
  "proxy": "http://user:pass@proxy:8080",
  "geoip": true,
  "locale": "en-US",
  "timezone": "America/New_York",
  "waitForTimeout": 30000
}
```

Response:
```json
{
  "success": true,
  "url": "https://example.com/",
  "title": "Example Domain",
  "content": "Example DomainThis domain is for use...",
  "html": "<!DOCTYPE html>...",
  "metadata": {
    "status": 200,
    "contentType": "text/html",
    "userAgent": "Mozilla/5.0 (Windows NT 10.0; Win64; x64)...",
    "responseTime": 1321
  }
}
```

### Get Content by Selector

```
POST /content
Content-Type: application/json

{
  "url": "https://example.com",
  "selector": "h1, p",
  "humanize": true
}
```

### Screenshot

```
POST /screenshot
Content-Type: application/json

{
  "url": "https://example.com",
  "fullPage": false,
  "humanize": true
}
```

Response:
```json
{
  "success": true,
  "screenshot": "data:image/jpeg;base64,..."
}
```

### Search/Links

```
POST /search
Content-Type: application/json

{
  "url": "https://example.com",
  "selector": "a",        // optional CSS selector
  "maxResults": 20,       // optional, default 20
  "humanize": true
}
```

Response:
```json
{
  "success": true,
  "url": "https://example.com/",
  "results": ["https://iana.org/domains/example"]
}
```

### Batch Scrape

```
POST /batch
Content-Type: application/json

{
  "urls": ["https://example.com", "https://example.org"],
  "concurrency": 2
}
```

Response:
```json
{
  "success": true,
  "total": 2,
  "results": [...]
}
```

## CLI Usage

```bash
# Start server on port 3000
bun run index.ts 3000

# Scrape via curl
curl -X POST http://localhost:3000/scrape \
  -H "Content-Type: application/json" \
  -d '{"url": "https://example.com"}'
```

## Options

| Option | Type | Default | Description |
|--------|------|---------|-------------|
| `url` | string | required | URL to scrape |
| `humanize` | boolean | `true` | Enable human-like interactions |
| `proxy` | string | none | Proxy URL with credentials |
| `geoip` | boolean | `true` | Auto-detect timezone/locale from proxy IP |
| `locale` | string | `en-US` | Browser locale |
| `timezone` | string | auto | Browser timezone |
| `waitFor` | string | `networkidle` | Wait strategy: load, domcontentloaded, networkidle, commit |
| `waitForTimeout` | number | `30000` | Navigation timeout in ms |
| `fullPage` | boolean | `false` | Take full page screenshot |

## Notes

- Each request uses a fresh browser profile in `/tmp` for isolation
- Profiles are cleaned up after each request
- reCAPTCHA v3 scores are per-session - rotating IPs mid-session can lower scores
- CloakBrowser prevents CAPTCHAs from appearing, doesn't solve them
