// src/apps/desktop_app/platform/macos/nalar_webview.mm
//
// Chunk 6: macOS implementation of the webview C ABI declared in
// shared/webview_c.h. The three `extern "C"` functions at the bottom of
// this file (nalar_webview_create / _run / _destroy) are linked directly
// into the nalar-desktop executable. The Zig side (webview.zig) declares
// matching `extern "c"` prototypes and calls them through a single API.
//
// Stack
// -----
//   * NSApplication (Cocoa) drives the event loop.
//   * NSWindow provides the chrome (title, size, close button).
//   * WKWebView (WebKit) renders the HTML/CSS/JS webapp.
//
// Asset interception
// ------------------
//   WKWebView gives us two interception hooks:
//     1. `decidePolicyForNavigationAction:` (a `WKNavigationDelegate`
//        method) — fires for top-level navigations (link clicks, address
//        bar, initial `loadRequest:`). We let non-app:// requests
//        through; app:// requests are answered inline by
//        `loadData:MIMEType:...`.
//     2. `WKURLSchemeHandler` — fires for subresource requests (fetch,
//        XHR, image/script/css load). WKWebView's navigation delegate
//        does NOT see subresource requests; a scheme handler is the
//        only way to intercept them.
//
//   We register an `app://` scheme handler that does both jobs:
//     * `app://localhost/index.html`, `app://localhost/assets/foo.js`,
//       etc. → look up the path in the asset table, return the bytes
//       with the correct MIME type.
//     * `app://localhost/api/...` → forward the request to the nalar
//       service over HTTP (the base URL comes from the C ABI config
//       as `api_proxy_base`). This lets the webview and the nalar API
//       live on different ports — the webview is served entirely off
//       the app:// scheme (no port), nalar is just the API on its own
//       port.
//
//   We keep the `decidePolicyForNavigationAction:` delegate method
//   around as a safety net (it answers the initial navigation, which
//   the scheme handler can also handle, but having both paths is
//   defensive).
//
// Memory model
// ------------
//   This file is compiled with `-ObjC++` (NOT `-fobjc-arc`), so we manage
//   reference counts manually with `retain` / `release` (the
//   "MRR" / manual retain-release model). `@property(retain)` is used
//   for owned objects, `@property(assign)` for borrowed pointers, and
//   `@property(copy)` for NSString* that the property should logically
//   own. The `dealloc` method explicitly releases owned properties.
//
//   IMPORTANT: the navigation delegate pattern creates a retain cycle —
//   webView retains delegate (via setNavigationDelegate:), delegate
//   retains webView (via _webView property). We break it in `dealloc` by
//   calling `setNavigationDelegate:nil` BEFORE releasing the webView.
//
// Why Objective-C++ and not pure C
// --------------------------------
//   The C ABI (webview_c.h) is plain C89, but the AppKit + WebKit APIs are
//   only available through Objective-C / Objective-C++. The `extern "C"`
//   block at the bottom of this file bridges the two worlds — the C ABI
//   callers (Zig) get plain C symbols, the implementation is Objective-C.
//
// The same header is copied to this directory (webview_c.h) so the .mm
// can `#include "webview_c.h"` without any -I search-path gymnastics —
// both files live in the same directory at compile time.

#import <Cocoa/Cocoa.h>
#import <WebKit/WebKit.h>
#import <string.h>
#import "webview_c.h"

// =============================================================================
// Raw-socket streaming proxy helpers
// =============================================================================
// `ProxyContext.performStreamingProxy` opens a TCP socket to the
// upstream nalar service and streams the response back to the
// webview. We use raw POSIX sockets (not NSURLSession) because
// NSURLSession's delegate-queue model proved unreliable in the
// WKURLSchemeHandler context — the session transitioned states but
// the delegate callbacks never fired, leaving the webview hung on
// the initial /api/events request.

#import <sys/socket.h>
#import <netinet/in.h>
#import <arpa/inet.h>
#import <netdb.h>
#import <unistd.h>

// Tiny RAII-ish helper: write all bytes or fail.
static int writeAll(int fd, const char* buf, size_t len) {
    size_t written = 0;
    while (written < len) {
        ssize_t n = write(fd, buf + written, len - written);
        if (n <= 0) return -1;
        written += (size_t)n;
    }
    return 0;
}

// Forward declaration for the WKURLSchemeHandler subclass. The full
// @interface (with method signatures and ivars) is here so the compiler
// can resolve `[[NalarSchemeHandler alloc] initWithAssets:count:proxyBase:]`
// calls in `applicationDidFinishLaunching:` below. The @implementation
// lives further down in the file, after NalarAppDelegate.
@interface NalarSchemeHandler : NSObject <WKURLSchemeHandler> {
@public
    // Borrowed from the parent delegate; valid for the webview's
    // lifetime (the Zig caller keeps the underlying C config alive
    // until after `nalar_webview_destroy`).
    const nalar_webview_asset* _assets;
    size_t _asset_count;
    NSString* _proxyBase;  // e.g. "http://127.0.0.1:8081" (retained)
    // Active proxy contexts (one per /api/* request currently in
    // flight). The handler needs this map because WebKit's
    // `stopURLSchemeTask:` callback is delivered to the SCHEME
    // HANDLER, not to the individual ProxyContext — we have to find
    // the matching ProxyContext by task identity so we can cancel
    // it (and any further calls to its WKURLSchemeTask become
    // invalid). The ProxyContext registers itself on creation and
    // unregisters on termination.
    NSMutableArray* _activeProxies;
}
- (instancetype)initWithAssets:(const nalar_webview_asset*)assets
                        count:(size_t)count
                    proxyBase:(NSString*)proxyBase;
@end

#pragma mark - Delegate

@interface NalarAppDelegate : NSObject <NSApplicationDelegate, WKNavigationDelegate>

// Borrowed by-value copy of the C config struct. The caller (Zig) keeps
// the original cfg alive for the webview's lifetime per the C ABI
// contract (defer nalar_webview_destroy). No retain/release needed.
@property(nonatomic, assign) nalar_webview_config config;

// URL to load at startup. `copy` so the NSString we set in create() is
// owned by the property (the original was autoreleased from
// +stringWithUTF8String:).
@property(nonatomic, copy) NSString* urlString;

// Borrowed pointer to the caller's asset table + count. Same lifetime
// contract as `config` — caller owns, we just read.
@property(nonatomic, assign) const nalar_webview_asset* assets;
@property(nonatomic, assign) size_t asset_count;

// Base URL to forward /api/* requests to. `copy` because the original
// C string is only valid for the duration of `nalar_webview_create`'s
// caller, but we need the URL for the entire webview lifetime
// (subresource requests can fire long after the call returns).
@property(nonatomic, copy) NSString* apiProxyBase;

