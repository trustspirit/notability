import XCTest
@testable import Notability

final class SummaryMarkdownTests: XCTestCase {

    private func plain(_ text: AttributedString) -> String {
        String(text.characters)
    }

    // The model emits ATX headers even though the prompt asks for bold-only
    // ones, and every meeting already stored on disk carries them. Rendering
    // them literally is the bug this parser exists to fix.
    func test_atx_header_becomes_a_heading() throws {
        let blocks = SummaryMarkdown.blocks(from: "## 논의 사항")

        XCTAssertEqual(blocks.count, 1)
        guard case .heading(let level, let text) = blocks[0] else {
            return XCTFail("Expected a heading, got \(blocks[0])")
        }
        XCTAssertEqual(level, 2)
        XCTAssertEqual(plain(text), "논의 사항")
    }

    func test_bold_only_line_is_still_a_heading() throws {
        // The format the prompt actually asks for has to keep working.
        let blocks = SummaryMarkdown.blocks(from: "**논의 사항**")

        guard case .heading(let level, let text) = blocks.first else {
            return XCTFail("Expected a heading, got \(String(describing: blocks.first))")
        }
        XCTAssertEqual(level, 2)
        XCTAssertEqual(plain(text), "논의 사항")
    }

    func test_nested_bullet_indented_by_two_spaces_reports_depth_two() throws {
        let markdown = """
        - **발언자**
          - 제안서를 보완한다
        """

        let blocks = SummaryMarkdown.blocks(from: markdown)

        XCTAssertEqual(blocks.count, 2)
        guard case .listItem(let outerDepth, _, let outer) = blocks[0],
              case .listItem(let innerDepth, _, let inner) = blocks[1] else {
            return XCTFail("Expected two list items, got \(blocks)")
        }
        XCTAssertEqual(outerDepth, 1)
        XCTAssertEqual(plain(outer), "발언자")
        XCTAssertEqual(innerDepth, 2, "Two-space indentation is what the model emits")
        XCTAssertEqual(plain(inner), "제안서를 보완한다")
    }

    func test_inline_bold_survives_inside_a_bullet() throws {
        let blocks = SummaryMarkdown.blocks(from: "- 두 번째 **강조** 항목")

        guard case .listItem(_, _, let text) = blocks.first else {
            return XCTFail("Expected a list item, got \(String(describing: blocks.first))")
        }
        XCTAssertEqual(plain(text), "두 번째 강조 항목")
        let bolded = text.runs
            .filter { $0.inlinePresentationIntent?.contains(.stronglyEmphasized) == true }
            .map { String(text[$0.range].characters) }
        XCTAssertEqual(bolded, ["강조"])
    }

    func test_ordered_list_carries_its_ordinal() throws {
        let blocks = SummaryMarkdown.blocks(from: "1. 첫째\n2. 둘째")

        let ordinals: [Int?] = blocks.map {
            if case .listItem(_, let ordinal, _) = $0 { return ordinal }
            return nil
        }
        XCTAssertEqual(ordinals, [1, 2])
    }

    func test_paragraph_and_blank_lines() throws {
        let blocks = SummaryMarkdown.blocks(from: "첫 문단.\n\n둘째 문단.")

        XCTAssertEqual(blocks.count, 2)
        for block in blocks {
            guard case .paragraph = block else {
                return XCTFail("Expected paragraphs, got \(blocks)")
            }
        }
    }

    func test_blockquote_and_thematic_break_are_recognised() throws {
        let blocks = SummaryMarkdown.blocks(from: "> 인용문\n\n---\n\n뒤 문단.")

        XCTAssertTrue(blocks.contains { if case .quote = $0 { return true }; return false })
        XCTAssertTrue(blocks.contains { if case .thematicBreak = $0 { return true }; return false })
    }

    func test_code_block_keeps_its_text() throws {
        let blocks = SummaryMarkdown.blocks(from: "```\nlet x = 1\n```")

        guard case .code(let source) = blocks.first else {
            return XCTFail("Expected a code block, got \(String(describing: blocks.first))")
        }
        XCTAssertEqual(source.trimmingCharacters(in: .whitespacesAndNewlines), "let x = 1")
    }

    // A summary that fails to parse must never come back empty — the user would
    // see a blank tab where their notes should be.
    func test_unparseable_input_falls_back_to_paragraphs() throws {
        let blocks = SummaryMarkdown.blocks(from: "그냥 텍스트")

        XCTAssertFalse(blocks.isEmpty)
        XCTAssertEqual(plain(blocks[0].text), "그냥 텍스트")
    }

    func test_empty_input_produces_no_blocks() throws {
        XCTAssertTrue(SummaryMarkdown.blocks(from: "").isEmpty)
        XCTAssertTrue(SummaryMarkdown.blocks(from: "   \n\n  ").isEmpty)
    }
}
