import SwiftUI

struct TransportPlaceholder: View {
    var body: some View {
        HStack(spacing: 12) {
            Button(action: {}) {
                Image(systemName: "play.fill")
                    .font(.system(size: 14))
                    .foregroundColor(CanopyColors.transportIcon)
            }
            .buttonStyle(.plain)

            Button(action: {}) {
                Image(systemName: "stop.fill")
                    .font(.system(size: 14))
                    .foregroundColor(CanopyColors.transportIcon)
            }
            .buttonStyle(.plain)

            Button(action: {}) {
                Image(systemName: "record.circle")
                    .font(.system(size: 14))
                    .foregroundColor(CanopyColors.transportIcon)
            }
            .buttonStyle(.plain)
        }
    }
}
