import Testing
@testable import HermesNative

@Suite("Render caching")
struct RenderCacheTests {
    @Test("markdown parser cache reuses identical long response parse")
    func markdownParserCacheReusesIdenticalInput() {
        #if DEBUG
        MarkdownParseCache.shared.resetForTesting()
        let markdown = "# Heading\n\n" + String(repeating: "A long paragraph with **markdown** content. ", count: 160)

        let first = MarkdownParseCache.shared.blocks(for: markdown)
        let second = MarkdownParseCache.shared.blocks(for: markdown)

        #expect(first == second)
        #expect(MarkdownParseCache.shared.parseCount == 1)
            #endif
    }

    @Test("long response document cache reuses parsed section model")
    func longResponseDocumentCacheReusesIdenticalInput() {
        #if DEBUG
        LongResponseDocumentCache.shared.resetForTesting()
        let markdown = "# One\n\nBody text.\n\n# Two\n\n" + String(repeating: "More words for a long completed response. ", count: 120)

        let first = LongResponseDocumentCache.shared.document(for: markdown)
        let second = LongResponseDocumentCache.shared.document(for: markdown)

        #expect(first.sections.count == second.sections.count)
        #expect(first.headings.count == second.headings.count)
        #expect(LongResponseDocumentCache.shared.parseCount == 1)
        #endif
    }
}
