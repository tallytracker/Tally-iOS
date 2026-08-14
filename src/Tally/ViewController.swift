import UIKit
import WebKit
import AuthenticationServices

var webView: WKWebView! = nil

class ViewController: UIViewController, WKNavigationDelegate, UIDocumentInteractionControllerDelegate {
    enum LoadingMode {
        case defaultCachePolicy
        case forceCache
    }

    var documentController: UIDocumentInteractionController?

    // Live references to the OAuth popup while it is on screen, so
    // webViewDidClose can dismiss the right one. See createWebViewWith in
    // WebView.swift for why popups have to be supported at all.
    var authPopupWebView: WKWebView?
    var authPopupController: UIViewController?

    // Strong reference to the in-flight Sign in with Apple request. See
    // handleAppleSignIn for why this must exist. Typed as Any? so the property
    // needs no @available annotation; cast at the point of use.
    var appleAuthController: Any?
    func documentInteractionControllerViewControllerForPreview(_ controller: UIDocumentInteractionController) -> UIViewController {
        return self
    }
    
    @IBOutlet weak var loadingView: UIView!
    @IBOutlet weak var progressView: UIProgressView!
    @IBOutlet weak var connectionProblemView: UIImageView!
    @IBOutlet weak var webviewView: UIView!
    var toolbarView: UIToolbar!
    
    var htmlIsLoaded = false;
    private var loadingMode = LoadingMode.defaultCachePolicy
    
