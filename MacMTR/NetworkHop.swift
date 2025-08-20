import SwiftUI
import Foundation

final class NetworkHop: ObservableObject, Identifiable {
    let id = UUID()
    let hopNumber: Int
    let ipAddress: String   // "*" represents an unknown hop (timeout)
    @Published var hostname: String

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
    
    func updateHostname(_ newHostname: String) {
        DispatchQueue.main.async {
            self.hostname = newHostname
        }
    }
}