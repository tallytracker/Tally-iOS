import UIKit
import WebKit
import AuthenticationServices
import SafariServices


func createWebView(container: UIView, WKSMH: WKScriptMessageHandler, WKND: WKNavigationDelegate, NSO: NSObject, VC: ViewController) -> WKWebView{

    let config = WKWebViewConfiguration()
    let userContentController = WKUserContentController()

    userContentController.add(WKSMH, name: "print")
    userContentController.add(WKSMH, name: "push-subscribe")
    userContentController.add(WKSMH, name: "push-permission-request")
    userContentController.add(WKSMH, name: "push-permission-state")
    userContentController.add(WKSMH, name: "push-token")

    config.userContentController = userContentController

    config.limitsNavigationsToAppBoundDomains = true;
    config.allowsInlineMediaPlayback = true
    config.preferences.javaScriptCanOpenWindowsAutomatically = true
    config.preferences.setValue(true, forKey: "standalone")
    
    let webView = WKWebView(frame: calcWebviewFrame(webviewView: container, toolbarView: nil), configuration: config)
    setCustomCookie(webView: webView)

    webView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
    webView.isHidden = true;
    webView.navigationDelegate = WKND
    webView.scrollView.bounces = false
    webView.scrollView.contentInsetAdjustmentBehavior = .never
    webView.allowsBackForwardNavigationGestures = true
    
    // Check if macCatalyst 16.4+ is available and if so, enable web inspector.
    // This allows the web app to be inspected using Safari Web Inspector. Supported on iOS 16.4+ and macOS 13.3+
    if #available(iOS 16.4, macOS 13.3, *) {
        webView.isInspectable = true
    }
    
    let deviceModel = UIDevice.current.model
    let osVersion = UIDevice.current.systemVersion
    webView.configuration.applicationNameForUserAgent = "Safari/604.1"
    webView.customUserAgent = "Mozilla/5.0 (\(deviceModel); CPU \(deviceModel) OS \(osVersion.replacingOccurrences(of: ".", with: "_")) like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/\(osVersion) Mobile/15E148 Safari/604.1 PWAShell"

    webView.addObserver(NSO, forKeyPath: #keyPath(WKWebView.estimatedProgress), options: NSKeyValueObservingOptions.new, context: nil)
    
    #if DEBUG
    if #available(iOS 16.4, *) {
        webView.isInspectable = true
    }
    #endif
    
    return webView
}

func setAppStoreAsReferrer(contentController: WKUserContentController) {
    let scriptSource = "document.referrer = `app-info://platform/ios-store`;"
    let script = WKUserScript(source: scriptSource, injectionTime: .atDocumentEnd, forMainFrameOnly: true)
    contentController.addUserScript(script);
}

func setCustomCookie(webView: WKWebView) {
    let _platformCookie = HTTPCookie(properties: [
        .domain: rootUrl.host!,
        .path: "/",
        .name: platformCookie.name,
        .value: platformCookie.value,
        .secure: "FALSE",
        .expires: NSDate(timeIntervalSinceNow: 31556926)
    ])!

    webView.configuration.websiteDataStore.httpCookieStore.setCookie(_platformCookie)

}

func calcWebviewFrame(webviewView: UIView, toolbarView: UIToolbar?) -> CGRect{
    if ((toolbarView) != nil) {
        return CGRect(x: 0, y: toolbarView!.frame.height, width: webviewView.frame.width, height: webviewView.frame.height - toolbarView!.frame.height)
    }
    else {
        let winScene = UIApplication.shared.connectedScenes.first
        let windowScene = winScene as! UIWindowScene
        var statusBarHeight = windowScene.statusBarManager?.statusBarFrame.height ?? 0

        switch displayMode {
        case "fullscreen":
            #if targetEnvironment(macCatalyst)
                if let titlebar = windowScene.titlebar {
                    titlebar.titleVisibility = .hidden
                    titlebar.toolbar = nil
                }
            #endif
            return CGRect(x: 0, y: 0, width: webviewView.frame.width, height: webviewView.frame.height)
        default:
            #if targetEnvironment(macCatalyst)
            statusBarHeight = 29
            #endif
            let windowHeight = webviewView.frame.height - statusBarHeight
            return CGRect(x: 0, y: statusBarHeight, width: webviewView.frame.width, height: windowHeight)
        }
    }
}

