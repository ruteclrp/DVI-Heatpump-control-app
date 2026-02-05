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

    var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                if showWebView, let url = webViewURL ?? bridgeConfig.activeURL {
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
                    }
                    .padding()
                    .background(Color(.systemGray6))

                    SidecarWebView(url: url, reloadTrigger: $reloadTrigger)
                        .edgesIgnoringSafeArea(.bottom)
                } else {
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
                        if bridgeConfig.isOnLocalNetwork && bridgeConfig.rawAddress != nil {
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
                                let rpiIP = bridgeConfig.rawAddress ?? ""
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
                        Spacer()
                    }
                    .contentShape(Rectangle())
                    .onTapGesture {
                        hideKeyboard()
                    }
                }
            }
            .navigationTitle("DVI Heatpump")
            // ...existing code...
            .onAppear {
                if let currentAddress = bridgeConfig.rawAddress {
                    manualAddress = currentAddress
                }
                bridgeConfig.startDiscovery()
            }
            .onDisappear {
                bridgeConfig.stopDiscovery()
            }
            .onChange(of: bridgeConfig.discoveredBridges) {
                if !hasAutoConnected && bridgeConfig.shouldAutoConnect() {
                    hasAutoConnected = true
                    if let activeURL = bridgeConfig.activeURL {
                        manualAddress = activeURL.absoluteString
                        attemptConnection()
                    }
                }
            }
            .onChange(of: bridgeConfig.rawAddress) {
                if let activeAddress = bridgeConfig.rawAddress {
                    manualAddress = activeAddress
                }
            }
            .onChange(of: scannedCode) {
                if let code = scannedCode {
                    manualAddress = code
                    bridgeConfig.saveTunnelURL(code)
                    attemptConnection()
                    scannedCode = nil
                }
            }
            .sheet(isPresented: $showQRScanner) {
                QRScannerView(scannedCode: $scannedCode)
                    .edgesIgnoringSafeArea(.all)
            }
            // Removed SidecarWebView sheet
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
        guard let currentAddress = bridgeConfig.rawAddress else {
            tunnelRefreshMessage = "⚠️ Not connected to bridge"
            return
        }
        
        isRefreshingTunnel = true
        tunnelRefreshMessage = nil
        
        bridgeConfig.fetchTunnelURLFromBridge(bridgeURL: currentAddress) { [self] tunnelURL in
            DispatchQueue.main.async {
                isRefreshingTunnel = false
                
                if let tunnelURL = tunnelURL {
                    tunnelRefreshMessage = "✓ Tunnel URL updated"
                    // Clear message after 3 seconds
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
}
    // Helper to dismiss keyboard
    #if canImport(UIKit)
    extension View {
        func hideKeyboard() {
            UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
        }
    }
    #endif
