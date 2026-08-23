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
//   WKWebView's WKNavigationDelegate protocol gives us
//   `webView:decidePolicyForNavigationAction:decisionHandler:` which fires
//   for every navigation request. We intercept `app://` URLs, look up the
//   path in the asset table, and load the bytes via
//   `-[WKWebView loadData:MIMEType:characterEncodingName:baseURL:]`. Any
//   non-app:// request is allowed through with
//   `WKNavigationActionPolicyAllow`, so external resources (CDNs, fonts,
//   etc.) still load normally.
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
//   IMPORTANT: the delegate patterns create retain cycles — webView
//   retains BOTH delegates (navigation + UI) via their setters, and the
//   delegate retains webView (via _webView property). We break them in
//   `dealloc` by calling `setNavigationDelegate:nil` AND
//   `setUIDelegate:nil` BEFORE releasing the webView.
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

#pragma mark - Delegate

@interface NalarAppDelegate : NSObject <NSApplicationDelegate, WKNavigationDelegate, WKUIDelegate>

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

// Owned by the delegate. Released in dealloc. `assign` for the window
// delegate is a retain cycle: window retains contentView (webView), so
// we MUST release them in dealloc.
@property(nonatomic, retain) NSWindow* window;
@property(nonatomic, retain) WKWebView* webView;

@end

#pragma mark - WebView subclass (context menu suppression)

/// WKWebView subclass that suppresses the default right-click context
/// menu by overriding `menuForEvent:` to return nil. WKWebView's public
/// API has no first-class "suppress default context menu" hook on macOS
/// (the `webView:contextMenuConfigurationForElement:` API uses
/// `UIContextMenuConfiguration` which is iOS / Mac Catalyst only, NOT
/// native macOS), so we subclass and override the NSView-level
/// `menuForEvent:` instead.
///
/// The page's JavaScript `contextmenu` DOM event still fires — the
/// WKWebView's right-click handling is unchanged; we only suppress the
/// NSMenu that the NSView system would otherwise show. So Vue's
/// @contextmenu.prevent handlers in the webapp (DesignView, LayersPanel,
/// GitChanges, etc.) run as intended.
@interface NalarWebView : WKWebView
@end

@implementation NalarWebView

- (NSMenu *)menuForEvent:(NSEvent *)event {
    (void)event;
    // Returning nil suppresses the default right-click context menu.
    // The DOM `contextmenu` event still fires inside the WKWebView —
    // we only prevent the NSMenu from appearing.
    return nil;
}

@end

@implementation NalarAppDelegate

@synthesize config = _config;
@synthesize urlString = _urlString;
@synthesize assets = _assets;
@synthesize asset_count = _asset_count;
@synthesize window = _window;
@synthesize webView = _webView;

