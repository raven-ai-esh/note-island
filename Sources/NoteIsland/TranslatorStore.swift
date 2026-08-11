import Combine
import Foundation
import Security

enum IslandMode: String, CaseIterable, Sendable {
    case notes
    case translator
    case meetings
    case recordings
    case screenshots

    var title: String {
        switch self {
        case .notes: "Заметки"
        case .translator: "Переводчик"
        case .meetings: "Встречи"
        case .recordings: "Записи"
        case .screenshots: "Скриншоты"
        }
    }

    var symbol: String {
        switch self {
        case .notes: "note.text"
        case .translator: "character.bubble"
        case .meetings: "calendar"
        case .recordings: "record.circle"
        case .screenshots: "camera.viewfinder"
        }
    }

    var shortcutTitle: String {
        switch self {
        case .notes: "⌘⇧N"
        case .translator: "⌘⇧T"
        case .meetings: "⌘⇧M"
        case .recordings: "⌘⇧R"
        case .screenshots: "⌘⇧S"
        }
    }
}

enum TranslationEngine: String, CaseIterable, Identifiable, Sendable {
    case system
    case google
    case deepL

    var id: String { rawValue }

    var title: String {
        switch self {
        case .system: "Apple Translation"
        case .google: "Google Cloud"
        case .deepL: "DeepL"
        }
    }

    var shortTitle: String {
        switch self {
        case .system: "Apple"
        case .google: "Google"
        case .deepL: "DeepL"
        }
    }

    var requiresAPIKey: Bool { self != .system }
}

enum TranslationLanguage: String, CaseIterable, Identifiable, Sendable {
    case russian = "ru"
    case english = "en"
    case spanish = "es"
    case german = "de"
    case french = "fr"
    case italian = "it"
    case portuguese = "pt"
    case chinese = "zh"
    case japanese = "ja"
    case korean = "ko"
    case ukrainian = "uk"
    case turkish = "tr"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .russian: "Русский"
        case .english: "Английский"
        case .spanish: "Испанский"
        case .german: "Немецкий"
        case .french: "Французский"
        case .italian: "Итальянский"
        case .portuguese: "Португальский"
        case .chinese: "Китайский"
        case .japanese: "Японский"
        case .korean: "Корейский"
        case .ukrainian: "Украинский"
        case .turkish: "Турецкий"
        }
    }
}

protocol TranslationCredentialStoring: AnyObject {
    func value(for engine: TranslationEngine) -> String?
    @discardableResult func setValue(_ value: String?, for engine: TranslationEngine) -> Bool
}

final class KeychainTranslationCredentials: TranslationCredentialStoring {
    private let service = "com.noteisland.translation"

    func value(for engine: TranslationEngine) -> String? {
        guard engine.requiresAPIKey else { return nil }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: engine.rawValue,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    @discardableResult
    func setValue(_ value: String?, for engine: TranslationEngine) -> Bool {
        guard engine.requiresAPIKey else { return false }
        let lookup: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: engine.rawValue
        ]
        SecItemDelete(lookup as CFDictionary)
        guard let value, !value.isEmpty, let data = value.data(using: .utf8) else { return true }
        var item = lookup
        item[kSecValueData as String] = data
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        return SecItemAdd(item as CFDictionary, nil) == errSecSuccess
    }
}

enum TranslationServiceError: LocalizedError {
    case missingKey(TranslationEngine)
    case invalidResponse
    case provider(String)

    var errorDescription: String? {
        switch self {
        case .missingKey(let engine): "Добавьте API-ключ для \(engine.title)"
        case .invalidResponse: "Сервис вернул некорректный ответ"
        case .provider(let message): message
        }
    }
}

struct TranslationHTTPService {
    static func googleRequest(
        text: String,
        source: TranslationLanguage?,
        target: TranslationLanguage,
        apiKey: String
    ) throws -> URLRequest {
        guard var components = URLComponents(string: "https://translation.googleapis.com/language/translate/v2") else {
            throw TranslationServiceError.invalidResponse
        }
        components.queryItems = [URLQueryItem(name: "key", value: apiKey)]
        guard let url = components.url else { throw TranslationServiceError.invalidResponse }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        var body: [String: Any] = [
            "q": text,
            "target": target.rawValue,
            "format": "text"
        ]
        if let source { body["source"] = source.rawValue }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }

