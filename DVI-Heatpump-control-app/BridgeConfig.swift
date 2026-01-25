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
    @Published var isVerifyingConnection: Bool = false
    @Published var currentNetworkType: String = "Unknown"  // "WiFi", "Cellular", "Other"
    
    private var browser: NetServiceBrowser?
    private var resolvingServices: Set<NetService> = []
    private var discoveredServicesMap: [String: DiscoveredBridge] = [:]
    private var networkMonitor: NWPathMonitor?
    private var monitorQueue = DispatchQueue(label: "NetworkMonitor")
    private var healthCheckTimer: Timer?
    private var discoveryRetryTimer: Timer?
    private var lastNetworkType: NWInterface.InterfaceType?
    
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
        // Cancel existing monitor if any
        networkMonitor?.cancel()
        
        networkMonitor = NWPathMonitor()
        networkMonitor?.pathUpdateHandler = { [weak self] path in
            guard let self = self else { return }
            let currentType = self.getCurrentInterfaceType(path: path)
            let networkChanged = currentType != self.lastNetworkType
            
            if let current = currentType {
                print("Network path update - Type: \(current), Changed: \(networkChanged)")
            }
            
            let previousType = self.lastNetworkType
            self.lastNetworkType = currentType
            
            DispatchQueue.main.async {
                if networkChanged && currentType != nil {
                    print("Network type changed from \(String(describing: previousType)) to \(String(describing: currentType)), forcing switch...")
                    // Update network status immediately
                    self.updateNetworkStatus()
                    // When network changes, force verify and switch
                    self.verifyAndUpdateActiveURL(forceSwitch: true)
                } else {
                    self.updateNetworkStatus()
                    self.updateActiveURL()
                }
            }
        }
        networkMonitor?.start(queue: monitorQueue)
        
        // Start periodic health checks if not already running
        if healthCheckTimer == nil {
            startHealthChecks()
        }
    }
    
    private func getCurrentInterfaceType(path: NWPath) -> NWInterface.InterfaceType? {
        if path.usesInterfaceType(.wifi) { return .wifi }
        if path.usesInterfaceType(.cellular) { return .cellular }
        if path.usesInterfaceType(.wiredEthernet) { return .wiredEthernet }
        return nil
    }
    
    private func updateNetworkStatus() {
        // Update based on ACTUAL network type, not URL type
        guard let path = networkMonitor?.currentPath else {
            isOnLocalNetwork = false
            currentNetworkType = "Unknown"
            return
        }
        
        let onWiFi = path.usesInterfaceType(.wifi)
        isOnLocalNetwork = onWiFi
        
        if path.usesInterfaceType(.wifi) {
            currentNetworkType = "WiFi"
        } else if path.usesInterfaceType(.cellular) {
            currentNetworkType = "Cellular"
        } else if path.usesInterfaceType(.wiredEthernet) {
            currentNetworkType = "Ethernet"
        } else {
            currentNetworkType = "Other"
        }
        
        print("Network status updated: \(currentNetworkType), isOnLocalNetwork: \(isOnLocalNetwork)")
    }
    
    func stopNetworkMonitoring() {
        networkMonitor?.cancel()
        networkMonitor = nil
        stopHealthChecks()
        stopDiscoveryRetry()
    }
    
    // MARK: - Health Checking
    func startHealthChecks() {
        // Check connection health every 10 seconds
        healthCheckTimer?.invalidate()
        healthCheckTimer = Timer.scheduledTimer(withTimeInterval: 10.0, repeats: true) { [weak self] _ in
            self?.verifyCurrentConnection()
        }
        print("✅ Health checks started")
    }
    
    func stopHealthChecks() {
        healthCheckTimer?.invalidate()
        healthCheckTimer = nil
        print("⏹️ Health checks stopped")
    }
    
    private func verifyCurrentConnection() {
        guard let urlString = rawAddress,
              let url = URL(string: urlString.hasPrefix("http") ? urlString : "http://\(urlString)") else {
            return
        }
        
        // Don't try to verify local addresses when not on WiFi
        guard let path = networkMonitor?.currentPath else { return }
        let onWiFi = path.usesInterfaceType(.wifi)
        
        if isCurrentURLLocal && !onWiFi {
            print("⏭️ Skipping health check - local URL on non-WiFi network")
            // Try to recover by switching to tunnel
            attemptConnectionRecovery()
            return
        }
        
        // Quick HEAD request to check if connection is alive
        var request = URLRequest(url: url)
        request.httpMethod = "HEAD"
        request.timeoutInterval = 3.0
        
        URLSession.shared.dataTask(with: request) { [weak self] _, response, error in
            DispatchQueue.main.async {
                if let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode < 400 {
                    // Connection is good
                    return
                } else if error != nil {
                    // Connection failed, try to switch if available
                    print("Health check failed for \(urlString), attempting recovery...")
                    self?.attemptConnectionRecovery()
                }
            }
        }.resume()
    }
    
    private func attemptConnectionRecovery() {
        guard let savedName = savedBridgeName,
              let savedBridge = discoveredBridges.first(where: { $0.name == savedName }) else {
            return
        }
        
        // Try switching to the alternate connection method
        if isOnLocalNetwork, let tunnel = savedBridge.tunnelURL {
            print("Local connection failed, trying tunnel: \(tunnel)")
            verifyAndSwitchURL(tunnel, fallback: nil, timeout: 3.0)
        } else {
            print("Tunnel connection failed, trying local: \(savedBridge.localAddress)")
            verifyAndSwitchURL(savedBridge.localAddress, fallback: savedBridge.tunnelURL, timeout: 3.0)
        }
    }
    
    // MARK: - URL Selection Logic
    func checkNetworkAndUpdateURL() {
        // Force a fresh network check by briefly stopping and restarting monitor
        print("🌐 checkNetworkAndUpdateURL() called")
        print("🌐 Current rawAddress: \(rawAddress ?? "nil")")
        print("Forcing fresh network state check...")
        networkMonitor?.cancel()
        
        // Create fresh monitor to get current network state
        let freshMonitor = NWPathMonitor()
        let semaphore = DispatchSemaphore(value: 0)
        var detectedPath: NWPath?
        
        freshMonitor.pathUpdateHandler = { path in
            detectedPath = path
            semaphore.signal()
        }
        freshMonitor.start(queue: DispatchQueue.global())
        
        // Wait up to 1 second for path update
        _ = semaphore.wait(timeout: .now() + 1.0)
        freshMonitor.cancel()
        
        // Restart our main monitor
        DispatchQueue.main.async { [weak self] in
            self?.startNetworkMonitoring()
            
            // Update network status first
            self?.updateNetworkStatus()
            
            // Now force update with the detected network state
            if let path = detectedPath {
                let onWiFi = path.usesInterfaceType(.wifi)
                let onCellular = path.usesInterfaceType(.cellular)
                print("Fresh network check - WiFi: \(onWiFi), Cellular: \(onCellular)")
                self?.forceUpdateForNetworkType(onWiFi: onWiFi)
            } else {
                self?.verifyAndUpdateActiveURL(forceSwitch: true)
            }
        }
    }
    
    private func forceUpdateForNetworkType(onWiFi: Bool) {
        print("🔄 forceUpdateForNetworkType - onWiFi: \(onWiFi)")
        print("🔄 Discovered bridges: \(discoveredBridges.count)")
        
        // If not on WiFi, clear discovered bridges since they're not reachable
        if !onWiFi && !discoveredBridges.isEmpty {
            print("🔄 Not on WiFi - clearing discovered bridges cache")
            discoveredBridges.removeAll()
        }
        
        // Find the saved bridge if we have one
        if let savedName = savedBridgeName,
           let savedBridge = discoveredBridges.first(where: { $0.name == savedName || $0.tunnelURL == savedTunnelURL }) {
            
            print("🔄 Found cached bridge: \(savedBridge.name)")
            
            if onWiFi {
                let newURL = savedBridge.localAddress
                print("→ Forcing switch to LOCAL: \(newURL)")
                verifyAndSwitchURL(newURL, fallback: savedBridge.tunnelURL, timeout: 2.0)
            } else if let tunnelURL = savedBridge.tunnelURL {
                print("→ Forcing switch to TUNNEL: \(tunnelURL) (on cellular/non-WiFi)")
                print("  🔍 Current rawAddress BEFORE: \(rawAddress ?? "nil")")
                print("  🔍 Discovered bridges count: \(discoveredBridges.count)")
                // On cellular, just switch to tunnel immediately without verification
                // Local address won't work anyway
                print("  → Switching immediately to tunnel URL without verification")
                activeURL = URL(string: tunnelURL)
                rawAddress = tunnelURL
                print("  🔍 rawAddress AFTER assignment: \(rawAddress ?? "nil")")
                updateNetworkStatus()
                // Force objectWillChange to notify observers
                objectWillChange.send()
                print("  ✅ Switched! rawAddress is now: \(tunnelURL)")
            }
        } else if let tunnelURL = savedTunnelURL {
            // No discovered bridge - use tunnel URL whether on WiFi or not
            // (could be on different WiFi network, or cellular)
            print("→ Using saved tunnel URL (bridge not discovered, on \(onWiFi ? "WiFi" : "cellular")): \(tunnelURL)")
            activeURL = URL(string: tunnelURL)
            rawAddress = tunnelURL
            updateNetworkStatus()
            objectWillChange.send()
        } else {
            print("❌ No saved bridge or tunnel URL!")
        }
    }
    
    private func verifyAndUpdateActiveURL(forceSwitch: Bool = false) {
        guard let path = networkMonitor?.currentPath else { return }
        let onWiFi = path.usesInterfaceType(.wifi)
        let onCellular = path.usesInterfaceType(.cellular)
        
        print("Network check - WiFi: \(onWiFi), Cellular: \(onCellular), Current URL: \(rawAddress ?? "none")")
        
        // Find the saved bridge if we have one
        if let savedName = savedBridgeName,
           let savedBridge = discoveredBridges.first(where: { $0.name == savedName || $0.tunnelURL == savedTunnelURL }) {
            // If on WiFi, prefer local URL (verify it first)
            if onWiFi {
                let newURL = savedBridge.localAddress
                if rawAddress != newURL || forceSwitch {
                    print("Network is WiFi, switching to local URL: \(newURL)")
                    verifyAndSwitchURL(newURL, fallback: savedBridge.tunnelURL, timeout: 3.0)
                }
            } else if let tunnelURL = savedBridge.tunnelURL {
                // Not on WiFi (cellular or other), prefer tunnel URL (verify it first)
                if rawAddress != tunnelURL || forceSwitch {
                    print("Network is NOT WiFi (cellular/other), switching to tunnel URL: \(tunnelURL)")
                    verifyAndSwitchURL(tunnelURL, fallback: savedBridge.localAddress, timeout: 3.0)
                }
            }
        } else if let tunnelURL = savedTunnelURL {
            // Fallback: if we have a saved tunnel URL, use it (especially when on cellular)
            if !onWiFi && rawAddress != tunnelURL {
                verifyAndSwitchURL(tunnelURL, fallback: nil, timeout: 3.0)
            }
        }
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
                    updateNetworkStatus()
                    print("Switched to local URL: \(newURL)")
                }
            } else if let tunnelURL = savedBridge.tunnelURL {
                // Not on WiFi, use tunnel URL
                if rawAddress != tunnelURL {
                    activeURL = URL(string: tunnelURL)
                    rawAddress = tunnelURL
                    updateNetworkStatus()
                    print("Switched to tunnel URL: \(tunnelURL)")
                }
            }
        } else if let tunnelURL = savedTunnelURL {
            // Fallback: if we have a saved tunnel URL, use it (especially when on cellular)
            if !onWiFi && rawAddress != tunnelURL {
                activeURL = normalizedURL
                rawAddress = tunnelURL
                updateNetworkStatus()
                print("Using saved tunnel URL: \(tunnelURL)")
            }
        }
    }
    
    private func verifyAndSwitchURL(_ urlString: String, fallback: String? = nil, timeout: TimeInterval = 3.0) {
        guard let url = URL(string: urlString.hasPrefix("http") ? urlString : "http://\(urlString)") else {
            return
        }
        
        isVerifyingConnection = true
        
        // Try to connect with a short timeout
        var request = URLRequest(url: url)
        request.httpMethod = "HEAD"
        request.timeoutInterval = timeout
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData  // Don't use cache
        
        URLSession.shared.dataTask(with: request) { [weak self] _, response, error in
            DispatchQueue.main.async {
                self?.isVerifyingConnection = false
                
                if let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode < 400 {
                    // Connection verified, switch to it
                    print("✓ Connection verified for \(urlString), switching...")
                    self?.activeURL = URL(string: urlString)
                    self?.rawAddress = urlString
                    self?.updateNetworkStatus()
                } else {
                    print("✗ Connection verification failed for \(urlString): \(error?.localizedDescription ?? "unknown")")
                    
                    // If verification failed and we have a fallback, try it immediately
                    if let fallbackURL = fallback, fallbackURL != urlString {
                        print("  → Immediately trying fallback URL: \(fallbackURL)")
                        // Try fallback without further fallback to avoid infinite loop
                        self?.verifyAndSwitchURL(fallbackURL, fallback: nil, timeout: 3.0)
                    } else {
                        // No fallback, but still switch - update network status to show current network type
                        print("  → No fallback available, switching to \(urlString) anyway")
                        self?.activeURL = URL(string: urlString)
                        self?.rawAddress = urlString
                        self?.updateNetworkStatus()
                    }
                }
            }
        }.resume()
    }
    
    // MARK: - Discovery with NetService
    func startDiscovery() {
        print("Starting bridge discovery...")
        
        // Only run discovery if on WiFi - mDNS doesn't work on cellular
        guard let path = networkMonitor?.currentPath, path.usesInterfaceType(.wifi) else {
            print("Not on WiFi - skipping mDNS discovery (cellular/other network)")
            // Stop any existing retry timer since we're not on WiFi
            stopDiscoveryRetry()
            return
        }
        
        // Force stop any existing discovery
        if browser != nil {
            stopDiscovery()
        }
        
        browser = NetServiceBrowser()
        browser?.delegate = self
        browser?.searchForServices(ofType: "_dvi-bridge._tcp.", inDomain: "local.")
        
        // Set up retry mechanism if discovery doesn't find anything within 5 seconds
        scheduleDiscoveryRetry()
    }
    
    func stopDiscovery() {
        browser?.stop()
        browser = nil
        
        // Stop resolving all services
        for service in resolvingServices {
            service.stop()
        }
        resolvingServices.removeAll()
        // Don't clear discovered services map - keep them cached
        stopDiscoveryRetry()
    }
    
    private func scheduleDiscoveryRetry() {
        stopDiscoveryRetry()
        
        // Only schedule retry if on WiFi - discovery won't work on cellular
        guard let path = networkMonitor?.currentPath, path.usesInterfaceType(.wifi) else {
            print("Not on WiFi - skipping discovery retry")
            return
        }
        
        discoveryRetryTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            
            // Check if still on WiFi before retrying
            guard let path = self.networkMonitor?.currentPath, path.usesInterfaceType(.wifi) else {
                print("No longer on WiFi - stopping discovery retry")
                self.stopDiscoveryRetry()
                return
            }
            
            if self.discoveredBridges.isEmpty {
                print("No bridges found on WiFi, retrying discovery...")
                self.forceRestartDiscovery()
            } else {
                // Found bridges, stop retrying
                self.stopDiscoveryRetry()
            }
        }
    }
    
    private func stopDiscoveryRetry() {
        discoveryRetryTimer?.invalidate()
        discoveryRetryTimer = nil
    }
    
    private func forceRestartDiscovery() {
        browser?.stop()
        resolvingServices.forEach { $0.stop() }
        resolvingServices.removeAll()
        
        // Restart immediately
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.browser?.searchForServices(ofType: "_dvi-bridge._tcp.", inDomain: "local.")
        }
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
        stopDiscovery()
    }
}
