import AppKit
import SwiftUI
@preconcurrency import Translation

struct TranslatorView: View {
    @ObservedObject var translator: TranslatorStore
    @ObservedObject var presentation: IslandPresentationState
    @State private var isEditingSource = false
    @State private var showsAPIKeyEditor = false
    @State private var apiKeyDraft = ""

    var body: some View {
        Group {
            if #available(macOS 15.0, *) {
                SystemTranslationHost(translator: translator) {
                    content
                }
            } else {
                content
            }
        }
        .onAppear {
            translator.scheduleTranslation(immediate: true)
        }
        .onChange(of: translator.inputText) {
            translator.scheduleTranslation()
        }
        .onChange(of: translator.engine) {
            showsAPIKeyEditor = translator.engine.requiresAPIKey && !translator.hasCurrentAPIKey
            apiKeyDraft = ""
            translator.settingsChanged()
        }
        .onChange(of: translator.sourceLanguage) {
            translator.settingsChanged()
        }
        .onChange(of: translator.targetLanguage) {
            translator.settingsChanged()
        }
    }

    private var content: some View {
        VStack(spacing: 12) {
            toolbar

            if showsAPIKeyEditor && translator.engine.requiresAPIKey {
                apiKeyEditor
            }

            HStack(spacing: 10) {
                sourcePanel
                resultPanel
            }
        }
        .padding(16)
        .frame(width: 560, height: 330)
    }

    private var toolbar: some View {
        HStack(spacing: 8) {
            languageMenu(title: translator.sourceLanguage?.title ?? "Определить", isSource: true)

            Button {
                translator.swapLanguages()
                presentation.bodyFocusRequestID &+= 1
            } label: {
                Image(systemName: "arrow.left.arrow.right")
                    .frame(width: 24, height: 24)
            }
            .buttonStyle(IslandIconButtonStyle())
            .accessibilityLabel("Поменять языки местами")

            languageMenu(title: translator.targetLanguage.title, isSource: false)

            Spacer()

            Menu {
                ForEach(TranslationEngine.allCases) { engine in
                    Button {
                        translator.engine = engine
                    } label: {
                        if translator.engine == engine {
                            Label(engine.title, systemImage: "checkmark")
                        } else {
                            Text(engine.title)
                        }
                    }
                }
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: translator.engine == .system ? "apple.logo" : "network")
                    Text(translator.engine.shortTitle)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 8, weight: .bold))
                }
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .padding(.horizontal, 9)
                .frame(height: 28)
                .background(IslandTheme.surface, in: Capsule())
                .foregroundStyle(.white)
            }
            .menuStyle(.borderlessButton)
            .tint(.white)
            .fixedSize()

            if translator.engine.requiresAPIKey {
                Button {
                    showsAPIKeyEditor.toggle()
                    apiKeyDraft = ""
                } label: {
                    Image(systemName: translator.hasCurrentAPIKey ? "key.fill" : "key")
                        .frame(width: 24, height: 24)
                }
                .buttonStyle(IslandIconButtonStyle())
                .accessibilityLabel("Настроить API-ключ")
            }
        }
        .foregroundStyle(.white)
    }

    private func languageMenu(title: String, isSource: Bool) -> some View {
        Menu {
            if isSource {
                Button("Определить автоматически") {
                    translator.sourceLanguage = nil
                }
                Divider()
            }
            ForEach(TranslationLanguage.allCases) { language in
                Button {
                    if isSource {
                        translator.sourceLanguage = language
                    } else {
                        translator.targetLanguage = language
                    }
                } label: {
                    let selected = isSource
                        ? translator.sourceLanguage == language
                        : translator.targetLanguage == language
                    if selected {
                        Label(language.title, systemImage: "checkmark")
                    } else {
                        Text(language.title)
                    }
                }
            }
        } label: {
            HStack(spacing: 5) {
                Text(title)
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .bold))
            }
            .font(.system(size: 11, weight: .semibold, design: .rounded))
            .padding(.horizontal, 9)
            .frame(height: 28)
            .background(IslandTheme.surface, in: Capsule())
            .foregroundStyle(.white)
        }
        .menuStyle(.borderlessButton)
        .tint(.white)
        .fixedSize()
    }

    private var apiKeyEditor: some View {
        HStack(spacing: 8) {
            Image(systemName: "key")
                .foregroundStyle(NoteColor.mint.color)
            SecureField("API-ключ \(translator.engine.title)", text: $apiKeyDraft)
                .textFieldStyle(.plain)
                .font(.system(size: 11, design: .rounded))
                .onSubmit(saveAPIKey)
            Button("Сохранить", action: saveAPIKey)
                .buttonStyle(.plain)
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .foregroundStyle(NoteColor.mint.color)
            if translator.hasCurrentAPIKey {
                Button("Удалить") {
                    translator.removeAPIKey()
                    apiKeyDraft = ""
                }
                .buttonStyle(.plain)
                .font(.system(size: 10, weight: .medium, design: .rounded))
                .foregroundStyle(IslandTheme.secondary)
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 34)
        .background(IslandTheme.surface, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private var sourcePanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("ТЕКСТ")
                .font(.system(size: 9, weight: .bold, design: .rounded))
                .foregroundStyle(IslandTheme.secondary)

            ZStack(alignment: .topLeading) {
                SynchronousTextView(
                    text: $translator.inputText,
                    isEditing: $isEditingSource,
                    focusRequestID: presentation.bodyFocusRequestID,
                    appendsNewlineOnFocus: false,
                    accessibilityLabel: "Текст для перевода"
                )

                if !isEditingSource && !translator.inputText.isEmpty {
                    Text(translator.inputText)
                        .font(.system(size: 14, weight: .regular, design: .rounded))
                        .foregroundStyle(Color.white.opacity(0.88))
                        .lineSpacing(4)
                        .padding(.top, 3)
                        .allowsHitTesting(false)
                }

                if translator.inputText.isEmpty && !isEditingSource {
                    Text("Начните печатать…")
                        .font(.system(size: 14, design: .rounded))
                        .foregroundStyle(IslandTheme.secondary.opacity(0.7))
                        .padding(.top, 3)
                        .allowsHitTesting(false)
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(IslandTheme.surface.opacity(0.62), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(NoteColor.mint.color.opacity(0.28), lineWidth: 0.75)
        }
    }

    private var resultPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("ПЕРЕВОД")
                    .font(.system(size: 9, weight: .bold, design: .rounded))
                    .foregroundStyle(IslandTheme.secondary)
                if let detected = translator.detectedLanguage {
                    Text(detected.uppercased())
                        .font(.system(size: 8, weight: .bold, design: .rounded))
                        .foregroundStyle(NoteColor.mint.color)
                }
                Spacer()
                if translator.isTranslating {
                    ProgressView()
                        .controlSize(.small)
                } else if !translator.outputText.isEmpty {
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(translator.outputText, forType: .string)
                    } label: {
                        Image(systemName: "doc.on.doc")
                            .frame(width: 20, height: 20)
                    }
                    .buttonStyle(IslandIconButtonStyle())
                    .accessibilityLabel("Скопировать перевод")
                }
            }

            if let error = translator.errorMessage {
                VStack(alignment: .leading, spacing: 7) {
                    Text(error)
                        .font(.system(size: 12, weight: .medium, design: .rounded))
                        .foregroundStyle(NoteColor.peach.color)
                    if translator.engine.requiresAPIKey {
                        Button("Добавить ключ") {
                            showsAPIKeyEditor = true
                        }
                        .buttonStyle(.plain)
                        .font(.system(size: 11, weight: .semibold, design: .rounded))
                        .foregroundStyle(NoteColor.mint.color)
                    }
                }
            } else if translator.outputText.isEmpty {
                Text("Перевод появится здесь")
                    .font(.system(size: 14, design: .rounded))
                    .foregroundStyle(IslandTheme.secondary.opacity(0.7))
            } else {
                ScrollView {
                    Text(translator.outputText)
                        .font(.system(size: 14, weight: .regular, design: .rounded))
                        .foregroundStyle(Color.white.opacity(0.94))
                        .lineSpacing(4)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(IslandTheme.surface.opacity(0.62), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private func saveAPIKey() {
        guard translator.saveAPIKey(apiKeyDraft) else { return }
        apiKeyDraft = ""
        showsAPIKeyEditor = false
    }
}

@available(macOS 15.0, *)
private struct SystemTranslationHost<Content: View>: View {
    @ObservedObject var translator: TranslatorStore
    @State private var configuration: TranslationSession.Configuration?
    @ViewBuilder let content: () -> Content

    var body: some View {
        content()
            .onChange(of: translator.systemRequestID, initial: true) {
                guard translator.systemRequestID > 0, translator.engine == .system else { return }
                let source = translator.sourceLanguage.map { Locale.Language(identifier: $0.rawValue) }
                let target = Locale.Language(identifier: translator.targetLanguage.rawValue)
                if configuration == nil {
                    configuration = TranslationSession.Configuration(source: source, target: target)
                } else {
                    configuration?.source = source
                    configuration?.target = target
                    configuration?.invalidate()
                }
            }
            .translationTask(configuration) { session in
                let requestID = translator.systemRequestID
                let sourceText = translator.inputText
                guard requestID > 0, translator.engine == .system, !sourceText.isEmpty else { return }
                do {
                    let response = try await session.translate(sourceText)
                    await MainActor.run {
                        translator.acceptSystemTranslation(
                            response.targetText,
                            detectedLanguage: response.sourceLanguage.minimalIdentifier,
                            requestID: requestID
                        )
                    }
                } catch is CancellationError {
                    return
                } catch {
                    await MainActor.run {
                        translator.failSystemTranslation(error, requestID: requestID)
                    }
                }
            }
    }
}
