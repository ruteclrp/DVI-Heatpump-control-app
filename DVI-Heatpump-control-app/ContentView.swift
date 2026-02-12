//
//  ContentView.swift
//  DVI-Heatpump-control-app
//
//  Created by Lars Robert Pedersen on 24/01/2026.
//

import SwiftUI

import Foundation
import Security

func saveTokenToKeychain(token: String, service: String = "RPiToken", account: String = "default") -> Bool {
    let data = token.data(using: .utf8)!
    let query: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: service,
        kSecAttrAccount as String: account,
        kSecValueData as String: data
    ]
    SecItemDelete(query as CFDictionary) // Remove any existing item
    // Remove legacy entries without account to avoid duplicates.
    SecItemDelete([
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: service
    ] as CFDictionary)
    let status = SecItemAdd(query as CFDictionary, nil)
    return status == errSecSuccess
}

func loadTokenFromKeychain(service: String = "RPiToken", account: String = "default") -> String? {
    let query: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: service,
        kSecAttrAccount as String: account,
        kSecReturnData as String: true,
        kSecMatchLimit as String: kSecMatchLimitOne
    ]
    var dataTypeRef: AnyObject?
    let status = SecItemCopyMatching(query as CFDictionary, &dataTypeRef)
    if status == errSecSuccess, let data = dataTypeRef as? Data {
        return String(data: data, encoding: .utf8)
    }

    // Backward compatibility for entries saved without account.
    let legacyQuery: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: service,
        kSecReturnData as String: true,
        kSecMatchLimit as String: kSecMatchLimitOne
    ]
    var legacyDataRef: AnyObject?
    let legacyStatus = SecItemCopyMatching(legacyQuery as CFDictionary, &legacyDataRef)
    if legacyStatus == errSecSuccess, let legacyData = legacyDataRef as? Data {
        let legacyToken = String(data: legacyData, encoding: .utf8)
        if let legacyToken = legacyToken {
            _ = saveTokenToKeychain(token: legacyToken, service: service, account: account)
        }
        return legacyToken
    }

    return nil
}

func deleteTokenFromKeychain(service: String = "RPiToken", account: String = "default") -> Bool {
    let query: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: service,
        kSecAttrAccount as String: account
    ]
    let status = SecItemDelete(query as CFDictionary)

    // Remove legacy entries without account as well.
    let legacyStatus = SecItemDelete([
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: service
    ] as CFDictionary)

    let okStatus = (status == errSecSuccess || status == errSecItemNotFound)
    let okLegacy = (legacyStatus == errSecSuccess || legacyStatus == errSecItemNotFound)
    return okStatus && okLegacy
}

// Fetch token from RPi bridge
func fetchTokenFromRPi(rpiIP: String, completion: @escaping (String?) -> Void) {
    // Sanitize address to avoid double http://
    var address = rpiIP.trimmingCharacters(in: .whitespacesAndNewlines)
    if !address.hasPrefix("http://") && !address.hasPrefix("https://") {
        address = "http://" + address
    }
    guard let url = URL(string: "\(address)/pair") else {
        print("[DEBUG] Invalid URL: \(address)/pair")
        completion(nil)
        return
    }
    print("[DEBUG] Fetching token from URL: \(url)")
    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.httpBody = Data()
    let task = URLSession.shared.dataTask(with: request) { data, response, error in
        if let error = error {
            print("[DEBUG] Network error: \(error.localizedDescription)")
            completion(nil)
            return
        }
        if let httpResponse = response as? HTTPURLResponse {
            print("[DEBUG] HTTP status code: \(httpResponse.statusCode)")
        }
        guard let data = data else {
            print("[DEBUG] No data received from server.")
            completion(nil)
            return
        }
            // Try to decode JSON response
            do {
                if let json = try JSONSerialization.jsonObject(with: data, options: []) as? [String: Any],
                   let token = json["token"] as? String {
                    print("[DEBUG] Received token: \(token)")
                    completion(token)
                } else {
                    print("[DEBUG] JSON does not contain 'token' key: \(String(data: data, encoding: .utf8) ?? "nil")")
                    completion(nil)
                }
            } catch {
                print("[DEBUG] Failed to parse JSON: \(error.localizedDescription)")
                completion(nil)
            }
    }
    task.resume()
}


