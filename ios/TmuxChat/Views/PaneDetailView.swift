//
//  PaneDetailView.swift
//  TmuxChat
//

import SwiftUI
import Observation

// MARK: - ZoomableTextView

struct ZoomableTextView: UIViewRepresentable {
    let attributedText: NSAttributedString
    let contentVersion: UUID
    @Binding var scrollToBottom: Bool

    func makeUIView(context: Context) -> UIScrollView {
        context.coordinator.lastContentVersion = nil
        let scrollView = UIScrollView()
        scrollView.delegate = context.coordinator
        scrollView.minimumZoomScale = 1.0
        scrollView.maximumZoomScale = 4.0
        scrollView.showsHorizontalScrollIndicator = true
        scrollView.showsVerticalScrollIndicator = true
        scrollView.backgroundColor = .systemBackground

        let textView = UITextView()
        textView.isEditable = false
        textView.isScrollEnabled = false
        textView.backgroundColor = .clear
        textView.textContainerInset = UIEdgeInsets(top: 8, left: 8, bottom: 8, right: 8)
        textView.tag = 100
        scrollView.addSubview(textView)

        let doubleTapGesture = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleDoubleTap(_:)))
        doubleTapGesture.numberOfTapsRequired = 2
        scrollView.addGestureRecognizer(doubleTapGesture)

        context.coordinator.scrollView = scrollView

        return scrollView
    }

    func updateUIView(_ scrollView: UIScrollView, context: Context) {
        guard let textView = scrollView.viewWithTag(100) as? UITextView else { return }

        if context.coordinator.lastContentVersion != contentVersion {
            context.coordinator.lastContentVersion = contentVersion

            CATransaction.begin()
            CATransaction.setDisableActions(true)

            textView.attributedText = attributedText

            let maxWidth = max(scrollView.bounds.width, 300)
            let size = textView.sizeThatFits(CGSize(width: maxWidth, height: .greatestFiniteMagnitude))
            textView.frame = CGRect(origin: .zero, size: size)
            scrollView.contentSize = size

            CATransaction.commit()
        }

        if scrollToBottom {
            DispatchQueue.main.async {
                let bottomOffset = CGPoint(
                    x: 0,
                    y: max(0, scrollView.contentSize.height - scrollView.bounds.height)
                )
                scrollView.setContentOffset(bottomOffset, animated: false)
                scrollToBottom = false
            }
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    class Coordinator: NSObject, UIScrollViewDelegate {
        var lastContentVersion: UUID?
        weak var scrollView: UIScrollView?

        func viewForZooming(in scrollView: UIScrollView) -> UIView? {
            scrollView.subviews.first { $0 is UITextView }
        }

        @objc func handleDoubleTap(_ gesture: UITapGestureRecognizer) {
            guard let scrollView = scrollView,
                  let textView = scrollView.subviews.first(where: { $0 is UITextView }) else { return }

            let currentZoom = scrollView.zoomScale
            let tapPoint = gesture.location(in: textView)

            let newZoom: CGFloat
            if currentZoom < 1.5 {
                newZoom = 2.0
            } else if currentZoom < 3.0 {
                newZoom = 4.0
            } else {
                newZoom = 1.0
            }

            let zoomRect = zoomRectForScale(scrollView: scrollView, scale: newZoom, center: tapPoint)
            UIView.animate(withDuration: 0.3) {
                scrollView.zoom(to: zoomRect, animated: false)
            }
        }

        private func zoomRectForScale(scrollView: UIScrollView, scale: CGFloat, center: CGPoint) -> CGRect {
            let size = CGSize(
                width: scrollView.bounds.width / scale,
                height: scrollView.bounds.height / scale
            )
            let origin = CGPoint(
                x: center.x - size.width / 2,
                y: center.y - size.height / 2
            )
            return CGRect(origin: origin, size: size)
        }
    }
}

// MARK: - PaneDetailView

struct PaneDetailView: View {
    let pane: Pane
    let windowName: String
    @State private var viewModel: PaneDetailViewModel
    @State private var scrollToBottom = false
    @State private var inputText = ""
    @FocusState private var isInputFocused: Bool
    @State private var showCommandEditor = false
    @State private var showCommandPicker = false
    @State private var pendingShortcutModifiers: Set<ShortcutModifier> = []

    init(pane: Pane, windowName: String) {
        self.pane = pane
        self.windowName = windowName
        _viewModel = State(wrappedValue: PaneDetailViewModel(target: pane.target))
    }

    private var canSend: Bool {
        !inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !viewModel.isSending
    }

    private var commandButtonOffsetY: CGFloat {
        -100
    }

    private func sendMessage() {
        let message = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !message.isEmpty, !viewModel.isSending else { return }
        inputText = ""
        isInputFocused = false
        Task {
            await viewModel.sendInput(message)
        }
    }

    private func sendShortcut(_ item: ShortcutItem) {
        guard !viewModel.isSending else { return }
        let resolution = ShortcutTapResolver.resolveTap(
            item: item,
            pendingModifiers: pendingShortcutModifiers
        )
        pendingShortcutModifiers = resolution.pendingModifiers
        guard let token = resolution.tokenToSend else {
            return
        }
        Task {
            _ = await viewModel.sendKey(token)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            ZoomableTextView(
                attributedText: viewModel.output,
                contentVersion: viewModel.contentVersion,
                scrollToBottom: $scrollToBottom
            )
            .onChange(of: viewModel.contentVersion) {
                scrollToBottom = true
            }
            .onChange(of: viewModel.isSending) { _, isSending in
                if !isSending {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                        scrollToBottom = true
                    }
                }
            }
            .overlay {
                if viewModel.isSending {
                    ZStack {
                        Color.black.opacity(0.3)
                        VStack(spacing: 12) {
                            ProgressView()
                                .scaleEffect(1.5)
                                .tint(.white)
                            Text("Sending...")
                                .font(.subheadline)
                                .foregroundStyle(.white)
                        }
                        .padding(24)
                        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
                    }
                }
            }

            Divider()

            if viewModel.canUseShortcutToolbar {
                ShortcutToolbarView(
                    isSending: viewModel.isSending,
                    pendingModifiers: pendingShortcutModifiers,
                    onKeyTapped: { item in
                        sendShortcut(item)
                    }
                )
            } else {
                HStack(spacing: 8) {
                    Image(systemName: "keyboard")
                        .foregroundStyle(.secondary)
                    Text(viewModel.shortcutStatusMessage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                    Spacer()
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(Color(.secondarySystemBackground))
            }
            Divider()

            ZStack(alignment: .topTrailing) {
                InputComposerView(text: $inputText, isFocused: $isInputFocused)
                    .disabled(viewModel.isSending)
                    .onSubmit {
                        sendMessage()
                    }

                HStack(spacing: 8) {
                    GlassButton {
                        showCommandPicker = true
                    } label: {
                        Image(systemName: "bookmark.fill")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(.purple)
                    }
                    .disabled(viewModel.isSending)

                    GlassButton {
                        Task {
                            await viewModel.sendEscape()
                        }
                    } label: {
                        Image(systemName: "stop.fill")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(.red)
                    }
                    .disabled(viewModel.isSending)

                    GlassButton {
                        sendMessage()
                    } label: {
                        Image(systemName: "paperplane.fill")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(canSend ? .blue : .gray)
                    }
                    .disabled(!canSend)
                }
                .offset(x: -12, y: commandButtonOffsetY)
            }
        }
        .navigationTitle(windowName)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    Task {
                        await viewModel.refresh()
                    }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .disabled(viewModel.isLoading)
            }

            ToolbarItem(placement: .secondaryAction) {
                Toggle("Auto Refresh", isOn: $viewModel.autoRefresh)
            }
        }
        .alert("Error", isPresented: $viewModel.showError) {
            Button("OK") {}
        } message: {
            Text(viewModel.errorMessage)
        }
        .sheet(isPresented: $showCommandEditor) {
            CommandEditorView()
                .modifier(iPadPagePresentationModifier())
        }
        .sheet(isPresented: $showCommandPicker) {
            CommandPickerView(
                onCommandSelected: { command in
                    Task {
                        await viewModel.sendInput(command)
                    }
                },
                onCommandInsert: { command in
                    inputText = command
                    isInputFocused = true
                },
                onEditCommands: {
                    showCommandPicker = false
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                        showCommandEditor = true
                    }
                }
            )
            .modifier(iPadPagePresentationModifier())
        }
        .task {
            await viewModel.startPolling()
        }
        .onDisappear {
            viewModel.stopPolling()
        }
        .onReceive(NotificationCenter.default.publisher(for: .unreadPanesChanged)) { _ in
            if let deviceId = ServerConfigManager.shared.activeServer?.deviceId {
                AppDelegate.shared?.markPaneAsRead(deviceId: deviceId, paneTarget: pane.target)
            }
        }
    }
}