// Owned by the delegate. Released in dealloc. `assign` for the window
// delegate is a retain cycle: window retains contentView (webView), so
// we MUST release them in dealloc.
@property(nonatomic, retain) NSWindow* window;
@property(nonatomic, retain) WKWebView* webView;

@end

@implementation NalarAppDelegate

@synthesize config = _config;
@synthesize urlString = _urlString;
@synthesize assets = _assets;
@synthesize asset_count = _asset_count;
@synthesize apiProxyBase = _apiProxyBase;
@synthesize window = _window;
@synthesize webView = _webView;

- (void)applicationDidFinishLaunching:(NSNotification*)notification {
    (void)notification;

    // ---- Window ----
    // Center the window on the main screen. A bare Mach-O executable
    // launched from a terminal is treated by the WindowServer as a
    // background process; the default frame origin (0,0) on whatever
    // screen is "active" can land off-screen on multi-monitor setups
    // or be hidden behind other apps' windows. Centering on the
    // main screen's visible frame is the safest default.
    NSScreen* mainScreen = [NSScreen mainScreen];
    NSRect screenFrame = [mainScreen visibleFrame];
    NSRect frame = NSMakeRect(
        screenFrame.origin.x + (screenFrame.size.width  - _config.width)  / 2,
        screenFrame.origin.y + (screenFrame.size.height - _config.height) / 2,
        _config.width,
        _config.height);

    NSWindowStyleMask style = NSWindowStyleMaskTitled | NSWindowStyleMaskClosable;
    if (_config.resizable)   style |= NSWindowStyleMaskResizable;
    if (_config.minimizable) style |= NSWindowStyleMaskMiniaturizable;

    _window = [[NSWindow alloc] initWithContentRect:frame
                                          styleMask:style
                                            backing:NSBackingStoreBuffered
                                              defer:NO];
    // setReleasedWhenClosed:NO — we own the window and release it in
    // dealloc. Default YES would autorelease on close, racing with the
    // explicit release below.
    [_window setReleasedWhenClosed:NO];
    // Note: NSWindow does NOT have a `setScreen:` method (it's on
    // NSView, not NSWindow). The window's screen is determined by
    // the screen that contains its frame — centering the frame on
    // `[NSScreen mainScreen].visibleFrame` puts the window on the
    // main display automatically. Don't add `setScreen:` here; it
    // throws an unrecognized-selector exception that aborts the
    // rest of applicationDidFinishLaunching: and the window never
    // gets shown.

    NSString* title = (_config.title != NULL)
        ? [NSString stringWithUTF8String:_config.title]
        : @"Nalar";
    [_window setTitle:title];

    if (_config.min_width > 0 && _config.min_height > 0) {
        [_window setMinSize:NSMakeSize(_config.min_width, _config.min_height)];
    }

    // ---- WKWebView ----
    // WKWebViewConfiguration is a config object — we autorelease it
    // after passing to the WKWebView. The WKWebView retains its
    // configuration internally, so we don't need to store it.
    WKWebViewConfiguration* wkconfig = [[[WKWebViewConfiguration alloc] init] autorelease];

    // Allow the webapp's JS `paste` event handler to read image bytes
    // from the system clipboard. WKWebView's default on macOS has been
    // tightening over recent releases — explicitly opting in matches
    // Chrome's permissive behavior so the same webapp code works
    // without #ifdef'ing the frontend. The webapp here is the user's
    // own embedded assets, not arbitrary third-party content, so this
    // is a safe enable.
    // javaScriptCanAccessClipboard was deprecated in macOS 14 (Sonoma)
    // and removed in macOS 15 (Sequoia). The replacement is to use the
    // WKWebViewConfiguration-defaults plus an info.plist entry
    // (NSPrincipalClass = NSApplication), which is what every other
    // Chromium / Electron-based desktop webview does today. For the
    // nalar-desktop app the permission is moot — there's no user
    // clipboard interaction in the embedded webapp — so we just drop
    // the call. The webapp itself uses web Clipboard API for paste.
    // (Keeping this commented to document the API history.)
    // wkconfig.preferences.javaScriptCanAccessClipboard = YES;

    // Developer extras ("Inspect Element" in the right-click menu, plus
    // the full Web Inspector via Safari → Develop → [this page]) are
    // gated by `WKPreferences.developerExtrasEnabled`. The property is
    // NOT exposed in Apple's public WKPreferences.h header — it's
    // available via KVC only. KVC has been the de-facto public API for
    // this since WKWebView shipped (and is what every Chromium / Electron
    // fork on macOS uses to toggle DevTools). We honor the
    // `enable_developer_extras` field from the C ABI so `--devtools`
    // works the same on macOS as on Linux (where WebKitGTK exposes the
    // equivalent via `webkit_settings_set_enable_developer_extras`).
    //
    // Note: this also enables the "Inspect Element" right-click menu
    // item automatically. WebKit hides that menu item when developer
    // extras are off.
    if (_config.enable_developer_extras) {
        [wkconfig.preferences setValue:@YES forKey:@"developerExtrasEnabled"];
    } else {
        // Explicitly disable to defeat any inherited default (e.g. a
        // user-defaults override or an Info.plist WebKitDeveloperExtras
        // entry). Without the NO, devtools could "leak" across runs.
        [wkconfig.preferences setValue:@NO forKey:@"developerExtrasEnabled"];
    }

    // Register the app:// scheme handler. This intercepts SUBRESOURCE
    // requests (fetch, XHR, image/script/css loads) — the navigation
    // delegate below only sees top-level navigations. The handler
    // serves assets from the table for non-/api/ paths and proxies
    // /api/* requests to the nalar service.
    //
    // The handler is owned by the WKWebView's configuration (WKWebView
    // retains it via setURLSchemeHandler:forURLScheme:), so we don't
    // need to keep a reference ourselves. It outlives the webview.
    NalarSchemeHandler* schemeHandler = [[[NalarSchemeHandler alloc]
        initWithAssets:_assets
                count:_asset_count
            proxyBase:_apiProxyBase] autorelease];
    [wkconfig setURLSchemeHandler:schemeHandler forURLScheme:@"app"];

    _webView = [[WKWebView alloc] initWithFrame:frame configuration:wkconfig];
    [_webView setNavigationDelegate:self];

    // The WKWebView IS the window's content view. This is the
    // simplest layout (no NSScrollView wrapper needed — the webview
    // scrolls internally). The webview's autoresizing-mask defaults
    // to `NSViewWidthSizable | NSViewHeightSizable` so it tracks
    // window resize automatically.
    [_window setContentView:_webView];
    // Show the window. For command-line-launched apps, `makeKeyAndOrderFront:`
    // followed by `orderFrontRegardless` is the most reliable pair —
    // `makeKeyAndOrderFront` can no-op if the app isn't yet activated,
    // and `orderFrontRegardless` brings the window to the front
    // regardless of the current app activation state.
    [_window makeKeyAndOrderFront:nil];
    [_window orderFrontRegardless];

    // ---- Initial navigation ----
    // We load `app://localhost/index.html` directly. The scheme handler
    // (registered below) serves the entrypoint from the asset table.
    // Loading via `loadRequest:` instead of `loadData:` means the
    // browser can navigate to other in-app URLs (e.g. SPA route
    // changes) through the same scheme handler.
    NSURL* initialURL = [NSURL URLWithString:_urlString];
    if (initialURL != nil) {
        NSURLRequest* req = [NSURLRequest requestWithURL:initialURL];
        [_webView loadRequest:req];
    } else {
        NSLog(@"nalar_webview: invalid URL string '%@', skipping initial load", _urlString);
    }
}

