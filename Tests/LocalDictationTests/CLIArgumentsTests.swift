import XCTest
@testable import LocalDictation

final class CLIArgumentsTests: XCTestCase {
    /// Unwrap a `.success` or fail the test with a message.
    private func expectSuccess(
        _ argv: [String],
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> CLIArguments? {
        switch CLIArguments.parse(argv) {
        case .some(.success(let cli)):
            return cli
        default:
            XCTFail("expected .success for \(argv)", file: file, line: line)
            return nil
        }
    }

    func testTranscribeFileParsed() {
        guard let cli = expectSuccess(["local-dictation", "--transcribe-file", "/tmp/a.wav"]) else { return }
        XCTAssertEqual(cli.file, "/tmp/a.wav")
        // Defaults: auto engine (nil), auto language, all guards on, no json.
        XCTAssertNil(cli.forcedEngine)
        XCTAssertEqual(cli.language, "auto")
        XCTAssertFalse(cli.accuracy)
        XCTAssertTrue(cli.vadGate)
        XCTAssertTrue(cli.hallucinationFilter)
        XCTAssertFalse(cli.json)
    }

    func testAbsentFlagReturnsNilForGuiLaunch() {
        // No CLI arguments (how the LaunchAgent starts us) → nil → run the GUI.
        XCTAssertNil(CLIArguments.parse(["local-dictation"]))
    }

    func testEngineLanguageAccuracyParsed() {
        guard let cli = expectSuccess([
            "local-dictation",
            "--transcribe-file", "/tmp/a.wav",
            "--engine", "whisper",
            "--language", "da",
            "--accuracy",
        ]) else { return }
        XCTAssertEqual(cli.forcedEngine, .whisper)
        XCTAssertEqual(cli.language, "da")
        XCTAssertTrue(cli.accuracy)
    }

    func testEngineAutoParsesAsNilForcedEngine() {
        // "--engine auto" is valid and means "use the router" (forcedEngine == nil).
        guard let cli = expectSuccess([
            "local-dictation", "--transcribe-file", "/tmp/a.wav", "--engine", "auto",
        ]) else { return }
        XCTAssertNil(cli.forcedEngine)
    }

    func testGuardBypassFlagsParsed() {
        guard let cli = expectSuccess([
            "local-dictation",
            "--transcribe-file", "/tmp/a.wav",
            "--no-vad-gate",
            "--no-hallucination-filter",
        ]) else { return }
        XCTAssertFalse(cli.vadGate)
        XCTAssertFalse(cli.hallucinationFilter)
    }

    func testJsonParsed() {
        guard let cli = expectSuccess([
            "local-dictation", "--transcribe-file", "/tmp/a.wav", "--json",
        ]) else { return }
        XCTAssertTrue(cli.json)
    }

    func testUnknownFlagRejected() {
        guard case .some(.failure) = CLIArguments.parse([
            "local-dictation", "--transcribe-file", "/tmp/a.wav", "--bogus",
        ]) else {
            return XCTFail("expected .failure for an unknown flag")
        }
    }

    func testInvalidEngineValueRejected() {
        guard case .some(.failure) = CLIArguments.parse([
            "local-dictation", "--transcribe-file", "/tmp/a.wav", "--engine", "banana",
        ]) else {
            return XCTFail("expected .failure for an invalid --engine value")
        }
    }

    func testMissingTranscribeFileRejected() {
        // CLI flags present but no required --transcribe-file → usage error, not GUI.
        guard case .some(.failure) = CLIArguments.parse(["local-dictation", "--json"]) else {
            return XCTFail("expected .failure when --transcribe-file is missing")
        }
    }

    func testMissingValueForFlagRejected() {
        guard case .some(.failure) = CLIArguments.parse([
            "local-dictation", "--transcribe-file",
        ]) else {
            return XCTFail("expected .failure when --transcribe-file has no path")
        }
    }
}
