//
//  BridgeConfig.swift
//  DVI-Heatpump-control-app
//
//  Created by Lars Robert Pedersen on 24/01/2026.
//
import Foundation
import Combine
import Network

class BridgeConfig: ObservableObject {
    @Published var rawAddress: String? = UserDefaults.standard.string(forKey: "savedTunnelURL")
    @Published var discoveredBridges: [DiscoveredBridge] = []
    
    private var browser: NWBrowser?
    
    struct DiscoveredBridge: Identifiable, Equatable {
        let id = UUID()
        let name: String
        let localAddress: String
        let tunnelURL: String?
    }

    init() {}

    // MARK: - Normalized URL
    var normalizedURL: URL? {
        guard let raw = rawAddress?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty else { return nil }

        if raw.hasPrefix("http://") || raw.hasPrefix("https://") {
            return URL(string: raw)
        }

        if raw.hasSuffix(".local") {
            return URL(string: "http://\(raw):5000")
        }

        if raw.range(of: #"^\d{1,3}(\.\d{1,3}){3}$"#,
                     options: .regularExpression) != nil {
            return URL(string: "http://\(raw):5000")
        }

        return URL(string: "https://\(raw)")
    }

    // MARK: - Discovery
    func startDiscovery() {
        let params = NWParameters()
        params.includePeerToPeer = true
        
        browser = NWBrowser(
            for: .bonjour(type: "_dvi-bridge._tcp", domain: nil),
            using: params
        )
        
        browser?.stateUpdateHandler = { state in
            if case .failed(let error) = state {
                print("Browser failed: \(error)")
            }
        }
        
        browser?.browseResultsChangedHandler = { [weak self] results, _ in
            guard let self = self else { return }
            
            var bridges: [DiscoveredBridge] = []
            
            for result in results {
                if case .service(let name, _, let domain, _) = result.endpoint {
                    // TXT records not available via this SDK's Network.framework
                    let bridge = DiscoveredBridge(
                        name: name,
                        localAddress: "\(name).\(domain):5000",
                        tunnelURL: nil
                    )
                    bridges.append(bridge)
                }
            }
            
            DispatchQueue.main.async {
                self.discoveredBridges = bridges
            }
        }
        
        browser?.start(queue: .main)
    }
    
    func stopDiscovery() {
        browser?.cancel()
        browser = nil
    }

    // MARK: - Persistence
    func saveTunnelURL(_ url: String) {
        UserDefaults.standard.set(url, forKey: "savedTunnelURL")
        rawAddress = url
    }
}
