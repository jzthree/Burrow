import AppKit
import Foundation
import PortKeeperCore
import WebKit

/// Browser-based SAML sign-in for GlobalProtect gateways, equivalent to
/// gp-saml-gui: fetch the SAML request from the VPN's prelogin endpoint, let
/// the user authenticate in a WebKit window, and capture the prelogin cookie
/// that openconnect then uses as its password. The web view uses the default
/// (persistent) data store, so the IdP session usually survives reconnects
/// and the window closes after a brief flash.
@MainActor
final class GPSAMLAuthenticator: NSObject, WKNavigationDelegate, NSWindowDelegate {
    struct SAMLResult {
        let username: String
        let cookie: String
        let usergroup: String
    }

    enum SAMLError: LocalizedError {
        case preloginFailed(String)
        case cancelled
        case interactionRequired

        var errorDescription: String? {
            switch self {
            case .preloginFailed(let message):
                return message
            case .cancelled:
                return "SAML sign-in was cancelled."
            case .interactionRequired:
                return "SAML sign-in needs attention — click Connect"
            }
        }
    }

    /// The IdP session persists in the web view's storage, so sign-in often
    /// completes with no interaction. The policy controls whether and when
    /// the window becomes visible.
    enum InteractionPolicy {
        case showImmediately
        /// Try silently; reveal the window if not finished after the delay.
        case showAfter(TimeInterval)
        /// Never show a window; fail with `.interactionRequired` on timeout.
        case silentOnly(TimeInterval)
    }

    private let gateway: GatewayConfig
    private var window: NSWindow?
    private var webView: WKWebView?
    private var completion: ((Result<SAMLResult, Error>) -> Void)?
    private var headerUsername: String?
    private var policy: InteractionPolicy = .showImmediately
    private var revealTask: Task<Void, Never>?
    private var isRevealed = false

    init(gateway: GatewayConfig) {
        self.gateway = gateway
    }


    func begin(policy: InteractionPolicy = .showImmediately, completion: @escaping (Result<SAMLResult, Error>) -> Void) {
        self.policy = policy
        self.completion = completion
        Task { @MainActor in
            do {
                let prelogin = try await fetchPrelogin()
                presentWebView(with: prelogin)
            } catch {
                finish(.failure(error))
            }
        }
    }

    func cancel() {
        finish(.failure(SAMLError.cancelled))
    }

    // MARK: - Prelogin

    private struct PreloginResponse {
        let method: String       // "REDIRECT" or "POST"
        let request: String      // decoded URL or HTML
        let cookieUsergroup: String
    }

    private func fetchPrelogin() async throws -> PreloginResponse {
        // Gateway interface first (cookie: prelogin-cookie), portal second
        // (cookie: portal-userauthcookie); deployments vary.
        let attempts: [(path: String, usergroup: String)] = [
            ("/ssl-vpn/prelogin.esp", "gateway:prelogin-cookie"),
            ("/global-protect/prelogin.esp", "portal:portal-userauthcookie"),
        ]

        var lastError = "No SAML prelogin response from \(gateway.server)."
        for attempt in attempts {
            guard let url = URL(string: "https://\(gateway.server)\(attempt.path)") else {
                continue
            }
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            request.setValue("PAN GlobalProtect", forHTTPHeaderField: "User-Agent")
            request.httpBody = Data("tmp=tmp&kerberos-support=yes&ipv6-support=yes&clientVer=4100&clientos=Mac".utf8)

            do {
                let (data, _) = try await URLSession.shared.data(for: request)
                let body = String(data: data, encoding: .utf8) ?? ""

                guard let methodTag = firstTag("saml-auth-method", in: body),
                      let requestTag = firstTag("saml-request", in: body) else {
                    if let status = firstTag("status", in: body), status.lowercased() != "success" {
                        let message = firstTag("msg", in: body) ?? status
                        lastError = "Prelogin (\(attempt.path)): \(message)"
                    } else {
                        lastError = "Prelogin (\(attempt.path)): no SAML request in response — the server may not use SAML on this interface."
                    }
                    continue
                }

                guard let decoded = Data(base64Encoded: requestTag, options: .ignoreUnknownCharacters)
                    .flatMap({ String(data: $0, encoding: .utf8) }) else {
                    lastError = "Prelogin (\(attempt.path)): could not decode SAML request."
                    continue
                }

                return PreloginResponse(method: methodTag.uppercased(), request: decoded, cookieUsergroup: attempt.usergroup)
            } catch {
                lastError = "Prelogin (\(attempt.path)): \(error.localizedDescription)"
                continue
            }
        }

        throw SAMLError.preloginFailed(lastError)
    }

