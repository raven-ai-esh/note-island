import Foundation
import XCTest
@testable import NoteIsland

final class TranslatorRequestTests: XCTestCase {
    func testGoogleRequestUsesOfficialV2EndpointAndAutoDetection() throws {
        let request = try TranslationHTTPService.googleRequest(
            text: "Hello",
            source: nil,
            target: .russian,
            apiKey: "test-key"
        )

        XCTAssertEqual(request.url?.host, "translation.googleapis.com")
        XCTAssertEqual(request.url?.path, "/language/translate/v2")
        XCTAssertEqual(URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?
            .queryItems?.first(where: { $0.name == "key" })?.value, "test-key")
        let body = try XCTUnwrap(request.httpBody)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(json["q"] as? String, "Hello")
        XCTAssertEqual(json["target"] as? String, "ru")
        XCTAssertNil(json["source"])
    }

    func testDeepLFreeRequestUsesQualityOptimizedModelAndAuthorizationHeader() throws {
        let request = try TranslationHTTPService.deepLRequest(
            text: "Привет",
            source: .russian,
            target: .english,
            apiKey: "test-key:fx"
        )

        XCTAssertEqual(request.url?.host, "api-free.deepl.com")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "DeepL-Auth-Key test-key:fx")
        let body = try XCTUnwrap(request.httpBody)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(json["source_lang"] as? String, "RU")
        XCTAssertEqual(json["target_lang"] as? String, "EN")
        XCTAssertEqual(json["model_type"] as? String, "prefer_quality_optimized")
    }
}

@MainActor
final class TranslatorStoreTests: XCTestCase {
    func testAutomaticDirectionSwapCreatesUsefulRussianEnglishPair() {
        let store = TranslatorStore(credentials: EphemeralTranslationCredentials())
        store.sourceLanguage = nil
        store.targetLanguage = .russian

        store.swapLanguages()

        XCTAssertEqual(store.sourceLanguage, .russian)
        XCTAssertEqual(store.targetLanguage, .english)
    }

    func testRemoteEngineRequiresSavedKey() {
        let store = TranslatorStore(credentials: EphemeralTranslationCredentials())
        store.engine = .google

        XCTAssertFalse(store.hasCurrentAPIKey)
        XCTAssertTrue(store.saveAPIKey("google-test-key"))
        XCTAssertTrue(store.hasCurrentAPIKey)
        store.removeAPIKey()
        XCTAssertFalse(store.hasCurrentAPIKey)
    }
}

private final class EphemeralTranslationCredentials: TranslationCredentialStoring {
    private var values: [TranslationEngine: String] = [:]

    func value(for engine: TranslationEngine) -> String? { values[engine] }

    func setValue(_ value: String?, for engine: TranslationEngine) -> Bool {
        values[engine] = value
        return true
    }
}
