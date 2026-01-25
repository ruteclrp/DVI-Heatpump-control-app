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

    var body: some View {
        NavigationView {
            VStack(spacing: 24) {

                Text("Connect to your DVI Heatpump")
                    .font(.title2)
                    .padding(.top, 40)

                VStack(alignment: .leading) {
                    Text("Bridge Address")
                        .font(.headline)

                    TextField("IP or hostname (e.g. 192.168.1.50 or dvi.local)", text: $manualAddress)
                        .textFieldStyle(RoundedBorderTextFieldStyle())
                        .keyboardType(.URL)
                        .autocapitalization(.none)
                        .disableAutocorrection(true)
                }
                .padding(.horizontal)

                Button("Connect") {
                    attemptConnection()
                }
                .buttonStyle(.borderedProminent)
                .padding(.top, 10)

                if let error = errorMessage {
                    Text(error)
                        .foregroundColor(.red)
                        .padding(.top, 10)
                }

                Spacer()
            }
            .navigationTitle("DVI Heatpump")
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