- (BOOL)applicationShouldTerminateAfterLastWindowClosed:(NSApplication*)sender {
    (void)sender;
    // When the user closes the window, the app should quit. This makes
    // [NSApp run] return, which unblocks nalar_webview_run on the Zig
    // side, which then calls nalar_webview_destroy.
    return YES;
}

#pragma mark - WKNavigationDelegate

// Fires for every TOP-LEVEL navigation (initial load, link click,
// redirect). The WKURLSchemeHandler registered above handles
// subresource requests (fetch, XHR, image/script/css); this delegate
// is the fallback for navigations the handler can't see. For an
// `app://` URL we just allow the navigation through — the scheme
// handler will service the request when WebKit routes it there.
// For non-app:// URLs we also allow through (external links, etc.).
- (void)webView:(WKWebView*)webView
    decidePolicyForNavigationAction:(WKNavigationAction*)navigationAction
    decisionHandler:(void (^)(WKNavigationActionPolicy))decisionHandler {
    (void)webView;
    (void)navigationAction;
    decisionHandler(WKNavigationActionPolicyAllow);
}

#pragma mark - Cleanup

- (void)dealloc {
    // Break the navigation-delegate retain cycle BEFORE releasing the
    // webView. Without this, the delegate would be retained by the
    // webView, the webView would be retained by us, and `release` in
    // nalar_webview_destroy would never reach zero.
    [_webView setNavigationDelegate:nil];
    [_webView release];
    _webView = nil;

    [_window release];
    _window = nil;

    [_urlString release];
    _urlString = nil;

    [super dealloc];
}

@end // NalarAppDelegate

#pragma mark - WKURLSchemeHandler (app://)
//
// `WKURLSchemeHandler` is the only mechanism that intercepts
// SUBRESOURCE requests (fetch, XHR, image/script/css loads). The
// `WKNavigationDelegate.decidePolicyForNavigationAction:` hook
// below only sees TOP-LEVEL navigations. Without a scheme handler
// registered for `app`, the webview's JS `fetch('/api/...')` would
// go to `app://localhost/api/...` and WebKit would refuse to load
// it (no scheme handler → 404 with no error message).
//
// Our handler does two things:
//   1. `app://localhost/api/<path>` → forward to the nalar service
//      over HTTP (the base URL is the `api_proxy_base` config field).
//      Lets the webapp use relative `/api/...` URLs without CORS.
//   2. `app://localhost/<asset-path>` → look up the path in the
//      in-memory asset table, return the bytes with the right MIME.
//
// We register a separate `NalarSchemeHandler` instance per
// webview (it captures the asset table + proxy base in its ivars).
//
// API proxy state machine
// ----------------------
// The proxy uses an `NSURLConnection` async delegate to forward
// upstream responses. For SSE streams (Content-Type:
// text/event-stream), the connection never finishes — each chunk
// is forwarded to the webview as it arrives from upstream, and
// the WKURLSchemeTask is `didFinish`d only when the upstream
// disconnects (or the webview cancels via `stopURLSchemeTask:`).
//
// The delegate methods (NSURLConnectionDelegate) run on a private
// background queue owned by NSURLConnection. WKURLSchemeTask
// callbacks MUST run on the main thread, so each delegate method
// dispatches the WebKit call via `dispatch_async` to the main
// queue. Lifetime is managed by the `ProxyContext` — it owns a
// strong reference to itself until the connection terminates
// (`connectionDidFinishLoading:` or `didFailWithError:`), then
// releases.
@interface ProxyContext : NSObject <NSURLSessionDataDelegate> {
@public
    id<WKURLSchemeTask> _task;
    NSURLRequest* _request;
    NalarSchemeHandler* _handler;  // strong; held until the connection ends
    NSHTTPURLResponse* _response;
    NSURLSession* _session;
    NSURLSessionDataTask* _dataTask;
    BOOL _didSendResponse;
    BOOL _didFinish;
    BOOL _cancelled;  // set by stopURLSchemeTask: — skip all WKURLSchemeTask calls
}
- (instancetype)initWithTask:(id<WKURLSchemeTask>)task
                     request:(NSURLRequest*)request;
- (void)cancel;  // called by stopURLSchemeTask:
@end

@implementation ProxyContext

- (instancetype)initWithTask:(id<WKURLSchemeTask>)task
                     request:(NSURLRequest*)request {
    self = [super init];
    if (self) {
        _task = task;
        _request = [request retain];
        _handler = nil;  // set by caller after init
        _response = nil;
        _session = nil;
        _dataTask = nil;
        _didSendResponse = NO;
        _didFinish = NO;
        _cancelled = NO;
    }
    return self;
}

- (void)dealloc {
    [_request release];
    [_response release];
    [_handler release];
    [_session release];
    [super dealloc];
}

