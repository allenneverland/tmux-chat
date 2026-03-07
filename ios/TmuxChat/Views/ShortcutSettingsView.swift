import SwiftUI

private enum ShortcutKeyInputSource: String, CaseIterable, Identifiable {
    case keyboard
    case special

    var id: String { rawValue }

    var title: String {
        switch self {
        case .keyboard:
            return "iOS Keyboard"
        case .special:
            return "Special Key"
        }
    }
}

private struct CurrentRowFramePreferenceKey: PreferenceKey {
    static var defaultValue: [UUID: CGRect] = [:]

    static func reduce(value: inout [UUID: CGRect], nextValue: () -> [UUID: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}

struct ShortcutSettingsView: View {
    @State private var layoutManager = ShortcutLayoutManager.shared
    @State private var showAddGroupAlert = false
    @State private var addGroupName = ""
    @State private var showRenameGroupAlert = false
    @State private var renameGroupID: UUID?
    @State private var renameGroupName = ""

    @State private var draftModifiers: Set<ShortcutModifier> = []
    @State private var keyInputSource: ShortcutKeyInputSource = .keyboard
    @State private var keyboardInput: String = ""
    @State private var selectedSpecialKeyID: String = ShortcutCatalog.iosMissingKeys.first?.id ?? ""

    @State private var currentRowItemFrames: [UUID: CGRect] = [:]
    @State private var draggingShortcutID: UUID?
    @State private var draggingOffsetX: CGFloat = 0

    private let currentRowCoordinateSpace = "ShortcutSettings.CurrentRow"

    private var specialKeys: [ShortcutCatalogKey] {
        ShortcutCatalog.iosMissingKeys
    }

    private var selectedSpecialKey: ShortcutCatalogKey? {
        specialKeys.first(where: { $0.id == selectedSpecialKeyID }) ?? specialKeys.first
    }

    private var keyboardBaseKey: ShortcutBaseKey? {
        TmuxShortcutTokenBuilder.keyboardBaseKey(from: keyboardInput)
    }

    private var draftBaseKey: ShortcutBaseKey? {
        switch keyInputSource {
        case .keyboard:
            return keyboardBaseKey
        case .special:
            guard let selectedSpecialKey else {
                return nil
            }
            return ShortcutBaseKey(label: selectedSpecialKey.label, token: selectedSpecialKey.tmuxToken)
        }
    }

    private var draftPreviewLabel: String? {
        guard let base = draftBaseKey else {
            return nil
        }
        return TmuxShortcutTokenBuilder.displayLabel(baseLabel: base.label, modifiers: draftModifiers)
    }

    private var draftToken: String? {
        guard let base = draftBaseKey else {
            return nil
        }
        return TmuxShortcutTokenBuilder.token(baseToken: base.token, modifiers: draftModifiers)
    }

    private var canAddDraft: Bool {
        guard let token = draftToken else {
            return false
        }
        return TmuxShortcutTokenBuilder.isValidKeyToken(token)
    }

    var body: some View {
        List {
            groupsSection
            selectedRowSection
            addKeySection
        }
        .navigationTitle("Shortcut Settings")
        .navigationBarTitleDisplayMode(.inline)
        .alert("Add Group", isPresented: $showAddGroupAlert) {
            TextField("Group name", text: $addGroupName)
            Button("Cancel", role: .cancel) {
                addGroupName = ""
            }
            Button("Add") {
                layoutManager.addGroup(named: addGroupName)
                addGroupName = ""
            }
        } message: {
            Text("Create a custom shortcut group")
        }
        .alert("Rename Group", isPresented: $showRenameGroupAlert) {
            TextField("Group name", text: $renameGroupName)
            Button("Cancel", role: .cancel) {
                renameGroupID = nil
                renameGroupName = ""
            }
            Button("Save") {
                if let renameGroupID {
                    layoutManager.renameGroup(id: renameGroupID, to: renameGroupName)
                }
                renameGroupID = nil
                renameGroupName = ""
            }
        } message: {
            Text("Update the group name")
        }
        .onAppear {
            syncSelectedSpecialKey()
        }
        .onChange(of: keyInputSource) { _, _ in
            syncSelectedSpecialKey()
        }
        .onChange(of: keyboardInput) { _, raw in
            normalizeKeyboardInput(raw)
        }
    }

    private var groupsSection: some View {
        Section {
            ForEach(layoutManager.groups) { group in
                HStack(spacing: 12) {
                    Button {
                        layoutManager.selectGroup(group.id)
                    } label: {
                        HStack(spacing: 8) {
                            Text(group.name)
                            Text("(\(group.items.count))")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .foregroundStyle(.primary)
                    }
                    .buttonStyle(.plain)

                    Spacer()

                    if layoutManager.selectedGroupID == group.id {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    }

                    Button {
                        renameGroupID = group.id
                        renameGroupName = group.name
                        showRenameGroupAlert = true
                    } label: {
                        Image(systemName: "pencil")
                    }
                    .buttonStyle(.plain)
                }
            }
            .onDelete { offsets in
                layoutManager.deleteGroups(at: offsets)
            }
            .onMove { source, destination in
                layoutManager.moveGroups(from: source, to: destination)
            }

            Button {
                showAddGroupAlert = true
            } label: {
                Label("Add Group", systemImage: "plus")
            }
        } header: {
            Text("Groups")
        } footer: {
            Text("Create, rename, reorder, and switch shortcut groups.")
        }
    }

    @ViewBuilder
    private var selectedRowSection: some View {
        if let selectedGroup = layoutManager.selectedGroup {
            Section {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        if selectedGroup.items.isEmpty {
                            Text("No keys in current row")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 8)
                        } else {
                            ForEach(selectedGroup.items) { item in
                                currentRowChip(item: item, groupID: selectedGroup.id)
                            }
                        }
                    }
                    .padding(.vertical, 4)
                    .padding(.horizontal, 2)
                }
                .coordinateSpace(name: currentRowCoordinateSpace)
                .scrollDisabled(draggingShortcutID != nil)
                .onPreferenceChange(CurrentRowFramePreferenceKey.self) { frames in
                    currentRowItemFrames = frames
                }
            } header: {
                Text("Current Row")
            } footer: {
                Text("Drag keys here to reorder. Keys in this row appear in the shortcut toolbar.")
            }
        }
    }