    static func deepLRequest(
        text: String,
        source: TranslationLanguage?,
        target: TranslationLanguage,
        apiKey: String
    ) throws -> URLRequest {
        let host = apiKey.hasSuffix(":fx") ? "api-free.deepl.com" : "api.deepl.com"
        guard let url = URL(string: "https://\(host)/v2/translate") else {
            throw TranslationServiceError.invalidResponse
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("DeepL-Auth-Key \(apiKey)", forHTTPHeaderField: "Authorization")
        var body: [String: Any] = [
            "text": [text],
            "target_lang": target.rawValue.uppercased(),
            "model_type": "prefer_quality_optimized"
        ]
        if let source { body["source_lang"] = source.rawValue.uppercased() }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }

    static func translate(
        engine: TranslationEngine,
        text: String,
        source: TranslationLanguage?,
        target: TranslationLanguage,
        apiKey: String,
        session: URLSession = .shared
    ) async throws -> (text: String, detectedLanguage: String?) {
        let request: URLRequest
        switch engine {
        case .system:
            throw TranslationServiceError.invalidResponse
        case .google:
            request = try googleRequest(text: text, source: source, target: target, apiKey: apiKey)
        case .deepL:
            request = try deepLRequest(text: text, source: source, target: target, apiKey: apiKey)
        }
        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw TranslationServiceError.invalidResponse
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            if let error = try? JSONDecoder().decode(ProviderErrorEnvelope.self, from: data) {
                throw TranslationServiceError.provider(error.message)
            }
            throw TranslationServiceError.provider("Ошибка сервиса: \(httpResponse.statusCode)")
        }
        switch engine {
        case .google:
            let decoded = try JSONDecoder().decode(GoogleEnvelope.self, from: data)
            guard let translation = decoded.data.translations.first else {
                throw TranslationServiceError.invalidResponse
            }
            return (translation.translatedText.decodingHTMLEntities, translation.detectedSourceLanguage)
        case .deepL:
            let decoded = try JSONDecoder().decode(DeepLEnvelope.self, from: data)
            guard let translation = decoded.translations.first else {
                throw TranslationServiceError.invalidResponse
            }
            return (translation.text, translation.detectedSourceLanguage?.lowercased())
        case .system:
            throw TranslationServiceError.invalidResponse
        }
    }
}

private struct GoogleEnvelope: Decodable {
    struct Payload: Decodable {
        struct Translation: Decodable {
            let translatedText: String
            let detectedSourceLanguage: String?
        }
        let translations: [Translation]
    }
    let data: Payload
}

private struct DeepLEnvelope: Decodable {
    struct Translation: Decodable {
        let detectedSourceLanguage: String?
        let text: String

        enum CodingKeys: String, CodingKey {
            case detectedSourceLanguage = "detected_source_language"
            case text
        }
    }
    let translations: [Translation]
}

private struct ProviderErrorEnvelope: Decodable {
    struct NestedError: Decodable { let message: String }
    let message: String

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let direct = try? container.decode(String.self, forKey: .message) {
            message = direct
        } else if let nested = try? container.decode(NestedError.self, forKey: .error) {
            message = nested.message
        } else {
            throw TranslationServiceError.invalidResponse
        }
    }

    private enum CodingKeys: String, CodingKey { case message, error }
}

private extension String {
    var decodingHTMLEntities: String {
        replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&apos;", with: "'")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&amp;", with: "&")
    }
}

@MainActor
final class TranslatorStore: ObservableObject {
    @Published var inputText = ""
    @Published private(set) var outputText = ""
    @Published var sourceLanguage: TranslationLanguage?
    @Published var targetLanguage: TranslationLanguage
    @Published var engine: TranslationEngine
    @Published private(set) var isTranslating = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var detectedLanguage: String?
    @Published private(set) var systemRequestID = 0

    private let credentials: TranslationCredentialStoring
    private var scheduledTask: Task<Void, Never>?

