@testable import CodexBridgeService
import CodexBridgeShared
import Foundation
import Testing

@Test func specDocumentWrapsFixtureTranscriptAndHtmlContainsTitle() throws {
    let memoID = try MemoID("aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee")
    let transcript = "Far far away from the watch, capture this thought."
    let spec = MemoSpecDocument.localFallback(
        transcript: transcript,
        capturedAt: Date(timeIntervalSince1970: 1_700_000_000),
        memoID: memoID
    )

    #expect(spec.provenance == .localFallback)
    #expect(spec.markdown.contains("# Far far away from the watch, capture this thought"))
    #expect(spec.markdown.contains("## Summary"))
    #expect(spec.markdown.contains("## Requirements"))
    #expect(spec.markdown.contains("## Open questions"))
    #expect(spec.markdown.contains("unverified local wrapper"))
    #expect(spec.markdown.contains(transcript))

    let html = MemoSpecDocument.html(markdown: spec.markdown, title: spec.title)
    #expect(html.contains("<title>Far far away from the watch, capture this thought</title>"))
    #expect(html.contains("<h1>Far far away from the watch, capture this thought</h1>"))
}

@Test func specStoreWritesSerializedMarkdownNextToDeliveryJournal() throws {
    let root = FileManager.default.temporaryDirectory.appending(
        path: "codexwatch-spec-store-\(UUID().uuidString)",
        directoryHint: .isDirectory
    )
    let memoID = try MemoID("bbbbbbbb-cccc-dddd-eeee-ffffffffffff")
    let store = MemoSpecStore(root: root)
    let spec = MemoSpecDocument.localFallback(
        transcript: "Build a quieter Mac inspector.",
        capturedAt: Date(timeIntervalSince1970: 1),
        memoID: memoID
    )
    try store.save(spec, memoID: memoID)

    let loaded = try #require(store.load(memoID: memoID))
    #expect(loaded.provenance == .localFallback)
    #expect(loaded.markdown.contains("Build a quieter Mac inspector."))
    let file = try String(contentsOf: store.url(for: memoID), encoding: .utf8)
    #expect(file.contains("<!-- provenance: local-fallback -->"))
}

@Test func specDocumentRejectsEmptyAppServerMarkdown() {
    #expect(MemoSpecDocument.acceptAppServerMarkdown("   ") == nil)
    #expect(MemoSpecDocument.acceptAppServerMarkdown("not a spec") == nil)
    let accepted = MemoSpecDocument.acceptAppServerMarkdown("""
    ```markdown
    # Quiet capture

    ## Summary
    Keep the raw transcript visible.
    ```
    """)
    #expect(accepted?.provenance == .appServer)
    #expect(accepted?.title == "Quiet capture")
}