    @ViewBuilder
    private var addKeySection: some View {
        if let selectedGroup = layoutManager.selectedGroup {
            Section {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Modifiers")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)

                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(ShortcutModifier.allCases) { modifier in
                                Button {
                                    toggleModifier(modifier)
                                } label: {
                                    Text(modifier.displayName)
                                        .font(.caption.weight(.semibold))
                                        .padding(.horizontal, 10)
                                        .padding(.vertical, 7)
                                        .foregroundStyle(
                                            draftModifiers.contains(modifier) ? Color.white : Color.primary
                                        )
                                        .background(
                                            Capsule()
                                                .fill(
                                                    draftModifiers.contains(modifier)
                                                        ? Color.accentColor
                                                        : Color(.systemGray5)
                                                )
                                        )
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }

                }

                Picker("Key Source", selection: $keyInputSource) {
                    ForEach(ShortcutKeyInputSource.allCases) { source in
                        Text(source.title).tag(source)
                    }
                }
                .pickerStyle(.segmented)

                switch keyInputSource {
                case .keyboard:
                    TextField("Tap one key on iOS keyboard", text: $keyboardInput)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                case .special:
                    Picker("Special Key", selection: $selectedSpecialKeyID) {
                        ForEach(specialKeys) { key in
                            Text(key.label).tag(key.id)
                        }
                    }
                    .pickerStyle(.menu)
                    .disabled(specialKeys.isEmpty)
                }

                LabeledContent("Preview") {
                    Text(draftPreviewLabel ?? "-")
                        .foregroundStyle(.secondary)
                }

                Button {
                    addDraftShortcut(to: selectedGroup.id)
                } label: {
                    Label("Add to Current Row", systemImage: "plus.circle.fill")
                }
                .disabled(!canAddDraft)
            } header: {
                Text("Add Key")
            } footer: {
                Text("Select any number of modifiers, then pick one base key. Example: Ctrl + Shift + R.")
            }
        }
    }

