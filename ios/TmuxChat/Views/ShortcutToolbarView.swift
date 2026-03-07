import SwiftUI
import UIKit

struct ShortcutToolbarView: View {
    @State private var layoutManager = ShortcutLayoutManager.shared

    var isSending: Bool
    var onKeyTapped: (ShortcutItem) -> Void
    private let swipeThreshold: CGFloat = 28

    private var canSwitchGroups: Bool {
        layoutManager.groups.count > 1
    }

    private func handleSwipe(_ value: DragGesture.Value) {
        guard canSwitchGroups else {
            return
        }

        let horizontal = abs(value.translation.width)
        let vertical = abs(value.translation.height)
        guard vertical > horizontal, vertical >= swipeThreshold else {
            return
        }

        if value.translation.height < 0 {
            layoutManager.selectNextGroup()
        } else {
            layoutManager.selectPreviousGroup()
        }

        let feedback = UIImpactFeedbackGenerator(style: .light)
        feedback.impactOccurred()
    }

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(layoutManager.selectedGroupItems) { item in
                    Button {
                        onKeyTapped(item)
                    } label: {
                        Text(item.displayLabel)
                            .font(.caption.weight(.semibold))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 8)
                            .background(.thinMaterial, in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .disabled(isSending)
                }
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 6)
        .background(.bar)
        .accessibilityLabel("Shortcut toolbar")
        .accessibilityHint(canSwitchGroups ? "Swipe up or down to switch shortcut groups." : "")
        .simultaneousGesture(
            DragGesture(minimumDistance: 20)
                .onEnded(handleSwipe)
        )
    }
}
