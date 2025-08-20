import SwiftUI
import Foundation

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
                VStack(spacing: 20) {
                    Spacer()
                    Image(systemName: "network")
                        .font(.system(size: 48))
                        .foregroundStyle(.secondary)
                    
                    VStack(spacing: 8) {
                        Text("No Route Data")
                            .font(.title2)
                            .fontWeight(.medium)
                        
                        Text(mtr.isMonitoring ? "Discovering route..." : "Enter a target host and click Start to begin monitoring")
                            .foregroundStyle(.secondary)
                            .font(.body)
                            .multilineTextAlignment(.center)
                    }
                    
                    if mtr.isMonitoring {
                        ProgressView()
                            .scaleEffect(0.8)
                            .padding(.top, 10)
                    }
                    
                    Spacer()
                }
                .frame(maxWidth: .infinity)
            } else {
                resultsTable
            }
        }
        .frame(minWidth: 700, minHeight: 500)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding()
        .background(Color(NSColor.windowBackgroundColor))
        .onAppear {
            // Set focus to target host field when view appears
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                NSApp.keyWindow?.makeFirstResponder(nil)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in
            mtr.stopMonitoring()
        }
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
                        .overlay(
                            RoundedRectangle(cornerRadius: 6)
                                .stroke(mtr.targetHost.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? Color.red.opacity(0.3) : Color.clear, lineWidth: 1)
                        )
                        .onSubmit {
                            if !mtr.isMonitoring && !mtr.targetHost.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                                mtr.startMonitoring()
                            }
                        }
                }

                VStack(alignment: .leading) {
                    Text("Max Hops:")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    TextField("30", value: $mtr.maxHops, format: .number)
                        .textFieldStyle(.roundedBorder)
                        .disabled(mtr.isMonitoring)
                        .frame(width: 80)
                        .onChange(of: mtr.maxHops) { newValue in
                            if newValue < 1 { mtr.maxHops = 1 }
                            if newValue > 64 { mtr.maxHops = 64 }
                        }
                }

                VStack(alignment: .leading) {
                    Text("Interval (s):")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    TextField("1.0", value: $mtr.interval, format: .number)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 80)
                        .onChange(of: mtr.interval) { newValue in
                            if newValue < 0.1 { mtr.interval = 0.1 }
                            if newValue > 60.0 { mtr.interval = 60.0 }
                        }
                }
            }

            HStack {
                if mtr.isMonitoring {
                    Button(action: { mtr.stopMonitoring() }) {
                        HStack(spacing: 8) {
                            Image(systemName: "stop.fill")
                            Text("Stop")
                        }
                        .padding(.horizontal, 8)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .tint(.red)
                } else {
                    Button(action: { 
                        guard !mtr.targetHost.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                            mtr.statusMessage = "Please enter a target host"
                            return
                        }
                        mtr.startMonitoring() 
                    }) {
                        HStack(spacing: 8) {
                            Image(systemName: "play.fill")
                            Text("Start")
                        }
                        .padding(.horizontal, 8)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .tint(.green)
                    .disabled(mtr.targetHost.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }

                Text(mtr.statusMessage)
                    .foregroundStyle(.secondary)
                    .padding(.leading)
                    .animation(.easeInOut(duration: 0.2), value: mtr.statusMessage)
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
                        HopRowView(
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