// Common teardown — sends `didFinish` to the webview (if not already),
// cancels the in-flight NSURLSession data task, and balances the
// self-retain we did in `proxyApiRequest:`.
- (void)terminate {
    if (_didFinish) return;
    _didFinish = YES;
    // Unregister from the handler's active-proxies list. We do this
    // under @synchronized to interlock with stopURLSchemeTask:'s
    // linear scan. `removeObjectIdenticalTo:` (the O(1) isEqual:
    // variant) is cheaper than indexOfObject: and avoids the
    // per-element isEqual: dispatch that crashed in the previous
    // build — NSArray's indexOfObject: calls objc_retain on each
    // element for the isEqual: call, and on a deallocating context
    // that retain segfaults.
    if (_handler != nil) {
        @synchronized (_handler) {
            [_handler->_activeProxies removeObjectIdenticalTo:self];
        }
    }
    if (_dataTask != nil) {
        [_dataTask cancel];
        _dataTask = nil;
    }
    if (_session != nil) {
        [_session finishTasksAndInvalidate];
        _session = nil;
    }
    // Send didFinish on the main queue. CRITICAL: the block captures
    // `strongSelf` (the ProxyContext), not the raw `task` pointer.
    // The ProxyContext holds the only strong ref to the task in
    // `_task`. If we captured the task directly, Block_copy would
    // retain it — but if WebKit has already cancelled + released
    // the task by the time the block is copied, the task's release
    // path segfaults with EXC_BAD_ACCESS. Capturing the ProxyContext
    // (which is always alive) and dereferencing self->_task inside
    // the block avoids the race: stopURLSchemeTask: nils _task
    // BEFORE the upstream disconnects, so the block reads nil and
    // no-ops. We also explicitly retain the task into a local so
    // Block_copy has a strong ref to bump (defense-in-depth — even
    // if WebKit's internal lifecycle somehow invalidates _task
    // without zeroing it, our local still has a retain).
    ProxyContext* strongSelf = self;
    id<WKURLSchemeTask> task = [_task retain];  // local strong ref
    strongSelf->_task = nil;
    dispatch_async(dispatch_get_main_queue(), ^{
        // Skip if stopURLSchemeTask: already cancelled the proxy. Even
        // though we read task from a local retain, the task may have
        // been finalized by WebKit and any call to it throws
        // NSInternalInconsistencyException ("No response has been
        // sent for this task" or "task is no longer valid"). The
        // _cancelled flag is the only safe signal we have.
        if (strongSelf->_cancelled || task == nil) {
            [task release];
            return;
        }
        @try {
            [task didFinish];
        } @catch (NSException* e) {
            NSLog(@"nalar_webview: ignored didFinish exception: %@", e);
        }
        [task release];  // balance the local retain
    });
    // Balance the [ctx retain] in proxyApiRequest:. The dispatched
    // block above holds a strong ref to strongSelf via the captured
    // `task` ivar (no — we only captured task, not self). Hmm —
    // actually the block doesn't capture self at all, so the
    // ProxyContext is only held by the original [ctx retain] in
    // proxyApiRequest:. After this release, the ProxyContext
    // dealloc's (releasing _task which we already nilled).
    [self release];
}

- (void)cancel {
    [self terminate];
}

// NSURLSessionDataDelegate methods (run on a background queue owned
// by the session). Each one dispatches the WebKit call to the main
// thread — WKURLSchemeTask callbacks MUST be on the main thread.
- (void)URLSession:(NSURLSession*)session
          dataTask:(NSURLSessionDataTask*)dataTask
didReceiveResponse:(NSURLResponse*)response
 completionHandler:(void (^)(NSURLSessionResponseDisposition))completionHandler {
    _response = [(NSHTTPURLResponse*)response retain];
    ProxyContext* strongSelf = self;
    NSHTTPURLResponse* resp = _response;
    dispatch_async(dispatch_get_main_queue(), ^{
        id<WKURLSchemeTask> task = strongSelf->_task;
        if (task != nil) {
            [task didReceiveResponse:resp];
        }
    });
    _didSendResponse = YES;
    completionHandler(NSURLSessionResponseAllow);
}

- (void)URLSession:(NSURLSession*)session
          dataTask:(NSURLSessionDataTask*)dataTask
    didReceiveData:(NSData*)data {
    if (!_didSendResponse) return;  // safety: response must come first
    NSData* chunk = [data retain];
    ProxyContext* strongSelf = self;
    dispatch_async(dispatch_get_main_queue(), ^{
        id<WKURLSchemeTask> task = strongSelf->_task;
        if (task != nil) {
            [task didReceiveData:chunk];
        }
        [chunk release];
    });
}

- (void)URLSession:(NSURLSession*)session
              task:(NSURLSessionTask*)task
didCompleteWithError:(NSError*)error {
    if (error != nil) {
        // Forward the error to the webview. If we already sent the
        // response (e.g. SSE: upstream disconnected mid-stream),
        // we can only close the task; otherwise we send a 502.
        ProxyContext* strongSelf = self;
        const char* msg = [[error localizedDescription] UTF8String];
        dispatch_async(dispatch_get_main_queue(), ^{
            id<WKURLSchemeTask> wvTask = strongSelf->_task;
            if (wvTask == nil) return;
            if (strongSelf->_didSendResponse) {
                [wvTask didFinish];
            } else {
                NSData* body = [NSData dataWithBytes:msg length:strlen(msg)];
                NSDictionary* headers = @{
                    @"Content-Type": @"text/plain; charset=utf-8",
                    @"Content-Length": [NSString stringWithFormat:@"%lu", (unsigned long)body.length],
                };
                NSHTTPURLResponse* resp = [[NSHTTPURLResponse alloc]
                    initWithURL:wvTask.request.URL
                    statusCode:502
                    HTTPVersion:@"HTTP/1.1"
                    headerFields:headers];
                [wvTask didReceiveResponse:resp];
                [resp release];
                [wvTask didReceiveData:body];
                [wvTask didFinish];
            }
        });
    }
    [self terminate];
}

