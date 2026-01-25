//
//  DVIHeatpumpApp.swift
//  DVI-Heatpump-control-app
//
//  Created by Lars Robert Pedersen on 24/01/2026.
//

import SwiftUI

@main
struct DVIHeatpumpApp: App {
    @StateObject private var bridgeConfig = BridgeConfig()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(bridgeConfig)
        }
        .onChange(of: scenePhase) { oldPhase, newPhase in
            if newPhase == .active {
                print("=== App became ACTIVE ===")
                // Restart health checks
                bridgeConfig.startHealthChecks()
                // Force complete restart of discovery when app becomes active
                bridgeConfig.stopDiscovery()
                // Small delay to ensure clean restart
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    bridgeConfig.startDiscovery()
                }
                // Force fresh network state check (this restarts network monitor)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    bridgeConfig.checkNetworkAndUpdateURL()
                }
            } else if newPhase == .background {
                print("=== App going to BACKGROUND ===")
                // Stop health checks to save battery
                bridgeConfig.stopHealthChecks()
                // Stop discovery when going to background to save battery
                bridgeConfig.stopDiscovery()
            }
        }
    }
}