    init(credentials: TranslationCredentialStoring = KeychainTranslationCredentials()) {
        self.credentials = credentials
        let defaults = UserDefaults.standard
        targetLanguage = TranslationLanguage(rawValue: defaults.string(forKey: "translator.target") ?? "ru") ?? .russian
        engine = TranslationEngine(rawValue: defaults.string(forKey: "translator.engine") ?? "system") ?? .system
        if let source = defaults.string(forKey: "translator.source") {
            sourceLanguage = TranslationLanguage(rawValue: source)
        }
    }

    var hasCurrentAPIKey: Bool {
        !engine.requiresAPIKey || !(credentials.value(for: engine) ?? "").isEmpty
    }

    func saveAPIKey(_ key: String) -> Bool {
        let saved = credentials.setValue(key.trimmingCharacters(in: .whitespacesAndNewlines), for: engine)
        if saved {
            errorMessage = nil
            scheduleTranslation(immediate: true)
        }
        return saved
    }

    func removeAPIKey() {
        credentials.setValue(nil, for: engine)
        outputText = ""
        errorMessage = "Добавьте API-ключ для \(engine.title)"
    }

    func swapLanguages() {
        let previousTarget = targetLanguage
        if let sourceLanguage {
            targetLanguage = sourceLanguage
            self.sourceLanguage = previousTarget
        } else {
            sourceLanguage = previousTarget
            targetLanguage = previousTarget == .russian ? .english : .russian
        }
        persistSettings()
        scheduleTranslation(immediate: true)
    }

    func settingsChanged() {
        persistSettings()
        outputText = ""
        errorMessage = nil
        scheduleTranslation(immediate: true)
    }

    func scheduleTranslation(immediate: Bool = false) {
        scheduledTask?.cancel()
        let trimmed = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            outputText = ""
            errorMessage = nil
            detectedLanguage = nil
            isTranslating = false
            return
        }
        scheduledTask = Task { [weak self] in
            if !immediate {
                try? await Task.sleep(for: .milliseconds(280))
            }
            guard !Task.isCancelled, let self else { return }
            await self.translateNow()
        }
    }

    func acceptSystemTranslation(_ text: String, detectedLanguage: String?, requestID: Int) {
        guard requestID == systemRequestID, engine == .system else { return }
        outputText = text
        self.detectedLanguage = detectedLanguage
        errorMessage = nil
        isTranslating = false
    }

    func failSystemTranslation(_ error: Error, requestID: Int) {
        guard requestID == systemRequestID, engine == .system else { return }
        errorMessage = error.localizedDescription
        isTranslating = false
    }

    private func translateNow() async {
        guard !inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        isTranslating = true
        errorMessage = nil
        if engine == .system {
            if #available(macOS 15.0, *) {
                systemRequestID &+= 1
            } else {
                errorMessage = "Apple Translation требует macOS 15 или новее"
                isTranslating = false
            }
            return
        }
        guard let key = credentials.value(for: engine), !key.isEmpty else {
            errorMessage = "Добавьте API-ключ для \(engine.title)"
            isTranslating = false
            return
        }
        let requestText = inputText
        let requestEngine = engine
        let requestSource = sourceLanguage
        let requestTarget = targetLanguage
        do {
            let response = try await TranslationHTTPService.translate(
                engine: requestEngine,
                text: requestText,
                source: requestSource,
                target: requestTarget,
                apiKey: key
            )
            guard !Task.isCancelled,
                  inputText == requestText,
                  engine == requestEngine,
                  sourceLanguage == requestSource,
                  targetLanguage == requestTarget else { return }
            outputText = response.text
            detectedLanguage = response.detectedLanguage
            errorMessage = nil
        } catch is CancellationError {
            return
        } catch {
            errorMessage = error.localizedDescription
        }
        isTranslating = false
    }

    private func persistSettings() {
        let defaults = UserDefaults.standard
        defaults.set(engine.rawValue, forKey: "translator.engine")
        defaults.set(targetLanguage.rawValue, forKey: "translator.target")
        defaults.set(sourceLanguage?.rawValue, forKey: "translator.source")
    }
}