// Streaming HTTP proxy via raw POSIX socket. NSURLSession's
// delegate-queue model proved unreliable for forwarding SSE
// chunks to the webview (delegate methods were never called in
// the WKURLSchemeHandler context, despite the task transitioning
// states). The raw-socket approach is dead simple:
//
//   1. Open TCP socket to upstream host:port.
//   2. Send the HTTP request manually (method, path, headers).
//   3. Read the response status line + headers, then loop on
//      the body. For each chunk, dispatch_async to the main
//      thread to call didReceiveData. The response headers are
//      forwarded exactly once via didReceiveResponse.
//
// This avoids:
//   - NSURLSession's internal scheduling
//   - The main-thread-blocking-semaphore vs background-callback
//     deadlock class
//   - Per-delegate protocol setup (we just have one worker thread)
//
// The worker's lifetime is tied to ProxyContext: it exits when the
// socket closes (upstream EOF or our cancel), and calls
// `terminate` to clean up.
- (void)performStreamingProxy {
    @autoreleasepool {
        NSURL* url = _request.URL;
        if (url == nil || url.host == nil) {
            [self sendProxyError:"bad upstream URL"];
            return;
        }
        const char* host = [[url host] UTF8String];
        int port = (int)[[url port] integerValue];
        if (port == 0) port = (int)([url.scheme isEqualToString:@"https"] ? 443 : 80);

        // ---- Open the socket ----
        int fd = socket(AF_INET, SOCK_STREAM, 0);
        if (fd < 0) {
            [self sendProxyError:"socket() failed"];
            return;
        }
        // 1s connect timeout via SO_SNDTIMEO is hard; just use a
        // blocking connect and let the user retry on failure.
        struct sockaddr_in addr;
        memset(&addr, 0, sizeof(addr));
        addr.sin_family = AF_INET;
        addr.sin_port = htons((uint16_t)port);
        // Resolve hostname (literal IP or DNS). We use inet_pton
        // for the common case (127.0.0.1) and fall back to
        // getaddrinfo for DNS names. For the desktop's typical
        // upstream (127.0.0.1) inet_pton is sufficient.
        if (inet_pton(AF_INET, host, &addr.sin_addr) != 1) {
            struct addrinfo hints;
            memset(&hints, 0, sizeof(hints));
            struct addrinfo* res = NULL;
            hints.ai_family = AF_INET;
            hints.ai_socktype = SOCK_STREAM;
            char port_str[8];
            snprintf(port_str, sizeof(port_str), "%d", port);
            int rc = getaddrinfo(host, port_str, &hints, &res);
            if (rc != 0 || res == NULL) {
                close(fd);
                [self sendProxyError:"getaddrinfo failed"];
                return;
            }
            addr.sin_addr = ((struct sockaddr_in*)res->ai_addr)->sin_addr;
            freeaddrinfo(res);
        }
        if (connect(fd, (struct sockaddr*)&addr, sizeof(addr)) < 0) {
            close(fd);
            [self sendProxyError:"connect() failed"];
            return;
        }

        // ---- Send the HTTP request line + headers ----
        NSString* pathAndQuery = url.path ?: @"/";
        if (url.query != nil) {
            pathAndQuery = [pathAndQuery stringByAppendingFormat:@"?%@", url.query];
        }
        NSString* method = _request.HTTPMethod ?: @"GET";
        NSString* reqLine = [NSString stringWithFormat:@"%@ %@ HTTP/1.1\r\n", method, pathAndQuery];
        const char* reqLineZ = [reqLine UTF8String];
        writeAll(fd, reqLineZ, strlen(reqLineZ));

        // Forward a minimal set of headers: Host, Connection: close
        // (so the upstream EOFs when done — works for normal
        // responses; SSE upstream ignores Connection).
        NSString* hostHeader = [NSString stringWithFormat:@"Host: %@\r\n", url.host];
        const char* hh = [hostHeader UTF8String];
        writeAll(fd, hh, strlen(hh));
        const char* cc = "Connection: close\r\n";
        writeAll(fd, cc, strlen(cc));
        const char* ua = "User-Agent: nalar-desktop/1.0\r\n";
        writeAll(fd, ua, strlen(ua));
        // Forward Content-Type + Content-Length for non-GET bodies.
        NSString* ct = [_request valueForHTTPHeaderField:@"Content-Type"];
        NSData* body = _request.HTTPBody;
        if (ct != nil && body != nil) {
            char buf[128];
            int n = snprintf(buf, sizeof(buf), "Content-Length: %lu\r\n",
                (unsigned long)body.length);
            writeAll(fd, buf, n);
            const char* ctLine = [[NSString stringWithFormat:@"Content-Type: %@\r\n", ct] UTF8String];
            writeAll(fd, ctLine, strlen(ctLine));
        }
        const char* crlf = "\r\n";
        writeAll(fd, crlf, 2);
        if (body != nil && body.length > 0) {
            writeAll(fd, (const char*)body.bytes, body.length);
        }

        // ---- Read the response ----
        // Read the status line: "HTTP/1.x NNN ..." then headers until
        // \r\n\r\n, then the body.
        NSMutableData* headerBuf = [NSMutableData dataWithCapacity:4096];
        char rawBuf[4096];
        ssize_t n;
        while ((n = read(fd, rawBuf, sizeof(rawBuf))) > 0) {
            [headerBuf appendBytes:rawBuf length:(NSUInteger)n];
            // Look for end of headers.
            const uint8_t* bytes = (const uint8_t*)headerBuf.bytes;
            NSUInteger len = headerBuf.length;
            if (len >= 4) {
                for (NSUInteger i = 0; i + 3 < len; i++) {
                    if (bytes[i] == '\r' && bytes[i+1] == '\n' &&
                        bytes[i+2] == '\r' && bytes[i+3] == '\n') {
                        // Parse the headers.
                        NSData* headerData = [[NSData dataWithBytes:bytes length:i] retain];
                        NSData* bodyData = [[NSData dataWithBytes:bytes + i + 4
                                                           length:len - i - 4] retain];
                        [self handleResponseHeaders:headerData
                                          prefixBody:bodyData
                                                fromFd:fd];
                        [headerData release];
                        [bodyData release];
                        return;
                    }
                }
            }
        }
        // If we get here, the connection closed before we saw full headers.
        close(fd);
        if (!_didSendResponse) {
            [self sendProxyError:"upstream closed before headers"];
        } else {
            [self terminate];
        }
    }
}

