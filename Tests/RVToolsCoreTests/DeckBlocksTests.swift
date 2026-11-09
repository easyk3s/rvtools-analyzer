import XCTest
@testable import RVToolsCore

final class DeckBlocksTests: XCTestCase {
    func testDefaultOptionsIncludeHeadlineAndEverySection() {
        let result = SolutionResult(headline: "Overview", sections: [
            .notes("Highlights", ["first"]),
            .notes("Risks", ["second"])
        ])

        let blocks = DeckBlocks.from(result, DeckOptions(title: "Report", includeAssumptions: false))

        XCTAssertEqual(blocks.count, 4)
        guard case .title("Report", _, _) = blocks[0],
              case .headline("Overview") = blocks[1],
              case .bullets("Highlights", _) = blocks[2],
              case .bullets("Risks", _) = blocks[3] else {
            return XCTFail("Default options should preserve all existing deck content")
        }
    }

    func testSelectedSectionsAndHeadlineAreIndependent() {
        let result = SolutionResult(headline: "Overview", sections: [
            .notes("Highlights", ["first"]),
            .notes("Risks", ["second"])
        ])
        let options = DeckOptions(title: "Report", includeAssumptions: false, includedSectionIndices: [1], includeHeadline: false)

        let blocks = DeckBlocks.from(result, options)

        XCTAssertEqual(blocks.count, 2)
        guard case .title("Report", _, _) = blocks[0],
              case .bullets("Risks", _) = blocks[1] else {
            return XCTFail("Only the selected section should be included when the headline is excluded")
        }
    }

    func testHeadlineMovesBeforeSelectedSectionsWhenNoMetricSectionIsSelected() {
        let result = SolutionResult(headline: "Overview", sections: [
            .metrics("Summary", [SolutionMetric("Hosts", "2")]),
            .notes("Highlights", ["first"])
        ])
        let options = DeckOptions(title: "Report", includeAssumptions: false, includedSectionIndices: [1])

        let blocks = DeckBlocks.from(result, options)

        XCTAssertEqual(blocks.count, 3)
        guard case .headline("Overview") = blocks[1],
              case .bullets("Highlights", _) = blocks[2] else {
            return XCTFail("The headline should remain included when its metrics section is omitted")
        }
    }
}