- (void)applicationWillFinishLaunching:(NSNotification*)notification {
    (void)notification;

    // ---- Application menu bar ----
    // A programmatically-created NSApplication has NO main menu. Without
    // an Edit menu, AppKit's key-equivalent dispatch finds no `paste:` /
    // `copy:` / `cut:` / `selectAll:` / `undo:` / `redo:` targets for
    // Cmd+V/C/X/A/Z — the keystrokes are silently swallowed BEFORE they
    // reach the WKWebView, so the DOM never sees a paste event (chat
    // text AND image paste both dead). Building a standard menu with
    // items targeting NSApp itself routes those shortcuts through the
    // responder chain into WebKit's editing machinery.
    //
    // MUST run in applicationWillFinishLaunching: (not DidFinish) — the
    // menu bar is built from the main menu when the app finishes
    // launching; setting it later leaves the default empty menu visible.
    NSMenu* menubar = [[NSMenu alloc] init];

    // -- App menu (first item = application name submenu; required for
    //    Quit/Cmd+Q and standard About/Hide plumbing).
    NSMenuItem* appMenuItem = [[NSMenuItem alloc] init];
    [menubar addItem:appMenuItem];
    NSMenu* appMenu = [[NSMenu alloc] init];
    [appMenuItem setSubmenu:appMenu];
    [appMenu addItemWithTitle:@"About Nalar"
                       action:@selector(orderFrontStandardAboutPanel:)
                keyEquivalent:@""];
    [appMenu addItem:[NSMenuItem separatorItem]];
    // addItemWithTitle:action:keyEquivalent: defaults to the Command
    // modifier, so Hide = Cmd+H out of the box.
    [appMenu addItemWithTitle:@"Hide Nalar"
                       action:@selector(hide:)
                keyEquivalent:@"h"];
    [appMenu addItem:[NSMenuItem separatorItem]];
    [appMenu addItemWithTitle:@"Quit Nalar"
                       action:@selector(terminate:)
                keyEquivalent:@"q"];

    // -- Edit menu: THE fix for Cmd+C/V/X/A/Z in the webview.
    NSMenuItem* editMenuItem = [[NSMenuItem alloc] init];
    [menubar addItem:editMenuItem];
    NSMenu* editMenu = [[NSMenu alloc] initWithTitle:@"Edit"];
    [editMenuItem setSubmenu:editMenu];
    [editMenu addItemWithTitle:@"Undo" action:@selector(undo:) keyEquivalent:@"z"];
    [editMenu addItemWithTitle:@"Redo"
                        action:@selector(redo:)
                 keyEquivalent:@"Z"]; // Shift+Cmd+Z via uppercase + default cmd modifier
    [editMenu addItem:[NSMenuItem separatorItem]];
    [editMenu addItemWithTitle:@"Cut" action:@selector(cut:) keyEquivalent:@"x"];
    [editMenu addItemWithTitle:@"Copy" action:@selector(copy:) keyEquivalent:@"c"];
    [editMenu addItemWithTitle:@"Paste" action:@selector(paste:) keyEquivalent:@"v"];
    [editMenu addItemWithTitle:@"Select All" action:@selector(selectAll:) keyEquivalent:@"a"];

    // -- Window menu (standard Minimize/Zoom plumbing).
    NSMenuItem* windowMenuItem = [[NSMenuItem alloc] init];
    [menubar addItem:windowMenuItem];
    NSMenu* windowMenu = [[NSMenu alloc] initWithTitle:@"Window"];
    [windowMenuItem setSubmenu:windowMenu];
    [windowMenu addItemWithTitle:@"Minimize" action:@selector(performMiniaturize:) keyEquivalent:@"m"];
    [windowMenu addItemWithTitle:@"Close" action:@selector(performClose:) keyEquivalent:@"w"];

    [NSApp setMainMenu:menubar];
    // NSApp retains the main menu; balance our alloc immediately.
    [menubar release];

    // Ownership: NSApp retains its main menu; each NSMenu retains its
    // parent item's submenu once attached. The bare container items
    // (appMenuItem/editMenuItem/windowMenuItem) were added to their
    // parent menus (which retain them), so we balance our allocs here.
    [appMenuItem release];
    [appMenu release];
    [editMenuItem release];
    [editMenu release];
    [windowMenuItem release];
    [windowMenu release];
}

