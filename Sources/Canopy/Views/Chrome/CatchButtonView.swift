import SwiftUI

/// Pulsing butterfly button in the toolbar — always visible in Forest/Focus modes.
/// Tap to open the Catch popup.
struct CatchButtonView: View {
    @ObservedObject var catchState: CatchState

    var body: some View {
        Button(action: { catchState.openCatch() }) {
            TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { context in
                let phase = context.date.timeIntervalSinceReferenceDate
                let pulse = 0.6 + 0.4 * (0.5 + 0.5 * sin(phase * .pi))

                Text("🦋")
                    .font(.system(size: 13))
                    .opacity(pulse)
                    .frame(width: 26, height: 22)
            }
        }
        .buttonStyle(.plain)
        .help("Catch — grab the last few seconds of audio")
        .popover(isPresented: $catchState.showPopover) {
            CatchPopoverView(catchState: catchState)
        }
    }
}
