//
//  ContentView.swift
//  DVI-Heatpump-control-app
//
//  Created by Lars Robert Pedersen on 24/01/2026.
//

import SwiftUI

import Foundation
import Security

func saveTokenToKeychain(token: String, service: String = "RPiToken") -> Bool {
    let data = token.data(using: .utf8)!
    let query: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: service,
        kSecValueData as String: data
    ]
    SecItemDelete(query as CFDictionary) // Remove any existing item
    let status = SecItemAdd(query as CFDictionary, nil)
    return status == errSecSuccess
}

func loadTokenFromKeychain(service: String = "RPiToken") -> String? {
    let query: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: service,
        kSecReturnData as String: true,
        kSecMatchLimit as String: kSecMatchLimitOne
    ]
    var dataTypeRef: AnyObject?
    let status = SecItemCopyMatching(query as CFDictionary, &dataTypeRef)
    if status == errSecSuccess, let data = dataTypeRef as? Data {
        return String(data: data, encoding: .utf8)
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
    @State private var showWebView = false
    @State private var errorMessage: String?
    @State private var reloadTrigger = false
    @State private var showQRScanner = false
    @State private var scannedCode: String? = nil
    @State private var hasAutoConnected = false
    @State private var isRefreshingTunnel = false
    @State private var tunnelRefreshMessage: String?
    @State private var tokenStatus: String? = nil

    var body: some View {
        NavigationView {
            VStack(spacing: 24) {
                // Only show title if not in settings sheet
                if !showWebView {
                    Text("Connect to your DVI Heatpump")
                        .font(.title2)
                        .padding(.top, 40)
                }

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

                // Tunnel refresh button (only show when on local network)
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

                    // Fetch and save token from RPi (visible only on local network)
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
                    if let token = loadTokenFromKeychain() {
                        Text("Saved Token: \(token)")
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
                    if showWebView {
                        reloadTrigger = true
                    }
                }
            }
            .onChange(of: bridgeConfig.activeURL) {
                if showWebView && bridgeConfig.activeURL != nil {
                    reloadTrigger = true
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
            .sheet(isPresented: $showWebView) {
                NavigationView {
                    if let url = bridgeConfig.normalizedURL {
                        VStack(spacing: 0) {
                            HStack {
                                if bridgeConfig.isVerifyingConnection {
                                    ProgressView()
                                        .scaleEffect(0.8)
                                    Text("Verifying connection...")
                                        .font(.subheadline)
                                        .foregroundColor(.secondary)
                                } else {
                                    Image(systemName: bridgeConfig.isOnLocalNetwork ? "wifi" : "antenna.radiowaves.left.and.right")
                                        .foregroundColor(bridgeConfig.isOnLocalNetwork ? .green : .blue)
                                        .font(.system(size: 14))
                                    Text(bridgeConfig.isOnLocalNetwork ? "WiFi - Home Network" : "\(bridgeConfig.currentNetworkType) - Remote Tunnel")
                                        .font(.subheadline)
                                        .foregroundColor(.primary)
                                }
                                Spacer()
                            }
                            .padding()
                            .background(bridgeConfig.isOnLocalNetwork ? Color.green.opacity(0.1) : Color.blue.opacity(0.1))
                            .border(bridgeConfig.isOnLocalNetwork ? Color.green.opacity(0.3) : Color.blue.opacity(0.3), width: 0.5)
                            SidecarWebView(url: url, reloadTrigger: $reloadTrigger)
                        }
                        .navigationTitle("Sidecar")
                        .navigationBarTitleDisplayMode(.inline)
                        .toolbar {
                            ToolbarItem(placement: .navigationBarLeading) {
                                Button("Change Address") {
                                    showWebView = false
                                    if let currentAddress = bridgeConfig.rawAddress {
                                        manualAddress = currentAddress
                                    }
                                }
                            }
                            ToolbarItem(placement: .navigationBarTrailing) {
                                Button("Reload") {
                                    reloadTrigger = true
                                }
                            }
                        }
                    } else {
                        Text("Invalid URL")
                            .foregroundColor(.red)
                    }
                }
            }
        }
    }
    
    private func attemptConnection() {
        guard !manualAddress.isEmpty else {
            errorMessage = "Please enter an IP or hostname."
            return
        }

        bridgeConfig.rawAddress = manualAddress
        errorMessage = nil

        if bridgeConfig.normalizedURL == nil {
            errorMessage = "Invalid address format."
            return
        }

        showWebView = true
    }    
    private func refreshTunnelURL() {
        guard let currentAddress = bridgeConfig.rawAddress else {
            tunnelRefreshMessage = "⚠️ Not connected to bridge"
            return
        }
        
        isRefreshingTunnel = true
        tunnelRefreshMessage = nil
        
        bridgeConfig.fetchTunnelURLFromBridge(bridgeURL: currentAddress) { [self] tunnelURL in
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
    // Helper to dismiss keyboard
    #if canImport(UIKit)
    extension View {
        func hideKeyboard() {
            UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
        }
    }
    #endif