struct ContentView: View {
    @EnvironmentObject var bridgeConfig: BridgeConfig
    @Environment(\.verticalSizeClass) private var verticalSizeClass

    @State private var manualAddress = ""
    // Removed showWebView: no longer using SidecarWebView
    @State private var errorMessage: String?
    @State private var reloadTrigger = false
    @State private var showQRScanner = false
    @State private var scannedCode: String? = nil
    @State private var hasAutoConnected = false
    @State private var isRefreshingTunnel = false
    @State private var tunnelRefreshMessage: String?
    @State private var tokenStatus: String? = nil
    @State private var showWebView = false
    @State private var webViewURL: URL? = nil
    @State private var showResetConfirm = false

    private var localBridgeAddress: String? {
        bridgeConfig.rawAddress ?? bridgeConfig.discoveredBridges.first?.preferredLocalAddress
    }

    private var hasLocalBridge: Bool {
        !bridgeConfig.discoveredBridges.isEmpty
    }

    var body: some View {
        let isLandscape = verticalSizeClass == .compact
        return NavigationView {
            mainContent(isLandscape: isLandscape)
                .navigationTitle(isLandscape ? "" : "DVI Heatpump")
                .toolbar(isLandscape ? .hidden : .visible, for: .navigationBar)
                .navigationBarHidden(isLandscape)
                .onChange(of: bridgeConfig.activeURL) {
                    guard let newURL = bridgeConfig.activeURL else { return }
                    if webViewURL?.absoluteString == newURL.absoluteString {
                        return
                    }
                    webViewURL = newURL
                    if showWebView {
                        reloadTrigger = true
                    }
                }
                .onChange(of: bridgeConfig.discoveredBridges) {
                    if !hasAutoConnected && bridgeConfig.shouldAutoConnect() {
                        hasAutoConnected = true
                        if let activeURL = bridgeConfig.activeURL {
                            manualAddress = activeURL.absoluteString
                            attemptConnection()
                        }
                    } else if bridgeConfig.activeURL == nil,
                              bridgeConfig.rawAddress == nil,
                              let firstBridge = bridgeConfig.discoveredBridges.first {
                        manualAddress = firstBridge.preferredLocalAddress
                        attemptConnection()
                    }
                }
        }
    }

    @ViewBuilder
    private func mainContent(isLandscape: Bool) -> some View {
        VStack(spacing: 0) {
            if showWebView, let url = webViewURL ?? bridgeConfig.activeURL {
                webViewContent(url: url, isLandscape: isLandscape)
            } else {
                connectContent
            }
        }
        .onAppear {
            autoConnectIfRemote()
        }
        .onChange(of: bridgeConfig.currentNetworkType) {
            autoConnectIfRemote()
        }
    }

    @ViewBuilder
    private func webViewContent(url: URL, isLandscape: Bool) -> some View {
        let requiresAuth = (url.scheme?.lowercased() == "https")
        let authToken = requiresAuth ? loadTokenFromKeychain() : nil
        if !isLandscape {
            connectionStatusView(authToken: authToken, requiresAuth: requiresAuth)
        }
        webViewCanvas(url: url, authToken: authToken, isLandscape: isLandscape)
    }

