// macOS 13+ version (reverted): SwiftUI traceroute monitor with IPv6 support,
// UDP→ICMP fallback, left‑aligned table, flexible Host column, right‑aligned Loss%

import SwiftUI
import Foundation
import AppKit
import Combine
import Darwin


// MARK: - NetworkHop Model (inlined here to ensure visibility)
final class NetworkHop: ObservableObject, Identifiable {
    let id = UUID()
    let hopNumber: Int
    let ipAddress: String   // "*" represents an unknown hop (timeout)
    let hostname: String

    @Published var sentPackets: Int = 0
    @Published var receivedPackets: Int = 0
    @Published var lastPing: Double = 0.0
    @Published var averagePing: Double = 0.0
    @Published var minPing: Double = 0.0
    @Published var maxPing: Double = 0.0
    @Published var lossPercentage: Double = 0.0

    private var pings: [Double] = []
    private var totalTime: Double = 0.0
    private let maxPings = 100

    init(hopNumber: Int, ipAddress: String, hostname: String? = nil) {
        self.hopNumber = hopNumber
        self.ipAddress = ipAddress
        self.hostname = hostname ?? ipAddress
    }

    func addPingResult(_ pingTime: Double?) {
        DispatchQueue.main.async {
            self.sentPackets += 1

            if let time = pingTime {
                self.receivedPackets += 1
                self.pings.append(time)
                self.totalTime += time
                self.lastPing = time

                if self.pings.count > self.maxPings {
                    let removed = self.pings.removeFirst()
                    self.totalTime -= removed
                }

                // Windowed stats based on current buffer
                self.averagePing = self.pings.isEmpty ? 0.0 : (self.totalTime / Double(self.pings.count))
                self.minPing = self.pings.min() ?? 0.0
                self.maxPing = self.pings.max() ?? 0.0
            } else {
                self.lastPing = 0.0
            }

            // Lifetime loss percentage
            self.lossPercentage = self.sentPackets > 0
                ? Double(self.sentPackets - self.receivedPackets) / Double(self.sentPackets) * 100.0
                : 0.0
        }
    }
}

