import SwiftUI

/// Identifies the photo the viewer is showing (`fullScreenCover(item:)`).
struct PhotoViewerItem: Identifiable, Hashable {
    let url: URL
    var id: URL { url }
}

/// Brief 019: a recipe photo full screen. Black, aspect-fit, a labelled Close button, and a swipe
/// down to dismiss. Under Reduce Motion the photo doesn't follow the finger or spring back; the
/// swipe still closes it.
struct RecipePhotoViewer: View {
    let url: URL

    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var dragOffset: CGFloat = 0

    var body: some View {
        ZStack {
            Color.black
                .opacity(PhotoViewerDismissal.backgroundOpacity(forDrag: dragOffset))
                .ignoresSafeArea()
            AsyncImage(url: url) { phase in
                switch phase {
                case .success(let image):
                    image.resizable().scaledToFit()
                case .failure:
                    Label("Couldn’t load the photo", systemImage: "photo")
                        .font(SLFont.body)
                        .foregroundStyle(.white)
                default:
                    ProgressView().tint(.white)
                }
            }
            .offset(y: dragOffset)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Recipe photo")
            .accessibilityAddTraits(.isImage)
        }
        .overlay(alignment: .topTrailing) {
            Button {
                close()
            } label: {
                Label("Close", systemImage: "xmark")
                    .labelStyle(.iconOnly)
                    .font(SLFont.headline)
                    .foregroundStyle(.white)
                    .frame(width: Metrics.minTapTarget, height: Metrics.minTapTarget)
                    .background(.white.opacity(0.18), in: Circle())
            }
            .accessibilityLabel("Close")
            .accessibilityIdentifier("photoViewer.close")
            .padding(Spacing.lg)
        }
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 10)
                .onChanged { value in
                    guard !reduceMotion else { return }
                    dragOffset = max(0, value.translation.height)
                }
                .onEnded { value in
                    if PhotoViewerDismissal.shouldDismiss(
                        translation: value.translation.height,
                        predictedEnd: value.predictedEndTranslation.height
                    ) {
                        close()
                    } else if reduceMotion {
                        dragOffset = 0
                    } else {
                        withAnimation(.spring(duration: 0.3)) { dragOffset = 0 }
                    }
                }
        )
        .accessibilityAction(.escape) { close() }
        .statusBarHidden()
        .preferredColorScheme(.dark)
    }

    private func close() {
        var transaction = Transaction()
        transaction.disablesAnimations = reduceMotion
        withTransaction(transaction) { dismiss() }
    }
}

/// The swipe-down rule, kept pure so it can be tested.
enum PhotoViewerDismissal {
    static let distance: CGFloat = 120
    static let flingDistance: CGFloat = 260

    /// A long enough drag down, or a quick fling down, closes the viewer. Upward drags never do.
    static func shouldDismiss(translation: CGFloat, predictedEnd: CGFloat) -> Bool {
        guard translation > 0 else { return false }
        return translation >= distance || predictedEnd >= flingDistance
    }

    /// The black fades as the photo is pulled down, so the recipe shows through.
    static func backgroundOpacity(forDrag offset: CGFloat) -> Double {
        let progress = min(max(offset, 0) / (distance * 2), 1)
        return 1 - Double(progress) * 0.5
    }
}
