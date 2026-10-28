import SwiftUI

/// A dashboard hint/banner card: a leading glyph, a title + message, a primary action button, and a
/// trailing dismiss (✕). A grouped content card (`cardSurface`) that scrolls with the sections. Shared
/// scaffolding for the first-run `CustomizeHintCard` and the `UpdateBannerCard`, so they read as one
/// family and a spacing/appearance tweak lands in one place.
/// Callers supply the copy and the two closures (each wraps its own animation as needed). A `tint` turns
/// the card into a warning: tinted glyph, fill, border, and a prominent action button.
struct DismissableHintCard: View {
    let systemImage: String
    let title: String
    let message: String
    let buttonTitle: String
    var tint: Color? = nil
    let action: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: systemImage)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(tint.map(AnyShapeStyle.init) ?? AnyShapeStyle(.secondary))
                .frame(width: 20, height: 20)

            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                actionButton
                    .controlSize(.small)
                    .padding(.top, 2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 16, height: 16)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Dismiss")
        }
        .padding(12)
        .background {
            if let tint { Theme.cardShape.fill(tint.opacity(0.14)) }
        }
        .cardSurface()
        .overlay {
            if let tint { Theme.cardShape.strokeBorder(tint.opacity(0.7), lineWidth: 1) }
        }
    }

    @ViewBuilder
    private var actionButton: some View {
        if let tint {
            Button(buttonTitle, action: action)
                .buttonStyle(.borderedProminent)
                .tint(tint)
        } else {
            Button(buttonTitle, action: action)
        }
    }
}
