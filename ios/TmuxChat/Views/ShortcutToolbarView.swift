import SwiftUI
import UIKit

struct ShortcutToolbarView: View {
    @State private var layoutManager = ShortcutLayoutManager.shared

    var pendingModifiers: Set<ShortcutModifier>
    var onKeyTapped: (ShortcutItem) -> Void
    private let swipeThreshold: CGFloat = 28

    private var canSwitchGroups: Bool {
        layoutManager.groups.count > 1
    }

    private var pendingModifierLabel: String {
        ShortcutModifier.allCases
            .filter { pendingModifiers.contains($0) }
            .map(\.displayName)
            .joined(separator: "+")
    }

    private func isModifierHighlighted(_ item: ShortcutItem) -> Bool {
        guard let modifierOnly = item.modifierOnly else {
            return false
        }
        return pendingModifiers.contains(modifierOnly)
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
        VStack(alignment: .leading, spacing: 6) {
            if !pendingModifiers.isEmpty {
                Text("Pending: \(pendingModifierLabel)")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal)
            }

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(layoutManager.selectedGroupItems) { item in
                        let highlighted = isModifierHighlighted(item)
                        Button {
                            onKeyTapped(item)
                        } label: {
                            Text(item.displayLabel)
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(highlighted ? Color.white : Color.primary)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 8)
                                .background(
                                    Capsule()
                                        .fill(highlighted ? Color.accentColor : Color(.secondarySystemBackground))
                                )
                        }
                        .buttonStyle(.plain)
                    }
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
