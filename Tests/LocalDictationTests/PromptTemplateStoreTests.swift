import XCTest
@testable import LocalDictation

final class PromptTemplateStoreTests: XCTestCase {
    private var dir: URL!

    override func setUp() {
        super.setUp()
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("PromptTemplateStoreTests-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: dir)
        dir = nil
        super.tearDown()
    }

    private func store() -> PromptTemplateStore {
        PromptTemplateStore(directory: dir)
    }

    private func write(_ name: String, _ contents: String) {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try! contents.write(to: dir.appendingPathComponent(name), atomically: true, encoding: .utf8)
    }

    func testBuiltInsAlwaysPresent() {
        // Empty (non-existent) folder: only the compiled built-ins.
        let all = store().all()
        XCTAssertEqual(all.map(\.id), ["standard", "terse"])
        XCTAssertEqual(all.first(where: { $0.id == "standard" })?.profile, .faithful)
        XCTAssertEqual(all.first(where: { $0.id == "terse" })?.profile, .terse)
    }

    func testCustomFileLoadsAsStylistic() {
        write("Pirate.md", "Rewrite it like a pirate, arr.")
        let all = store().all()
        let pirate = all.first { $0.id == "pirate" }
        XCTAssertNotNil(pirate)
        XCTAssertEqual(pirate?.name, "Pirate")             // stem is the display name
        XCTAssertEqual(pirate?.profile, .stylistic)        // custom = loosened guards
        XCTAssertEqual(pirate?.instructions, "Rewrite it like a pirate, arr.")
    }

    func testCustomFileOverridesBuiltIn() {
        write("terse.md", "My own terser prompt.")
        let all = store().all()
        // Still exactly two ids (no duplicate), but terse now carries the file.
        XCTAssertEqual(all.map(\.id).sorted(), ["standard", "terse"])
        let terse = all.first { $0.id == "terse" }
        XCTAssertEqual(terse?.instructions, "My own terser prompt.")
        XCTAssertEqual(terse?.profile, .stylistic)         // file override => stylistic
    }

    func testEmptyFileIgnored() {
        write("Blank.md", "   \n\t  \n")
        XCTAssertNil(store().all().first { $0.id == "blank" })
    }

    func testNonMarkdownFileIgnored() {
        write("notes.txt", "not a template")
        XCTAssertNil(store().all().first { $0.id == "notes" })
    }

    func testTemplateForIDFallsBackToTerse() {
        XCTAssertEqual(store().template(forID: "nope-deleted").id, "terse")
        write("GenZ.md", "genz prompt")
        XCTAssertEqual(store().template(forID: "genz").name, "GenZ")
    }

    func testEnsureSeededWritesStartersOnce() {
        let s = store()
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.path))
        s.ensureSeeded()
        let ids = Set(s.all().map(\.id))
        XCTAssertTrue(ids.isSuperset(of: ["genz", "millennial", "boomer", "corporate", "marketing"]))

        // Seed-once (by name marker): deleting a starter and re-seeding does not
        // resurrect it.
        try? FileManager.default.removeItem(at: dir.appendingPathComponent("GenZ.md"))
        s.ensureSeeded()
        XCTAssertNil(s.all().first { $0.id == "genz" })
    }

    func testEnsureSeededFillsMissingStartersInExistingFolder() {
        // Simulates an existing install (folder present, one starter, no marker):
        // ensureSeeded must add the rest without a folder-absence gate.
        write("GenZ.md", "my edited genz")
        let s = store()
        s.ensureSeeded()
        let ids = Set(s.all().map(\.id))
        XCTAssertTrue(ids.isSuperset(of: ["corporate", "marketing", "millennial", "boomer"]))
        // A pre-existing same-named file is never clobbered.
        XCTAssertEqual(s.all().first { $0.id == "genz" }?.instructions, "my edited genz")
    }

    func testSeedMarkerNotShownAsTemplate() {
        let s = store()
        s.ensureSeeded()
        XCTAssertNil(s.all().first { $0.id == ".seeded" || $0.name == ".seeded" })
    }
}
