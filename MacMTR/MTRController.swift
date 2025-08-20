import SwiftUI
import Foundation
import AppKit
import Combine
import Darwin

final class MTRController: ObservableObject {
    @Published var hops: [NetworkHop] = []
    @Published var isMonitoring = false
    @Published var targetHost = "google.com"
    @Published var maxHops = 30
    @Published var interval: Double = 1.0
    @Published var statusMessage = "Ready to start monitoring"

    private let queue = DispatchQueue(label: "com.macmtr.monitoring", qos: .utility)
    private var shouldRun: Bool = false
    private var dnsCache: [String:String] = [:] // ip -> hostname
    private var pingTasks: [Process] = [] // Track active ping processes for cleanup

    // MARK: Control
    func startMonitoring() {
        guard !isMonitoring else { return }

        statusMessage = "Discovering route to \(targetHost)..."
        hops.removeAll()
        isMonitoring = true
        shouldRun = true

        queue.async { [weak self] in
            self?.discoverRoute { success in
                DispatchQueue.main.async {
                    guard let self else { return }
                    if success {
                        self.statusMessage = "Monitoring \(self.hops.count) hops to \(self.targetHost)"
                        self.scheduleNextTick()
                    } else {
                        self.isMonitoring = false
                        self.shouldRun = false
                        if self.statusMessage == "Discovering route to \(self.targetHost)..." {
                            self.statusMessage = "Failed to discover route. Check target hostname."
                        }
                    }
                }
            }
        }
    }

    func stopMonitoring() {
        isMonitoring = false
        shouldRun = false
        statusMessage = "Monitoring stopped"
        
        // Clean up any running ping processes
        queue.async {
            for task in self.pingTasks {
                if task.isRunning {
                    task.terminate()
                }
            }
            self.pingTasks.removeAll()
        }
    }

    // Self-scheduling loop: prevents overlap and adapts to interval changes
    private func scheduleNextTick() {
        guard shouldRun else { return }
        pingAllHops { [weak self] in
            guard let self else { return }
            let delay = max(0.1, self.interval)
            self.queue.asyncAfter(deadline: .now() + delay) {
                self.scheduleNextTick()
            }
        }
    }

    private func pingAllHops(completion: @escaping () -> Void) {
        let group = DispatchGroup()
        for hop in hops {
            group.enter()
            queue.async {
                self.pingHop(hop) {
                    group.leave()
                }
            }
        }
        group.notify(queue: queue) { completion() }
    }

    // MARK: Route discovery
    // Resolve a hostname to IPv4 address only using getaddrinfo
    private func resolveToIPAddress(_ host: String) -> String? {
        let trimmed = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        var hints = addrinfo(
            ai_flags: AI_DEFAULT,
            ai_family: AF_INET, // Force IPv4 only
            ai_socktype: SOCK_DGRAM,
            ai_protocol: 0,
            ai_addrlen: 0,
            ai_canonname: nil,
            ai_addr: nil,
            ai_next: nil
        )
        var res: UnsafeMutablePointer<addrinfo>?
        let status = getaddrinfo(trimmed, nil, &hints, &res)
        guard status == 0, let first = res else { return nil }
        defer { freeaddrinfo(res) }
        var hostBuffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        let gi = getnameinfo(
            first.pointee.ai_addr,
            socklen_t(first.pointee.ai_addrlen),
            &hostBuffer,
            socklen_t(hostBuffer.count),
            nil,
            0,
            NI_NUMERICHOST
        )
        guard gi == 0 else { return nil }
        return String(cString: hostBuffer)
    }

    private enum TraceProto { case udp, icmp }

    private func execTraceroute(ip: String, proto: TraceProto) -> (out: String, err: String, status: Int32) {
        let task = Process()
        
        // Use IPv4 traceroute only
        task.executableURL = URL(fileURLWithPath: "/usr/sbin/traceroute")

        var args: [String] = []
        
        // Add protocol-specific flags
        if proto == .icmp {
            args.append("-I")  // Use ICMP ECHO instead of UDP datagrams
        }
        
        // Add standard options
        args.append("-n")  // Print hop addresses numerically rather than symbolically and numerically
        args.append("-q")  // Set number of probes per hop
        args.append("1")   // Only 1 probe per hop
        args.append("-w")  // Set time to wait for response
        args.append("3")   // Wait 3 seconds
        args.append("-m")  // Set max hops
        args.append(String(maxHops))
        
        // Add target IP
        args.append(ip)
        
        task.arguments = args

        let outPipe = Pipe()
        task.standardOutput = outPipe
        let errPipe = Pipe()
        task.standardError = errPipe

        do {
            try task.run()
            task.waitUntilExit()
        } catch {
            return ("", "launch failed: \(error.localizedDescription)", -1)
        }

        let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
        let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
        let output = String(data: outData, encoding: .utf8) ?? ""
        let errOutput = String(data: errData, encoding: .utf8) ?? ""
        return (output, errOutput, task.terminationStatus)
    }