// MARK: - iPadPagePresentationModifier

struct iPadPagePresentationModifier: ViewModifier {
    private var isIPad: Bool {
        UIDevice.current.userInterfaceIdiom == .pad
    }

    func body(content: Content) -> some View {
        if isIPad {
            content.presentationDetents([.large])
        } else {
            content.presentationDetents([.medium, .large])
        }
    }
}

// MARK: - QuickAction

struct DetectedOption {
    let number: String
    let label: String
}

enum ShortcutEndpointState: Equatable {
    case available
    case unknownLegacy
    case unsupportedByServer
    case deploymentMismatch

    var canUseToolbar: Bool {
        switch self {
        case .available, .unknownLegacy:
            return true
        case .unsupportedByServer, .deploymentMismatch:
            return false
        }
    }

    var statusMessage: String {
        switch self {
        case .available, .unknownLegacy:
            return ""
        case .unsupportedByServer:
            return "This host does not expose shortcut-key support. Update tmux-chatd and reconnect."
        case .deploymentMismatch:
            return "Shortcut route mismatch detected. Verify reverse-proxy routing and active tmux-chatd binary."
        }
    }
}

enum QuickAction {
    case options([DetectedOption])
    case suggestions([String])
    case yesNo
    case none
}

// MARK: - PaneDetailViewModel

