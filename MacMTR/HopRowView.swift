import SwiftUI

struct HopRowView: View {
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

            Text(hop.sentPackets > 0 ? String(format: "%.1f%%", hop.lossPercentage) : "-")
                .font(.system(.body, design: .monospaced))
                .foregroundStyle(
                    hop.lossPercentage >= 100 ? .orange :
                    hop.lossPercentage > 50 ? .red :
                    hop.lossPercentage > 10 ? .yellow : .primary
                )
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

internal struct VSep: View {
    var body: some View {
        Rectangle()
            .fill(Color.black.opacity(0.08))
            .frame(width: 1)
            .frame(maxHeight: .infinity)
    }
}