    private func currentRowChip(item: ShortcutItem, groupID: UUID) -> some View {
        HStack(spacing: 4) {
            Text(item.displayLabel)
                .font(.caption.weight(.semibold))

            Button {
                layoutManager.removeItem(item.id, from: groupID)
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.caption)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(.thinMaterial, in: Capsule())
        .overlay(alignment: .center) {
            GeometryReader { proxy in
                Color.clear
                    .preference(
                        key: CurrentRowFramePreferenceKey.self,
                        value: [item.id: proxy.frame(in: .named(currentRowCoordinateSpace))]
                    )
            }
        }
        .offset(x: draggingShortcutID == item.id ? draggingOffsetX : 0)
        .zIndex(draggingShortcutID == item.id ? 1 : 0)
        .gesture(reorderGesture(for: item.id, groupID: groupID), including: .gesture)
        .animation(.easeInOut(duration: 0.12), value: layoutManager.selectedGroupItems.map(\.id))
    }

    private func reorderGesture(for itemID: UUID, groupID: UUID) -> some Gesture {
        LongPressGesture(minimumDuration: 0.15)
            .sequenced(before: DragGesture(minimumDistance: 0, coordinateSpace: .named(currentRowCoordinateSpace)))
            .onChanged { value in
                switch value {
                case .first(true):
                    if draggingShortcutID == nil {
                        draggingShortcutID = itemID
                        draggingOffsetX = 0
                    }
                case .second(true, let drag?):
                    guard draggingShortcutID == itemID else {
                        return
                    }
                    draggingOffsetX = drag.translation.width
                    reorderWhileDragging(itemID: itemID, groupID: groupID, translationX: drag.translation.width)
                default:
                    break
                }
            }
            .onEnded { _ in
                draggingShortcutID = nil
                draggingOffsetX = 0
            }
    }

    private func reorderWhileDragging(itemID: UUID, groupID: UUID, translationX: CGFloat) {
        guard let sourceFrame = currentRowItemFrames[itemID],
              let group = layoutManager.groups.first(where: { $0.id == groupID }),
              let sourceIndex = group.items.firstIndex(where: { $0.id == itemID }) else {
            return
        }

        let draggingCenterX = sourceFrame.midX + translationX
        let proposedDestination = group.items.reduce(into: 0) { partialResult, item in
            guard item.id != itemID,
                  let frame = currentRowItemFrames[item.id] else {
                return
            }

            if draggingCenterX > frame.midX {
                partialResult += 1
            }
        }

        guard proposedDestination != sourceIndex else {
            return
        }

        layoutManager.moveItem(in: groupID, itemID: itemID, to: proposedDestination)
    }

    private func toggleModifier(_ modifier: ShortcutModifier) {
        if draftModifiers.contains(modifier) {
            draftModifiers.remove(modifier)
        } else {
            draftModifiers.insert(modifier)
        }
    }

    private func normalizeKeyboardInput(_ raw: String) {
        guard !raw.isEmpty else {
            keyboardInput = ""
            return
        }

        let candidate = String(raw.suffix(1))
        if TmuxShortcutTokenBuilder.keyboardBaseKey(from: candidate) != nil {
            keyboardInput = candidate
        } else {
            keyboardInput = ""
        }
    }

    private func addDraftShortcut(to groupID: UUID) {
        guard let base = draftBaseKey else {
            return
        }

        let added = layoutManager.addShortcut(
            baseLabel: base.label,
            baseToken: base.token,
            modifiers: draftModifiers,
            to: groupID
        )

        if added {
            draftModifiers.removeAll()
            if keyInputSource == .keyboard {
                keyboardInput = ""
            }
        }
    }

    private func syncSelectedSpecialKey() {
        guard !specialKeys.isEmpty else {
            selectedSpecialKeyID = ""
            return
        }

        if specialKeys.contains(where: { $0.id == selectedSpecialKeyID }) {
            return
        }
        selectedSpecialKeyID = specialKeys[0].id
    }
}