// Forward headers + start of body to the webview, then continue
// reading the body in a loop and forwarding chunks until EOF.
- (void)handleResponseHeaders:(NSData*)headerData
                  prefixBody:(NSData*)prefixBody
                        fromFd:(int)fd {
    NSString* headerStr = [[[NSString alloc] initWithData:headerData encoding:NSASCIIStringEncoding] autorelease];
    if (headerStr == nil) {
        close(fd);
        [self sendProxyError:"upstream sent non-ASCII headers"];
        return;
    }
    NSArray* lines = [headerStr componentsSeparatedByString:@"\r\n"];
    if ([lines count] == 0) {
        close(fd);
        [self sendProxyError:"empty upstream response"];
        return;
    }
    // Status line: "HTTP/1.x NNN <text>"
    NSString* statusLine = lines[0];
    NSInteger statusCode = 502;
    NSDictionary* headers = [NSMutableDictionary dictionary];
    NSArray* statusParts = [statusLine componentsSeparatedByString:@" "];
    if ([statusParts count] >= 2) {
        statusCode = [statusParts[1] integerValue];
    }
    for (NSUInteger i = 1; i < [lines count]; i++) {
        NSString* line = lines[i];
        if ([line length] == 0) continue;
        NSRange colon = [line rangeOfString:@":"];
        if (colon.location == NSNotFound) continue;
        NSString* k = [[line substringToIndex:colon.location]
            lowercaseString];
        NSString* v = [[line substringFromIndex:colon.location + 1]
            stringByTrimmingCharactersInSet:
                [NSCharacterSet whitespaceCharacterSet]];
        [headers setValue:v forKey:k];
    }
    NSLog(@"nalar_webview API proxy: upstream status=%ld ct=%@",
        (long)statusCode, headers[@"content-type"]);
    // CRITICAL: capture `self` (the ProxyContext), not the raw task.
    // The task pointer can become dangling after WebKit cancels the
    // scheme task; capturing it directly causes Block_copy to crash
    // inside the task's release path. Self is always alive (this
    // method is being called on it). Access _task inside the block
    // so we read the current value at dispatch time.
    ProxyContext* strongSelf = self;
    NSHTTPURLResponse* resp = [[NSHTTPURLResponse alloc]
        initWithURL:_request.URL
        statusCode:(NSInteger)statusCode
        HTTPVersion:@"HTTP/1.1"
        headerFields:headers];
    dispatch_async(dispatch_get_main_queue(), ^{
        id<WKURLSchemeTask> task = strongSelf->_task;
        if (task != nil) {
            [task didReceiveResponse:resp];
        }
    });
    [resp release];
    _didSendResponse = YES;

    // Forward the prefix body if any.
    if (prefixBody.length > 0) {
        NSData* chunk = [prefixBody retain];
        // Capture self, not `task` — see the comment in -terminate
        // for why direct task capture is unsafe (Block_copy on a
        // dangling task pointer segfaults).
        ProxyContext* strongSelf = self;
        dispatch_async(dispatch_get_main_queue(), ^{
            id<WKURLSchemeTask> task = strongSelf->_task;
            if (task != nil) {
                [task didReceiveData:chunk];
            }
            [chunk release];
        });
    }

    // Continue reading the body. For SSE this loops forever; for
    // normal responses it exits when the upstream closes (we sent
    // Connection: close above) or read() returns 0/negative.
    char readBuf[8192];
    ssize_t n;
    while ((n = read(fd, readBuf, sizeof(readBuf))) > 0) {
        NSData* chunk = [[NSData dataWithBytes:readBuf length:(NSUInteger)n] retain];
        ProxyContext* strongSelf = self;
        dispatch_async(dispatch_get_main_queue(), ^{
            id<WKURLSchemeTask> task = strongSelf->_task;
            if (task != nil) {
                [task didReceiveData:chunk];
            }
            [chunk release];
        });
    }
    close(fd);
    [self terminate];
}

- (void)sendProxyError:(const char*)message {
    NSLog(@"nalar_webview API proxy error: %s", message);
    if (_didSendResponse) {
        [self terminate];
        return;
    }
    NSData* body = [NSData dataWithBytes:message length:strlen(message)];
    NSDictionary* headers = @{
        @"Content-Type": @"text/plain; charset=utf-8",
        @"Content-Length": [NSString stringWithFormat:@"%lu", (unsigned long)body.length],
    };
    NSHTTPURLResponse* resp = [[NSHTTPURLResponse alloc]
        initWithURL:_request.URL
        statusCode:502
        HTTPVersion:@"HTTP/1.1"
        headerFields:headers];
    // Capture self, not the task — see -terminate for why direct
    // task capture is unsafe (the task can be cancelled by the webview
    // and its release path crashes inside Block_copy).
    ProxyContext* strongSelf = self;
    dispatch_async(dispatch_get_main_queue(), ^{
        id<WKURLSchemeTask> wvTask = strongSelf->_task;
        if (wvTask != nil) {
            [wvTask didReceiveResponse:resp];
            [wvTask didReceiveData:body];
            [wvTask didFinish];
        }
    });
    [resp release];
    [self terminate];
}

@end
// (The @interface is declared at the top of the file so it's visible
// to NalarAppDelegate's `applicationDidFinishLaunching:`. The
// @implementation follows here.)

@implementation NalarSchemeHandler

- (instancetype)initWithAssets:(const nalar_webview_asset*)assets
                        count:(size_t)count
                    proxyBase:(NSString*)proxyBase {
    self = [super init];
    if (self) {
        _assets = assets;
        _asset_count = count;
        // Copy: the caller's NSString may go out of scope when the
        // delegate is freed; we want this URL string to outlive that.
        _proxyBase = [proxyBase copy];
        // Active proxy registry: each /api/* request creates a
        // ProxyContext that registers itself here so the handler's
        // stopURLSchemeTask: can find + cancel it. NSMutableArray is
        // fine for the expected small N (a few concurrent SSE/JSON
        // fetches); the alternative (CFDictionary<WKURLSchemeTask*, ...>)
        // would require manual reference management on the task pointer
        // — exactly the thing that's become invalid by the time we'd
        // want to look it up.
        _activeProxies = [[NSMutableArray alloc] init];
    }
    return self;
}

- (void)dealloc {
    [_proxyBase release];
    _proxyBase = nil;
    [super dealloc];
}

// Find an asset by path. Returns NULL if no match. No allocation, no
// copy — the returned asset is owned by the asset table.
- (const nalar_webview_asset*)findAssetForPath:(const char*)path {
    if (_assets == NULL || path == NULL) return NULL;
    for (size_t i = 0; i < _asset_count; i++) {
        const nalar_webview_asset* a = &_assets[i];
        if (a->path != NULL && strcmp(a->path, path) == 0) return a;
    }
    return NULL;
}

// Build a "200 OK" response with the given bytes. The data is COPIED
// into an NSData so the caller can free its buffer immediately.
- (void)sendOKResponse:(id<WKURLSchemeTask>)task
                  data:(NSData*)body
                  mime:(const char*)mime {
    NSString* mimeStr = (mime != NULL)
        ? [NSString stringWithUTF8String:mime]
        : @"application/octet-stream";
    NSDictionary* headers = @{
        @"Content-Type": mimeStr,
        @"Content-Length": [NSString stringWithFormat:@"%lu", (unsigned long)body.length],
    };
    NSHTTPURLResponse* resp = [[NSHTTPURLResponse alloc]
        initWithURL:task.request.URL
        statusCode:200
        HTTPVersion:@"HTTP/1.1"
        headerFields:headers];
    [task didReceiveResponse:resp];
    [resp release];
    [task didReceiveData:body];
    [task didFinish];
}

// Build a "404 Not Found" response with a plain-text body.
- (void)sendNotFound:(id<WKURLSchemeTask>)task path:(const char*)path {
    char msg[256];
    snprintf(msg, sizeof(msg), "app:// scheme handler: '%s' not found in asset table", path);
    NSData* body = [NSData dataWithBytes:msg length:strlen(msg)];
    NSString* bodyStr = [NSString stringWithUTF8String:msg];
    NSDictionary* headers = @{
        @"Content-Type": @"text/plain; charset=utf-8",
        @"Content-Length": [NSString stringWithFormat:@"%lu", (unsigned long)body.length],
    };
    NSHTTPURLResponse* resp = [[NSHTTPURLResponse alloc]
        initWithURL:task.request.URL
        statusCode:404
        HTTPVersion:@"HTTP/1.1"
        headerFields:headers];
    [task didReceiveResponse:resp];
    [resp release];
    [task didReceiveData:body];
    [task didFinish];
}

