/// CloakBrowser Web Browsing Prompt
/// Stealth browser library for AI agents to browse the web
/// https://github.com/CloakHQ/CloakBrowser
pub const CloakBrowserPrompt =
    \\## Web Browsing with CloakBrowser
    \\
    \\CloakBrowser is a stealth Chromium browser that bypasses anti-bot detection (Cloudflare Turnstile, reCAPTCHA v3, FingerprintJS, etc.). It uses real Chromium with 58 source-level patches to modify fingerprints at compile time.
    \\
    \\### Installation
    \\
    \\npm install cloakbrowser playwright-core
    \\
    \\### Quick Start
    \\
    \\import launch from 'cloakbrowser';
    \\
    \\const browser = await launch({ headless: true, humanize: true });
    \\const page = await browser.newPage();
    \\await page.goto('https://example.com');
    \\console.log(await page.title());
    \\await browser.close();
    \\
    \\**IMPORTANT: Always use OS temp directory for browser data (profiles, cache, screenshots):**
    \\- **Linux/macOS:** `os.tmpdir()` or `/tmp/cloakbrowser`
    \\- **Windows:** `os.tmpdir()` or `C:\\Users\\<user>\\AppData\\Local\\Temp\\cloakbrowser`
    \\
    \\Example with temp profile:
    \\```javascript
    \\import { launchPersistentContext } from 'cloakbrowser';
    \\import os from 'os';
    \\import path from 'path';
    \\
    \\const tmpDir = os.tmpdir();
    \\const profilePath = path.join(tmpDir, 'cloakbrowser-profile');
    \\
    \\const ctx = await launchPersistentContext({
    \\  userDataDir: profilePath,
    \\  headless: true,
    \\  humanize: true,
    \\});
    \\```
    \\
    \\---
    \\
    \\## Core Browsing Actions
    \\
    \\### Navigation
    \\
    \\| Action | Code |
    \\|--------|------|
    \\| Open URL | await page.goto('https://url.com') |
    \\| Reload | await page.reload() |
    \\| Go back | await page.goBack() |
    \\| Go forward | await page.goForward() |
    \\| Wait for URL | await page.waitForURL('**/target/**') |
    \\
    \\### Clicking Elements
    \\
    \\| Action | Code |
    \\|--------|------|
    \\| Click selector | await page.click('button#submit') |
    \\| Click by text | await page.click('text=Submit') |
    \\| Double-click | await page.dblclick('.item') |
    \\| Right-click | await page.click('.item', { button: 'right' }) |
    \\
    \\### Form Input
    \\
    \\| Action | Code | Notes |
    \\|--------|------|-------|
    \\| Type with delay | await page.type('#input', 'text', { delay: 50 }) | PREFERRED - simulates real typing |
    \\| Fill directly | await page.fill('#input', 'text') | Bypasses keyboard events |
    \\| Press key | await page.press('#input', 'Enter') | Keys: Enter, Tab, Escape, etc. |
    \\| Select dropdown | await page.selectOption('#select', 'value') | |
    \\
    \\**Important:** Use page.type() with delay instead of page.fill() for better reCAPTCHA scores.
    \\
    \\### Scrolling
    \\
    \\await page.mouse.wheel(0, 300)  // Scroll down 300px
    \\await page.evaluate(() => window.scrollBy(0, 500))  // JS scroll
    \\
    \\### Content Extraction
    \\
    \\| Action | Code |
    \\|--------|------|
    \\| Page HTML | await page.content() |
    \\| Element text | await page.innerText('.selector') |
    \\| Element HTML | await page.innerHTML('.selector') |
    \\| Attribute | await page.getAttribute('.selector', 'href') |
    \\| Page title | await page.title() |
    \\| Current URL | await page.url() |
    \\
    \\### Waiting
    \\
    \\| Action | Code | Notes |
    \\|--------|------|-------|
    \\| Wait for element | await page.waitForSelector('.loader') | |
    \\| Wait for load state | await page.waitForLoadState('networkidle') | load, domcontentloaded, networkidle |
    \\| Sleep | await new Promise(r => setTimeout(r, 2000)) | USE THIS, not waitForTimeout |
    \\
    \\**Critical:** page.waitForTimeout() sends CDP signals detected by reCAPTCHA. Always use native setTimeout().
    \\
    \\### JavaScript Execution
    \\
    \\await page.evaluate(() => document.title)  // Execute JS, get result
    \\await page.evaluate(() => { /* complex logic */ })
    \\
    \\### Screenshots
    \\
    \\await page.screenshot()                              // As bytes
    \\await page.screenshot({ path: 'shot.png' })           // Save to file
    \\await page.screenshot({ fullPage: true })            // Full page
    \\
    \\---
    \\
    \\## Launch Options
    \\
    \\const browser = await launch({
    \\  headless: true,           // Headless mode (default: true)
    \\  proxy: 'http://user:pass@proxy:8080',  // Proxy server
    \\  geoip: true,              // Auto-detect timezone/locale from proxy IP
    \\  humanize: true,          // Human-like mouse/keyboard/scroll behavior
    \\  humanPreset: 'careful',  // 'default' or 'careful' (slower)
    \\  timezone: 'America/New_York',
    \\  locale: 'en-US',
    \\  stealthArgs: true,        // Include default stealth fingerprint args
    \\});
    \\
    \\### Proxy Configuration
    \\
    \\// String (credentials auto-extracted)
    \\proxy: 'http://user:pass@proxy:8080'
    \\proxy: 'socks5://proxy:1080'
    \\
    \\// Object
    \\proxy: { server: 'http://proxy:8080', bypass: '.google.com', username: 'user', password: 'pass' }
    \\
    \\### Persistent Context (stay logged in)
    \\
    \\const ctx = await launchPersistentContext({
    \\  userDataDir: './chrome-profile',
    \\  headless: false,
    \\  proxy: 'http://proxy:8080',
    \\});
    \\const page = ctx.pages()[0] || await ctx.newPage();
    \\await page.goto('https://example.com');
    \\await ctx.close();  // profile saved - reuse to restore state
    \\
    \\---
    \\
    \\## Humanize Mode
    \\
    \\Human-like interactions for aggressive anti-bot sites:
    \\
    \\const browser = await launch({ humanize: true });
    \\
    \\// Per-call override:
    \\await page.click(selector, { human_config: { mouse_steps_divisor: 12 } });
    \\
    \\### Key HumanConfig Parameters
    \\
    \\**Keyboard:**
    \\- typing_delay - ms between keystrokes (default: 70ms)
    \\- typing_delay_spread - variance (default: +-40ms)
    \\- typing_pause_chance - probability of pause mid-typing (default: 10%)
    \\- mistype_chance - typo simulation probability (default: 2%)
    \\
    \\**Mouse:**
    \\- mouse_steps_divisor - movement smoothness (higher = smoother, default: 8)
    \\- mouse_wobble_max - lateral deviation in pixels (default: 1.5px)
    \\- mouse_overshoot_chance - probability of overshooting target (default: 15%)
    \\
    \\**Clicks:**
    \\- click_aim_delay_input - aim time before clicking inputs (default: 60-140ms)
    \\- click_aim_delay_button - aim time before clicking buttons (default: 80-200ms)
    \\- click_hold_button - button press duration (default: 60-150ms)
    \\
    \\**Scroll:**
    \\- scroll_delta_base - scroll amount per tick (default: 80-130px)
    \\- scroll_overshoot_chance - probability of overshooting (default: 10%)
    \\
    \\---
    \\
    \\## Frame/iFrame Handling
    \\
    \\const frame = page.frame({ name: 'framename' });  // By name
    \\const frame = page.frame({ url: /iframe-url/ });   // By URL regex
    \\await frame.goto('https://example.com');
    \\await frame.click('.button');
    \\
    \\---
    \\
    \\## Dialog/Popup Handling
    \\
    \\page.on('dialog', async dialog => {
    \\  console.log(dialog.message());
    \\  await dialog.accept('input text');    // or dialog.dismiss()
    \\});
    \\
    \\---
    \\
    \\## Best Practices for AI Agent Browsing
    \\
    \\1. **Use page.type() with delay** instead of page.fill() for form inputs
    \\2. **Use native setTimeout()** instead of page.waitForTimeout()
    \\3. **Use residential proxies** - datacenter IPs are flagged by IP reputation
    \\4. **Enable geoip: true** when using proxies
    \\5. **Use humanize: true** for aggressive anti-bot sites
    \\6. **Spend 15+ seconds** on page before triggering reCAPTCHA
    \\7. **Space out requests** - wait 30+ seconds between reCAPTCHA-execute calls
    \\8. **Use persistent contexts** to warm up cookies
    \\9. **Use page.click()** over page.evaluate() for form interactions
    \\10. **Minimize page.evaluate() calls** before reCAPTCHA checks
    \\
    \\---
    \\
    \\## Environment Variables
    \\
    \\| Variable | Default | Description |
    \\|----------|---------|-------------|
    \\| CLOAKBROWSER_BINARY_PATH | - | Use local Chromium binary |
    \\| CLOAKBROWSER_CACHE_DIR | ~/.cloakbrowser | Binary cache directory |
    \\| CLOAKBROWSER_AUTO_UPDATE | true | Disable background update checks |
    \\| CLOAKBROWSER_BACKEND | playwright | Backend: playwright or patchright |
    \\
    \\---
    \\
    \\## Detection Test Results
    \\
    \\| Detection Service | Stock Browser | CloakBrowser |
    \\|-------------------|---------------|--------------|
    \\| reCAPTCHA v3 | 0.1 (bot) | **0.9** (human) |
    \\| Cloudflare Turnstile | FAIL | **PASS** |
    \\| FingerprintJS | DETECTED | **PASS** |
    \\| BrowserScan | DETECTED | **NORMAL (4/4)** |
    \\| navigator.webdriver | true | **false** |
    \\| CDP detection | Detected | **Not detected** |
    \\
    \\---
    \\
    \\## Key Limitations
    \\
    \\- **reCAPTCHA v3 scores are per-session** - rotating IPs mid-session can lower scores
    \\- **page.waitForTimeout() sends CDP traffic** - use native sleep instead
    \\- **Persistent context first visit** - some sites challenge first-time visitors; warm up cookies once, reuse
    \\- **No CAPTCHA solving** - CloakBrowser prevents CAPTCHAs from appearing, doesn't solve them
;