    @ViewBuilder
    private func connectionStatusView(authToken: String?, requiresAuth: Bool) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Connection Status")
                    .font(.headline)
                Spacer()
                Button("Settings") {
                    showWebView = false
                }
            }
            Text("Network: \(bridgeConfig.currentNetworkType)")
                .font(.caption)
                .foregroundColor(.secondary)
            Text("Mode: \(bridgeConfig.isOnLocalNetwork ? "Local" : "Remote")")
                .font(.caption)
                .foregroundColor(.secondary)
            if let activeAddress = bridgeConfig.rawAddress {
                Text("Address: \(activeAddress)")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            if requiresAuth {
                Text("Auth: \(authToken == nil ? "Missing" : "Token loaded")")
                    .font(.caption)
                    .foregroundColor(authToken == nil ? .orange : .secondary)
            }
        }
        .padding()
        .background(Color(.systemGray6))
    }

    @ViewBuilder
    private func webViewCanvas(url: URL, authToken: String?, isLandscape: Bool) -> some View {
        GeometryReader { proxy in
            let webView = SidecarWebView(url: url, authToken: authToken, reloadTrigger: $reloadTrigger)
                .frame(width: proxy.size.width, height: proxy.size.height)

            if isLandscape {
                ZStack {
                    Color.black
                    webView
                }
                .ignoresSafeArea()
            } else {
                webView
            }
        }
    }

    private var connectContent: some View {
        VStack(spacing: 24) {
            // Only show title if not in settings sheet
            Text("Connect to your DVI Heatpump")
                .font(.title2)
                .padding(.top, 40)

            // Auto-discovered bridges
            if !bridgeConfig.discoveredBridges.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Found on Network")
                        .font(.headline)
                        .padding(.horizontal)
                    ForEach(bridgeConfig.discoveredBridges) { bridge in
                        Button(action: {
                            bridgeConfig.saveBridge(bridge)
                            manualAddress = bridgeConfig.isOnLocalNetwork ? bridge.preferredLocalAddress : (bridge.tunnelURL ?? bridge.preferredLocalAddress)
                            attemptConnection()
                            hideKeyboard()
                        }) {
                            HStack {
                                Image(systemName: "antenna.radiowaves.left.and.right")
                                VStack(alignment: .leading) {
                                    Text(bridge.name)
                                        .font(.subheadline)
                                    if bridgeConfig.isOnLocalNetwork {
                                        // Show hostname if available, otherwise IP
                                        if let hostname = bridge.hostname, !hostname.isEmpty {
                                            Text("Local: \(hostname)")
                                                .font(.caption)
                                                .foregroundColor(.secondary)
                                        } else {
                                            Text("Local: \(bridge.localAddress)")
                                                .font(.caption)
                                                .foregroundColor(.secondary)
                                        }
                                    } else {
                                        Text("Remote: \(bridge.tunnelURL ?? "N/A")")
                                            .font(.caption)
                                            .foregroundColor(.secondary)
                                    }
                                }
                                Spacer()
                                Image(systemName: "chevron.right")
                            }
                            .padding()
                            .background(Color(.systemGray6))
                            .cornerRadius(8)
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.horizontal)
                }
            }

            VStack(alignment: .leading) {
                Text("Manual Entry")
                    .font(.headline)
                TextField("IP, hostname, or tunnel URL", text: $manualAddress)
                    .textFieldStyle(RoundedBorderTextFieldStyle())
                    .keyboardType(.URL)
                    .autocapitalization(.none)
                    .disableAutocorrection(true)
            }
            .padding(.horizontal)

            HStack(spacing: 16) {
                Button(action: {
                    showQRScanner = true
                    hideKeyboard()
                }) {
                    Label("Scan QR", systemImage: "qrcode.viewfinder")
                }
                .buttonStyle(.bordered)
                Button("Connect") {
                    attemptConnection()
                    hideKeyboard()
                }
                .buttonStyle(.borderedProminent)
            }
            .padding(.top, 10)

            // Tunnel refresh and token fetch UI remains (for now)
            if hasLocalBridge && localBridgeAddress != nil {
                VStack(spacing: 8) {
                    Button(action: {
                        refreshTunnelURL()
                        hideKeyboard()
                    }) {
                        HStack {
                            if isRefreshingTunnel {
                                ProgressView()
                                    .scaleEffect(0.8)
                            } else {
                                Image(systemName: "arrow.clockwise")
                            }
                            Text(isRefreshingTunnel ? "Updating Tunnel..." : "Update Tunnel URL")
                        }
                    }
                    .buttonStyle(.bordered)
                    .disabled(isRefreshingTunnel)
                    if let message = tunnelRefreshMessage {
                        Text(message)
                            .font(.caption)
                            .foregroundColor(message.contains("✓") ? .green : .orange)
                    }
                }
                .padding(.top, 8)
                Button(action: {
                    let rpiIP = localBridgeAddress ?? ""
                    fetchTokenFromRPi(rpiIP: rpiIP) { token in
                        DispatchQueue.main.async {
                            if let token = token {
                                let saved = saveTokenToKeychain(token: token)
                                tokenStatus = saved ? "Token saved!" : "Failed to save token"
                            } else {
                                tokenStatus = "Failed to fetch token"
                            }
                        }
                    }
                    hideKeyboard()
                }) {
                    Label("Fetch & Save RPi Token", systemImage: "key.fill")
                }
                .buttonStyle(.borderedProminent)
                if let status = tokenStatus {
                    Text(status)
                        .font(.caption)
                        .foregroundColor(status.contains("saved") ? .green : .red)
                }
                if loadTokenFromKeychain() != nil {
                    Text("Token saved in Keychain")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            if let error = errorMessage {
                Text(error)
                    .foregroundColor(.red)
                    .padding(.top, 10)
            }
            Button(role: .destructive) {
                showResetConfirm = true
            } label: {
                Label("Reset App", systemImage: "arrow.counterclockwise")
            }
            .buttonStyle(.bordered)
            .padding(.top, 8)
            Spacer()
        }
        .contentShape(Rectangle())
        .onTapGesture {
            hideKeyboard()
        }
    }

    private func attemptConnection() {
        let trimmedAddress = manualAddress.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedAddress.isEmpty else {
            errorMessage = "Please enter an IP or hostname."
            return
        }

        errorMessage = nil

        if let normalizedURL = bridgeConfig.normalizedURL(from: trimmedAddress) {
            bridgeConfig.rawAddress = trimmedAddress
            bridgeConfig.activeURL = normalizedURL
            webViewURL = normalizedURL
            showWebView = true
            return
        }

        errorMessage = "Invalid address format."
    }

    private func refreshTunnelURL() {
        guard let currentAddress = localBridgeAddress else {
            tunnelRefreshMessage = "⚠️ Not connected to bridge"
            return
        }

        isRefreshingTunnel = true
        tunnelRefreshMessage = nil

        bridgeConfig.fetchTunnelURLFromBridge(bridgeURL: currentAddress) { [self] tunnelURL in
            DispatchQueue.main.async {
                isRefreshingTunnel = false

                if tunnelURL != nil {
                    tunnelRefreshMessage = "✓ Tunnel URL updated"
                    DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                        if self.tunnelRefreshMessage == "✓ Tunnel URL updated" {
                            self.tunnelRefreshMessage = nil
                        }
                    }
                } else {
                    tunnelRefreshMessage = "⚠️ Could not fetch tunnel URL"
                }
            }
        }
    }

    private func autoConnectIfRemote() {
        guard !showWebView else { return }
        guard !bridgeConfig.isOnLocalNetwork else { return }

        if let activeURL = bridgeConfig.activeURL ?? bridgeConfig.normalizedURL {
            webViewURL = activeURL
            showWebView = true
            return
        }

        if let raw = bridgeConfig.rawAddress, !raw.isEmpty {
            manualAddress = raw
            attemptConnection()
        }
    }
}

// Helper to dismiss keyboard
#if canImport(UIKit)
extension View {
    func hideKeyboard() {
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
    }
}
#endif
