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
                // Restart discovery when app becomes active
                bridgeConfig.startDiscovery()
                // Force network status update
                bridgeConfig.checkNetworkAndUpdateURL()
            } else if newPhase == .background {
                // Stop discovery when going to background
                bridgeConfig.stopDiscovery()
            }
        }
    }
}
