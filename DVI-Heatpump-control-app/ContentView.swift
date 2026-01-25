//
//  ContentView.swift
//  DVI-Heatpump-control-app
//
//  Created by Lars Robert Pedersen on 24/01/2026.
//

import SwiftUI

struct ContentView: View {
    @EnvironmentObject var bridgeConfig: BridgeConfig

    @State private var manualAddress = ""
    @State private var showWebView = false
    @State private var errorMessage: String?
    @State private var reloadTrigger = false
    @State private var showQRScanner = false
    @State private var scannedCode: String? = nil

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
                                // Save tunnel URL if available
                                if let tunnelURL = bridge.tunnelURL {
                                    bridgeConfig.saveTunnelURL(tunnelURL)
                                    manualAddress = tunnelURL
                                } else {
                                    // Use local address for now
                                    manualAddress = bridge.localAddress
                                }
                                attemptConnection()
                            }) {
                                HStack {
                                    Image(systemName: "antenna.radiowaves.left.and.right")
                                    VStack(alignment: .leading) {
                                        Text(bridge.name)
                                            .font(.subheadline)
                                        Text(bridge.tunnelURL ?? bridge.localAddress)
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

                HStack(spacing: 16) {
                    Button(action: {
                        showQRScanner = true
                    }) {
                        Label("Scan QR", systemImage: "qrcode.viewfinder")
                    }
                    .buttonStyle(.bordered)
                    
                    Button("Connect") {
                        attemptConnection()
                    }
                    .buttonStyle(.borderedProminent)
                }
                .padding(.top, 10)

                if let error = errorMessage {
                    Text(error)
                        .foregroundColor(.red)
                        .padding(.top, 10)
                }

                Spacer()
            }
            .navigationTitle("DVI Heatpump")
            .onAppear {
                bridgeConfig.startDiscovery()
            }
            .onDisappear {
                bridgeConfig.stopDiscovery()
            }
            .onChange(of: scannedCode) { newValue in
                if let code = newValue {
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
                        SidecarWebView(url: url, reloadTrigger: $reloadTrigger)
                            .navigationTitle("Sidecar")
                            .navigationBarTitleDisplayMode(.inline)
                            .toolbar {

                                // Change IP / Close
                                ToolbarItem(placement: .navigationBarLeading) {
                                    Button("Change Address") {
                                        showWebView = false
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
}
