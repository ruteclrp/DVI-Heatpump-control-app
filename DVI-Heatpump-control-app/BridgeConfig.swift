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
    private var connections: [NWConnection] = []
    
    struct DiscoveredBridge: Identifiable {
        let id = UUID()
        let name: String
        let localAddress: String
        let tunnelURL: String?
    }

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
    
    func startDiscovery() {
        let params = NWParameters()
        params.includePeerToPeer = true
        
        browser = NWBrowser(for: .bonjour(type: "_dvi-bridge._tcp", domain: nil), using: params)
        
        browser?.stateUpdateHandler = { [weak self] state in
            if case .failed(let error) = state {
                print("Browser failed: \(error)")
            }
        }
        
        browser?.browseResultsChangedHandler = { [weak self] results, changes in
            guard let self = self else { return }
            // Clean up old connections
            self.connections.forEach { $0.cancel() }
            self.connections.removeAll()
            
            var bridges: [DiscoveredBridge] = []
            
            for result in results {
                if case .service(let name, _, let domain, let interface) = result.endpoint {
                    // Create connection to fetch TXT records
                    let connection = NWConnection(to: result.endpoint, using: .tcp)
                    self.connections.append(connection)
                    
                    // Fetch TXT records
                    connection.stateUpdateHandler = { state in
                        if case .ready = state {
                            // Extract metadata
                            if let metadata = connection.metadata(definition: NWProtocolTLS.definition) as? NWProtocolTLS.Metadata,
                               let txtRecords = metadata.txtRecord {
                                // Parse TXT records for tunnel URL
                                self.parseTXTRecords(txtRecords, name: name, domain: domain, bridges: &bridges)
                            } else {
                                // No TXT records available, add without tunnel
                                let bridge = DiscoveredBridge(
                                    name: name,
                                    localAddress: "\(name).\(domain):5000",
                                    tunnelURL: nil
                                )
                                bridges.append(bridge)
                            }
        connections.forEach { $0.cancel() }
        connections.removeAll()
    }
    
    private func parseTXTRecords(_ records: Data, name: String, domain: String, bridges: inout [DiscoveredBridge]) {
        // Parse TXT record data for tunnel URL
        // TXT records are in the format: key=value
        // Look for "tunnel=https://..."
        // This is a simplified version - proper parsing would decode the TXT record format
    }
    
    func saveTunnelURL(_ url: String) {
        UserDefaults.standard.set(url, forKey: "savedTunnelURL")
        rawAddress = url
                        }
                    }
                    connection.start(queue: .main)
                    
                    // Simplified: add bridge immediately (tunnel URL fetched async)
                    let bridge = DiscoveredBridge(
                        name: name,
                        localAddress: "\(name).\(domain):5000",
                        tunnelURL: nil // Will be updated when TXT records arrive
                    )
                    bridges.append(bridge   tunnelURL: nil // Will be populated from TXT records
                    ))
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
}
