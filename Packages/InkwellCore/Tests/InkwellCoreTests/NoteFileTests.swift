import Foundation
import Testing
@testable import InkwellCore

struct NoteFileTests {
    @Test func plainNoteHasNoFrontMatter() {
        let file = NoteFile(contents: "# Hello\nWorld")
        #expect(file.frontMatter.isEmpty)
        #expect(file.body == "# Hello\nWorld")
        #expect(file.contents == "# Hello\nWorld")
    }

    @Test func frontMatterRoundTripsUnknownKeys() {
        let contents = """
            ---
            title: Something Else
            aliases:
              - one
              - two
            tags: [work, "api design"]
            pinned: true
            ---
            # Body
            text
            """
        let file = NoteFile(contents: contents)
        #expect(file.body == "# Body\ntext")
        #expect(file.frontMatter.list("tags") == ["work", "api design"])
        #expect(file.frontMatter.list("aliases") == ["one", "two"])
        #expect(file.frontMatter.bool("pinned"))
        #expect(file.contents == contents)
    }

    @Test func settingKeysKeepsOtherLines() {
        var file = NoteFile(contents: "---\nlayout: post\n---\nBody")
        file.frontMatter.set("pinned", "true")
        #expect(file.contents == "---\nlayout: post\npinned: true\n---\nBody")
        file.frontMatter.set("pinned", nil)
        file.frontMatter.set("layout", nil)
        #expect(file.contents == "Body")
    }

    @Test func leadingRuleIsNotFrontMatter() {
        let contents = "---\nJust a rule, then text\n---\nMore"
        let file = NoteFile(contents: contents)
        #expect(file.frontMatter.isEmpty)
        #expect(file.body == contents)
    }

    @Test func unclosedFrontMatterIsBody() {
        let file = NoteFile(contents: "---\nkey: value\nno end")
        #expect(file.frontMatter.isEmpty)
    }

    @Test func crlfIsNormalised() {
        let file = NoteFile(contents: "---\r\npinned: true\r\n---\r\nHi\r\nthere")
        #expect(file.frontMatter.bool("pinned"))
        #expect(file.body == "Hi\nthere")
    }
}

struct NoteTextTests {
    @Test func titleSkipsBlankLinesAndHeadingMarkers() {
        #expect(NoteText.title(of: "\n\n## API **design** ##\nmore") == "API design")
        #expect(NoteText.title(of: "Groceries\n- milk") == "Groceries")
        #expect(NoteText.title(of: "   \n") == "")
        #expect(NoteText.title(of: "#hashtag first") == "#hashtag first")
    }

    @Test func previewSkipsTitleFencesAndMarkers() {
        let body = "# Title\n\n- [ ] Buy **milk**\n```swift\nlet x = 1\n```\n> quoted [link](https://x.y)"
        #expect(NoteText.preview(of: body) == "Buy milk let x = 1 quoted link")
    }

    @Test func inlineTags() {
        let body = """
            Plan #work and #Work/api, not #123 or C# or https://x.com/#anchor
            `#notatag` but #tag-two.
            ```
            #include <stdio.h>
            ```
            # Heading
            """
        #expect(NoteText.inlineTags(in: body) == ["work", "Work/api", "tag-two"])
    }

    @Test func fileNames() {
        #expect(NoteText.fileName(for: "API: design/notes") == "API- design-notes")
        #expect(NoteText.fileName(for: "...hidden") == "hidden")
        #expect(NoteText.fileName(for: "   ") == "Untitled")
        #expect(NoteText.fileName(for: String(repeating: "a", count: 200)).count == 80)
    }

    @Test func summaryMergesFrontMatterAndInlineTags() {
        let file = NoteFile(contents: "---\ntags: [Work]\npinned: yes\n---\n# Plan\nSee #work and #ideas")
        let summary = NoteSummary(path: "Work/Plan.md", file: file, created: .now, modified: .now)
        #expect(summary.tags == ["Work", "ideas"])
        #expect(summary.pinned)
        #expect(summary.title == "Plan")
        #expect(summary.folder == "Work")
        #expect(!summary.isTrashed)
    }
}

struct SearchIndexTests {
    @Test func searchRanksTitlesAndMatchesPrefixes() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("idx-\(UUID().uuidString).sqlite")
        let index = try SearchIndex(url: url, rootIdentity: "/notes")
        func note(_ path: String, _ title: String) -> NoteSummary {
            NoteSummary(path: path, title: title, preview: "", tags: [], pinned: false, created: .now, modified: .now)
        }
        await index.apply(upserts: [
            (note("a.md", "Groceries"), "Groceries\nmilk eggs"),
            (note("b.md", "Kubernetes deploys"), "Kubernetes deploys\nkubectl rollout restart"),
            (note("c.md", "Random"), "mentions kubernetes once"),
        ], removals: [])
        #expect(await index.search("kube") == ["b.md", "c.md"])
        #expect(await index.search("rollout kubect") == ["b.md"])
        #expect(await index.search("\"quoted\" (weird)") == [])
        #expect(await index.search("   ") == [])

        await index.apply(upserts: [], removals: ["b.md"])
        #expect(await index.search("kube") == ["c.md"])
        #expect(await index.allSummaries().count == 2)

        // A different notes folder empties the cache.
        let other = try SearchIndex(url: url, rootIdentity: "/elsewhere")
        #expect(await other.allSummaries().isEmpty)
    }
}
