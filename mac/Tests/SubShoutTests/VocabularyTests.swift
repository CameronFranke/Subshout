import XCTest
@testable import SubShout

final class VocabularyTests: XCTestCase {
    func testEditorNormalizesWhitespaceAndDeduplicatesInOrder() throws {
        XCTAssertEqual(
            try Vocabulary.parse("  SubShout  \n\nNew\t York\r\nsubshout\n NEW  YORK \nCafé\ncAFÉ"),
            ["SubShout", "New York", "Café"]
        )
        XCTAssertEqual(try Vocabulary.parse(" \t\n\r\n"), [])
        XCTAssertEqual(try Vocabulary.normalize(["one\n two", "three\u{00a0}four", "a\u{1c}b"]),
                       ["one two", "three four", "a b"])
        XCTAssertEqual(try Vocabulary.normalize(["Straße", "STRASSE"]), ["Straße"])
    }

    func testNonWhitespaceControlsAreRejectedWithoutExposingTerms() {
        for control in ["\u{00}", "\u{07}", "\u{7f}", "\u{200b}", "\u{e000}", "\u{0378}"] {
            XCTAssertThrowsError(try Vocabulary.parse("secret\(control)term")) { error in
                XCTAssertEqual(error as? Vocabulary.ValidationError, .controlCharacter(1))
                XCTAssertFalse(error.localizedDescription.contains("secret"))
            }
        }
        XCTAssertThrowsError(try Vocabulary.normalize([" \t\n"])) { error in
            XCTAssertEqual(error as? Vocabulary.ValidationError, .emptyPhrase(1))
        }
    }

    func testPhraseLimitCountsUTF8BytesAfterNormalization() throws {
        let boundary = String(repeating: "é", count: 128)
        XCTAssertEqual(try Vocabulary.normalize(["  \(boundary)  "]), [boundary])
        XCTAssertThrowsError(try Vocabulary.normalize([boundary + "a"])) { error in
            XCTAssertEqual(error as? Vocabulary.ValidationError, .phraseTooLong(1))
        }
    }

    func testEntryLimitCountsUniqueNormalizedEntries() throws {
        let boundary = (0..<128).map { "term \($0)" }
        XCTAssertEqual(try Vocabulary.normalize(boundary + ["TERM 0"]), boundary)
        XCTAssertThrowsError(try Vocabulary.normalize(boundary + ["another"])) { error in
            XCTAssertEqual(error as? Vocabulary.ValidationError, .tooManyEntries)
        }
    }

    func testPersistenceDefaultsEmptyAndDoesNotChangeModel() throws {
        let suite = "subshout.tests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(defaults: defaults)
        XCTAssertEqual(settings.vocabulary, [])
        settings.modelID = "selected-test-model"
        try settings.saveVocabulary(["  SubShout ", "subshout", "New\tYork"])
        let restored = AppSettings(defaults: defaults)
        XCTAssertEqual(restored.vocabulary, ["SubShout", "New York"])
        XCTAssertEqual(restored.modelID, "selected-test-model")
        XCTAssertThrowsError(try settings.saveVocabulary(["bad\u{00}term"]))
        XCTAssertEqual(settings.vocabulary, ["SubShout", "New York"])
        XCTAssertEqual(AppSettings(defaults: defaults).vocabulary, ["SubShout", "New York"])
        try settings.saveVocabulary([])
        XCTAssertEqual(AppSettings(defaults: defaults).vocabulary, [])
    }

    func testTranscribeHeaderOmitsEmptyVocabulary() throws {
        let header = try DaemonClient.transcribeHeader(sampleRate: 16_000, vocabulary: [])
        XCTAssertEqual(Set(header.keys), Set(["type", "sample_rate"]))
        XCTAssertEqual(header["type"] as? String, "transcribe")
        XCTAssertEqual(header["sample_rate"] as? Int, 16_000)
    }

    func testTranscribeHeaderEncodesVocabularyAndKeepsPCM() throws {
        let header = try DaemonClient.transcribeHeader(
            sampleRate: 16_000, vocabulary: [" SubShout ", "subshout", "New York"]
        )
        let pcm = Data([0, 1, 2, 3])
        let frame = try WireProtocol.encodeFrame(header: header, payload: pcm)
        let headerLength = Int(WireProtocol.headerLength(fromPrefix: Data(frame.prefix(4))))
        let decoded = try XCTUnwrap(JSONSerialization.jsonObject(
            with: frame.subdata(in: 4..<(4 + headerLength))
        ) as? [String: Any])
        XCTAssertEqual(decoded["vocabulary"] as? [String], ["SubShout", "New York"])
        XCTAssertEqual(decoded["payload_len"] as? Int, pcm.count)
        XCTAssertEqual(Data(frame.suffix(pcm.count)), pcm)
        XCTAssertThrowsError(try DaemonClient.transcribeHeader(
            sampleRate: 16_000, vocabulary: ["bad\u{00}term"]
        ))
    }
}