@MainActor
@Observable
class PaneDetailViewModel {
    var output: NSAttributedString = NSAttributedString()
    var contentVersion: UUID = UUID()
    var isLoading = false
    var isSending = false
    var showError = false
    var errorMessage = ""
    var autoRefresh = true
    var quickAction: QuickAction = .none
    var shortcutEndpointState: ShortcutEndpointState = .unknownLegacy

    var canUseShortcutToolbar: Bool {
        shortcutEndpointState.canUseToolbar
    }

    var shortcutStatusMessage: String {
        shortcutEndpointState.statusMessage
    }

    private let target: String
    private let api = TmuxChatAPI.shared
    @ObservationIgnored private var pollingTask: Task<Void, Never>?
    @ObservationIgnored private var rawOutput: String = ""
    @ObservationIgnored private var shortcutSupportFromCapabilities: DaemonShortcutKeysSupport = .unknown
    @ObservationIgnored private var didReportUnsupportedKeyEndpoint = false
    @ObservationIgnored private var didReportShortcutDeploymentMismatch = false

    init(target: String) {
        self.target = target
    }

    nonisolated private static func detectQuickAction(from text: String) -> QuickAction {
        if detectYesNoPrompt(from: text) {
            return .yesNo
        }
        let options = parseOptions(from: text)
        if !options.isEmpty {
            return .options(options)
        }
        let suggestions = parseSuggestions(from: text)
        if !suggestions.isEmpty {
            return .suggestions(suggestions)
        }
        return .none
    }