    private func firstTag(_ tag: String, in text: String) -> String? {
        guard let openRange = text.range(of: "<\(tag)>"),
              let closeRange = text.range(of: "</\(tag)>", range: openRange.upperBound..<text.endIndex) else {
            return nil
        }
        let value = String(text[openRange.upperBound..<closeRange.lowerBound])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    // MARK: - Web view

    private func presentWebView(with prelogin: PreloginResponse) {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 480, height: 640), configuration: configuration)
        webView.navigationDelegate = self
        webView.customUserAgent = "PAN GlobalProtect"
        self.webView = webView

        let window = NSWindow(contentViewController: NSViewController())
        window.contentView = webView
        window.styleMask = [.titled, .closable, .resizable]
        window.title = "Sign in — \(gateway.name)"
        window.setContentSize(NSSize(width: 480, height: 640))
        window.isReleasedWhenClosed = false
        window.level = .floating
        window.delegate = self
        // Keep the window on-screen but fully transparent and click-through so
        // WebKit treats it as visible and runs the IdP's redirect JavaScript
        // normally (a never-shown or off-screen window gets its timers and
        // rendering throttled — the main reason silent sign-in was flaky). We
        // make it visible only if a login form actually appears (session
        // expired), via reveal().
        window.center()
        window.alphaValue = 0
        window.ignoresMouseEvents = true
        window.orderFrontRegardless()
        self.window = window
        self.pendingUsergroup = prelogin.cookieUsergroup

        if prelogin.method == "POST" {
            webView.loadHTMLString(prelogin.request, baseURL: URL(string: "https://\(gateway.server)/"))
        } else if let url = URL(string: prelogin.request) {
            webView.load(URLRequest(url: url))
        } else {
            finish(.failure(SAMLError.preloginFailed("SAML request was not a loadable URL.")))
            return
        }