- (void)applicationDidFinishLaunching:(NSNotification*)notification {
    (void)notification;

    // ---- Window ----
    // Place at a fixed origin (100, 100) for predictability. The webapp
    // remembers window position itself if it cares.
    NSRect frame = NSMakeRect(100, 100, _config.width, _config.height);

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

    _webView = [[NalarWebView alloc] initWithFrame:frame configuration:wkconfig];
    [_webView setNavigationDelegate:self];
    // WKUIDelegate is REQUIRED for <input type="file"> to work: clicking
    // such an input makes WebKit ask its UI delegate to show a picker via
    // runOpenPanelWithParameters:. With no delegate (or no implementation)
    // WebKit completes the picker with an empty result — the file dialog
    // never opens and nothing is attached, silently.
    [_webView setUIDelegate:self];

    // The WKWebView IS the window's content view. This is the
    // simplest layout (no NSScrollView wrapper needed — the webview
    // scrolls internally). The webview's autoresizing-mask defaults
    // to `NSViewWidthSizable | NSViewHeightSizable` so it tracks
    // window resize automatically.
    [_window setContentView:_webView];
    [_window makeKeyAndOrderFront:nil];

    // ---- Initial navigation ----
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

// Fires for every navigation (initial load, link click, asset fetch,
// redirect, etc.). We cancel the decision for `app://` URLs and serve
// the matching asset from the in-memory table; everything else is
// allowed through.
- (void)webView:(WKWebView*)webView
    decidePolicyForNavigationAction:(WKNavigationAction*)navigationAction
    decisionHandler:(void (^)(WKNavigationActionPolicy))decisionHandler {

    NSURL* requestURL = navigationAction.request.URL;
    NSString* urlString = [requestURL absoluteString];

    // Defensive: if URL is nil for any reason, just allow it.
    if (urlString == nil) {
        decisionHandler(WKNavigationActionPolicyAllow);
        return;
    }

    if (![urlString hasPrefix:@"app://"]) {
        decisionHandler(WKNavigationActionPolicyAllow);
        return;
    }

    // ---- Asset lookup ----
    // Strip "app://" prefix.
    NSString* afterScheme = [urlString substringFromIndex:[@"app://" length]];

    // Skip the host: find the first "/" after the scheme. If there's no
    // "/" (e.g. "app://localhost"), default to "/".
    NSString* path;
    NSRange firstSlash = [afterScheme rangeOfString:@"/"];
    if (firstSlash.location != NSNotFound) {
        path = [afterScheme substringFromIndex:firstSlash.location];
    } else {
        path = @"/";
    }

    const char* pathUTF8 = [path UTF8String];
    if (pathUTF8 != NULL) {
        for (size_t i = 0; i < _asset_count; i++) {
            const nalar_webview_asset* asset = &_assets[i];
            if (asset->path != NULL && strcmp(asset->path, pathUTF8) == 0) {
                // Asset hit. Load it inline via loadData: which gives us
                // full control over content + MIME (loadHTMLString:
                // would re-parse, but loadData: is a single-shot serve
                // that matches WebKitGTK's webkit_uri_scheme_request_finish
                // semantics).
                NSData* data = [NSData dataWithBytes:asset->content
                                              length:asset->content_len];
                NSString* mime = [NSString stringWithUTF8String:asset->mime];
                NSURL* baseURL = [NSURL URLWithString:@"app://localhost/"];

                [webView loadData:data
                          MIMEType:mime
            characterEncodingName:@"utf-8"
                          baseURL:baseURL];
                decisionHandler(WKNavigationActionPolicyCancel);
                return;
            }
        }
    }

    // ---- 404 ----
    // Asset not found. Return a plain-text "Not Found" body and cancel
    // the original navigation. This mirrors the Linux implementation's
    // "empty 200 with text/plain" strategy in spirit (don't propagate a
    // platform-specific error to the webview).
    NSData* notFound = [@"Not Found" dataUsingEncoding:NSUTF8StringEncoding];
    NSURL* baseURL = [NSURL URLWithString:@"app://localhost/"];
    [webView loadData:notFound
              MIMEType:@"text/plain"
  characterEncodingName:@"utf-8"
              baseURL:baseURL];
    decisionHandler(WKNavigationActionPolicyCancel);
}

#pragma mark - WKUIDelegate

// Fires when the page clicks an <input type="file"> (the chat composer's
// paperclip button). Present a native NSOpenPanel and hand the chosen
// URLs back through the completion handler. MUST call the completion
// handler exactly once in every path — WebKit hangs the input otherwise.
- (void)webView:(WKWebView*)webView runOpenPanelWithParameters:(WKOpenPanelParameters*)parameters initiatedByFrame:(WKFrameInfo*)frame completionHandler:(void (^)(NSArray<NSURL*>* URLs))completionHandler {
    (void)webView;
    (void)frame;

    NSOpenPanel* panel = [NSOpenPanel openPanel];
    [panel setCanChooseFiles:YES];
    [panel setCanChooseDirectories:NO];
    // The frontend's hidden <input type="file"> has no `multiple`
    // attribute, but honoring the web's request keeps us future-proof —
    // WKOpenPanelParameters.allowsMultipleSelection reflects it.
    [panel setAllowsMultipleSelection:[parameters allowsMultipleSelection]];

    // Modal from the app window; completion handler runs on the panel's
    // close. Passing nil URLs on cancel = "no files chosen".
    [panel beginSheetModalForWindow:_window
                  completionHandler:^(NSInteger result) {
        if (result == NSModalResponseOK) {
            completionHandler(panel.URLs);
        } else {
            completionHandler(nil);
        }
    }];
}

#pragma mark - Cleanup

- (void)dealloc {
    // Break BOTH delegate retain cycles BEFORE releasing the webView.
    // Without this, the delegate would be retained by the webView (via
    // navigation + UI delegate properties), the webView would be
    // retained by us, and `release` in nalar_webview_destroy would never
    // reach zero.
    [_webView setNavigationDelegate:nil];
    [_webView setUIDelegate:nil];
    [_webView release];
    _webView = nil;

    [_window release];
    _window = nil;

    [_urlString release];
    _urlString = nil;

    [super dealloc];
}

@end

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
