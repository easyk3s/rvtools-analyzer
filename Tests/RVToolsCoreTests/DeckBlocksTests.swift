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

    func testIncludedCheckAreasFilterOnlyTheSelectedChecks() {
        let checks = [
            makeCheck("host", area: "ESXi hosts & hardware"),
            makeCheck("network", area: "Networking"),
            makeCheck("license", area: "Licensing"),
            makeCheck("vcenter", area: "vCenter"),
        ]
        let result = SolutionResult(headline: "", sections: [.checks("Readiness checks", checks)])
        let allBlocks = DeckBlocks.from(result, DeckOptions(title: "Report", includeReadyChecks: true, includeAssumptions: false))
        let selectedBlocks = DeckBlocks.from(result, DeckOptions(title: "Report", includeReadyChecks: true, includeAssumptions: false,
                                                                  includedCheckAreas: ["ESXi hosts & hardware", "Licensing", "vCenter"]))

        guard case .table(let allTable) = allBlocks[1],
              case .table(let selectedTable) = selectedBlocks[1] else {
            return XCTFail("Readiness checks should export as tables")
        }
        XCTAssertEqual(allTable.rows.map { $0[2].text }, ["Host", "Network", "License", "Vcenter"])
        XCTAssertEqual(selectedTable.rows.map { $0[2].text }, ["Host", "License", "Vcenter"])
    }

    func testIncludedCheckAreasSupportOtherSolutionCategories() {
        let result = SolutionResult(headline: "", sections: [
            .checks("Migration considerations", [
                makeCheck("pricing", area: "Pricing"),
                makeCheck("networking", area: "Networking"),
            ])
        ])
        let options = DeckOptions(title: "Migration", includeReadyChecks: true, includeAssumptions: false,
                                  includedCheckAreas: ["Pricing"])

        let blocks = DeckBlocks.from(result, options)

        guard case .table(let table) = blocks[1] else {
            return XCTFail("Selected check areas should be supported for any solution")
        }
        XCTAssertEqual(table.rows.map { $0[2].text }, ["Pricing"])
    }

    func testSelectedAreasEachGetTheirTopIssueDetails() {
        let checks = [
            makeCheck("vc-1", area: "vCenter", status: .blocker),
            makeCheck("vc-2", area: "vCenter", status: .warning),
            makeCheck("host-1", area: "ESXi hosts & hardware", status: .warning),
            makeCheck("cluster-1", area: "Clusters", status: .warning),
            makeCheck("network-1", area: "Networking", status: .warning),
            makeCheck("network-2", area: "Networking", status: .warning),
            makeCheck("storage-1", area: "Storage", status: .warning),
            makeCheck("vm-1", area: "Virtual machines", status: .warning),
            makeCheck("license-1", area: "Licensing", status: .warning),
        ]
        let result = SolutionResult(headline: "", sections: [.checks("Readiness checks", checks)])
        let options = DeckOptions(title: "Report", issueDetails: 1, includeAssumptions: false,
                                  includedCheckAreas: Set(checks.map(\.area)))

        let blocks = DeckBlocks.from(result, options)
        let detailAreas = blocks.compactMap { block -> String? in
            if case .issue(let check) = block { return check.area }
            return nil
        }

        XCTAssertEqual(detailAreas, ["vCenter", "ESXi hosts & hardware", "Clusters", "Networking", "Storage", "Virtual machines", "Licensing"])
    }

    func testIssueDetailsRemainGloballyLimitedWhenNoAreaSelectionIsProvided() {
        let result = SolutionResult(headline: "", sections: [.checks("Checks", [
            makeCheck("host", area: "Hosts", status: .warning),
            makeCheck("storage", area: "Storage", status: .warning),
        ])])

        let blocks = DeckBlocks.from(result, DeckOptions(title: "Report", issueDetails: 1, includeAssumptions: false))

        XCTAssertEqual(blocks.filter { if case .issue = $0 { return true }; return false }.count, 1)
    }

    func testNoSelectedCheckAreasOmitTheReadinessChecksSection() {
        let result = SolutionResult(headline: "", sections: [
            .checks("Readiness checks", [makeCheck("network", area: "Networking")])
        ])

        let blocks = DeckBlocks.from(result, DeckOptions(title: "Report", includeAssumptions: false, includedCheckAreas: []))

        XCTAssertEqual(blocks.count, 1)
        guard case .title("Report", _, _) = blocks[0] else {
            return XCTFail("No readiness check areas should produce no checks content")
        }
    }

    private func makeCheck(_ id: String, area: String, status: CheckStatus = .ready) -> SolutionCheck {
        SolutionCheck(id: id, area: area, title: id.capitalized, status: status, summary: status == .ready ? "Passed" : "Needs attention",
                      remediation: "", affected: [])
    }
}
