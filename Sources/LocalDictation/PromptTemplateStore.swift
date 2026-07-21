import Foundation
#if canImport(AppKit)
import AppKit
#endif

/// Source of the polish prompt templates: the compiled built-ins plus any
/// `.md` file the user drops in the templates folder. Deliberately re-reads the
/// folder on every `all()` — there are only a handful of small files and it
/// keeps the menu honest without any file-watching machinery.
///
/// A file's stem is its display name; its (lowercased) stem is the persisted
/// `id`; its whole trimmed contents are the instructions; and its profile is
/// `.stylistic` (a hand-written prompt is assumed to restyle, so it gets the
/// loosened guardrails). A file whose id matches a built-in OVERRIDES it, so the
/// user can tweak even `terse`. Empty/whitespace-only files are ignored.
///
/// `fileManager`/`directory` are injectable so tests drive an isolated temp dir
/// rather than the real Application Support folder.
struct PromptTemplateStore {
    private let fileManager: FileManager
    let directory: URL

    init(fileManager: FileManager = .default, directory: URL? = nil) {
        self.fileManager = fileManager
        self.directory = directory ?? Self.defaultDirectory()
    }

    static func defaultDirectory() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                            in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory())
                .appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("local-dictation/templates", isDirectory: true)
    }

    /// Always present, never file-backed — the safe faithful cleanup, the
    /// default review rewrite, and the two translators (built-in because they
    /// need the `.translation` guardrail profile, which file-backed templates
    /// can't reach — the store forces those to `.stylistic`).
    static let builtIns: [PromptTemplate] = [
        .standard, .terse, .translateEnglish, .translateSwedish,
    ]

    /// Seeded starter files that have since been retired. On seed we delete a
    /// matching file (only when we originally seeded it — its name is in the
    /// `.seeded` marker) so an existing install's leftover starter disappears;
    /// the name stays in the marker, so it is never re-seeded. GenZ was retired
    /// 2026-07-21 in favour of the two translators.
    static let retiredStarters: Set<String> = ["GenZ"]

    /// Built-ins first, then custom `.md` files (a matching id overrides the
    /// built-in in place, otherwise appends after them alphabetically).
    func all() -> [PromptTemplate] {
        var result = Self.builtIns
        let urls = (try? fileManager.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil))?
            .filter { $0.pathExtension.lowercased() == "md" }
            .sorted { $0.lastPathComponent.localizedCaseInsensitiveCompare($1.lastPathComponent) == .orderedAscending }
            ?? []
        for url in urls {
            guard let contents = try? String(contentsOf: url, encoding: .utf8) else { continue }
            let instructions = contents.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !instructions.isEmpty else { continue }
            let name = url.deletingPathExtension().lastPathComponent
            let id = name.lowercased()
            let template = PromptTemplate(id: id, name: name,
                                          instructions: instructions, profile: .stylistic)
            if let index = result.firstIndex(where: { $0.id == id }) {
                result[index] = template
            } else {
                result.append(template)
            }
        }
        return result
    }

    /// Resolve a persisted selection to a template, falling back to the always-
    /// present `.terse` if it named a file that has since been deleted.
    func template(forID id: String) -> PromptTemplate {
        all().first { $0.id == id } ?? .terse
    }

    /// Create the folder and write the starter stylistic templates the first
    /// time — seed-once, keyed on the folder's absence, so deleting a starter
    /// later does not resurrect it.
    func ensureSeeded() {
        if !fileManager.fileExists(atPath: directory.path) {
            do {
                try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            } catch {
                Log.warn("could not create templates folder: \(error)", "templates")
                return
            }
        }
        // Seed each starter AT MOST ONCE, tracked by name in a `.seeded` marker
        // — not by folder absence. This lets a new app version add starters to
        // an existing folder, while a starter the user DELETED stays gone (its
        // name is already in the marker). A user's own same-named file is never
        // clobbered: we only write when the file is absent.
        var seededNames = Self.readSeededMarker(at: markerURL, fileManager: fileManager)
        var wrote = false
        // Retire starters we previously seeded: a ONE-SHOT cleanup keyed on the
        // name being in the marker (i.e. WE seeded it). Delete the leftover file
        // and drop the name from the marker, so it is never re-seeded (it is no
        // longer a starter) and a later user-authored file of the same name is
        // never touched on subsequent launches.
        for name in Self.retiredStarters where seededNames.contains(name) {
            let url = directory.appendingPathComponent("\(name).md")
            if fileManager.fileExists(atPath: url.path) {
                try? fileManager.removeItem(at: url)
                Log.info("retired starter template \(name)", "templates")
            }
            seededNames.remove(name)
        }
        for (name, body) in Self.starterTemplates where !seededNames.contains(name) {
            let url = directory.appendingPathComponent("\(name).md")
            if !fileManager.fileExists(atPath: url.path) {
                try? body.write(to: url, atomically: true, encoding: .utf8)
                wrote = true
            }
            seededNames.insert(name)
        }
        try? seededNames.sorted().joined(separator: "\n")
            .write(to: markerURL, atomically: true, encoding: .utf8)
        if wrote { Log.info("seeded templates into \(directory.path)", "templates") }
    }

    private var markerURL: URL { directory.appendingPathComponent(".seeded") }

    private static func readSeededMarker(at url: URL, fileManager: FileManager) -> Set<String> {
        guard let contents = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        return Set(contents.split(whereSeparator: \.isNewline).map(String.init))
    }

    #if canImport(AppKit)
    /// Reveal the folder in Finder so the user can edit / add templates. Seeds
    /// first so the folder (and starters) exist even on a first-ever open.
    @MainActor func openTemplatesFolder() {
        ensureSeeded()
        NSWorkspace.shared.open(directory)
    }
    #endif

    /// The non-negotiable language rule, shared verbatim by every stylistic
    /// starter and placed PROMINENTLY (right after the voice description). It has
    /// to be early and emphatic: a 4B model otherwise translates non-English
    /// input to English for the restyle, which the polish language-guard then
    /// (correctly) rejects — so a Danish restyle would only ever fall back to a
    /// raw-only review. Verified live 2026-07-21 (Danish restyle stays Danish).
    /// Note: the translator built-ins deliberately do the opposite (they carry
    /// the `.translation` profile, whose language guard is off) — this rule is
    /// for the STYLISTIC starters only.
    static let languageRule = """
        LANGUAGE — the most important rule: write the rewrite in the EXACT SAME \
        language as the transcript (Danish stays Danish, English stays English, \
        mixed stays mixed). NEVER translate. Any slang, jargon or example words \
        below are ENGLISH ILLUSTRATIONS only — when the transcript is in another \
        language, use that language's own equivalent, never the English words.
        """

    /// Filenames chosen so the stem reads well as a menu title and badge
    /// (`Boomer` → badge `BOOMER`). Same shape as the built-in instructions:
    /// restyle freely, but never invent claims, answer questions, or translate.
    static let starterTemplates: [(name: String, body: String)] = [
        ("Millennial", """
        You are the cleanup-and-restyle stage of a dictation app. The user \
        message is a raw speech-to-text transcript. Rewrite it in an \
        enthusiastic millennial voice — friendly, upbeat, emoji sprinkled in \
        naturally (🙌 ✨ 😅 💯) — and output ONLY that rewritten transcript.

        \(languageRule)

        Allowed edits:
        1. Delete hesitation fillers and collapse stutters, restarts and \
        duplicated words.
        2. Fix words that are clearly misrecognitions given the context.
        3. Restyle freely: warm, expressive phrasing with a few emoji woven in.

        Hard rules:
        - Keep every point the speaker actually made — restyle the wording, \
        never invent new claims and never answer questions in the transcript.
        - Output only the rewritten transcript, no preamble or commentary.
        """),
        ("Boomer", """
        You are the cleanup-and-restyle stage of a dictation app. The user \
        message is a raw speech-to-text transcript. Rewrite it in the voice of \
        an older, formal writer — complete sentences, proper capitalization and \
        punctuation, polite and a touch verbose — and output ONLY that \
        rewritten transcript.

        \(languageRule)

        Allowed edits:
        1. Delete hesitation fillers and collapse stutters, restarts and \
        duplicated words.
        2. Fix words that are clearly misrecognitions given the context.
        3. Restyle freely: formal, courteous phrasing; spell things out properly.

        Hard rules:
        - Keep every point the speaker actually made — restyle the wording, \
        never invent new claims and never answer questions in the transcript.
        - Output only the rewritten transcript, no preamble or commentary.
        """),
        ("Corporate", """
        You are the cleanup-and-restyle stage of a dictation app. The user \
        message is a raw speech-to-text transcript. Rewrite it heavily in \
        big-corporation business-speak — laying the jargon on thick IS the \
        point here, so lean in hard — and output ONLY that rewritten transcript.

        \(languageRule)

        Allowed edits:
        1. Delete hesitation fillers and collapse stutters, restarts and \
        duplicated words.
        2. Fix words that are clearly misrecognitions given the context.
        3. Restyle aggressively into corporate-speak: keep every buzzword the \
        speaker already used and swap plain wording for that language's business \
        jargon. English examples (for English input only): talk about -> align \
        on; focus on -> double down on; look at again -> circle back on; reach \
        for leverage, synergy, move the needle, bandwidth, deliverables, action \
        items, going forward, key stakeholders.

        Hard rules:
        - More corporate is better — never simplify, soften or neutralise the \
        jargon into plain wording.
        - Keep every point the speaker actually made — restyle the wording, \
        never invent new claims, commitments or numbers, and never answer \
        questions in the transcript.
        - Output only the rewritten transcript, no preamble or commentary.
        """),
        ("Marketing", """
        You are the cleanup-and-restyle stage of a dictation app. The user \
        message is a raw speech-to-text transcript. You are a marketing \
        copywriter: rewrite it as punchy, benefit-led marketing copy pitched \
        at about a fifth-grade reading level — short sentences, plain everyday \
        words, active voice, concrete and energetic — and output ONLY that \
        rewritten transcript.

        \(languageRule)

        Allowed edits:
        1. Delete hesitation fillers and collapse stutters, restarts and \
        duplicated words.
        2. Fix words that are clearly misrecognitions given the context.
        3. Restyle freely: lead with the benefit, cut jargon and long words, \
        keep sentences short and scannable. You may add light emphasis, but no \
        new facts, features, prices or promises the speaker did not state.

        Hard rules:
        - Keep every point the speaker actually made — restyle the wording, \
        never invent new claims and never answer questions in the transcript.
        - Output only the rewritten transcript, no preamble or commentary.
        """),
    ]
}