extension ViewController: WKUIDelegate, WKDownloadDelegate {
    // POPUP (window.open) SUPPORT — added 12 Aug 2026.
    //
    // PWABuilder ships this method returning nil and loading the request in the
    // MAIN webview instead. That breaks every popup-based OAuth flow, because
    // returning nil makes window.open() evaluate to null in JavaScript. Sign in
    // with Apple's JS SDK (AppleID.auth.signIn with usePopup:true) and
    // Firebase's signInWithPopup both need that window handle to receive their
    // result from; with no handle the promise never settles. The old behaviour
    // made it worse by navigating the main frame away to the provider, which
    // tore down the very page that was waiting, along with the one-time nonce
    // held in its memory — so no fallback could recover it either.
    //
    // Observed on TestFlight build 6: Apple's sheet appears, you authorise, get
    // dropped on Firebase's /__/auth/handler page showing its manual "Continue
    // to the app" button, tap it, and the app is still signed out. Google
    // sign-in was unaffected because it consults _preferRedirectAuth() and takes
    // the full-page redirect path instead; Apple's SDK is hardcoded to popup.
    //
    // The child webview MUST be constructed from the `configuration` passed in,
    // not a fresh one. That object carries the opener relationship the
    // postMessage handshake depends on, and it carries
    // limitsNavigationsToAppBoundDomains, which keeps the popup inside
    // WKAppBoundDomains (appleid.apple.com and accounts.google.com are both
    // listed in Info.plist).
    //
    // navigationDelegate is deliberately left unset. The main one's
    // decidePolicyFor is written around the app's own origin and diverts
    // anything else to SFSafariViewController, which would kick the provider's
    // own sub-navigations out of the popup and break the flow again.
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        let popup = WKWebView(frame: .zero, configuration: configuration)
        popup.customUserAgent = webView.customUserAgent
        popup.uiDelegate = self
        popup.translatesAutoresizingMaskIntoConstraints = false

        let host = UIViewController()
        host.view.backgroundColor = .systemBackground
        host.view.addSubview(popup)

        // Apple and Firebase both call window.close() when the flow finishes,
        // which lands in webViewDidClose below. This button is the escape hatch
        // for a user who backs out halfway and would otherwise be stuck in a
        // chrome-less webview with no way back.
        let cancel = UIButton(type: .system)
        cancel.setTitle("Cancel", for: .normal)
        cancel.translatesAutoresizingMaskIntoConstraints = false
        cancel.addTarget(self, action: #selector(dismissAuthPopup), for: .touchUpInside)
        host.view.addSubview(cancel)

        NSLayoutConstraint.activate([
            cancel.topAnchor.constraint(equalTo: host.view.safeAreaLayoutGuide.topAnchor, constant: 8),
            cancel.leadingAnchor.constraint(equalTo: host.view.leadingAnchor, constant: 16),
            popup.topAnchor.constraint(equalTo: cancel.bottomAnchor, constant: 8),
            popup.leadingAnchor.constraint(equalTo: host.view.leadingAnchor),
            popup.trailingAnchor.constraint(equalTo: host.view.trailingAnchor),
            popup.bottomAnchor.constraint(equalTo: host.view.bottomAnchor)
        ])

        authPopupWebView = popup
        authPopupController = host
        host.modalPresentationStyle = .formSheet
        present(host, animated: true)
        return popup
    }

    // WebKit calls this when the popup runs window.close() — the normal end of
    // a successful sign-in.
    func webViewDidClose(_ webView: WKWebView) {
        if webView === authPopupWebView { dismissAuthPopup() }
    }

    @objc func dismissAuthPopup() {
        authPopupController?.dismiss(animated: true)
        authPopupWebView = nil
        authPopupController = nil
    }
    // restrict navigation to target host, open external links in 3rd party apps
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        if (navigationAction.request.url?.scheme == "about") {
            return decisionHandler(.allow)
        }
        if (navigationAction.shouldPerformDownload || navigationAction.request.url?.scheme == "blob") {
            return decisionHandler(.download)
        }

