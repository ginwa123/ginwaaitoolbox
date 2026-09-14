/**
 * Nalar browser window — the injected chrome bar.
 *
 * This file is embedded verbatim into `nalar-desktop` (see `webview_lib.zig`)
 * and handed to `webview_init`, so it runs in every document the browser
 * window loads, before the page's own scripts.
 *
 * Why an overlay bar and not a native one: a window holds exactly one engine
 * view (webview.h replaces the window's single child on every platform), so a
 * native bar would need a per-OS patch of the vendored container. The bar is
 * therefore part of the page's document: it can be covered or stripped by the
 * page — a documented, bounded wart. It is appended LAST and carries the
 * maximum z-index so it wins equal-z-index ties.
 *
 * Constraints this file must keep (the shell has no bindings in this window):
 *  * no inline script element, no eval, no network — its own styles and DOM
 *    APIs only, so a page's `script-src` / `style-src` CSP cannot break it;
 *  * nothing here may call into the shell (the browser window carries no
 *    bindings — see the plan's §3.2 invariant);
 *  * no timers: recovery is MutationObserver-driven, so an idle page costs
 *    exactly zero CPU. Once the removal budget is spent the observer
 *    disconnects and the bar stays gone.
 *
 * Navigation is one assignment (`location.href`) — the engine owns history,
 * cookies and the store, so there is nothing to persist here.
 */