    nonisolated private static func parseSuggestions(from text: String) -> [String] {
        let lines = text.components(separatedBy: "\n").suffix(20)
        var suggestions: [String] = []
        let prefixes = ["❯", "›", "▶", "▸", "➤", "⟩"]
        let trailingPattern = #"\s*↵\s*\w*\s*$"#

        for line in lines {
            var cleanLine = line.replacingOccurrences(
                of: "\u{1B}\\[[0-9;]*m",
                with: "",
                options: .regularExpression
            ).trimmingCharacters(in: .whitespaces)

            // Remove trailing "↵ send" or similar
            cleanLine = cleanLine.replacingOccurrences(
                of: trailingPattern,
                with: "",
                options: .regularExpression
            ).trimmingCharacters(in: .whitespaces)

            for prefix in prefixes {
                if cleanLine.hasPrefix(prefix) {
                    let suggestion = String(cleanLine.dropFirst()).trimmingCharacters(in: .whitespaces)
                    if !suggestion.isEmpty && suggestion.count < 100 {
                        suggestions.append(suggestion)
                    }
                    break
                }
            }
        }

        return suggestions
    }

    nonisolated private static func detectYesNoPrompt(from text: String) -> Bool {
        let lastLines = text.components(separatedBy: "\n").suffix(5).joined(separator: "\n")
        let cleanText = lastLines.replacingOccurrences(
            of: "\u{1B}\\[[0-9;]*m",
            with: "",
            options: .regularExpression
        ).lowercased()

        let patterns = [
            "(y/n)",
            "(yes/no)",
            "allow?",
            "proceed?",
            "continue?",
            "confirm?",
            "do you want to",
            "would you like to"
        ]

        return patterns.contains { cleanText.contains($0) }
    }

    nonisolated private static func parseOptions(from text: String) -> [DetectedOption] {
        let lines = text.components(separatedBy: "\n").suffix(30)
        let pattern = #"^\s*([❯>])?\s*(\d+)[.\)]\s+(.+)$"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else {
            return []
        }

        var options: [DetectedOption] = []
        var hasSelector = false

        for line in lines {
            let cleanLine = line.replacingOccurrences(
                of: "\u{1B}\\[[0-9;]*m",
                with: "",
                options: .regularExpression
            )

            let range = NSRange(cleanLine.startIndex..., in: cleanLine)
            if let match = regex.firstMatch(in: cleanLine, options: [], range: range) {
                if let selectorRange = Range(match.range(at: 1), in: cleanLine) {
                    let selector = String(cleanLine[selectorRange])
                    if selector == "❯" || selector == ">" {
                        hasSelector = true
                    }
                }

                if let numRange = Range(match.range(at: 2), in: cleanLine),
                   let labelRange = Range(match.range(at: 3), in: cleanLine) {
                    let number = String(cleanLine[numRange])
                    let label = String(cleanLine[labelRange]).trimmingCharacters(in: .whitespaces)
                    if label.count < 100 {
                        options.append(DetectedOption(number: number, label: label))
                    }
                }
            }
        }

