// Owner: claude-core. TitleResolver (SPEC §E.4) and TranscriptTailParser.
import Foundation
import Testing

@testable import SuperNotchCore

@Suite("TitleResolver")
struct TitleResolverTests {
    @Test func order() {
        var candidates = TitleCandidates(
            customTitle: "custom", aiTitle: "ai", sessionTitle: "session", agentsName: "agents", generated: "generated")
        func resolved() -> SessionTitle { TitleResolver.resolve(candidates, firstPrompt: "prompt text", projectName: "proj") }
        #expect(resolved() == SessionTitle(text: "custom", source: .customTitle))
        candidates.customTitle = "  "
        #expect(resolved() == SessionTitle(text: "ai", source: .aiTitle))
        candidates.aiTitle = nil
        #expect(resolved() == SessionTitle(text: "session", source: .sessionTitle))
        candidates.sessionTitle = nil
        #expect(resolved() == SessionTitle(text: "agents", source: .agentsName))
        candidates.agentsName = "proj-3f"  // default display name is not a title
        #expect(resolved() == SessionTitle(text: "generated", source: .generated))
        candidates.generated = nil
        #expect(resolved() == SessionTitle(text: "Prompt text", source: .firstPrompt))
        #expect(
            TitleResolver.resolve(candidates, firstPrompt: "  \n ", projectName: "proj")
                == SessionTitle(text: "proj", source: .fallback))
    }

    @Test func longNativeTitlesAreShortenedOrReplacedByGenerated() {
        var candidates = TitleCandidates(aiTitle: "Investigate why the nightly integration tests are flaky")
        #expect(TitleResolver.resolve(candidates, firstPrompt: nil, projectName: "p").text == "Investigate why the nightly…")
        #expect(!TitleResolver.needsGeneration(candidates, firstPrompt: "x"))
        #expect(TitleResolver.needsCompression(candidates))
        candidates.generated = "Flaky nightly tests"
        #expect(TitleResolver.resolve(candidates, firstPrompt: nil, projectName: "p") == SessionTitle(text: "Flaky nightly tests", source: .generated))
        #expect(!TitleResolver.needsCompression(candidates))
    }

    @Test func generationPolicy() {
        let none = TitleCandidates()
        #expect(TitleResolver.needsGeneration(none, firstPrompt: "fix the bug"))
        #expect(!TitleResolver.needsGeneration(none, firstPrompt: "<pasted_content id=\"1\"> </pasted_content id=\"1\">"))
        #expect(!TitleResolver.needsGeneration(TitleCandidates(sessionTitle: "Named"), firstPrompt: "fix"))
        #expect(!TitleResolver.needsGeneration(TitleCandidates(generated: "Done"), firstPrompt: "fix"))
        // Too early: Claude Code has not had its chance to write an ai-title.
        #expect(
            !TitleResolver.shouldRequestGeneration(
                none, firstPrompt: "fix", completedTurns: 0, secondsSinceFirstPrompt: 5, transcriptReadSinceCheckpoint: true))
        #expect(
            !TitleResolver.shouldRequestGeneration(
                none, firstPrompt: "fix", completedTurns: 1, secondsSinceFirstPrompt: 5, transcriptReadSinceCheckpoint: false))
        #expect(
            TitleResolver.shouldRequestGeneration(
                none, firstPrompt: "fix", completedTurns: 1, secondsSinceFirstPrompt: 5, transcriptReadSinceCheckpoint: true))
        #expect(
            TitleResolver.shouldRequestGeneration(
                none, firstPrompt: "fix", completedTurns: 0, secondsSinceFirstPrompt: 31, transcriptReadSinceCheckpoint: false,
                transcriptUnavailable: true))
        #expect(TitleResolver.generationSource(none, firstPrompt: "  fix   the\nbug ") == "fix the bug")
        #expect(TitleResolver.haikuPrompt(for: "fix the bug").hasSuffix("Reply with the title only.\n\nfix the bug"))
    }

    @Test func shortening() {
        #expect(TitleResolver.shorten("Fix login bug") == "Fix login bug")
        #expect(TitleResolver.shorten("one two three four five") == "one two three four…")
        #expect(TitleResolver.shorten("Supercalifragilisticexpialidocious-and-more") == "Supercalifragilisticexpiali…")
        #expect(TitleResolver.shorten("**\"Refactor parser.\"**") == "Refactor parser")
        #expect(TitleResolver.shorten("a,\n b,  c, d, e") == "a, b, c, d…")
        #expect(TitleResolver.shorten("").isEmpty)
        for text in ["x", "a b c d e f g h", String(repeating: "word ", count: 30)] {
            #expect(TitleResolver.shorten(text).count <= TitleResolver.maxCharacters)
        }
    }

    @Test func promptTitles() {
        func title(_ prompt: String) -> String { TitleResolver.resolve(TitleCandidates(), firstPrompt: prompt, projectName: "p").text }
        #expect(title("hey claude, can you please fix the login bug?") == "Fix the login bug")
        #expect(title("Please add dark mode") == "Add dark mode")
        #expect(title("sort the list") == "Sort the list")  // "so" is not a filler here
        #expect(title("<pasted_content id=\"1\">\nstack trace\n</pasted_content id=\"1\"> why does this crash") == "Stack trace why does…")
        #expect(title("```\ncode\n```") == "Code")
        #expect(title("claude.md cleanup") == "Claude.md cleanup")
    }

    @Test func generatedOutputSanitizing() {
        #expect(TitleResolver.sanitizeGenerated("Billing Retry Refactor") == "Billing Retry Refactor")
        #expect(TitleResolver.sanitizeGenerated("Title: \"Auth refactor.\"\n") == "Auth refactor")
        #expect(TitleResolver.sanitizeGenerated("\n\n**Dark mode toggle**\nExplanation: …") == "Dark mode toggle")
        #expect(TitleResolver.sanitizeGenerated("Error handling cleanup") == "Error handling cleanup")
        #expect(TitleResolver.sanitizeGenerated("I'm sorry, I can't help with that") == nil)
        #expect(TitleResolver.sanitizeGenerated("API Error: 529 overloaded") == nil)
        #expect(TitleResolver.sanitizeGenerated("Error: not logged in") == nil)
        #expect(TitleResolver.sanitizeGenerated("   ") == nil)
        #expect(TitleResolver.sanitizeGenerated(String(repeating: "word ", count: 12)) == nil)
    }

    @Test func defaultAgentsNames() {
        #expect(TitleResolver.isDefaultAgentsName("my-app-3f", projectName: "my-app"))
        #expect(TitleResolver.isDefaultAgentsName("my-app-3f (2)", projectName: "my-app"))
        #expect(TitleResolver.isDefaultAgentsName("my-app-v2-a1", projectName: "My App_v2"))
        #expect(!TitleResolver.isDefaultAgentsName("my-app-refactor", projectName: "my-app"))
        #expect(!TitleResolver.isDefaultAgentsName("fix-db", projectName: "my-app"))
        #expect(!TitleResolver.isDefaultAgentsName("auth-refactor-graceful-unicorn", projectName: "auth"))
    }
}

