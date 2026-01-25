//
//  BridgeConfig.swift
//  DVI-Heatpump-control-app
//
//  Created by Lars Robert Pedersen on 24/01/2026.
//
import Foundation
import Combine
import Network

class BridgeConfig: NSObject, ObservableObject, NetServiceBrowserDelegate, NetServiceDelegate {
    @Published var rawAddress: String? = UserDefaults.standard.string(forKey: "savedTunnelURL")
    @Published var discoveredBridges: [DiscoveredBridge] = []
    @Published var isOnLocalNetwork: Bool = false
    @Published var activeURL: URL? = nil
    
    private var browser: NetServiceBrowser?
    private var resolvingServices: Set<NetService> = []
    private var discoveredServicesMap: [String: DiscoveredBridge] = [:]
    private var networkMonitor: NWPathMonitor?
    private var monitorQueue = DispatchQueue(label: "NetworkMonitor")
    
    // Store saved bridge info
    private var savedTunnelURL: String? {
        get { UserDefaults.standard.string(forKey: "savedTunnelURL") }
        set { UserDefaults.standard.set(newValue, forKey: "savedTunnelURL") }
    }
    private var savedBridgeName: String? {
        get { UserDefaults.standard.string(forKey: "savedBridgeName") }
        set { UserDefaults.standard.set(newValue, forKey: "savedBridgeName") }
    }
    
    struct DiscoveredBridge: Identifiable, Equatable {
        let id = UUID()
        let name: String
        let localAddress: String
        let tunnelURL: String?
    }

    override init() {
        super.init()
        startNetworkMonitoring()
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
    
    // Check if the current URL is a local address (IP or .local hostname)
    private var isCurrentURLLocal: Bool {
        guard let raw = rawAddress?.trimmingCharacters(in: .whitespacesAndNewlines) else { return false }
        
        // Check if it's an IP address
        if raw.range(of: #"^https?://\d{1,3}(\.\d{1,3}){3}"#, options: .regularExpression) != nil {
            return true
        }
        
        // Check if it's a .local address
        if raw.contains(".local") {
            return true
        }
        
        // Check if it's just an IP without protocol
        if raw.range(of: #"^\d{1,3}(\.\d{1,3}){3}$"#, options: .regularExpression) != nil {
            return true
        }
        
        // Otherwise it's likely a tunnel URL (https://domain)
        return false
    }

    // MARK: - Network Monitoring
    func startNetworkMonitoring() {
        networkMonitor = NWPathMonitor()
        networkMonitor?.pathUpdateHandler = { [weak self] path in
            DispatchQueue.main.async {
                // When network changes, update the active URL (switch between local/tunnel)
                self?.updateActiveURL()
            }
        }
        networkMonitor?.start(queue: monitorQueue)
    }
    
    private func updateNetworkStatus() {
        // The indicator should reflect the URL type being used, not just the network type
        // If using a local address (IP or .local), show "Local Network"
        // If using a tunnel URL (https://domain), show "Remote Tunnel"
        isOnLocalNetwork = isCurrentURLLocal
    }
    
    func stopNetworkMonitoring() {
        networkMonitor?.cancel()
        networkMonitor = nil
    }
    
    // MARK: - URL Selection Logic
    func checkNetworkAndUpdateURL() {
        updateActiveURL()
    }
    
    private func updateActiveURL() {
        guard let path = networkMonitor?.currentPath else { return }
        let onWiFi = path.usesInterfaceType(.wifi)
        
        // Find the saved bridge if we have one
        if let savedName = savedBridgeName,
           let savedBridge = discoveredBridges.first(where: { $0.name == savedName || $0.tunnelURL == savedTunnelURL }) {
            // If on WiFi, use local URL
            if onWiFi {
                let newURL = savedBridge.localAddress
                if rawAddress != newURL {
                    activeURL = URL(string: newURL)
                    rawAddress = newURL
                    print("Switching to local URL: \(newURL)")
                }
            } else if let tunnelURL = savedBridge.tunnelURL {
                // Not on WiFi, use tunnel URL
                if rawAddress != tunnelURL {
                    activeURL = URL(string: tunnelURL)
                    rawAddress = tunnelURL
                    print("Switching to tunnel URL: \(tunnelURL)")
                }
            }
        } else if let tunnelURL = savedTunnelURL {
            // Fallback: if we have a saved tunnel URL, use it (especially when on cellular)
            if !onWiFi && rawAddress != tunnelURL {
                activeURL = normalizedURL
                rawAddress = tunnelURL
                print("Using saved tunnel URL: \(tunnelURL)")
            }
        }
        
        // Update network status after URL changes
        updateNetworkStatus()
    }
    
    // MARK: - Discovery with NetService
    func startDiscovery() {
        print("Starting bridge discovery...")
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
            print("Discovered bridges updated: \(self.discoveredBridges.count) bridges")
            
            // If we have a saved tunnel URL but no saved bridge name,
            // try to match it with a discovered bridge
            if self.savedTunnelURL != nil && self.savedBridgeName == nil {
                if let matchingBridge = self.discoveredBridges.first(where: { $0.tunnelURL == self.savedTunnelURL }) {
                    print("Auto-linking discovered bridge \(matchingBridge.name) to saved tunnel URL")
                    self.savedBridgeName = matchingBridge.name
                }
            }
            
            self.updateActiveURL()
            self.updateNetworkStatus()
        }
    }

    // MARK: - Persistence
    func saveTunnelURL(_ url: String) {
        savedTunnelURL = url
        rawAddress = url
    }
    
    func saveBridge(_ bridge: DiscoveredBridge) {
        if let tunnelURL = bridge.tunnelURL {
            savedTunnelURL = tunnelURL
        }
        savedBridgeName = bridge.name
        updateActiveURL()
    }
    
    // Check if we should auto-connect to a discovered bridge
    func shouldAutoConnect() -> Bool {
        guard let savedName = savedBridgeName else { return false }
        return discoveredBridges.contains(where: { $0.name == savedName })
    }
    
    deinit {
        stopNetworkMonitoring()
    }
}
