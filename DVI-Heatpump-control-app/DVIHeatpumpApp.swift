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

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(bridgeConfig)
        }
    }
}
