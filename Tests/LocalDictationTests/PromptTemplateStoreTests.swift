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
        XCTAssertEqual(all.map(\.id), ["standard", "terse", "translate-english", "translate-swedish"])
        XCTAssertEqual(all.first(where: { $0.id == "standard" })?.profile, .faithful)
        XCTAssertEqual(all.first(where: { $0.id == "terse" })?.profile, .terse)
        XCTAssertEqual(all.first(where: { $0.id == "translate-english" })?.profile, .translation)
        XCTAssertEqual(all.first(where: { $0.id == "translate-swedish" })?.profile, .translation)
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
        // Still exactly the built-in ids (no duplicate), but terse now carries the file.
        XCTAssertEqual(all.map(\.id).sorted(),
                       ["standard", "terse", "translate-english", "translate-swedish"])
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
        XCTAssertTrue(ids.isSuperset(of: ["millennial", "boomer", "corporate", "marketing"]))
        XCTAssertNil(s.all().first { $0.id == "genz" })   // GenZ is retired, never seeded

        // Seed-once (by name marker): deleting a starter and re-seeding does not
        // resurrect it.
        try? FileManager.default.removeItem(at: dir.appendingPathComponent("Boomer.md"))
        s.ensureSeeded()
        XCTAssertNil(s.all().first { $0.id == "boomer" })
    }

    func testEnsureSeededFillsMissingStartersInExistingFolder() {
        // Simulates an existing install (folder present, one starter, no marker):
        // ensureSeeded must add the rest without a folder-absence gate.
        write("Boomer.md", "my edited boomer")
        let s = store()
        s.ensureSeeded()
        let ids = Set(s.all().map(\.id))
        XCTAssertTrue(ids.isSuperset(of: ["corporate", "marketing", "millennial", "boomer"]))
        // A pre-existing same-named file is never clobbered.
        XCTAssertEqual(s.all().first { $0.id == "boomer" }?.instructions, "my edited boomer")
    }

    func testEnsureSeededRetiresPreviouslySeededGenZ() {
        // Simulates an install that HAD GenZ seeded: file present + name in the
        // marker. ensureSeeded must delete the leftover file (one-shot) and not
        // show it as a template.
        write("GenZ.md", "the old seeded genz body")
        write(".seeded", "Boomer\nCorporate\nGenZ\nMarketing\nMillennial")
        let s = store()
        s.ensureSeeded()
        XCTAssertNil(s.all().first { $0.id == "genz" })
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent("GenZ.md").path))
    }

    func testEnsureSeededDoesNotDeleteUserAuthoredGenZ() {
        // A user's OWN GenZ.md (no marker entry — we never seeded it) must survive
        // retirement: retirement is keyed on the name being in the marker.
        write("GenZ.md", "my own genz i wrote after retirement")
        let s = store()
        s.ensureSeeded()
        XCTAssertEqual(s.all().first { $0.id == "genz" }?.instructions,
                       "my own genz i wrote after retirement")
    }

    func testSeedMarkerNotShownAsTemplate() {
        let s = store()
        s.ensureSeeded()
        XCTAssertNil(s.all().first { $0.id == ".seeded" || $0.name == ".seeded" })
    }
}
