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
    private var networkConnectionTime: Date?
    private var discoveryStopTimer: Timer?
    private var consecutiveHealthCheckFailures: Int = 0
    private var healthCheckBackoffInterval: TimeInterval = 10.0
    private var lastHealthCheckTime: Date?
    private var cachedDeviceIP: String?
    private var cachedNetworkScope: String?
    private var lastNetworkInterfaceCheck: Date?
    
    // Store saved bridge info
    private var savedTunnelURL: String? {
        get { UserDefaults.standard.string(forKey: "savedTunnelURL") }
        set { UserDefaults.standard.set(newValue, forKey: "savedTunnelURL") }
    }
    private var savedBridgeName: String? {
        get { UserDefaults.standard.string(forKey: "savedBridgeName") }
        set { UserDefaults.standard.set(newValue, forKey: "savedBridgeName") }
    }
    private var homeNetworkScope: String? {
        get { UserDefaults.standard.string(forKey: "homeNetworkScope") }
        set { UserDefaults.standard.set(newValue, forKey: "homeNetworkScope") }
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
    
    // MARK: - IP Scope Detection
    
    /// Extract network scope (first 3 octets) from an IP address string
    /// e.g., "192.168.1.100" -> "192.168.1"
    private func extractNetworkScope(from ipAddress: String) -> String? {
        let pattern = #"^(\d{1,3}\.\d{1,3}\.\d{1,3})"#
        if let range = ipAddress.range(of: pattern, options: .regularExpression) {
            return String(ipAddress[range])
        }
        return nil
    }
    
    /// Get the current device's IP address on WiFi (cached)
    private func getCurrentDeviceIPAddress() -> String? {
        // Cache IP address for 5 seconds to avoid expensive system calls
        if let lastCheck = lastNetworkInterfaceCheck,
           Date().timeIntervalSince(lastCheck) < 5.0,
           let cached = cachedDeviceIP {
            return cached
        }
        
        var address: String?
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        
        guard getifaddrs(&ifaddr) == 0 else { return nil }
        defer { freeifaddrs(ifaddr) }
        
        var ptr = ifaddr
        while ptr != nil {
            defer { ptr = ptr?.pointee.ifa_next }
            
            guard let interface = ptr else { continue }
            let addrFamily = interface.pointee.ifa_addr.pointee.sa_family
            
            if addrFamily == UInt8(AF_INET) {
                let name = String(cString: interface.pointee.ifa_name)
                // Look for WiFi interface (en0 on iOS)
                if name == "en0" {
                    var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                    getnameinfo(interface.pointee.ifa_addr,
                              socklen_t(interface.pointee.ifa_addr.pointee.sa_len),
                              &hostname,
                              socklen_t(hostname.count),
                              nil,
                              socklen_t(0),
                              NI_NUMERICHOST)
                    address = String(cString: hostname)
                    break
                }
            }
        }
        
        // Update cache
        cachedDeviceIP = address
        lastNetworkInterfaceCheck = Date()
        return address
    }
    
    /// Check if current network matches home network scope (cached)
    private func isOnHomeNetworkScope() -> Bool {
        guard let homeScope = homeNetworkScope else {
            return false
        }
        
        // Use cached scope if available and recent
        if let lastCheck = lastNetworkInterfaceCheck,
           Date().timeIntervalSince(lastCheck) < 5.0,
           let cached = cachedNetworkScope {
            let matches = cached == homeScope
            return matches
        }
        
        // Calculate and cache
        guard let currentIP = getCurrentDeviceIPAddress(),
              let currentScope = extractNetworkScope(from: currentIP) else {
            return false
        }
        
        cachedNetworkScope = currentScope
        let matches = currentScope == homeScope
        print("🏠 Network scope check: current=\(currentScope), home=\(homeScope), matches=\(matches)")
        return matches
    }
    
    /// Check if bridge has been discovered locally (not just tunnel)
    private func isBridgeDiscoveredLocally() -> Bool {
        // Check if we have a saved bridge name that's in discovered bridges
        if let savedName = savedBridgeName {
            let isDiscovered = discoveredBridges.contains(where: { $0.name == savedName })
            if isDiscovered {
                print("✅ Bridge '\(savedName)' is discovered locally")
                return true
            }
        }
        
        // Also check if current rawAddress is pointing to a local IP/hostname
        if isCurrentURLLocal && rawAddress != nil {
            print("✅ Currently using local bridge address: \(rawAddress!)")
            return true
        }
        
        print("❌ Bridge not discovered locally")
        return false
    }
    
    /// Save the home network scope from a bridge's local IP address
    private func saveHomeNetworkScope(from localAddress: String) {
        // Extract IP from URL like "http://192.168.1.100:5000"
        let ipPattern = #"(\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3})"#
        if let range = localAddress.range(of: ipPattern, options: .regularExpression) {
            let ipAddress = String(localAddress[range])
            if let scope = extractNetworkScope(from: ipAddress) {
                homeNetworkScope = scope
                print("🏠 Saved home network scope: \(scope)")
            }
        }
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
            
            // Skip processing if network hasn't actually changed
            // OS fires path updates frequently for signal quality, routing changes, etc.
            // We only care about actual network type changes (WiFi ↔ Cellular)
            guard networkChanged else {
                return
            }
            
            if let current = currentType {
                print("Network type changed to: \(current)")
            }
            
            let previousType = self.lastNetworkType
            self.lastNetworkType = currentType
            
            DispatchQueue.main.async {
                print("Network type changed from \(String(describing: previousType)) to \(String(describing: currentType)), switching...")
                // Record network connection time
                self.networkConnectionTime = Date()
                
                // Invalidate network cache on actual network change
                self.cachedDeviceIP = nil
                self.cachedNetworkScope = nil
                self.lastNetworkInterfaceCheck = nil
                
                // Update network status immediately
                self.updateNetworkStatus()
                
                // Smart discovery: only if WiFi + matching home scope
                if path.usesInterfaceType(.wifi) && self.shouldRunDiscovery() {
                    print("📡 Starting time-limited discovery (10s window)")
                    self.startSmartDiscovery()
                } else {
                    print("⏭️ Skipping discovery - using tunnel (cellular or different network scope)")
                    // Immediately switch to tunnel for non-home networks
                    self.switchToTunnelURL()
                }
                
                // When network changes, force verify and switch
                self.verifyAndUpdateActiveURL(forceSwitch: true)
            }
        }
        networkMonitor?.start(queue: monitorQueue)
        
        // Health checks disabled - unnecessary since:
        // 1. Network changes handled by OS notifications (instant)
        // 2. If bridge is down, both local and tunnel fail anyway
        // 3. No recovery action possible if bridge itself is offline
        // This saves significant battery by eliminating continuous polling
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
        
        // Determine network status based on interface type, home network scope, AND bridge discovery
        if path.usesInterfaceType(.cellular) {
            // Cellular network - always uses remote tunnel
            currentNetworkType = "Cellular"
            isOnLocalNetwork = false
        } else if path.usesInterfaceType(.wifi) {
            // WiFi network - check if it's home network with discovered bridge
            if isOnHomeNetworkScope() && isBridgeDiscoveredLocally() {
                currentNetworkType = "WiFi"
                isOnLocalNetwork = true
            } else {
                // Either different scope OR same scope but bridge not found
                currentNetworkType = "WiFi"
                isOnLocalNetwork = false
            }
        } else if path.usesInterfaceType(.wiredEthernet) {
            // Ethernet - check scope similar to WiFi
            if isOnHomeNetworkScope() && isBridgeDiscoveredLocally() {
                currentNetworkType = "Ethernet"
                isOnLocalNetwork = true
            } else {
                currentNetworkType = "Ethernet"
                isOnLocalNetwork = false
            }
        } else {
            currentNetworkType = "Other"
            isOnLocalNetwork = false
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
        // Start with default interval
        consecutiveHealthCheckFailures = 0
        healthCheckBackoffInterval = 10.0
        scheduleNextHealthCheck()
        print("✅ Health checks started")
    }
    
    private func scheduleNextHealthCheck() {
        healthCheckTimer?.invalidate()
        healthCheckTimer = Timer.scheduledTimer(withTimeInterval: healthCheckBackoffInterval, repeats: false) { [weak self] _ in
            self?.verifyCurrentConnection()
            // Schedule next check after this one completes
            self?.scheduleNextHealthCheck()
        }
    }
    
    func stopHealthChecks() {
        healthCheckTimer?.invalidate()
        healthCheckTimer = nil
        print("⏹️ Health checks stopped")
    }
    
    private func verifyCurrentConnection() {
        lastHealthCheckTime = Date()
        
        guard let urlString = rawAddress,
              let url = URL(string: urlString.hasPrefix("http") ? urlString : "http://\(urlString)") else {
            return
        }
        
        guard let path = networkMonitor?.currentPath else { return }
        let onWiFi = path.usesInterfaceType(.wifi)
        
        // Only do health checks when on home WiFi using local bridge
        // All other scenarios are handled by network change detection:
        // - Cellular -> only tunnel available, no point checking
        // - WiFi with tunnel -> already determined not home network, no need to keep checking
        // - WiFi goes down -> OS switches to cellular, triggers network change handler
        
        if !onWiFi {
            // Not on WiFi - skip health checks
            return
        }
        
        if !isCurrentURLLocal {
            // On WiFi but using tunnel (not home network) - skip health checks
            return
        }
        
        if !isOnLocalNetwork {
            // Not on home network - skip health checks
            return
        }
        
        // Only reach here if: on home WiFi + using local bridge
        // Check if local bridge is still responsive
        
        // Quick HEAD request to check if connection is alive
        var request = URLRequest(url: url)
        request.httpMethod = "HEAD"
        request.timeoutInterval = 3.0
        
        URLSession.shared.dataTask(with: request) { [weak self] _, response, error in
            DispatchQueue.main.async {
                guard let self = self else { return }
                
                if let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode < 400 {
                    // Connection is good - reset failure tracking
                    if self.consecutiveHealthCheckFailures > 0 {
                        print("✅ Connection recovered after \(self.consecutiveHealthCheckFailures) failures")
                    }
                    self.consecutiveHealthCheckFailures = 0
                    self.healthCheckBackoffInterval = 10.0
                } else if error != nil {
                    // Connection failed - increase backoff
                    self.consecutiveHealthCheckFailures += 1
                    
                    // Exponential backoff: 10s, 20s, 40s, 60s (cap at 60s)
                    self.healthCheckBackoffInterval = min(10.0 * pow(2.0, Double(min(self.consecutiveHealthCheckFailures - 1, 2))), 60.0)
                    
                    if self.consecutiveHealthCheckFailures <= 3 {
                        print("⚠️ Health check failed for \(urlString) (failure #\(self.consecutiveHealthCheckFailures)), next check in \(Int(self.healthCheckBackoffInterval))s")
                        // Try to switch on first few failures
                        if self.consecutiveHealthCheckFailures <= 2 {
                            self.attemptConnectionRecovery()
                        }
                    } else {
                        // After 3 failures, stop spamming logs and recovery attempts
                        print("⏸️ Multiple failures (\(self.consecutiveHealthCheckFailures)), backing off to \(Int(self.healthCheckBackoffInterval))s intervals")
                    }
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
    
    /// Determine if discovery should run based on network scope and timing
    private func shouldRunDiscovery() -> Bool {
        // If no home scope saved yet, allow discovery (first-time setup)
        guard homeNetworkScope != nil else {
            print("📡 No home network scope saved - allowing first-time discovery")
            return true
        }
        
        // Check if we're on the home network scope
        guard isOnHomeNetworkScope() else {
            print("📡 Not on home network scope - skipping discovery")
            return false
        }
        
        // Check if we're within 10 seconds of network connection
        if let connectionTime = networkConnectionTime {
            let elapsed = Date().timeIntervalSince(connectionTime)
            if elapsed > 10.0 {
                print("📡 Discovery window expired (\(Int(elapsed))s > 10s) - skipping")
                return false
            }
            print("📡 Within discovery window (\(Int(elapsed))s / 10s)")
        }
        
        return true
    }
    
    /// Start smart discovery with automatic 10-second timeout
    private func startSmartDiscovery() {
        print("Starting smart bridge discovery...")
        
        // Only run discovery if on WiFi - mDNS doesn't work on cellular
        guard let path = networkMonitor?.currentPath, path.usesInterfaceType(.wifi) else {
            print("Not on WiFi - skipping mDNS discovery (cellular/other network)")
            stopDiscoveryRetry()
            return
        }
        
        // Check if we should run discovery
        guard shouldRunDiscovery() else {
            print("Smart discovery check failed - using tunnel")
            switchToTunnelURL()
            return
        }
        
        // Force stop any existing discovery
        if browser != nil {
            stopDiscovery()
        }
        
        browser = NetServiceBrowser()
        browser?.delegate = self
        browser?.searchForServices(ofType: "_dvi-bridge._tcp.", inDomain: "local.")
        
        // Set up 10-second hard stop for discovery
        discoveryStopTimer?.invalidate()
        discoveryStopTimer = Timer.scheduledTimer(withTimeInterval: 10.0, repeats: false) { [weak self] _ in
            print("⏱️ 10-second discovery window expired - stopping discovery")
            self?.stopDiscovery()
            // If no bridge found, ensure we're using tunnel
            if self?.discoveredBridges.isEmpty == true {
                print("No bridges discovered in time window - falling back to tunnel")
                self?.switchToTunnelURL()
            }
        }
        
        // Discovery retry disabled - mDNS is expensive and retrying every 5s wastes battery
        // If bridge isn't found in first scan, it likely won't appear until next network change
        // Let the OS network change detection handle it instead of continuous polling
    }
    
    func startDiscovery() {
        // Public method now calls smart discovery
        startSmartDiscovery()
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
        
        // Stop the 10-second discovery window timer
        discoveryStopTimer?.invalidate()
        discoveryStopTimer = nil
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
            
            // Check if still within 10-second discovery window
            if let connectionTime = self.networkConnectionTime {
                let elapsed = Date().timeIntervalSince(connectionTime)
                if elapsed > 10.0 {
                    print("⏱️ Discovery window expired during retry - stopping")
                    self.stopDiscoveryRetry()
                    self.stopDiscovery()
                    return
                }
            }
            
            // Check if still on WiFi before retrying
            guard let path = self.networkMonitor?.currentPath, path.usesInterfaceType(.wifi) else {
                print("No longer on WiFi - stopping discovery retry")
                self.stopDiscoveryRetry()
                return
            }
            
            // Check if should still be discovering based on network scope
            guard self.shouldRunDiscovery() else {
                print("Discovery conditions no longer met - stopping retry")
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
                print("Found tunnel URL in TXT record: \(tunnel)")
            }
        }
        
        let port = sender.port > 0 ? sender.port : 5000
        let localAddr = "http://\(localAddress):\(port)"
        
        // Create initial bridge entry
        let bridge = DiscoveredBridge(
            name: sender.name,
            localAddress: localAddr,
            tunnelURL: tunnelURL
        )
        
        discoveredServicesMap[sender.name] = bridge
        resolvingServices.remove(sender)
        updateDiscoveredBridges()
        
        // Also fetch tunnel URL via HTTP to get the latest (in case TXT record is outdated)
        // This is especially useful when trycloudflare tunnel is recreated
        fetchTunnelURLFromBridge(bridgeURL: localAddr) { [weak self] fetchedURL in
            if let fetchedURL = fetchedURL {
                // Update bridge entry with fetched tunnel URL
                let updatedBridge = DiscoveredBridge(
                    name: sender.name,
                    localAddress: localAddr,
                    tunnelURL: fetchedURL
                )
                self?.discoveredServicesMap[sender.name] = updatedBridge
                self?.updateDiscoveredBridges()
            }
        }
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

    /// Immediately switch to tunnel URL without discovery
    private func switchToTunnelURL() {
        guard let tunnelURL = savedTunnelURL else {
            print("⚠️ No tunnel URL saved to switch to")
            return
        }
        
        print("🔄 Switching immediately to tunnel: \(tunnelURL)")
        activeURL = URL(string: tunnelURL)
        rawAddress = tunnelURL
        updateNetworkStatus()
        objectWillChange.send()
    }
    
    // MARK: - Tunnel URL Discovery
    
    /// Fetch the current tunnel URL from the bridge when connected locally
    /// This is useful when the tunnel is recreated and the app needs to get the new URL
    func fetchTunnelURLFromBridge(bridgeURL: String, completion: ((String?) -> Void)? = nil) {
        // Construct endpoint URL (assuming bridge exposes tunnel info at /api/tunnel)
        guard var baseURL = URL(string: bridgeURL.hasPrefix("http") ? bridgeURL : "http://\(bridgeURL)") else {
            print("⚠️ Invalid bridge URL: \(bridgeURL)")
            completion?(nil)
            return
        }
        
        // Try /api/tunnel endpoint
        baseURL.appendPathComponent("api")
        baseURL.appendPathComponent("tunnel")
        
        print("🔍 Fetching tunnel URL from bridge at: \(baseURL.absoluteString)")
        
        var request = URLRequest(url: baseURL)
        request.httpMethod = "GET"
        request.timeoutInterval = 5.0
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        
        URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            DispatchQueue.main.async {
                if let error = error {
                    print("❌ Failed to fetch tunnel URL: \(error.localizedDescription)")
                    completion?(nil)
                    return
                }
                
                guard let httpResponse = response as? HTTPURLResponse else {
                    print("❌ Invalid response from bridge")
                    completion?(nil)
                    return
                }
                
                guard httpResponse.statusCode == 200 else {
                    print("❌ Bridge returned status code: \(httpResponse.statusCode)")
                    completion?(nil)
                    return
                }
                
                guard let data = data else {
                    print("❌ No data received from bridge")
                    completion?(nil)
                    return
                }
                
                do {
                    // Try to parse JSON response
                    if let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                       let tunnelURL = json["tunnel_url"] as? String {
                        print("✅ Fetched tunnel URL from bridge: \(tunnelURL)")
                        
                        // Update saved tunnel URL if it changed
                        if self?.savedTunnelURL != tunnelURL {
                            print("🔄 Tunnel URL changed, updating: \(self?.savedTunnelURL ?? "nil") → \(tunnelURL)")
                            self?.savedTunnelURL = tunnelURL
                            
                            // Update the discovered bridge entry if we have it
                            if let savedName = self?.savedBridgeName,
                               let bridge = self?.discoveredServicesMap[savedName] {
                                let updatedBridge = DiscoveredBridge(
                                    name: bridge.name,
                                    localAddress: bridge.localAddress,
                                    tunnelURL: tunnelURL
                                )
                                self?.discoveredServicesMap[savedName] = updatedBridge
                                self?.updateDiscoveredBridges()
                            }
                        }
                        
                        completion?(tunnelURL)
                        return
                    }
                    
                    print("❌ Unexpected JSON format from bridge")
                    completion?(nil)
                } catch {
                    print("❌ Failed to parse JSON response: \(error.localizedDescription)")
                    completion?(nil)
                }
            }
        }.resume()
    }
    
    /// Refresh tunnel URL from the bridge if currently connected locally
    func refreshTunnelURLIfLocal() {
        guard isOnLocalNetwork, let currentAddress = rawAddress else {
            print("⏭️ Not on local network or no current address, skipping tunnel refresh")
            return
        }
        
        print("🔄 Refreshing tunnel URL from local bridge...")
        fetchTunnelURLFromBridge(bridgeURL: currentAddress)
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
        
        // Save home network scope from bridge's local address
        saveHomeNetworkScope(from: bridge.localAddress)
        
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