// MARK: - MTR Controller
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
    // Resolve a hostname to a numeric IP string (IPv4 or IPv6) using getaddrinfo
    private func resolveToIPAddress(_ host: String) -> String? {
        let trimmed = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        var hints = addrinfo(
            ai_flags: AI_DEFAULT,
            ai_family: AF_UNSPEC,
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

    private func execTraceroute(ip: String, isIPv6: Bool, proto: TraceProto) -> (out: String, err: String, status: Int32) {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/sbin/traceroute")

        var args = ["-n", "-q", "1", "-w", "3", "-m", String(maxHops)]
        if isIPv6 { args.insert("-6", at: 0) }
        if proto == .icmp { args.insert("-I", at: 0) }
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
        // Pre-resolve to numeric IP; clearer errors and avoids traceroute name-resolution oddities
        let original = targetHost
        guard let ip = resolveToIPAddress(original) else {
            DispatchQueue.main.async {
                self.statusMessage = "Can't resolve target host: \(original.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "<empty>" : original)"
            }
            completion(false)
            return
        }

        let isIPv6 = ip.contains(":")

        // Attempt 1: UDP (default)
        let udp = execTraceroute(ip: ip, isIPv6: isIPv6, proto: .udp)
        parseTracerouteOutput(udp.out)

        if !self.hops.isEmpty {
            completion(true)
            return
        }

        // Attempt 2: ICMP echo (some networks block UDP traceroute)
        let icmp = execTraceroute(ip: ip, isIPv6: isIPv6, proto: .icmp)
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
        // Capture hop number + first token (IPv4, IPv6, or *)
        let hopRegex = try! NSRegularExpression(pattern: #"^\s*(\d+)\s+([0-9A-Fa-f:.]+|\*)"#)

        var discovered: [NetworkHop] = []
        for line in lines {
            let nsRange = NSRange(location: 0, length: line.utf16.count)
            guard let match = hopRegex.firstMatch(in: line, range: nsRange) else { continue }
            let hopNum = Int((line as NSString).substring(with: match.range(at: 1))) ?? 0
            let token = (line as NSString).substring(with: match.range(at: 2))

            if token == "*" {
                discovered.append(NetworkHop(hopNumber: hopNum, ipAddress: "*", hostname: "*"))
            } else {
                let host = resolveHostname(token)
                discovered.append(NetworkHop(hopNumber: hopNum, ipAddress: token, hostname: host))
            }
        }

        DispatchQueue.main.async {
            self.hops = discovered.sorted { $0.hopNumber < $1.hopNumber }
        }
    }

    // MARK: Hostname resolution with simple cache
    private func resolveHostname(_ ipAddress: String) -> String {
        if let cached = dnsCache[ipAddress] { return cached }

        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/host")
        task.arguments = [ipAddress]

        let pipe = Pipe()
        task.standardOutput = pipe

        do {
            try task.run()
            task.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            var out = String(data: data, encoding: .utf8) ?? ""
            out = out.trimmingCharacters(in: .whitespacesAndNewlines)

            if let range = out.range(of: "domain name pointer ") {
                var hostname = String(out[range.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
                if hostname.hasSuffix(".") { hostname.removeLast() } // remove trailing dot
                dnsCache[ipAddress] = hostname
                return hostname.isEmpty ? ipAddress : hostname
            }
        } catch {
            // fall through to returning ip
        }
        dnsCache[ipAddress] = ipAddress
        return ipAddress
    }

    // MARK: Ping
    private func pingHop(_ hop: NetworkHop, completion: @escaping () -> Void) {
        // For unknown hops, record as loss quickly
        guard hop.ipAddress != "*" else {
            hop.addPingResult(nil)
            completion()
            return
        }

        let isIPv6 = hop.ipAddress.contains(":")
        let task = Process()
        task.executableURL = URL(fileURLWithPath: isIPv6 ? "/sbin/ping6" : "/sbin/ping")
        // macOS ping: -c 1 (one probe), -W 2000 (ms to wait for a reply)
        task.arguments = ["-c", "1", "-W", "2000", hop.ipAddress]

        let pipe = Pipe()
        task.standardOutput = pipe

        do {
            try task.run()
            queue.async {
                task.waitUntilExit()
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                let output = String(data: data, encoding: .utf8) ?? ""

                var pingTime: Double? = nil
                if task.terminationStatus == 0 {
                    let timeRegex = try! NSRegularExpression(pattern: #"time=([0-9.]+)\s*ms"#)
                    let nsRange = NSRange(location: 0, length: output.utf16.count)
                    if let m = timeRegex.firstMatch(in: output, range: nsRange) {
                        let s = (output as NSString).substring(with: m.range(at: 1))
                        pingTime = Double(s)
                    }
                }

                hop.addPingResult(pingTime)
                completion()
            }
        } catch {
            hop.addPingResult(nil)
            completion()
        }
    }
}

// MARK: - Views
struct MainView: View {
    @StateObject private var mtr = MTRController()
    private let colHop: CGFloat = 44
    private let colLoss: CGFloat = 70
    private let colSent: CGFloat = 60
    private let colRecv: CGFloat = 60
    private let colLat: CGFloat = 80
    @State private var headerElevated = false
    private let headerHeight: CGFloat = 44

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            controls
            if mtr.hops.isEmpty {
                Spacer()
                Text("No route data available")
                    .foregroundStyle(.secondary)
                    .font(.title2)
                Spacer()
            } else {
                resultsTable
            }
        }
        .frame(minWidth: 820, minHeight: 620)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding()
    }

    private var controls: some View {
        VStack(spacing: 15) {
            Text("MacMTR - Network Route Monitor")
                .font(.title)
                .fontWeight(.bold)

            HStack(spacing: 15) {
                VStack(alignment: .leading) {
                    Text("Target Host:")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    TextField("Enter hostname or IP", text: $mtr.targetHost)
                        .textFieldStyle(.roundedBorder)
                        .disabled(mtr.isMonitoring)
                        .frame(minWidth: 240)
                }

                VStack(alignment: .leading) {
                    Text("Max Hops:")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    TextField("30", value: $mtr.maxHops, format: .number)
                        .textFieldStyle(.roundedBorder)
                        .disabled(mtr.isMonitoring)
                        .frame(width: 80)
                }

                VStack(alignment: .leading) {
                    Text("Interval (s):")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    TextField("1.0", value: $mtr.interval, format: .number)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 80)
                }
            }

            HStack {
                if mtr.isMonitoring {
                    Button("Stop") { mtr.stopMonitoring() }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                } else {
                    Button("Start") { mtr.startMonitoring() }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                }

                Text(mtr.statusMessage)
                    .foregroundStyle(.secondary)
                    .padding(.leading)
            }
        }
        .padding()
        .background(.thinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var resultsTable: some View {
        ZStack(alignment: .top) {
            ScrollView {
                // Track scroll offset for header shadow
                GeometryReader { proxy in
                    Color.clear
                        .preference(key: ScrollYKey.self, value: proxy.frame(in: .named("tableScroll")).minY)
                }
                .frame(height: 0)

                LazyVStack(spacing: 0) {
                    ForEach(mtr.hops) { hop in
                        HopRow(
                            hop: hop,
                            colHop: colHop,
                            colSent: colSent,
                            colRecv: colRecv,
                            colLoss: colLoss,
                            colLat: colLat
                        )
                        .background(hop.hopNumber % 2 == 0 ? Color.clear : Color.gray.opacity(0.06))
                    }
                }
                .padding(.top, headerHeight) // make room for sticky header
            }
            .coordinateSpace(name: "tableScroll")
            .onPreferenceChange(ScrollYKey.self) { y in
                // y becomes negative when content scrolls up
                withAnimation(.easeInOut(duration: 0.15)) {
                    headerElevated = y < -1
                }
            }

            // Sticky header overlay
            headerRow
                .frame(height: headerHeight)
                .background(Color.gray.opacity(0.18))
                .overlay(Divider(), alignment: .bottom)
                .shadow(color: headerElevated ? Color.black.opacity(0.12) : .clear, radius: 6, y: 3)
        }
        .background(Color(NSColor.textBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Color.black.opacity(0.06), lineWidth: 1)
        )
    }

    private var headerRow: some View {
        HStack(alignment: .center, spacing: 0) {
            Text("Hop")
                .fontWeight(.semibold)
                .frame(width: colHop, height: headerHeight, alignment: .leading)
            VSep()

            Text("Host")
                .fontWeight(.semibold)
                .frame(maxWidth: .infinity, alignment: .leading)
                .frame(height: headerHeight, alignment: .leading)
            VSep()

            Text("Loss%")
                .fontWeight(.semibold)
                .frame(width: colLoss, height: headerHeight, alignment: .trailing)
            VSep()

            Text("Sent")
                .fontWeight(.semibold)
                .frame(width: colSent, height: headerHeight, alignment: .trailing)
            VSep()

            Text("Recvd")
                .fontWeight(.semibold)
                .frame(width: colRecv, height: headerHeight, alignment: .trailing)
            VSep()

            Text("Last")
                .fontWeight(.semibold)
                .frame(width: colLat, height: headerHeight, alignment: .trailing)
        }
        .padding(.horizontal, 12)
    }
}

// Tracks the vertical scroll offset of the table content
private struct ScrollYKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

// MARK: - Row + Vertical Separator
private struct VSep: View {
    var body: some View {
        Rectangle()
            .fill(Color.black.opacity(0.08))
            .frame(width: 1)
            .frame(maxHeight: .infinity)
    }
}

private struct HopRow: View {
    @ObservedObject var hop: NetworkHop
    let colHop: CGFloat
    let colSent: CGFloat
    let colRecv: CGFloat
    let colLoss: CGFloat
    let colLat: CGFloat

    var body: some View {
        HStack(alignment: .center, spacing: 0) {
            Text("\(hop.hopNumber)")
                .font(.system(.body, design: .monospaced))
                .frame(width: colHop, alignment: .leading)
            VSep()

            VStack(alignment: .leading, spacing: 2) {
                Text(hop.hostname)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if hop.hostname != hop.ipAddress {
                    Text(hop.ipAddress)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 6)
            VSep()

            Text(hop.lossPercentage > 0 ? String(format: "%.1f%%", hop.lossPercentage) : "-")
                .font(.system(.body, design: .monospaced))
                .foregroundStyle(hop.lossPercentage > 10 ? .red : .primary)
                .frame(width: colLoss, alignment: .trailing)
            VSep()

            Text("\(hop.sentPackets)")
                .font(.system(.body, design: .monospaced))
                .frame(width: colSent, alignment: .trailing)
            VSep()

            Text("\(hop.receivedPackets)")
                .font(.system(.body, design: .monospaced))
                .frame(width: colRecv, alignment: .trailing)
            VSep()

            Text(hop.lastPing > 0 ? String(format: "%.1f ms", hop.lastPing) : "-")
                .font(.system(.body, design: .monospaced))
                .frame(width: colLat, alignment: .trailing)
        }
        .padding(.horizontal, 12)
    }
}

// Uses the existing @main MacMTRApp defined in the other file