// Build a "502 Bad Gateway" response when the API proxy fails.
- (void)sendProxyError:(id<WKURLSchemeTask>)task message:(const char*)message {
    NSData* body = [NSData dataWithBytes:message length:strlen(message)];
    NSDictionary* headers = @{
        @"Content-Type": @"text/plain; charset=utf-8",
    };
    NSHTTPURLResponse* resp = [[NSHTTPURLResponse alloc]
        initWithURL:task.request.URL
        statusCode:502
        HTTPVersion:@"HTTP/1.1"
        headerFields:headers];
    [task didReceiveResponse:resp];
    [resp release];
    [task didReceiveData:body];
    [task didFinish];
}

// Forward an app://localhost/api/* request to the nalar HTTP service.
// We synchronously connect + send + read using NSURLSession so the
// request looks like a real network call to the webview (proper
// response headers, status codes, etc.).
- (void)proxyApiRequest:(id<WKURLSchemeTask>)task
                  path:(const char*)path {
    if (_proxyBase == NULL) {
        [self sendProxyError:task message:"API proxy not configured (api_proxy_base is null)"];
        return;
    }

    // Build the upstream URL: proxy_base + "/" + path. `path` already
    // starts with "/" (extracted from the app:// URL below), so the
    // final URL is e.g. "http://127.0.0.1:8081/api/workers?limit=50".
    NSString* pathStr = [NSString stringWithUTF8String:path];
    NSString* fullStr = [_proxyBase stringByAppendingString:pathStr];
    NSURL* upstreamURL = [NSURL URLWithString:fullStr];
    if (upstreamURL == NULL) {
        [self sendProxyError:task message:"API proxy: failed to build upstream URL"];
        return;
    }

    NSMutableURLRequest* upstreamReq = [NSMutableURLRequest
        requestWithURL:upstreamURL
        cachePolicy:NSURLRequestReloadIgnoringLocalCacheData
        timeoutInterval:30.0];
    // Forward the original HTTP method (fetch() defaults to GET, but
    // the webapp may POST/PUT/DELETE).
    upstreamReq.HTTPMethod = task.request.HTTPMethod ?: @"GET";
    // Forward Content-Type if the webapp set one (so nalar parses the
    // JSON body correctly on POSTs).
    NSString* contentType = [task.request valueForHTTPHeaderField:@"Content-Type"];
    if (contentType != NULL) {
        [upstreamReq setValue:contentType forHTTPHeaderField:@"Content-Type"];
    }
    // Forward the request body for non-GET methods.
    if (task.request.HTTPBody != nil) {
        upstreamReq.HTTPBody = task.request.HTTPBody;
    } else if (task.request.HTTPBodyStream != nil) {
        // WKURLSchemeTask gives us HTTPBodyStream; rewind + read.
        NSInputStream* s = task.request.HTTPBodyStream;
        [s open];
        NSMutableData* buf = [NSMutableData data];
        uint8_t chunk[4096];
        NSInteger n;
        while ((n = [s read:chunk maxLength:sizeof(chunk)]) > 0) {
            [buf appendBytes:chunk length:(NSUInteger)n];
        }
        [s close];
        if (buf.length > 0) {
            upstreamReq.HTTPBody = buf;
        }
    }

    // Stream the upstream response back to the webview via a
    // dedicated worker thread. The thread opens a TCP socket, sends
    // the HTTP request, and reads the response in a loop. For SSE
    // streams, the response body never ends — we forward each chunk
    // as it arrives. For normal responses, we forward everything and
    // close.
    //
    // Using a thread + raw socket is the most reliable way to handle
    // SSE here: NSURLSession's delegate callbacks go through internal
    // queues that don't play well with the WKURLSchemeTask contract
    // (callbacks must be on the main thread). A raw socket on a
    // worker thread is simple and bulletproof.
    //
    // WKURLSchemeTask callbacks must be on the main thread, so we
    // dispatch_async each chunk + the final didFinish to the main
    // queue. Lifetime is managed by ProxyContext: the worker thread
    // self-retains the context; the context's -terminate signals the
    // worker to stop and releases the retain.
    ProxyContext* ctx = [[ProxyContext alloc] initWithTask:task request:upstreamReq];
    // Retain the handler (us) for the lifetime of the proxy so the
    // scheme handler's ivars stay valid. Released in -dealloc.
    ctx->_handler = [self retain];
    // Self-retain: the worker thread is the only thing keeping the
    // context alive (it has a strong ref via its capture). When the
    // worker exits it calls terminate which releases this retain.
    [ctx retain];
    // Register with the handler's active-proxies list so
    // stopURLSchemeTask: can find + cancel this context when WebKit
    // aborts the request. NSMutableArray holds strong references, so
    // removing on terminate is the matching unregister.
    @synchronized (self) {
        [_activeProxies addObject:ctx];
    }
    NSThread* worker = [[NSThread alloc]
        initWithTarget:ctx
              selector:@selector(performStreamingProxy)
                object:nil];
    [worker start];
    [worker release];  // thread retains itself + ctx via the target
}