(function () {
  'use strict'
  if (typeof document === 'undefined') return

  var BAR_ID = '__nalar_browser_chrome__'
  var ERROR_ID = '__nalar_browser_chrome_error__'
  var SEARCH_URL = 'https://www.google.com/search?q='
  var SCHEME_RE = /^[a-zA-Z][a-zA-Z0-9+.-]*:/
  /* Removals tolerated before the observer gives up: the 5th removal is the
   * last one we react to, so a hostile page's stripping costs bounded work. */
  var MAX_REMOVALS = 5

  var removals = 0
  var remountQueued = false
  var observer = null

  function style(el, props) {
    for (var key in props) {
      if (Object.prototype.hasOwnProperty.call(props, key)) el.style[key] = props[key]
    }
  }

  function isHttpUrl(text) {
    var head = text.slice(0, 8).toLowerCase()
    return head.indexOf('http://') === 0 || head.indexOf('https://') === 0
  }

  /**
   * Mirror of the tab body's `normalizeAddressInput` (helpers/browserUrl.ts):
   * the two address bars must agree on what a URL is.
   */
  function normalize(raw) {
    var text = String(raw == null ? '' : raw).replace(/^\s+|\s+$/g, '')
    if (text === '') return { ok: false, reason: 'Enter an address or a search term' }
    var match = SCHEME_RE.exec(text)
    if (match) {
      var scheme = match[0].slice(0, -1).toLowerCase()
      var rest = text.slice(match[0].length)
      // `localhost:5173` / `example.com:8080` are hosts, not schemes.
      var hostPort = scheme === 'localhost' || /^\d+([/?#]|$)/.test(rest)
      if (!hostPort) {
        if (isHttpUrl(text)) return { ok: true, url: text }
        return { ok: false, reason: scheme + ': URLs are not allowed here' }
      }
    }
    var beforeSlash = text.split('/')[0]
    if (
      beforeSlash === 'localhost' ||
      beforeSlash.indexOf('localhost:') === 0 ||
      beforeSlash.indexOf('.') !== -1
    ) {
      return { ok: true, url: 'https://' + text }
    }
    return { ok: true, url: SEARCH_URL + encodeURIComponent(text) }
  }

  function go(url) {
    try {
      location.href = url
    } catch (e) {
      /* A sandboxed / non-navigable context — nothing sensible to do. */
    }
  }

  function makeButton(label, title) {
    var button = document.createElement('button')
    button.type = 'button'
    button.textContent = label
    button.title = title
    style(button, {
      flex: '0 0 auto',
      width: '24px',
      height: '24px',
      padding: '0',
      border: '1px solid #282727',
      borderRadius: '4px',
      background: '#242320',
      color: '#c5c9c5',
      font: '13px/1 system-ui, sans-serif',
      cursor: 'pointer',
    })
    return button
  }

  function build() {
    var bar = document.createElement('div')
    bar.id = BAR_ID
    bar.setAttribute('data-nalar-browser-chrome', '')
    style(bar, {
      position: 'fixed',
      top: '0',
      left: '0',
      right: '0',
      height: '34px',
      boxSizing: 'border-box',
      zIndex: '2147483647',
      display: 'flex',
      alignItems: 'center',
      gap: '6px',
      padding: '0 8px',
      background: '#1d1c19',
      color: '#c5c9c5',
      borderBottom: '1px solid #282727',
      boxShadow: '0 1px 4px rgba(0, 0, 0, 0.45)',
      font: '12px/1.4 system-ui, -apple-system, "Segoe UI", Roboto, sans-serif',
    })

    var brand = document.createElement('span')
    brand.textContent = '\u25a4 Nalar'
    style(brand, { flex: '0 0 auto', opacity: '0.7', whiteSpace: 'nowrap' })

    var back = makeButton('\u2190', 'Back')
    var forward = makeButton('\u2192', 'Forward')
    var reload = makeButton('\u21bb', 'Reload')

    var input = document.createElement('input')
    input.type = 'text'
    input.spellcheck = false
    input.setAttribute('autocomplete', 'off')
    input.setAttribute('data-nalar-browser-chrome-address', '')
    input.value = String(location.href)
    style(input, {
      flex: '1 1 auto',
      minWidth: '0',
      height: '24px',
      padding: '0 8px',
      border: '1px solid #282727',
      borderRadius: '4px',
      background: '#141412',
      color: '#c5c9c5',
      font: '12px/1 system-ui, sans-serif',
      outline: 'none',
    })

    var error = document.createElement('span')
    error.id = ERROR_ID
    error.setAttribute('data-nalar-browser-chrome-error', '')
    style(error, {
      display: 'none',
      flex: '0 1 auto',
      maxWidth: '40%',
      overflow: 'hidden',
      textOverflow: 'ellipsis',
      whiteSpace: 'nowrap',
      color: '#e39a9a',
    })

    function showError(reason) {
      error.textContent = reason
      error.style.display = 'block'
    }

    function clearError() {
      error.textContent = ''
      error.style.display = 'none'
    }

    input.addEventListener('keydown', function (event) {
      if (event.key === 'Escape') {
        input.value = String(location.href)
        clearError()
        return
      }
      if (event.key !== 'Enter') {
        // Any other key means the user is editing: drop the stale reason.
        clearError()
        return
      }
      var result = normalize(input.value)
      if (!result.ok) {
        showError(result.reason)
        return
      }
      clearError()
      // Show where we are going even if the navigation itself is refused by
      // the surrounding context (devtools, a sandbox).
      input.value = result.url
      go(result.url)
    })

    back.addEventListener('click', function () {
      try {
        history.back()
      } catch (e) {
        /* see go() */
      }
    })
    forward.addEventListener('click', function () {
      try {
        history.forward()
      } catch (e) {
        /* see go() */
      }
    })
    reload.addEventListener('click', function () {
      try {
        location.reload()
      } catch (e) {
        /* see go() */
      }
    })

    bar.appendChild(brand)
    bar.appendChild(back)
    bar.appendChild(forward)
    bar.appendChild(reload)
    bar.appendChild(input)
    bar.appendChild(error)
    return bar
  }

  function mount() {
    var root = document.documentElement
    if (!root) return
    if (document.getElementById(BAR_ID)) return
    // Appended LAST: a document that re-adds nodes keeps the bar on top.
    root.appendChild(build())
  }

  function onMutation() {
    if (document.getElementById(BAR_ID)) return
    removals += 1
    if (removals >= MAX_REMOVALS) {
      if (observer) {
        observer.disconnect()
        observer = null
      }
      return
    }
    if (remountQueued) return
    // Coalesce a burst of mutations into one remount (still no timers).
    remountQueued = true
    queueMicrotask(function () {
      remountQueued = false
      mount()
    })
  }

  function startObserver() {
    if (typeof MutationObserver === 'undefined') return
    if (observer) return
    var root = document.documentElement
    if (!root) return
    observer = new MutationObserver(onMutation)
    observer.observe(root, { childList: true })
  }

  function start() {
    mount()
    startObserver()
  }

  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', start)
  } else {
    // Injected after the document started parsing (or re-injected by hand).
    start()
  }
})()
