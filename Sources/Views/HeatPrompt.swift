import SwiftUI

/// Asked before recording something this iPhone can't keep up for long, or while it's
/// already hot. Offers the closest setting that runs cool, or recording anyway.
struct HeatPrompt: View {
    let prompt: ForcePrompt
    let recommended: () -> Void
    let anyway: (_ remember: Bool) -> Void
    let cancel: () -> Void

    @State private var remember = false

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "flame.fill")
                .font(.system(size: 30))
                .foregroundStyle(.orange)
                .padding(.top, 6)

            Text(prompt.alreadyHot ? "Your iPhone is already hot" : "This will run hot")
                .font(.system(size: 20, weight: .semibold))

            Text(message)
                .font(.system(size: 15))
                .foregroundStyle(.white.opacity(0.75))
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

            VStack(spacing: 10) {
                if let alternative = prompt.alternative {
                    Button(action: recommended) {
                        Text("Record in \(alternative.label)")
                            .frame(maxWidth: .infinity, minHeight: 50)
                            .foregroundStyle(.black)
                            .background(.yellow, in: Capsule())
                    }
                }
                Button { anyway(remember) } label: {
                    Text(prompt.alreadyHot ? "Record" : "Record \(prompt.mode.label) anyway")
                        .frame(maxWidth: .infinity, minHeight: 50)
                        .foregroundStyle(.white)
                        .glass(in: Capsule())
                }
                if !prompt.alreadyHot {
                    Button { remember.toggle() } label: {
                        HStack(spacing: 8) {
                            Image(systemName: remember ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(remember ? .yellow : .white.opacity(0.6))
                            Text("Don't ask again for \(prompt.mode.label)")
                                .foregroundStyle(.white.opacity(0.8))
                        }
                        .font(.system(size: 14))
                        .padding(.vertical, 6)
                    }
                }
                Button("Cancel", action: cancel)
                    .foregroundStyle(.white.opacity(0.8))
                    .padding(.top, 2)
            }
            .font(.system(size: 17, weight: .semibold))
            .buttonStyle(.plain)
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 22)
        .padding(.vertical, 22)
        .frame(maxWidth: 420)
        .background(Color(white: 0.1), in: RoundedRectangle(cornerRadius: 34, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 34, style: .continuous).strokeBorder(.white.opacity(0.08)))
    }

    private var message: String {
        if prompt.alreadyHot {
            return "Recording now may slow the frame rate, or stop the front camera, to let it cool off. Both files are always saved."
        }
        return "\(prompt.mode.label) on both cameras is more than this iPhone can keep up for long. It may slow down, or stop the front camera, after a few minutes. Both files are always saved."
    }
}