@Suite("TranscriptTailParser")
struct TranscriptTailParserTests {
    @Test func realisticTail() throws {
        let signals = TranscriptTailParser.parse(tail: try ClaudeFixtures.data("transcript-tail", "jsonl"), isTruncated: true)
        #expect(signals.customTitle == "a11y login")
        #expect(signals.aiTitle == "Improve login form accessibility")
        #expect(signals.summary == "Old summary from a previous conversation")
        #expect(signals.interrupted)  // sidechain and meta entries do not count
        let expected = try #require(TranscriptTailParser.parseTimestamp("2026-09-29T10:00:09.500Z"))
        #expect(signals.interruptedAt == expected)
    }

    @Test func assistantAfterInterruptClearsIt() {
        let text = """
            {"type":"user","message":{"role":"user","content":"[Request interrupted by user]"},"timestamp":"2026-09-29T10:00:00Z"}
            {"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"ok"}]}}
            """
        let signals = TranscriptTailParser.parse(tail: Data(text.utf8), isTruncated: false)
        #expect(!signals.interrupted)
        #expect(signals.interruptedAt == nil)
    }

    @Test func truncatedFirstLineIsSkippedEvenIfItParses() {
        let text = #"{"type":"custom-title","customTitle":"stale"}"# + "\n" + #"{"type":"ai-title","aiTitle":"fresh"}"#
        let truncated = TranscriptTailParser.parse(tail: Data(text.utf8), isTruncated: true)
        #expect(truncated.customTitle == nil)
        #expect(truncated.aiTitle == "fresh")
        let whole = TranscriptTailParser.parse(tail: Data(text.utf8), isTruncated: false)
        #expect(whole.customTitle == "stale")
    }

    @Test func headParseAndMerging() {
        let head = #"{"type":"ai-title","aiTitle":"From the head"}"# + "\n" + #"{"type":"user","message":{"content":"[Request interr"#
        let headSignals = TranscriptTailParser.parse(head: Data(head.utf8))
        #expect(headSignals.aiTitle == "From the head")
        #expect(!headSignals.interrupted)
        let tail = TranscriptSignals(customTitle: "Tail name", interrupted: true)
        let merged = tail.fillingTitles(from: headSignals)
        #expect(merged.customTitle == "Tail name")
        #expect(merged.aiTitle == "From the head")
        #expect(merged.interrupted)
    }

    @Test func garbageNeverThrows() {
        let inputs: [Data] = [Data(), Data([0xFF, 0xFE, 0x0A, 0x00]), Data("{}\n[]\nnull\n{\"type\":5}".utf8)]
        for input in inputs {
            let signals = TranscriptTailParser.parse(tail: input, isTruncated: false)
            #expect(signals == TranscriptSignals())
        }
    }
}