    private var themeObservation: NSKeyValueObservation?
    var currentWebViewTheme: UIUserInterfaceStyle = .unspecified
    override var preferredStatusBarStyle : UIStatusBarStyle {
        if #available(iOS 13, *), overrideStatusBar{
            if #available(iOS 15, *) {
                return .default
            } else {
                return statusBarTheme == "dark" ? .lightContent : .darkContent
            }
        }
        return .default
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        initWebView()
        initToolbarView()
        loadRootUrl()
    
        NotificationCenter.default.addObserver(self, selector: #selector(self.keyboardWillHide(_:)), name: UIResponder.keyboardWillHideNotification , object: nil)
        
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        Tally.webView.frame = calcWebviewFrame(webviewView: webviewView, toolbarView: nil)
    }
    
    @objc func keyboardWillHide(_ notification: NSNotification) {
        Tally.webView.setNeedsLayout()
    }
    
    func initWebView() {
        Tally.webView = createWebView(container: webviewView, WKSMH: self, WKND: self, NSO: self, VC: self)
        webviewView.addSubview(Tally.webView);
        
        Tally.webView.uiDelegate = self;
        
        Tally.webView.addObserver(self, forKeyPath: #keyPath(WKWebView.estimatedProgress), options: .new, context: nil)

        if(pullToRefresh){
            let refreshControl = UIRefreshControl()
            refreshControl.addTarget(self, action: #selector(refreshWebView(_:)), for: UIControl.Event.valueChanged)
            Tally.webView.scrollView.addSubview(refreshControl)
            Tally.webView.scrollView.bounces = true
        }

        if #available(iOS 15.0, *), adaptiveUIStyle {
            themeObservation = Tally.webView.observe(\.themeColor) { [unowned self] webView, _ in
                let backgroundColor = Tally.webView.underPageBackgroundColor;
                let themeColor = Tally.webView.themeColor;
                currentWebViewTheme = themeColor?.isLight() ?? backgroundColor?.isLight() ?? true ? .light : .dark
                self.overrideUIStyle()
                view.backgroundColor = themeColor ?? backgroundColor;
            }
        }
    }

    @objc func refreshWebView(_ sender: UIRefreshControl) {
        Tally.webView?.reload()
        sender.endRefreshing()
    }

    func createToolbarView() -> UIToolbar{
        let winScene = UIApplication.shared.connectedScenes.first
        let windowScene = winScene as! UIWindowScene
        var statusBarHeight = windowScene.statusBarManager?.statusBarFrame.height ?? 60
        
        #if targetEnvironment(macCatalyst)
        if (statusBarHeight == 0){
            statusBarHeight = 30
        }
        #endif
        
        let toolbarView = UIToolbar(frame: CGRect(x: 0, y: 0, width: webviewView.frame.width, height: 0))
        toolbarView.sizeToFit()
        toolbarView.frame = CGRect(x: 0, y: 0, width: webviewView.frame.width, height: toolbarView.frame.height + statusBarHeight)
//        toolbarView.autoresizingMask = [.flexibleTopMargin, .flexibleRightMargin, .flexibleWidth]
        
        let flex = UIBarButtonItem(barButtonSystemItem: .flexibleSpace, target: nil, action: nil)
        let close = UIBarButtonItem(barButtonSystemItem: .done, target: self, action: #selector(loadRootUrl))
        toolbarView.setItems([close,flex], animated: true)
        
        toolbarView.isHidden = true
        
        return toolbarView
    }
    
    func overrideUIStyle(toDefault: Bool = false) {
        if #available(iOS 15.0, *), adaptiveUIStyle {
            if (((htmlIsLoaded && !Tally.webView.isHidden) || toDefault) && self.currentWebViewTheme != .unspecified) {
                UIApplication
                    .shared
                    .connectedScenes
                    .flatMap { ($0 as? UIWindowScene)?.windows ?? [] }
                    .first { $0.isKeyWindow }?.overrideUserInterfaceStyle = toDefault ? .unspecified : self.currentWebViewTheme;
            }
        }
    }
    
    func initToolbarView() {
        toolbarView =  createToolbarView()
        
        webviewView.addSubview(toolbarView)
    }
    
    @objc func loadRootUrl(cachePolicy: NSURLRequest.CachePolicy = .useProtocolCachePolicy) {
        Tally.webView.load(URLRequest(url: SceneDelegate.universalLinkToLaunch ?? SceneDelegate.shortcutLinkToLaunch ?? rootUrl, cachePolicy: cachePolicy))
    }
    
    func reloadWebview(
        loadingMode: LoadingMode = LoadingMode.defaultCachePolicy
    ) {
        switch loadingMode {
        case LoadingMode.defaultCachePolicy:
            loadRootUrl(cachePolicy: .useProtocolCachePolicy);

        case LoadingMode.forceCache:
            loadRootUrl(cachePolicy: .useProtocolCachePolicy);
        }

        self.loadingMode = loadingMode
    }
    
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!){
        htmlIsLoaded = true
        
        self.setProgress(1.0, true)
        self.animateConnectionProblem(false)
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
            Tally.webView.isHidden = false
            self.loadingView.isHidden = true
           
            self.setProgress(0.0, false)
            
            self.overrideUIStyle()
        }
    }
    
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        if (error as NSError)._code == (-999) { return }
        if (error as NSError)._code == 102 { return }

        // SAY WHAT FAILED (14 Aug 2026). Blocked navigations were completely
        // silent on device, which cost two builds guessing which Google domain
        // the sign-in chain wanted next. See reportNavigationFailure.
        reportNavigationFailure(webView, error)

        // DO NOT TEAR THE APP DOWN WHEN IT IS THE AUTH POPUP THAT FAILED
        // (14 Aug 2026). Everything below treats a failure as "the main page
        // could not load": it hides the web view, shows the connection-problem
        // screen and reloads. Applied to the sign-in popup that is exactly wrong
        // — it throws away the half-finished OAuth flow and drops the user back
        // on the welcome screen with no explanation, which is precisely what
        // Google sign-in did on build 17. Only the MAIN web view gets the
        // recovery treatment.
        if webView !== Tally.webView { return }

        htmlIsLoaded = false;

        self.overrideUIStyle(toDefault: true);
        webView.isHidden = true;
        loadingView.isHidden = false;

        if loadingMode == LoadingMode.defaultCachePolicy {
            DispatchQueue.main.async {
                self.reloadWebview(loadingMode: LoadingMode.forceCache)
            }
        } else {
            animateConnectionProblem(true);
            setProgress(0.05, true);
            
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                self.setProgress(0.1, true);
                DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                    self.reloadWebview()
                }
            }
        }
    }
    
    override func observeValue(forKeyPath keyPath: String?, of object: Any?, change: [NSKeyValueChangeKey : Any]?, context: UnsafeMutableRawPointer?) {

        if (keyPath == #keyPath(WKWebView.estimatedProgress) &&
                Tally.webView.isLoading &&
                !self.loadingView.isHidden &&
                !self.htmlIsLoaded) {
                    var progress = Float(Tally.webView.estimatedProgress);
                    
                    if (progress >= 0.8) { progress = 1.0; };
                    if (progress >= 0.3) { self.animateConnectionProblem(false); }
                    
                    self.setProgress(progress, true);
        }
    }
    
    func setProgress(_ progress: Float, _ animated: Bool) {
        self.progressView.setProgress(progress, animated: animated);
    }
    
    
    func animateConnectionProblem(_ show: Bool) {
        if (show) {
            self.connectionProblemView.isHidden = false;
            self.connectionProblemView.alpha = 0
            UIView.animate(withDuration: 0.7, delay: 0, options: [.repeat, .autoreverse], animations: {
                self.connectionProblemView.alpha = 1
            })
        }
        else {
            UIView.animate(withDuration: 0.3, delay: 0, options: [], animations: {
                self.connectionProblemView.alpha = 0 // Here you will get the animation you want
            }, completion: { _ in
                self.connectionProblemView.isHidden = true;
                self.connectionProblemView.layer.removeAllAnimations();
            })
        }
    }
        
    deinit {
        Tally.webView.removeObserver(self, forKeyPath: #keyPath(WKWebView.estimatedProgress))
    }
}