    private func discoverRoute(completion: @escaping (Bool) -> Void) {
        // Pre-resolve to numeric IPv4 IP; clearer errors and avoids traceroute name-resolution oddities
        let original = targetHost
        guard let ip = resolveToIPAddress(original) else {
            DispatchQueue.main.async {
                self.statusMessage = "Can't resolve target host to IPv4: \(original.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "<empty>" : original)"
            }
            completion(false)
            return
        }

        // Attempt 1: UDP (default)
        let udp = execTraceroute(ip: ip, proto: .udp)
        parseTracerouteOutput(udp.out)

        if !self.hops.isEmpty {
            completion(true)
            return
        }

        // Attempt 2: ICMP echo (some networks block UDP traceroute)
        let icmp = execTraceroute(ip: ip, proto: .icmp)
        parseTracerouteOutput(icmp.out)

        let success = !self.hops.isEmpty
        if !success {
            DispatchQueue.main.async {
                let u = udp.err.trimmingCharacters(in: .whitespacesAndNewlines)
                let i = icmp.err.trimmingCharacters(in: .whitespacesAndNewlines)
                var reason = ""
                if !u.isEmpty { reason += "UDP: \(u)" }
                if !i.isEmpty { reason += (reason.isEmpty ? "" : " | ") + "ICMP: \(i)" }
                self.statusMessage = reason.isEmpty ? "Failed to discover route to \(ip)" : "traceroute error: \(reason)"
            }
        }
        completion(success)
    }

    private func parseTracerouteOutput(_ output: String) {
        let lines = output.components(separatedBy: .newlines)
        // Capture hop number + first token (IPv4 or *)
        let hopRegex = try! NSRegularExpression(pattern: #"^\s*(\d+)\s+([0-9.]+|\*)"#)

        var discovered: [NetworkHop] = []
        for line in lines {
            let nsRange = NSRange(location: 0, length: line.utf16.count)
            guard let match = hopRegex.firstMatch(in: line, range: nsRange) else { continue }
            let hopNum = Int((line as NSString).substring(with: match.range(at: 1))) ?? 0
            let token = (line as NSString).substring(with: match.range(at: 2))

            if token == "*" {
                discovered.append(NetworkHop(hopNumber: hopNum, ipAddress: "*", hostname: "*"))
            } else {
                // Start with IP address, resolve hostname asynchronously
                let hop = NetworkHop(hopNumber: hopNum, ipAddress: token, hostname: token)
                discovered.append(hop)
                
                // Resolve hostname in background
                queue.async {
                    let hostname = self.resolveHostname(token)
                    DispatchQueue.main.async {
                        hop.updateHostname(hostname)
                    }
                }
            }
        }

        DispatchQueue.main.async {
            self.hops = discovered.sorted { $0.hopNumber < $1.hopNumber }
        }
    }

    // MARK: Hostname resolution with simple cache (IPv4 only)
    private func resolveHostname(_ ipAddress: String) -> String {
        if let cached = dnsCache[ipAddress] { return cached }

        var resolvedHostname = ipAddress
        
        // Use getaddrinfo for reverse DNS lookup (IPv4 only)
        var hints = addrinfo(
            ai_flags: AI_DEFAULT,
            ai_family: AF_INET, // Force IPv4 only
            ai_socktype: 0,
            ai_protocol: 0,
            ai_addrlen: 0,
            ai_canonname: nil,
            ai_addr: nil,
            ai_next: nil
        )
        
        var res: UnsafeMutablePointer<addrinfo>?
        let status = getaddrinfo(ipAddress, nil, &hints, &res)
        
        if status == 0, let addr = res {
            defer { freeaddrinfo(res) }
            
            var hostBuffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            let gi = getnameinfo(
                addr.pointee.ai_addr,
                socklen_t(addr.pointee.ai_addrlen),
                &hostBuffer,
                socklen_t(hostBuffer.count),
                nil,
                0,
                NI_NAMEREQD // Only return if name available
            )
            
            if gi == 0 {
                let hostname = String(cString: hostBuffer)
                if !hostname.isEmpty && hostname != ipAddress {
                    resolvedHostname = hostname
                }
            }
        }
        
        dnsCache[ipAddress] = resolvedHostname
        return resolvedHostname
    }

    // MARK: MTR-style probing (IPv4 only)
    private func pingHop(_ hop: NetworkHop, completion: @escaping () -> Void) {
        // For unknown hops, record as loss quickly
        guard hop.ipAddress != "*" else {
            hop.addPingResult(nil)
            completion()
            return
        }

        // Get the original target from the first resolution
        guard let finalTarget = resolveToIPAddress(targetHost) else {
            hop.addPingResult(nil)
            completion()
            return
        }

        // Use traceroute-style probing to the final target with TTL set to reach this hop
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/sbin/traceroute")
        
        // Send a probe to the final target but with TTL set to reach exactly this hop
        // This is how MTR actually works - it sends probes with specific TTL values
        task.arguments = [
            "-n",                           // Numeric output
            "-q", "1",                      // Send 1 probe
            "-w", "1",                      // Wait 1 second
            "-f", String(hop.hopNumber),    // First TTL (start at this hop)
            "-m", String(hop.hopNumber),    // Max TTL (end at this hop)
            finalTarget                     // Final target, not the hop IP
        ]

        let pipe = Pipe()
        let errorPipe = Pipe()
        task.standardOutput = pipe
        task.standardError = errorPipe
        
        // Track the task for cleanup
        pingTasks.append(task)

        do {
            try task.run()
            queue.async {
                task.waitUntilExit()
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                let output = String(data: data, encoding: .utf8) ?? ""

                var pingTime: Double? = nil
                
                // Look for timing information in traceroute output
                let timeRegex = try! NSRegularExpression(pattern: #"([0-9.]+)\s*ms"#)
                let nsRange = NSRange(location: 0, length: output.utf16.count)
                if let m = timeRegex.firstMatch(in: output, range: nsRange) {
                    let s = (output as NSString).substring(with: m.range(at: 1))
                    pingTime = Double(s)
                }

                hop.addPingResult(pingTime)
                
                // Remove completed task from tracking
                self.pingTasks.removeAll { $0 === task }
                completion()
            }
        } catch {
            hop.addPingResult(nil)
            // Remove failed task from tracking
            pingTasks.removeAll { $0 === task }
            completion()
        }
    }
}