- (void)webView:(WKWebView*)webView
    startURLSchemeTask:(id<WKURLSchemeTask>)task {
    NSURL* url = task.request.URL;
    NSLog(@"nalar_webview scheme task: URL=%@ method=%@", url, task.request.HTTPMethod);
    if (url == nil) {
        [self sendNotFound:task path:"(null URL)"];
        return;
    }
    // URL is e.g. "app://localhost/index.html" or
    // "app://localhost/api/workers?limit=50". Extract the path
    // (everything after the host) — NSURL's `path` does exactly that
    // for app:// URLs.
    NSString* pathNS = url.path;
    if (pathNS == nil) pathNS = @"/";
    const char* path = [pathNS UTF8String];

    // Route based on prefix: /api/* → upstream, else → asset table.
    if (strncmp(path, "/api/", 5) == 0 || strcmp(path, "/api") == 0) {
        [self proxyApiRequest:task path:path];
        return;
    }

    const nalar_webview_asset* hit = [self findAssetForPath:path];
    if (hit != NULL) {
        NSData* body = [NSData dataWithBytes:hit->content
                                      length:hit->content_len];
        [self sendOKResponse:task data:body mime:hit->mime];
        return;
    }

    // SPA fallback: the webapp is a Vue Router SPA. When the user
    // navigates to /app or /app/chat/abc123, the client-side router
    // needs to take over. We can't return 404 — the webapp's
    // <router-view> would stay empty. Instead, serve index.html
    // for any path that doesn't look like a static asset (no "." in
    // the basename, suggesting a route like /app/chat/xyz, not
    // /favicon.ico). Static asset paths that genuinely don't exist
    // still get 404 below.
    //
    // Heuristic: a "route" path has no '.' in its last segment
    // AND no leading slash+alphanumeric+digit-dash pattern that
    // looks like a hash/asset. Concretely: a path like /app/chat/123
    // has no dot in "123", so we serve index.html. A path like
    // /foo.png has a dot, so we return 404. /favicon.ico has a dot,
    // 404 (which is fine — the browser's favicon request is cosmetic).
    const char* lastSlash = strrchr(path, '/');
    const char* basename = lastSlash ? lastSlash + 1 : path;
    BOOL looksLikeRoute = YES;
    for (const char* p = basename; *p != 0; p++) {
        if (*p == '.') {
            looksLikeRoute = NO;
            break;
        }
    }
    if (looksLikeRoute) {
        // Serve index.html so the SPA router can take over.
        const nalar_webview_asset* indexHit = [self findAssetForPath:"/index.html"];
        if (indexHit != NULL) {
            NSData* body = [NSData dataWithBytes:indexHit->content
                                          length:indexHit->content_len];
            [self sendOKResponse:task data:body mime:indexHit->mime];
            return;
        }
    }

    [self sendNotFound:task path:path];
}

- (void)webView:(WKWebView*)webView
    stopURLSchemeTask:(id<WKURLSchemeTask>)task {
    // WebKit calls this when the webview navigates away, closes the
    // window, or otherwise aborts an in-flight scheme request. After
    // this returns, the WKURLSchemeTask is invalidated — any further
    // calls to its methods (didReceiveResponse, didReceiveData,
    // didFinish) throw an NSException "WKURLSchemeTask is no longer
    // valid" and crash the host process. We MUST cancel the matching
    // ProxyContext here so the worker's streaming loop (or the
    // response header send) doesn't dispatch a block that touches
    // the now-invalid task.
    //
    // Linear scan: at most a few concurrent /api/* requests (SSE +
    // a few short JSON fetches). The list is small in practice; the
    // alternative (a CFDictionary<WKURLSchemeTask*,ProxyContext*>)
    // would require manual reference management on the task's ObjC
    // pointer, which is exactly what we're trying to avoid (the
    // pointer is the thing that's become invalid).
    @synchronized (self) {
        for (NSUInteger i = 0; i < _activeProxies.count; i++) {
            ProxyContext* ctx = (ProxyContext*)_activeProxies[i];
            if (ctx->_task == task) {
                // Mark cancelled FIRST so any concurrent terminate()
                // call sees the flag and skips dispatching to the
                // task. Then call [ctx cancel] which calls
                // [ctx terminate] on the worker thread.
                ctx->_cancelled = YES;
                ctx->_task = nil;
                [ctx cancel];
                [_activeProxies removeObjectAtIndex:i];
                break;
            }
        }
    }
}

@end // NalarSchemeHandler

#pragma mark - C ABI implementations

extern "C" nalar_webview* nalar_webview_create(
    const nalar_webview_config* cfg,
    const char*                 url
) {
    if (cfg == NULL || url == NULL) {
        NSLog(@"nalar_webview_create: cfg (%p) or url (%p) is NULL", cfg, url);
        return NULL;
    }

    // 1. Construct the delegate (alloc + init). Retain count: 1.
    NalarAppDelegate* delegate = [[NalarAppDelegate alloc] init];

    // 2. Copy the config struct by value (assign property = no retain
    //    dance; just memcpy the struct).
    delegate.config = *cfg;

    // 3. Copy the URL string. +stringWithUTF8String: returns an
    //    autoreleased NSString; the `copy` property retains it.
    delegate.urlString = [NSString stringWithUTF8String:url];

    // 4. Borrow the asset table.
    delegate.assets = cfg->assets;
    delegate.asset_count = cfg->asset_count;

    // 5. Copy the API proxy base URL (if provided). This is the HTTP
    //    base the WKURLSchemeHandler forwards app://localhost/api/*
    //    requests to. May be NULL when the webapp doesn't talk to
    //    any HTTP backend (e.g. the asset table is fully self-contained).
    if (cfg->api_proxy_base != NULL) {
        delegate.apiProxyBase = [NSString stringWithUTF8String:cfg->api_proxy_base];
    } else {
        delegate.apiProxyBase = nil;
    }

    // 5. Set up the NSApplication. sharedApplication creates the
    //    singleton if it doesn't exist; safe to call repeatedly.
    [NSApplication sharedApplication];

    // 6. Regular activation policy = the app appears in the Dock and
    //    can receive focus (vs. .Accessory which is menu-bar-only, or
    //    .Prohibited which is background-only).
    [NSApp setActivationPolicy:NSApplicationActivationPolicyRegular];

    // 7. Install the delegate and activate. activateIgnoringOtherApps:
    //    YES forces the app to the foreground even if the user is in
    //    another app — standard behavior for a desktop-launched app.
    [NSApp setDelegate:delegate];
    [NSApp activateIgnoringOtherApps:YES];

    // Return as opaque. The Zig side casts this back to NalarAppDelegate*
    // inside nalar_webview_destroy to release it.
    return (nalar_webview*)delegate;
}

extern "C" void nalar_webview_run(nalar_webview* wv) {
    (void)wv;

    // [NSApp run] starts the Cocoa event loop. It blocks until the
    // application terminates (which, with our
    // applicationShouldTerminateAfterLastWindowClosed: returning YES,
    // happens when the user closes the window). The previous
    // applicationDidFinishLaunching: callback has already created the
    // window by the time we get here.
    [NSApp run];
}

extern "C" void nalar_webview_destroy(nalar_webview* wv) {
    NalarAppDelegate* delegate = (NalarAppDelegate*)wv;
    if (delegate == NULL) {
        return;
    }

    // [NSApp run] has already returned (otherwise we wouldn't be
    // executing). So [NSApp terminate:nil] is a no-op — but it's
    // harmless and defensive in case the run loop is somehow still
    // alive (e.g. window wasn't actually closed, just hidden).
    [NSApp terminate:nil];

    // Balance the `alloc` from nalar_webview_create. The delegate's
    // dealloc releases _webView (after breaking the navigation
    // delegate cycle), _window, and _urlString.
    [delegate release];
}