extension UIColor {
    // Check if the color is light or dark, as defined by the injected lightness threshold.
    // Some people report that 0.7 is best. I suggest to find out for yourself.
    // A nil value is returned if the lightness couldn't be determined.
    func isLight(threshold: Float = 0.5) -> Bool? {
        let originalCGColor = self.cgColor

        // Now we need to convert it to the RGB colorspace. UIColor.white / UIColor.black are greyscale and not RGB.
        // If you don't do this then you will crash when accessing components index 2 below when evaluating greyscale colors.
        let RGBCGColor = originalCGColor.converted(to: CGColorSpaceCreateDeviceRGB(), intent: .defaultIntent, options: nil)
        guard let components = RGBCGColor?.components else {
            return nil
        }
        guard components.count >= 3 else {
            return nil
        }

        let brightness = Float(((components[0] * 299) + (components[1] * 587) + (components[2] * 114)) / 1000)
        return (brightness > threshold)
    }
}

extension ViewController: WKScriptMessageHandler {
  func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        if message.name == "print" {
            printView(webView: Tally.webView)
        }
        if message.name == "push-subscribe" {
            handleSubscribeTouch(message: message)
        }
        if message.name == "push-permission-request" {
            handlePushPermission()
        }
        if message.name == "push-permission-state" {
            handlePushState()
        }
        if message.name == "push-token" {
            handleFCMToken()
        }
        if message.name == "apple-signin" {
            if #available(iOS 13.0, *) { handleAppleSignIn(message: message) }
            else { sendAppleSignInResult(["error": "unsupported"]) }
        }
  }
}
// ===== NATIVE SIGN IN WITH APPLE (added 11 Aug 2026) =====
//
// WHY THIS EXISTS. The web app can sign in with Apple on its own, via Apple's
// JS SDK at appleid.apple.com. That works in Safari but is close to unusable
// inside the wrapper: a WKWebView cannot reach the device keychain, so Apple
// shows its full web login and asks for the Apple ID PASSWORD, and its "sign in
// with passkey" button does nothing there. Face ID has made that password
// something almost nobody remembers, so Apple sign-in was present but
// effectively a dead end. This bridge runs the REAL native sheet instead:
// Face ID, name and email already filled in, no password.
//
// Guideline 4.8 does NOT require the native sheet — the web flow passes review.
// This is a conversion fix, not a compliance one.
//
// HOW IT FITS TOGETHER. The web app owns the nonce, because Firebase needs the
// raw value to verify the token it gets back:
//   1. JS generates a random rawNonce, SHA-256 hashes it, and posts the HASH
//      here through the 'apple-signin' message handler.
//   2. Swift asks Apple to sign in, passing that hash as request.nonce.
//   3. Apple returns an identity token with the hash embedded.
//   4. Swift hands the token and authorization code back as an
//      'apple-signin-result' event, base64-encoded.
//   5. JS builds the Firebase credential from {idToken, rawNonce} and signs in,
//      then exchanges the code for a refresh token so account deletion can
//      still revoke it (Guideline 5.1.1(v)).
//
// The authorization code is the reason this cannot just use Firebase's own
// Apple provider: that flow does not surface the code, and without it there is
// nothing to revoke on deletion.
@available(iOS 13.0, *)
extension ViewController: ASAuthorizationControllerDelegate, ASAuthorizationControllerPresentationContextProviding {

