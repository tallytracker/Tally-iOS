import WebKit

struct Cookie {
    var name: String
    var value: String
}

let gcmMessageIDKey = "00000000000" // update this with actual ID if using Firebase 

// URL for first launch.
// CHANGED 6 Aug 2026: was https://tallytracker.github.io/Tally. Moved to web.app
// so the app, the Firebase authDomain and the Android v5 package all use ONE
// canonical domain — sign-in breaks on github.io (that is why hosting moved),
// and a listing whose URLs disagree with the app is a review risk.
let rootUrl = URL(string: "https://tally-app-c82c6.web.app/Tally")!

// allowed origin is for what we are sticking to pwa domain
// This should also appear in Info.plist
let allowedOrigins: [String] = ["tally-app-c82c6.web.app"]

// auth origins will open in modal and show toolbar for back into the main origin.
// These should also appear in Info.plist
// appleid.cdn-apple.com serves Apple's Sign in with Apple JS SDK — without it
// the script cannot load inside the webview and Apple sign-in silently falls
// back to the no-revocation path.
// accounts.youtube.com ADDED 14 Aug 2026 — DO NOT REMOVE IT.
// Google finishes a sign-in by bouncing through other Google properties to
// propagate the login cookie, and accounts.youtube.com is one of those hops.
// It was missing here, so the webview CANCELLED that redirect and reopened the
// URL in a bare SFSafariViewController with none of the cookies or state from
// the flow it was halfway through. Google answered "400. That's an error. The
// server cannot process the request because it is malformed." Google only takes
// that hop when it needs to sync YouTube cookies, which is why Google sign-in
// worked in the app for weeks and then suddenly did not — the bug was always
// here, the route was not. Anything else in that chain belongs here too.
let authOrigins: [String] = ["tally-app-c82c6.firebaseapp.com", "accounts.google.com", "accounts.youtube.com", "appleid.apple.com", "appleid.cdn-apple.com"] // Firebase auth helper + Google OAuth (+ its YouTube cookie hop) + Sign in with Apple
// allowedOrigins + authOrigins <= 10

let platformCookie = Cookie(name: "app-platform", value: "iOS App Store")

// UI options
let displayMode = "standalone" // standalone / fullscreen.
let adaptiveUIStyle = true     // iOS 15+ only. Change app theme on the fly to dark/light related to WebView background color.
let overrideStatusBar = false   // iOS 13-14 only. if you don't support dark/light system theme.
let statusBarTheme = "dark"    // dark / light, related to override option.
let pullToRefresh = true    // Enable/disable pull down to refresh page
