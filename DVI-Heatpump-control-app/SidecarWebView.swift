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
    @Binding var reloadTrigger: Bool
    let username: String?
    let password: String?

    func makeUIView(context: Context) -> WKWebView {
        let webView = WKWebView()
        context.coordinator.webView = webView
        webView.navigationDelegate = context.coordinator
        let request = makeRequest()
        webView.load(request)
        return webView
    }

    private func makeRequest() -> URLRequest {
        var request = URLRequest(url: url)
        if let user = username, let pass = password, !user.isEmpty, !pass.isEmpty {
            let loginString = String(format: "%@:%@", user, pass)
            if let loginData = loginString.data(using: .utf8) {
                let base64LoginString = loginData.base64EncodedString()
                request.setValue("Basic \(base64LoginString)", forHTTPHeaderField: "Authorization")
            }
        }
        return request
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {
        if reloadTrigger {
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
    }
}