    func handleAppleSignIn(message: WKScriptMessage) {
        guard let body = message.body as? [String: Any],
              let hashedNonce = body["nonce"] as? String, !hashedNonce.isEmpty else {
            sendAppleSignInResult(["error": "bad-request"])
            return
        }
        let request = ASAuthorizationAppleIDProvider().createRequest()
        request.requestedScopes = [.fullName, .email]
        request.nonce = hashedNonce
        let controller = ASAuthorizationController(authorizationRequests: [request])
        controller.delegate = self
        controller.presentationContextProvider = self
        // HOLD A STRONG REFERENCE. delegate and presentationContextProvider are
        // both weak, and the controller itself is only a local here — if ARC
        // releases it before Apple calls back, the request dies instantly and
        // surfaces as a generic failure with no explanation, which is exactly
        // the symptom seen on build 8. Cleared in both delegate callbacks.
        appleAuthController = controller
        // Apple requires this on the main thread. The WKScriptMessageHandler
        // callback normally is already, but asserting it costs nothing and a
        // background call fails silently.
        DispatchQueue.main.async { controller.performRequests() }
    }

    func presentationAnchor(for controller: ASAuthorizationController) -> ASPresentationAnchor {
        // A detached, never-shown ASPresentationAnchor() is a bad fallback:
        // Apple cannot present its sheet on it and fails the request. Prefer the
        // real key window, then any window in the scene, and only then give up.
        if let w = self.view.window { return w }
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        if let key = scenes.flatMap({ $0.windows }).first(where: { $0.isKeyWindow }) { return key }
        if let any = scenes.flatMap({ $0.windows }).first { return any }
        return ASPresentationAnchor()
    }

    func authorizationController(controller: ASAuthorizationController,
                                 didCompleteWithAuthorization authorization: ASAuthorization) {
        appleAuthController = nil
        guard let cred = authorization.credential as? ASAuthorizationAppleIDCredential,
              let tokenData = cred.identityToken,
              let idToken = String(data: tokenData, encoding: .utf8) else {
            sendAppleSignInResult(["error": "no-identity-token"])
            return
        }
        var payload: [String: Any] = ["idToken": idToken]
        if let codeData = cred.authorizationCode,
           let code = String(data: codeData, encoding: .utf8) {
            payload["code"] = code
        }
        // Apple sends the name and email ONLY on the very first authorisation
        // for this app. Every later sign-in returns nil for both, which is why
        // the web app must not depend on them being present.
        if let given = cred.fullName?.givenName, !given.isEmpty {
            payload["givenName"] = given
        }
        if let email = cred.email, !email.isEmpty {
            payload["email"] = email
        }
        sendAppleSignInResult(payload)
    }

    func authorizationController(controller: ASAuthorizationController,
                                 didCompleteWithError error: Error) {
        // A cancel is a normal outcome, not a failure — the web app maps it to
        // auth/popup-closed-by-user and stays quiet rather than showing an error.
        //
        // Everything else reports Apple's ACTUAL error code, because "failed"
        // alone is undiagnosable and there is no way to read a device console
        // without a Mac. ASAuthorizationError codes: 1000 unknown, 1001
        // canceled, 1002 invalidResponse, 1003 notHandled, 1004 failed, 1005
        // notInteractive. 1000 and 1004 usually mean the entitlement or the App
        // ID's Sign in with Apple configuration is wrong rather than anything
        // in this code.
        appleAuthController = nil
        var reason = "failed"
        if let authError = error as? ASAuthorizationError {
            if authError.code == .canceled {
                reason = "cancelled"
            } else {
                reason = "asauth-\(authError.code.rawValue)"
            }
        } else {
            reason = "nserr-\((error as NSError).code)"
        }
        sendAppleSignInResult(["error": reason, "detail": error.localizedDescription])
    }
}

extension ViewController {
    // Base64 rather than raw JSON: identity tokens are long, and names and email
    // addresses can contain characters that would need escaping inside a
    // JavaScript string literal. Encoding sidesteps the whole quoting problem.
    func sendAppleSignInResult(_ payload: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: payload, options: []),
              let json = String(data: data, encoding: .utf8) else {
            return
        }
        let encoded = Data(json.utf8).base64EncodedString()
        DispatchQueue.main.async {
            Tally.webView.evaluateJavaScript(
                "window.dispatchEvent(new CustomEvent('apple-signin-result',{detail:'\(encoded)'}))"
            )
        }
    }
}