        if let requestUrl = navigationAction.request.url{
            if let requestHost = requestUrl.host {
                // NOTE: Match auth origin first, because host origin may be a subset of auth origin and may therefore always match
                let matchingAuthOrigin = authOrigins.first(where: { requestHost.range(of: $0) != nil })
                if (matchingAuthOrigin != nil) {
                    decisionHandler(.allow)
                    if (toolbarView.isHidden) {
                        toolbarView.isHidden = false
                        webView.frame = calcWebviewFrame(webviewView: webviewView, toolbarView: toolbarView)
                    }
                    return
                }

                let matchingHostOrigin = allowedOrigins.first(where: { requestHost.range(of: $0) != nil })
                if (matchingHostOrigin != nil) {
                    // Open in main webview
                    decisionHandler(.allow)
                    if (!toolbarView.isHidden) {
                        toolbarView.isHidden = true
                        webView.frame = calcWebviewFrame(webviewView: webviewView, toolbarView: nil)
                    }
                    return
                }
                if (navigationAction.navigationType == .other &&
                    navigationAction.value(forKey: "syntheticClickType") as! Int == 0 &&
                    (navigationAction.targetFrame != nil) &&
                    // no error here, fake warning
                    (navigationAction.sourceFrame != nil)
                ) {
                    decisionHandler(.allow)
                    return
                }
                else {
                    decisionHandler(.cancel)
                }


                if ["http", "https"].contains(requestUrl.scheme?.lowercased() ?? "") {
                    // Can open with SFSafariViewController
                    let safariViewController = SFSafariViewController(url: requestUrl)
                    self.present(safariViewController, animated: true, completion: nil)
                } else {
                    // Scheme is not supported or no scheme is given, use openURL
                    if (UIApplication.shared.canOpenURL(requestUrl)) {
                        UIApplication.shared.open(requestUrl)
                    }
                }
            } else {
                decisionHandler(.cancel)
                if (navigationAction.request.url?.scheme == "tel" || navigationAction.request.url?.scheme == "mailto" ){
                    if (UIApplication.shared.canOpenURL(requestUrl)) {
                        UIApplication.shared.open(requestUrl)
                    }
                }
                else {
                    if requestUrl.isFileURL {
                        // not tested
                        downloadAndOpenFile(url: requestUrl.absoluteURL)
                    }
                    // if (requestUrl.absoluteString.contains("base64")){
                    //     downloadAndOpenBase64File(base64String: requestUrl.absoluteString)
                    // }
                }
            }
        }
        else {
            decisionHandler(.cancel)
        }

    }
    // Handle javascript: `window.alert(message: String)`
    func webView(_ webView: WKWebView,
        runJavaScriptAlertPanelWithMessage message: String,
        initiatedByFrame frame: WKFrameInfo,
        completionHandler: @escaping () -> Void) {

        // Set the message as the UIAlertController message
        let alert = UIAlertController(
            title: nil,
            message: message,
            preferredStyle: .alert
        )

        // Add a confirmation action “OK”
        let okAction = UIAlertAction(
            title: "OK",
            style: .default,
            handler: { _ in
                // Call completionHandler
                completionHandler()
            }
        )
        alert.addAction(okAction)

        // Display the NSAlert
        present(alert, animated: true, completion: nil)
    }
    // Handle javascript: `window.confirm(message: String)`
    func webView(_ webView: WKWebView,
        runJavaScriptConfirmPanelWithMessage message: String,
        initiatedByFrame frame: WKFrameInfo,
        completionHandler: @escaping (Bool) -> Void) {

        // Set the message as the UIAlertController message
        let alert = UIAlertController(
            title: nil,
            message: message,
            preferredStyle: .alert
        )

        // Add a confirmation action “Cancel”
        let cancelAction = UIAlertAction(
            title: "Cancel",
            style: .cancel,
            handler: { _ in
                // Call completionHandler
                completionHandler(false)
            }
        )

        // Add a confirmation action “OK”
        let okAction = UIAlertAction(
            title: "OK",
            style: .default,
            handler: { _ in
                // Call completionHandler
                completionHandler(true)
            }
        )
        alert.addAction(cancelAction)
        alert.addAction(okAction)

        // Display the NSAlert
        present(alert, animated: true, completion: nil)
    }
    // Handle javascript: `window.prompt(prompt: String, defaultText: String?)`
    func webView(_ webView: WKWebView,
        runJavaScriptTextInputPanelWithPrompt prompt: String,
        defaultText: String?,
        initiatedByFrame frame: WKFrameInfo,
        completionHandler: @escaping (String?) -> Void) {

        // Set the message as the UIAlertController message
        let alert = UIAlertController(
            title: nil,
            message: prompt,
            preferredStyle: .alert
        )

        // Add a confirmation action “Cancel”
        let cancelAction = UIAlertAction(
            title: "Cancel",
            style: .cancel,
            handler: { _ in
                // Call completionHandler
                completionHandler(nil)
            }
        )

        // Add a confirmation action “OK”
        let okAction = UIAlertAction(
            title: "OK",
            style: .default,
            handler: { _ in
                // Call completionHandler with Alert input
                if let input = alert.textFields?.first?.text {
                    completionHandler(input)
                }
            }
        )

        alert.addTextField { textField in
            textField.placeholder = defaultText
        }
        alert.addAction(cancelAction)
        alert.addAction(okAction)

        // Display the NSAlert
        present(alert, animated: true, completion: nil)
    }

    func downloadAndOpenFile(url: URL){

        let destinationFileUrl = url
        let sessionConfig = URLSessionConfiguration.default
        let session = URLSession(configuration: sessionConfig)
        let request = URLRequest(url:url)
        let task = session.downloadTask(with: request) { (tempLocalUrl, response, error) in
            if let tempLocalUrl = tempLocalUrl, error == nil {
                if let statusCode = (response as? HTTPURLResponse)?.statusCode {
                    print("Successfully download. Status code: \(statusCode)")
                }
                do {
                    try FileManager.default.copyItem(at: tempLocalUrl, to: destinationFileUrl)
                    self.openFile(url: destinationFileUrl)
                } catch (let writeError) {
                    print("Error creating a file \(destinationFileUrl) : \(writeError)")
                }
            } else {
                print("Error took place while downloading a file. Error description: \(error?.localizedDescription ?? "N/A") ")
            }
        }
        task.resume()
    }

    // func downloadAndOpenBase64File(base64String: String) {
    //     // Split the base64 string to extract the data and the file extension
    //     let components = base64String.components(separatedBy: ";base64,")

    //     // Make sure the base64 string has the correct format
    //     guard components.count == 2, let format = components.first?.split(separator: "/").last else {
    //         print("Invalid base64 string format")
    //         return
    //     }

    //     // Remove the data type prefix to get the base64 data
    //     let dataString = components.last!

    //     if let imageData = Data(base64Encoded: dataString) {
    //         let documentsUrl: URL  =  FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
    //         let destinationFileUrl = documentsUrl.appendingPathComponent("image.\(format)")

    //         do {
    //             try imageData.write(to: destinationFileUrl)
    //             self.openFile(url: destinationFileUrl)
    //         } catch {
    //             print("Error writing image to file url: \(destinationFileUrl): \(error)")
    //         }
    //     }
    // }

    func openFile(url: URL) {
        self.documentController = UIDocumentInteractionController(url: url)
        self.documentController?.delegate = self
        self.documentController?.presentPreview(animated: true)
    }

    func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) {
        download.delegate = self
    }

    func download(_ download: WKDownload, decideDestinationUsing response: URLResponse,
                suggestedFilename: String,
                completionHandler: @escaping (URL?) -> Void) {

        let documentsPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let fileURL = documentsPath.appendingPathComponent(suggestedFilename)

        // Remove existing file if it exists, otherwise it may show an old file/content just by having the same name.
        if FileManager.default.fileExists(atPath: fileURL.path) {
            try? FileManager.default.removeItem(at: fileURL)
        }

        self.openFile(url: fileURL)
        completionHandler(fileURL)
    }
}
