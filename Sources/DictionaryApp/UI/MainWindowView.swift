import AppKit
import SwiftUI

struct MainWindowView: View {
    @ObservedObject var state: ManualLookupState
    @ObservedObject var coordinator: LookupCoordinator
    var onSettings: () -> Void = {}
    @ObservedObject var readiness: AppReadiness = .preview()
    @ObservedObject var serviceSettings: LookupServiceSettings = .preview()
    var onSetup: () -> Void = {}
    @StateObject private var presentation = MainWindowPresentation()

    private var isHome: Bool { if case .idle = coordinator.manual { return true }; return false }

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 26) {
                HStack(spacing: 10) { DictionaryMark(); Text("Dictionary").font(.system(size: 15, weight: .semibold)) }
                Label("查词", systemImage: "magnifyingglass")
                    .font(.system(size: 13, weight: .medium))
                    .frame(maxWidth: .infinity, alignment: .leading).padding(10)
                    .foregroundStyle(DictionaryStyle.accent)
                    .background(DictionaryStyle.accent.opacity(0.09), in: RoundedRectangle(cornerRadius: 8))
                Text("在语境里理解，\n然后继续阅读。")
                    .font(.system(size: 12)).lineSpacing(5).foregroundStyle(DictionaryStyle.secondary)
                    .padding(.horizontal, 8)
                Spacer()
                Button(action: onSetup) {
                    Label(serviceSettings.label, systemImage: serviceSettings.selected == .deepSeek ? "cloud" : "desktopcomputer")
                        .font(.system(size: 11)).fixedSize(horizontal: false, vertical: true)
                }.buttonStyle(.plain).foregroundStyle(DictionaryStyle.secondary).padding(.horizontal, 10)
                if readiness.permission != .granted {
                    Button(action: onSettings) {
                        Label(readiness.permissionLabel, systemImage: "hand.raised")
                            .font(.system(size: 11)).fixedSize(horizontal: false, vertical: true)
                    }.buttonStyle(.plain).foregroundStyle(DictionaryStyle.secondary)
                        .padding(.horizontal, 10).accessibilityIdentifier("selection-permission-settings")
                }
                Button(action: onSettings) { Label("偏好设置", systemImage: "slider.horizontal.3") }
                    .buttonStyle(.plain).font(.system(size: 13)).padding(10)
                    .accessibilityIdentifier("open-settings")
                Text("选词查词   ⌥ D").font(.system(size: 11)).foregroundStyle(DictionaryStyle.secondary).padding(.horizontal, 10)
            }
            .padding(18).frame(width: 185).frame(maxHeight: .infinity)
            .background(DictionaryStyle.surface)
            Rectangle().fill(DictionaryStyle.line).frame(width: 1)
            VStack(spacing: 0) {
                HStack {
                    Text(isHome ? "查词" : "词语释义")
                    Spacer()
                    if coordinator.manual.isLoading {
                        Button("取消") { state.cancel() }
                            .accessibilityIdentifier("cancel-manual-lookup")
                    }
                    Text("英语 → 简体中文")
                }.font(.system(size: 12)).foregroundStyle(DictionaryStyle.secondary)
                    .padding(.horizontal, 28).frame(height: 48)
                Divider()
                ScrollView {
                    VStack(alignment: .leading, spacing: 22) {
                        if isHome {
                            VStack(alignment: .leading, spacing: 10) {
                                Text("WORDS, IN CONTEXT.").font(.system(size: 10, weight: .semibold))
                                    .tracking(2).foregroundStyle(DictionaryStyle.accent)
                                Text("读懂一个词，也读懂此刻。")
                                    .font(.system(size: 27, weight: .medium)).fixedSize(horizontal: false, vertical: true)
                                Text("从一句话开始，找到词语在其中的含义。")
                                    .font(.system(size: 13)).foregroundStyle(DictionaryStyle.secondary)
                            }.padding(.top, 30)
                        }
                        if serviceSettings.needsSetup {
                            DictionaryCard {
                                Text("先选择一种查词方式").font(.system(size: 17, weight: .medium))
                                Text("选择 DeepSeek 云端查词，或使用本机 Ollama。")
                                    .font(.system(size: 13)).foregroundStyle(DictionaryStyle.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                                Button("设置查词方式", action: onSetup).buttonStyle(.borderedProminent)
                                    .accessibilityIdentifier("setup-lookup-service")
                            }
                        } else {
                            searchInput
                        }
                        if !isHome && !serviceSettings.needsSetup {
                            Divider()
                            LookupResultView(phase: coordinator.manual, cloud: coordinator.manualCloud,
                                showsCloudControls: !coordinator.primaryIsCloud, primaryLabel: coordinator.primaryLabel,
                                showsAdditionalMeanings: !coordinator.primaryIsCloud)
                            if case .finished(_, .failure) = coordinator.manual {
                                Button("打开查词服务设置", action: onSetup).font(.system(size: 12))
                            }
                        } else {
                            VStack(alignment: .leading, spacing: 12) {
                                Divider()
                                Label("阅读时选中英文单词，按 ⌥D 即可查词。", systemImage: "text.cursor")
                                Text("也可以输入短语或句子，按 ⌘Return 提交。")
                            }.font(.system(size: 12)).foregroundStyle(DictionaryStyle.secondary).padding(.top, 18)
                        }
                    }
                    .padding(28).frame(minWidth: 0, maxWidth: 720, alignment: .leading).frame(maxWidth: .infinity)
                }
            }
        }
        .frame(minWidth: 640, minHeight: 520)
        .background(DictionaryStyle.paper).foregroundStyle(DictionaryStyle.ink).tint(DictionaryStyle.accent)
        .onAppear {
            readiness.refresh()
            if !state.context.isEmpty { presentation.contextExpanded = true }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in readiness.refresh() }
        .onChange(of: coordinator.manual.isLoading) { _, loading in
            if loading { presentation.contextExpanded = false }
        }
    }

    private var searchInput: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass").foregroundStyle(DictionaryStyle.secondary)
                LookupTextEditor(text: $state.target, label: "输入英文单词、短语或句子",
                                 placeholder: "输入英文单词、短语或句子", centersFirstLine: true,
                                 onSubmit: { state.submit() })
                    .frame(height: 46)
                Button("查词") { state.submit() }.disabled(!state.canSubmit)
                    .buttonStyle(.borderedProminent).controlSize(.large)
            }.padding(.horizontal, 12).padding(.vertical, 4)
                .background(DictionaryStyle.surface, in: RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(DictionaryStyle.line))
            DisclosureGroup("添加语境 · 可选", isExpanded: $presentation.contextExpanded) {
                LookupTextEditor(text: $state.context, label: "包含这个词的英文语境",
                                 placeholder: "粘贴包含这个词的英文句子…", onSubmit: { state.submit() })
                    .frame(height: 84).padding(6)
                    .background(DictionaryStyle.surface, in: RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(DictionaryStyle.line))
                    .padding(.top, 8)
            }.font(.system(size: 12)).foregroundStyle(DictionaryStyle.secondary)
            if let message = state.validationMessage {
                Text(message).font(.system(size: 12)).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

@MainActor
private final class MainWindowPresentation: ObservableObject {
    @Published var contextExpanded = false
}

/// NSTextView supplies marked-text awareness, normal editing, and multiline Return behavior.
struct LookupTextEditor: NSViewRepresentable {
    @Binding var text: String
    let label: String
    var placeholder: String = ""
    var centersFirstLine = false
    let onSubmit: () -> Void

    func makeCoordinator() -> Delegate { Delegate(text: $text) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.borderType = .noBorder
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        let editor = SubmitTextView()
        editor.isRichText = false
        editor.drawsBackground = false
        editor.textColor = .labelColor
        editor.allowsUndo = true
        editor.isAutomaticQuoteSubstitutionEnabled = false
        editor.isAutomaticDashSubstitutionEnabled = false
        let font = NSFont.systemFont(ofSize: 14)
        editor.font = font
        // Placeholder, glyphs and insertion point share the native text container.
        // The search viewport is 46pt high; multiline context remains top aligned.
        let lineHeight = editor.layoutManager?.defaultLineHeight(for: font) ?? 17
        editor.textContainerInset = NSSize(width: 6, height: centersFirstLine ? (46 - lineHeight) / 2 : 8)
        editor.textContainer?.lineFragmentPadding = 0
        editor.placeholder = placeholder
        editor.isVerticallyResizable = true
        editor.isHorizontallyResizable = false
        editor.autoresizingMask = [.width]
        editor.textContainer?.widthTracksTextView = true
        editor.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        editor.setAccessibilityLabel(label)
        editor.delegate = context.coordinator
        editor.textStorage?.delegate = context.coordinator
        editor.onSubmit = onSubmit
        editor.string = text
        scroll.documentView = editor
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let editor = scroll.documentView as? SubmitTextView else { return }
        context.coordinator.text = $text
        editor.onSubmit = onSubmit
        editor.placeholder = placeholder
        if !editor.hasMarkedText(), editor.string != text { editor.string = text }
        editor.needsDisplay = true
    }

    final class Delegate: NSObject, NSTextViewDelegate, NSTextStorageDelegate {
        var text: Binding<String>
        init(text: Binding<String>) { self.text = text }
        func textDidChange(_ notification: Notification) {
            guard let view = notification.object as? NSTextView else { return }
            updateDraft(view.string)
        }
        func textStorage(_ textStorage: NSTextStorage, didProcessEditing editedMask: NSTextStorageEditActions,
                         range editedRange: NSRange, changeInLength delta: Int) {
            // Undo/redo can change storage without a textDidChange callback.
            guard editedMask.contains(.editedCharacters) else { return }
            updateDraft(textStorage.string)
        }
        private func updateDraft(_ value: String) {
            if text.wrappedValue != value { text.wrappedValue = value }
        }
    }
}

final class SubmitTextView: NSTextView {
    var placeholder = "" { didSet { if oldValue != placeholder { needsDisplay = true } } }

    var placeholderRect: NSRect {
        NSRect(origin: textContainerOrigin,
               size: NSSize(width: textContainer?.containerSize.width ?? bounds.width,
                            height: bounds.height - textContainerOrigin.y))
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard string.isEmpty, !hasMarkedText(), !placeholder.isEmpty else { return }
        (placeholder as NSString).draw(with: placeholderRect, options: [.usesLineFragmentOrigin],
            attributes: [.font: font ?? NSFont.systemFont(ofSize: 14),
                         .foregroundColor: NSColor.secondaryLabelColor])
    }

    override func didChangeText() {
        super.didChangeText()
        needsDisplay = true
    }

    var onSubmit: (() -> Void)?
    override func keyDown(with event: NSEvent) {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if (event.keyCode == 36 || event.keyCode == 76), modifiers.contains(.command) {
            if !hasMarkedText() { onSubmit?(); return }
        }
        super.keyDown(with: event)
    }
}