        switch policy {
        case .showImmediately:
            reveal()
        case .showAfter(let delay):
            // Safety fallback only — interaction detection usually reveals or
            // resolves well before this fires.
            revealTask = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(delay))
                guard let self, !Task.isCancelled, self.completion != nil else {
                    return
                }
                self.reveal()
            }
        case .silentOnly(let timeout):
            revealTask = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(timeout))
                guard let self, !Task.isCancelled, self.completion != nil else {
                    return
                }
                self.finish(.failure(SAMLError.interactionRequired))
            }
        }
    }

    private func reveal() {
        guard let window, !isRevealed else {
            return
        }
        isRevealed = true
        revealTask?.cancel()
        MenuBarPopover.dismiss()
        window.alphaValue = 1
        window.ignoresMouseEvents = false
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// The IdP session is stale and a login form is showing. Reveal the window
    /// for the user (interactive policies), or give up (silent policy).
    private func handleInteractionNeeded() {
        guard completion != nil, !isRevealed else {
            return
        }
        switch policy {
        case .showImmediately, .showAfter:
            reveal()
        case .silentOnly:
            finish(.failure(SAMLError.interactionRequired))
        }
    }

    private var pendingUsergroup = "gateway:prelogin-cookie"

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationResponse: WKNavigationResponse,
        decisionHandler: @escaping @MainActor (WKNavigationResponsePolicy) -> Void
    ) {
        if let httpResponse = navigationResponse.response as? HTTPURLResponse {
            var headers: [String: String] = [:]
            for (key, value) in httpResponse.allHeaderFields {
                if let key = key as? String, let value = value as? String {
                    headers[key.lowercased()] = value
                }
            }
            if let username = headers["saml-username"] {
                headerUsername = username
            }
            if let cookie = headers["prelogin-cookie"] {
                deliver(cookie: cookie, usergroup: "gateway:prelogin-cookie")
            } else if let cookie = headers["portal-userauthcookie"] {
                deliver(cookie: cookie, usergroup: "portal:portal-userauthcookie")
            }
        }
        decisionHandler(.allow)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        // Some IdPs return the tokens in the final page body instead of headers.
        webView.evaluateJavaScript("document.documentElement.outerHTML") { [weak self] result, _ in
            guard let self, self.completion != nil, let html = result as? String else {
                return
            }
            if let username = self.firstTag("saml-username", in: html) {
                self.headerUsername = username
            }
            if let cookie = self.firstTag("prelogin-cookie", in: html) {
                self.deliver(cookie: cookie, usergroup: "gateway:prelogin-cookie")
                return
            } else if let cookie = self.firstTag("portal-userauthcookie", in: html) {
                self.deliver(cookie: cookie, usergroup: "portal:portal-userauthcookie")
                return
            }

            // No token yet. If the page is a real credential prompt, the cached
            // IdP session is stale — surface it for the user. If it's an Entra/
            // Azure interstitial (account picker, "stay signed in?"), advance it
            // automatically so silent sign-in completes. Otherwise it's a mid-
            // flow redirect; keep waiting for the next navigation.
            if self.looksLikeLoginForm(html) {
                self.handleInteractionNeeded()
            } else {
                self.tryAutoAdvance(webView, html: html)
            }
        }
    }

    private var autoAdvanceCount = 0

    /// Clicks through known Entra/Azure interstitials (account tile, "stay
    /// signed in?") so a valid IdP session completes without user interaction.
    /// Falls back to revealing the window if it can't make progress.
    private func tryAutoAdvance(_ webView: WKWebView, html: String) {
        let lowered = html.lowercased()
        guard autoAdvanceCount < 6 else {
            handleInteractionNeeded()
            return
        }

        let email = (gateway.user ?? headerUsername ?? "")
        let js: String
        if lowered.contains("pick an account") || lowered.contains("aria-label=\"pick an account\"") {
            js = """
            (function(){
              function fire(el){el.click();['mousedown','mouseup','click'].forEach(function(ev){
                el.dispatchEvent(new MouseEvent(ev,{bubbles:true,cancelable:true,view:window}));});}
              var email=\(jsStringLiteral(email)).toLowerCase();
              // The clickable account is a [role=button] / div.table whose
              // data-test-id is the email — NOT the .tile/.row list wrapper.
              var btn=null;
              if(email){btn=document.querySelector('[data-test-id="'+email+'"]');}
              if(!btn){var bs=document.querySelectorAll('[role="button"][data-test-id], div.table[role="button"], [data-test-id]');
                for(var i=0;i<bs.length;i++){var id=(bs[i].getAttribute('data-test-id')||'');
                  if(id.indexOf('@')>=0){btn=bs[i];break;}}}
              if(!btn){btn=document.querySelector('[data-test-id*="@"]');}
              if(btn){fire(btn);return 'clicked:'+(btn.getAttribute('data-test-id')||btn.className).slice(0,40);}
              return 'no-btn';
            })()
            """
        } else if lowered.contains("stay signed in") || lowered.contains("kmsi") {
            js = """
            (function(){
              function fire(el){['mousedown','mouseup','click'].forEach(function(ev){
                el.dispatchEvent(new MouseEvent(ev,{bubbles:true,cancelable:true,view:window}));});}
              var b=document.querySelectorAll('input[type=submit],button,[role="button"]');
              for(var i=0;i<b.length;i++){var v=((b[i].value||'')+' '+(b[i].innerText||'')).toLowerCase();
                if(v.indexOf('yes')>=0){fire(b[i]);return 'stay-yes';}}
              if(b.length){fire(b[0]);return 'stay-first';}
              return 'no-btn';
            })()
            """
        } else {
            // Unknown non-credential page that isn't progressing — let the user look.
            handleInteractionNeeded()
            return
        }

        autoAdvanceCount += 1
        webView.evaluateJavaScript(js) { result, _ in
        }

        // Auto-advance is best-effort: some IdPs (notably Entra/Azure account
        // pickers) reject synthetic clicks, so for interactive policies reveal
        // the window shortly after so the user can finish with one real click
        // (their account — no password). If the auto-click did navigate, the
        // next page either yields the cookie (done) or we handle it there.
        switch policy {
        case .showImmediately, .showAfter:
            revealTask?.cancel()
            revealTask = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .milliseconds(1800))
                guard let self, !Task.isCancelled, self.completion != nil, !self.isRevealed else {
                    return
                }
                self.reveal()
            }
        case .silentOnly:
            break
        }
    }

    private func jsStringLiteral(_ s: String) -> String {
        let escaped = s
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "'", with: "\\'")
            .replacingOccurrences(of: "\n", with: "")
        return "'\(escaped)'"
    }

    private func looksLikeLoginForm(_ html: String) -> Bool {
        let lowered = html.lowercased()
        guard lowered.contains("type=\"password\"") || lowered.contains("type='password'") else {
            return false
        }
        // A bare auto-submit form often contains a hidden password placeholder;
        // require a sign-in affordance too to avoid false positives mid-redirect.
        return lowered.contains("login") || lowered.contains("sign in") || lowered.contains("signin")
            || lowered.contains("username") || lowered.contains("u_name") || lowered.contains("okta")
            || lowered.contains("microsoftonline") || lowered.contains("passwd")
    }



    func windowWillClose(_ notification: Notification) {
        if completion != nil {
            finish(.failure(SAMLError.cancelled), closeWindow: false)
        }
    }

    private func deliver(cookie: String, usergroup: String) {
        guard completion != nil else {
            return
        }
        let username = headerUsername ?? gateway.user ?? ""
        guard !username.isEmpty else {
            finish(.failure(SAMLError.preloginFailed("SAML sign-in finished but no username was returned; set a User on the gateway as a fallback.")))
            return
        }
        finish(.success(SAMLResult(username: username, cookie: cookie, usergroup: usergroup)))
    }

    private func finish(_ result: Result<SAMLResult, Error>, closeWindow: Bool = true) {
        guard let completion else {
            return
        }
        self.completion = nil
        revealTask?.cancel()
        revealTask = nil
        if closeWindow {
            window?.delegate = nil
            window?.close()
        }
        window = nil
        webView?.navigationDelegate = nil
        webView = nil
        completion(result)
    }
}
