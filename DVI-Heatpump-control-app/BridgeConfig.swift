//
//  BridgeConfig.swift
//  DVI-Heatpump-control-app
//
//  Created by Lars Robert Pedersen on 24/01/2026.
//
import Foundation
import Combine

class BridgeConfig: ObservableObject {
    @Published var rawAddress: String? = nil

    init() {}

    var normalizedURL: URL? {
        guard let raw = rawAddress?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty else { return nil }

        // Already has scheme
        if raw.hasPrefix("http://") || raw.hasPrefix("https://") {
            return URL(string: raw)
        }

        // .local mDNS hostname
        if raw.hasSuffix(".local") {
            return URL(string: "http://\(raw):5000")
        }

        // IPv4 address
        if raw.range(of: #"^\d{1,3}(\.\d{1,3}){3}$"#,
                     options: .regularExpression) != nil {
            return URL(string: "http://\(raw):5000")
        }

        // Otherwise treat as remote domain (Cloudflare Tunnel)
        return URL(string: "https://\(raw)")
    }
}