        return (options.count >= 2 && hasSelector) ? options : []
    }

    nonisolated private static func parseAnsiToAttributedString(_ text: String) -> NSAttributedString {
        let result = NSMutableAttributedString()
        var currentColor: UIColor = .label
        var isBold = false
        var isDim = false

        let baseFont = UIFont.monospacedSystemFont(ofSize: 8, weight: .regular)
        let boldFont = UIFont.monospacedSystemFont(ofSize: 8, weight: .bold)

        let pattern = "\u{1B}\\[([0-9;]*)m"
        let regex = try! NSRegularExpression(pattern: pattern, options: [])

        var lastEnd = text.startIndex
        let nsText = text as NSString
        let matches = regex.matches(in: text, options: [], range: NSRange(location: 0, length: nsText.length))

        for match in matches {
            if let range = Range(match.range, in: text) {
                let beforeRange = lastEnd..<range.lowerBound
                if beforeRange.lowerBound < beforeRange.upperBound {
                    let segmentText = String(text[beforeRange])
                    let color = isDim ? currentColor.withAlphaComponent(0.6) : currentColor
                    let font = isBold ? boldFont : baseFont
                    let attrs: [NSAttributedString.Key: Any] = [
                        .foregroundColor: color,
                        .font: font
                    ]
                    result.append(NSAttributedString(string: segmentText, attributes: attrs))
                }
                lastEnd = range.upperBound
            }

            if let codeRange = Range(match.range(at: 1), in: text) {
                let codes = String(text[codeRange]).split(separator: ";").compactMap { Int($0) }
                for code in codes {
                    switch code {
                    case 0:
                        currentColor = .label
                        isBold = false
                        isDim = false
                    case 1:
                        isBold = true
                    case 2:
                        isDim = true
                    case 22:
                        isBold = false
                        isDim = false
                    case 30: currentColor = .black
                    case 31: currentColor = .systemRed
                    case 32: currentColor = .systemGreen
                    case 33: currentColor = .systemYellow
                    case 34: currentColor = .systemBlue
                    case 35: currentColor = .systemPurple
                    case 36: currentColor = .systemCyan
                    case 37: currentColor = .label
                    case 39: currentColor = .label
                    case 90: currentColor = .gray
                    case 91: currentColor = .systemRed
                    case 92: currentColor = .systemGreen
                    case 93: currentColor = .systemYellow
                    case 94: currentColor = .systemBlue
                    case 95: currentColor = .systemPurple
                    case 96: currentColor = .systemCyan
                    case 97: currentColor = .label
                    default: break
                    }
                }
            }
        }

        if lastEnd < text.endIndex {
            let segmentText = String(text[lastEnd...])
            let color = isDim ? currentColor.withAlphaComponent(0.6) : currentColor
            let font = isBold ? boldFont : baseFont
            let attrs: [NSAttributedString.Key: Any] = [
                .foregroundColor: color,
                .font: font
            ]
            result.append(NSAttributedString(string: segmentText, attributes: attrs))
        }

        return result
    }

    private func applyShortcutSupport(_ support: DaemonShortcutKeysSupport) {
        shortcutSupportFromCapabilities = support
        switch support {
        case .supported:
            shortcutEndpointState = .available
        case .unsupported:
            shortcutEndpointState = .unsupportedByServer
        case .unknown:
            shortcutEndpointState = .unknownLegacy
        }
    }

    private func refreshShortcutCapability(forceRefresh: Bool = false) async {
        do {
            let capabilities = try await api.getCapabilities(forceRefresh: forceRefresh)
            applyShortcutSupport(capabilities.shortcutKeysSupport)
        } catch let error as APIError {
            // Older deployments may not expose /capabilities; keep legacy behavior.
            if case .httpError(let statusCode, let path, _) = error,
               statusCode == 404,
               path == "/capabilities" {
                applyShortcutSupport(.unknown)
            }
        } catch {
            // Keep current state on transient failures.
        }
    }

    func stopPolling() {
        pollingTask?.cancel()
        pollingTask = nil
    }

    func startPolling() async {
        stopPolling()
        await refreshShortcutCapability()
        await refresh()

        pollingTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                if autoRefresh {
                    await refreshSilently()
                }
            }
        }
    }

    private func refreshSilently() async {
        do {
            let newRawOutput = try await api.getOutput(target: target, lines: 500)
            guard newRawOutput != rawOutput else { return }
            rawOutput = newRawOutput

            let text = rawOutput
            async let parsedOutput = Task.detached(priority: .userInitiated) {
                Self.parseAnsiToAttributedString(text)
            }.value

            async let detectedAction = Task.detached(priority: .utility) {
                Self.detectQuickAction(from: text)
            }.value

            let (newOutput, newAction) = await (parsedOutput, detectedAction)
            output = newOutput
            quickAction = newAction
            contentVersion = UUID()
        } catch {
            // Silently ignore errors during polling
        }
    }

    func refresh() async {
        isLoading = true
        defer { isLoading = false }

        do {
            let newRawOutput = try await api.getOutput(target: target, lines: 500)
            guard newRawOutput != rawOutput else { return }
            rawOutput = newRawOutput

            let text = rawOutput
            async let parsedOutput = Task.detached(priority: .userInitiated) {
                Self.parseAnsiToAttributedString(text)
            }.value

            async let detectedAction = Task.detached(priority: .utility) {
                Self.detectQuickAction(from: text)
            }.value

            let (newOutput, newAction) = await (parsedOutput, detectedAction)
            output = newOutput
            quickAction = newAction
            contentVersion = UUID()
        } catch let error as APIError {
            if case .unauthorized = error {
                errorMessage = "Server authentication expired. Reconnect and re-pair this server."
                showError = true
                return
            }
            errorMessage = error.localizedDescription
            showError = true
        } catch {
            errorMessage = error.localizedDescription
            showError = true
        }
    }

    func sendInput(_ text: String) async {
        isSending = true
        defer { isSending = false }

        do {
            try await api.sendInput(target: target, text: text)
            CommandHistoryManager.shared.add(text)
            try? await Task.sleep(for: .milliseconds(300))
            await refreshSilently()
        } catch let error as APIError {
            if case .unauthorized = error {
                errorMessage = "Server authentication expired. Reconnect and re-pair this server."
                showError = true
                return
            }
            errorMessage = error.localizedDescription
            showError = true
        } catch {
            errorMessage = error.localizedDescription
            showError = true
        }
    }

    func sendKey(_ key: String) async -> Bool {
        if shortcutEndpointState == .unsupportedByServer {
            if !didReportUnsupportedKeyEndpoint {
                didReportUnsupportedKeyEndpoint = true
                errorMessage = shortcutStatusMessage
                showError = true
            }
            return false
        }

        if shortcutEndpointState == .deploymentMismatch {
            if !didReportShortcutDeploymentMismatch {
                didReportShortcutDeploymentMismatch = true
                errorMessage = shortcutStatusMessage
                showError = true
            }
            return false
        }

        isSending = true
        defer { isSending = false }

        do {
            try await api.sendKey(target: target, key: key)
            if shortcutEndpointState == .unknownLegacy {
                shortcutEndpointState = .available
            }
            try? await Task.sleep(for: .milliseconds(150))
            await refreshSilently()
            return true
        } catch let error as APIError {
            switch error {
            case .unauthorized:
                errorMessage = "Server authentication expired. Reconnect and re-pair this server."
                showError = true
            case .httpError(let statusCode, let path, _):
                if statusCode == 404 &&
                    path.contains("/panes/") &&
                    path.hasSuffix("/key") {
                    if shortcutSupportFromCapabilities == .supported {
                        shortcutEndpointState = .deploymentMismatch
                        if !didReportShortcutDeploymentMismatch {
                            didReportShortcutDeploymentMismatch = true
                            errorMessage = "Shortcut route mismatch detected. Server claims support, but /panes/{target}/key returned 404. Verify reverse proxy routes and active tmux-chatd binary."
                            showError = true
                        }
                    } else {
                        shortcutEndpointState = .unsupportedByServer
                        if !didReportUnsupportedKeyEndpoint {
                            didReportUnsupportedKeyEndpoint = true
                            errorMessage = "This tmux-chatd deployment does not expose shortcut keys yet. Upgrade tmux-chatd and reconnect."
                            showError = true
                        }
                    }
                } else {
                    errorMessage = error.localizedDescription
                    showError = true
                }
            case .serverError:
                errorMessage = error.localizedDescription
                showError = true
            case .decodingError, .invalidURL, .networkError:
                errorMessage = error.localizedDescription
                showError = true
            }
            return false
        } catch {
            errorMessage = error.localizedDescription
            showError = true
            return false
        }
    }

    func sendEscape() async {
        isSending = true
        defer { isSending = false }

        do {
            try await api.sendEscape(target: target)
            try? await Task.sleep(for: .milliseconds(300))
            await refreshSilently()
        } catch let error as APIError {
            if case .unauthorized = error {
                errorMessage = "Server authentication expired. Reconnect and re-pair this server."
                showError = true
                return
            }
            errorMessage = error.localizedDescription
            showError = true
        } catch {
            errorMessage = error.localizedDescription
            showError = true
        }
    }
}

#Preview {
    NavigationStack {
        PaneDetailView(
            pane: Pane(index: 0, active: true, target: "test:0.0", currentPath: "/Users/test"),
            windowName: "bash"
        )
    }
}
