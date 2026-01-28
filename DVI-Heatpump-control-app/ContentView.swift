//
//  ContentView.swift
//  DVI-Heatpump-control-app
//
//  Created by Lars Robert Pedersen on 24/01/2026.
//

import SwiftUI
import Security

let keychainService = "DVIHeatpumpAppAuth"

struct ContentView: View {
    @EnvironmentObject var bridgeConfig: BridgeConfig

    @State private var manualAddress = ""
    @State private var username: String = ""
    @State private var password: String = ""
    @State private var showWebView = false
    @State private var errorMessage: String?
    @State private var reloadTrigger = false
    @State private var showQRScanner = false
    @State private var scannedCode: String? = nil
    @State private var hasAutoConnected = false
    @State private var isRefreshingTunnel = false
    @State private var tunnelRefreshMessage: String?

    var body: some View {
        NavigationView {
            VStack(spacing: 24) {

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
                                manualAddress = bridgeConfig.isOnLocalNetwork ? bridge.localAddress : (bridge.tunnelURL ?? bridge.localAddress)
                                attemptConnection()
                            }) {
                                HStack {
                                    Image(systemName: "antenna.radiowaves.left.and.right")
                                    VStack(alignment: .leading) {
                                        Text(bridge.name)
                                            .font(.subheadline)
                                        Text(bridgeConfig.isOnLocalNetwork ? "Local: \(bridge.localAddress)" : "Remote: \(bridge.tunnelURL ?? "N/A")")
                                            .font(.caption)
                                            .foregroundColor(.secondary)
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

                // Username/Password fields (only show when NOT on local WiFi)
                if !bridgeConfig.isOnLocalNetwork {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Authorization (Cloudflare only)")
                            .font(.headline)
                        TextField("Username", text: $username)
                            .textFieldStyle(RoundedBorderTextFieldStyle())
                            .autocapitalization(.none)
                            .disableAutocorrection(true)
                        SecureField("Password", text: $password)
                            .textFieldStyle(RoundedBorderTextFieldStyle())
                    }
                    .padding(.horizontal)
                }

                HStack(spacing: 16) {
                    Button(action: {
                        showQRScanner = true
                    }) {
                        Label("Scan QR", systemImage: "qrcode.viewfinder")
                    }
                    .buttonStyle(.bordered)
                    
                    Button("Connect") {
                        saveCredentials()
                        attemptConnection()
                    }
                    .buttonStyle(.borderedProminent)
                }
                .padding(.top, 10)                
                // Tunnel refresh button (only show when on local network)
                if bridgeConfig.isOnLocalNetwork && bridgeConfig.rawAddress != nil {
                    VStack(spacing: 8) {
                        Button(action: {
                            refreshTunnelURL()
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
                }
                if let error = errorMessage {
                    Text(error)
                        .foregroundColor(.red)
                        .padding(.top, 10)
                }

                Spacer()
            }
            .navigationTitle("DVI Heatpump")
            .onAppear {
                // Sync manual address with current rawAddress on appear
                if let currentAddress = bridgeConfig.rawAddress {
                    print("📝 ContentView: onAppear - syncing manualAddress to: \(currentAddress)")
                    manualAddress = currentAddress
                } else {
                    print("📝 ContentView: onAppear - rawAddress is nil")
                }
                loadCredentials()
                bridgeConfig.startDiscovery()
            }
            .onDisappear {
                bridgeConfig.stopDiscovery()
            }
            .onChange(of: bridgeConfig.discoveredBridges) {
                // Auto-connect if we find the saved bridge and haven't already connected
                if !hasAutoConnected && bridgeConfig.shouldAutoConnect() {
                    hasAutoConnected = true
                    if let activeURL = bridgeConfig.activeURL {
                        manualAddress = activeURL.absoluteString
                        attemptConnection()
                    }
                }
            }
            .onChange(of: bridgeConfig.rawAddress) {
                // Sync the manual address field with the active URL whenever it changes
                print("📝 ContentView: onChange(rawAddress) triggered")
                if let activeAddress = bridgeConfig.rawAddress {
                    print("📝 ContentView: rawAddress changed to \(activeAddress)")
                    print("📝 ContentView: manualAddress WAS: \(manualAddress)")
                    manualAddress = activeAddress
                    print("📝 ContentView: manualAddress NOW: \(manualAddress)")
                    // If web view is showing, trigger reload
                    if showWebView {
                        print("📝 ContentView: Web view is showing, triggering reload")
                        reloadTrigger = true
                    }
                } else {
                    print("📝 ContentView: rawAddress is nil")
                }
            }
            .onChange(of: bridgeConfig.activeURL) {
                // When activeURL changes (network switch), force reload if webview is showing
                if showWebView && bridgeConfig.activeURL != nil {
                    print("Active URL changed, triggering reload")
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
                            // Connection status indicator
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
                            
                            SidecarWebView(url: url, reloadTrigger: $reloadTrigger, username: bridgeConfig.isOnLocalNetwork ? nil : username, password: bridgeConfig.isOnLocalNetwork ? nil : password)
                        }
                        .navigationTitle("Sidecar")
                        .navigationBarTitleDisplayMode(.inline)
                        .toolbar {

                            // Change IP / Close
                            ToolbarItem(placement: .navigationBarLeading) {
                                Button("Change Address") {
                                    showWebView = false
                                    // Sync address when returning to ContentView
                                    if let currentAddress = bridgeConfig.rawAddress {
                                        manualAddress = currentAddress
                                        print("📝 WebView closing - synced manualAddress to: \(currentAddress)")
                                    }
                                }
                            }

                            // Reload button
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

                // MARK: - Keychain Integration
                private func saveCredentials() {
                    guard !username.isEmpty, !password.isEmpty else { return }
                    if let userData = username.data(using: .utf8) {
                        _ = KeychainHelper.save(service: keychainService, account: "username", data: userData)
                    }
                    if let passData = password.data(using: .utf8) {
                        _ = KeychainHelper.save(service: keychainService, account: "password", data: passData)
                    }
                }

                private func loadCredentials() {
                    if let userData = KeychainHelper.load(service: keychainService, account: "username"),
                       let user = String(data: userData, encoding: .utf8) {
                        username = user
                    }
                    if let passData = KeychainHelper.load(service: keychainService, account: "password"),
                       let pass = String(data: passData, encoding: .utf8) {
                        password = pass
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
