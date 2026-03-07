import SwiftUI

private enum ShortcutKeyInputSource: String, CaseIterable, Identifiable {
    case keyboard
    case special
    case modifierOnly

    var id: String { rawValue }

    var title: String {
        switch self {
        case .keyboard:
            return "iOS Keyboard"
        case .special:
            return "Special Key"
        case .modifierOnly:
            return "Modifier"
        }
    }
}

struct ShortcutSettingsView: View {
    @State private var layoutManager = ShortcutLayoutManager.shared
    @State private var showAddGroupAlert = false
    @State private var addGroupName = ""
    @State private var showRenameGroupAlert = false
    @State private var renameGroupID: UUID?
    @State private var renameGroupName = ""
    @State private var isAddKeyFormVisible = false

    @State private var draftModifiers: Set<ShortcutModifier> = []
    @State private var keyInputSource: ShortcutKeyInputSource = .keyboard
    @State private var keyboardInput: String = ""
    @State private var selectedSpecialKeyID: String = ShortcutCatalog.iosMissingKeys.first?.id ?? ""
    @State private var selectedModifierOnly: ShortcutModifier = .control

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
        case .modifierOnly:
            return nil
        }
    }

    private var draftPreviewLabel: String? {
        switch keyInputSource {
        case .modifierOnly:
            return selectedModifierOnly.displayName
        case .keyboard, .special:
            guard let base = draftBaseKey else {
                return nil
            }
            return TmuxShortcutTokenBuilder.displayLabel(baseLabel: base.label, modifiers: draftModifiers)
        }
    }

    private var draftToken: String? {
        guard let base = draftBaseKey,
              keyInputSource != .modifierOnly else {
            return nil
        }
        return TmuxShortcutTokenBuilder.token(baseToken: base.token, modifiers: draftModifiers)
    }

    private var canAddDraft: Bool {
        if keyInputSource == .modifierOnly {
            return true
        }
        guard let token = draftToken else {
            return false
        }
        return TmuxShortcutTokenBuilder.isValidKeyToken(token)
    }

    var body: some View {
        List {
            groupsSection
            shortcutsSection
        }
        .navigationTitle("Shortcut Settings")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            EditButton()
        }
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
        .onChange(of: layoutManager.selectedGroupID) { _, _ in
            isAddKeyFormVisible = false
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
    private var shortcutsSection: some View {
        if let selectedGroup = layoutManager.selectedGroup {
            Section {
                if selectedGroup.items.isEmpty {
                    Text("No shortcuts in this group")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                ForEach(selectedGroup.items) { item in
                    shortcutRow(item)
                }
                .onDelete { offsets in
                    layoutManager.deleteItems(in: selectedGroup.id, at: offsets)
                }
                .onMove { source, destination in
                    layoutManager.moveItems(in: selectedGroup.id, from: source, to: destination)
                }

                Button {
                    withAnimation(.easeInOut(duration: 0.15)) {
                        isAddKeyFormVisible.toggle()
                    }
                } label: {
                    Label(
                        isAddKeyFormVisible ? "Hide Add Key Form" : "Add Key",
                        systemImage: isAddKeyFormVisible ? "chevron.up.circle" : "plus.circle.fill"
                    )
                }

                if isAddKeyFormVisible {
                    addKeyForm(groupID: selectedGroup.id)
                }
            } header: {
                Text("Shortcuts")
            } footer: {
                Text("Shortcuts are shown in toolbar order. Use Edit to reorder or remove.")
            }
        }
    }

    private func shortcutRow(_ item: ShortcutItem) -> some View {
        HStack(spacing: 12) {
            Text(item.displayLabel)
                .font(.body)

            Spacer()

            Text(item.sendToken ?? "Modifier")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func addKeyForm(groupID: UUID) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            if keyInputSource != .modifierOnly {
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
            case .modifierOnly:
                Picker("Modifier", selection: $selectedModifierOnly) {
                    ForEach(ShortcutModifier.allCases) { modifier in
                        Text(modifier.displayName).tag(modifier)
                    }
                }
                .pickerStyle(.segmented)
            }

            LabeledContent("Preview") {
                Text(draftPreviewLabel ?? "-")
                    .foregroundStyle(.secondary)
            }

            Button {
                addDraftShortcut(to: groupID)
            } label: {
                Label("Add to Shortcut List", systemImage: "plus.circle.fill")
            }
            .disabled(!canAddDraft)
        }
        .padding(.vertical, 4)
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
        let added: Bool
        switch keyInputSource {
        case .modifierOnly:
            added = layoutManager.addModifierShortcut(selectedModifierOnly, to: groupID)
        case .keyboard, .special:
            guard let base = draftBaseKey else {
                return
            }
            added = layoutManager.addShortcut(
                baseLabel: base.label,
                baseToken: base.token,
                modifiers: draftModifiers,
                to: groupID
            )
        }

        if added {
            draftModifiers.removeAll()
            if keyInputSource == .keyboard {
                keyboardInput = ""
            }
            isAddKeyFormVisible = false
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
