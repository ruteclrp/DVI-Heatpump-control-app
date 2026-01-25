//
//  BridgeConfig.swift
//  DVI-Heatpump-control-app
//
//  Created by Lars Robert Pedersen on 24/01/2026.
//
import Foundation
import Combine

class BridgeConfig: NSObject, ObservableObject, NetServiceBrowserDelegate, NetServiceDelegate {
    @Published var rawAddress: String? = UserDefaults.standard.string(forKey: "savedTunnelURL")
    @Published var discoveredBridges: [DiscoveredBridge] = []
    
    private var browser: NetServiceBrowser?
    private var resolvingServices: Set<NetService> = []
    private var discoveredServicesMap: [String: DiscoveredBridge] = [:]
    
    struct DiscoveredBridge: Identifiable, Equatable {
        let id = UUID()
        let name: String
        let localAddress: String
        let tunnelURL: String?
    }

    override init() {
        super.init()
    }

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

    // MARK: - Discovery with NetService (backward compatible)
    func startDiscovery() {
        browser = NetServiceBrowser()
        browser?.delegate = self
        browser?.searchForServices(ofType: "_dvi-bridge._tcp.", inDomain: "local.")
    }
    
    func stopDiscovery() {
        browser?.stop()
        browser = nil
        
        // Stop resolving all services
        for service in resolvingServices {
            service.stop()
        }
        resolvingServices.removeAll()
        discoveredServicesMap.removeAll()
    }

    // MARK: - NetServiceBrowserDelegate
    func netServiceBrowser(_ browser: NetServiceBrowser, didFind service: NetService, moreComing: Bool) {
        print("Found service: \(service.name)")
        service.delegate = self
        resolvingServices.insert(service)
        service.resolve(withTimeout: 5.0)
    }
    
    func netServiceBrowser(_ browser: NetServiceBrowser, didRemove service: NetService, moreComing: Bool) {
        print("Removed service: \(service.name)")
        discoveredServicesMap.removeValue(forKey: service.name)
        resolvingServices.remove(service)
        updateDiscoveredBridges()
    }
    
    func netServiceBrowser(_ browser: NetServiceBrowser, didNotSearch errorDict: [String : NSNumber]) {
        print("Search failed: \(errorDict)")
    }
    
    // MARK: - NetServiceDelegate
    func netServiceDidResolveAddress(_ sender: NetService) {
        print("Resolved service: \(sender.name)")
        
        var localAddress = "\(sender.hostName ?? sender.name).local"
        
        // Try to get actual IP address from resolved addresses
        if let addresses = sender.addresses, !addresses.isEmpty {
            for addressData in addresses {
                let address = addressData.withUnsafeBytes { (pointer: UnsafeRawBufferPointer) -> String? in
                    guard let baseAddress = pointer.baseAddress else { return nil }
                    let sockaddr = baseAddress.assumingMemoryBound(to: sockaddr.self)
                    
                    if sockaddr.pointee.sa_family == AF_INET {
                        return baseAddress.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { addr in
                            var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
                            var sinAddr = addr.pointee.sin_addr
                            inet_ntop(AF_INET, &sinAddr, &buffer, socklen_t(INET_ADDRSTRLEN))
                            return String(cString: buffer)
                        }
                    }
                    return nil
                }
                
                if let ipAddress = address {
                    localAddress = ipAddress
                    break
                }
            }
        }
        
        // Read TXT record for tunnel URL
        var tunnelURL: String? = nil
        if let txtData = sender.txtRecordData() {
            let txtDict = NetService.dictionary(fromTXTRecord: txtData)
            if let tunnelData = txtDict["tunnel_url"], let tunnel = String(data: tunnelData, encoding: .utf8) {
                tunnelURL = tunnel
                print("Found tunnel URL: \(tunnel)")
            }
        }
        
        let port = sender.port > 0 ? sender.port : 5000
        let bridge = DiscoveredBridge(
            name: sender.name,
            localAddress: "http://\(localAddress):\(port)",
            tunnelURL: tunnelURL
        )
        
        discoveredServicesMap[sender.name] = bridge
        resolvingServices.remove(sender)
        updateDiscoveredBridges()
    }
    
    func netService(_ sender: NetService, didNotResolve errorDict: [String : NSNumber]) {
        print("Failed to resolve service: \(sender.name), error: \(errorDict)")
        resolvingServices.remove(sender)
    }
    
    private func updateDiscoveredBridges() {
        DispatchQueue.main.async {
            self.discoveredBridges = Array(self.discoveredServicesMap.values)
        }
    }

    // MARK: - Persistence
    func saveTunnelURL(_ url: String) {
        UserDefaults.standard.set(url, forKey: "savedTunnelURL")
        rawAddress = url
    }
}
