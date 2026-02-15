//
//  SidecarWebView.swift
//  DVI-Heatpump-control-app
//
//  Created by Lars Robert Pedersen on 24/01/2026.
//

import SwiftUI
import WebKit


struct SidecarWebView: UIViewRepresentable {
    let url: URL
    let authToken: String?
    @Binding var reloadTrigger: Bool

    func makeUIView(context: Context) -> WKWebView {
        let webView = WKWebView(frame: .zero, configuration: makeConfiguration())
        context.coordinator.webView = webView
        context.coordinator.allowedHost = url.host
        context.coordinator.authToken = authToken
        webView.navigationDelegate = context.coordinator
        if #available(iOS 11.0, *) {
            webView.scrollView.contentInsetAdjustmentBehavior = .never
        }
        let request = makeRequest()
        webView.load(request)
        return webView
    }

    private func makeConfiguration() -> WKWebViewConfiguration {
        let config = WKWebViewConfiguration()
        config.defaultWebpagePreferences.preferredContentMode = .mobile
        return config
    }

    private func makeRequest() -> URLRequest {
        var request = URLRequest(url: url)
        if let authToken = authToken, !authToken.isEmpty {
            request.setValue("Bearer \(authToken)", forHTTPHeaderField: "Authorization")
        }
        return request
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {
        context.coordinator.allowedHost = url.host
        context.coordinator.authToken = authToken

        if reloadTrigger || uiView.url != url {
            let request = makeRequest()
            uiView.load(request)
            DispatchQueue.main.async {
                reloadTrigger = false
            }
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    class Coordinator: NSObject, WKNavigationDelegate {
        weak var webView: WKWebView?
        var authToken: String?
        var allowedHost: String?

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        }

        func webView(_ webView: WKWebView,
                     decidePolicyFor navigationAction: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            decisionHandler(.allow)
        }
    }
}
