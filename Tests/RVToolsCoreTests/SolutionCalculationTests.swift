import XCTest
@testable import RVToolsCore

final class SolutionCalculationTests: XCTestCase {
    func testVCFLicenseMinimumIsAppliedPerCPU() {
        var cluster = Cluster(id: "vc01|cluster-a")
        cluster.name = "Cluster A"
        cluster.vcenter = "vc01"
        cluster.datacenter = "DC1"
        cluster.hostCount = 2
        var belowMinimum = makeHost("esx01", cluster: cluster, sockets: 2, coresPerSocket: 8)
        belowMinimum.cpuModel = "Intel Xeon Gold 6338"
        var atMinimum = makeHost("esx02", cluster: cluster, sockets: 2, coresPerSocket: 16)
        atMinimum.cpuModel = "Intel Xeon Gold 6338"

        var vm = VM(id: "vc01|vm01")
        vm.name = "app01"
        vm.vcenter = "vc01"
        vm.clusterKey = cluster.id
        vm.hostKey = belowMinimum.id

        var inventory = Inventory()
        inventory.tabsPresent = ["vhost"]
        inventory.clusters = [cluster]
        inventory.hosts = [belowMinimum, atMinimum]
        inventory.vms = [vm]

        let result = VCF9Readiness().run(
            vms: [vm],
            inventory: inventory,
            values: ParamValues(values: ["coreMin": .number(16)])
        )
        let licensingCheck = result.sections
            .compactMap { section -> [SolutionCheck]? in
                guard case .checks(_, let checks, _) = section else { return nil }
                return checks
            }
            .flatMap { $0 }
            .first { $0.id == "lic.cores" }
        let coreMetric = result.sections
            .compactMap { section -> SolutionMetric? in
                guard case .metrics(_, let metrics) = section else { return nil }
                return metrics.first { $0.label == "VCF cores" }
            }
            .first

        XCTAssertEqual(licensingCheck?.summary,
                       "64 cores for 4 CPUs on 2 hosts (16-core minimum per CPU); 48 physical, so 16 cores (25%) are over-licensed on 1 hosts with CPUs below the minimum")
        XCTAssertEqual(licensingCheck?.affected.map(\.detail), ["2 × 8 cores, licensed 2 × 16 (+16)"])
        XCTAssertEqual(coreMetric?.value, "64")
        XCTAssertEqual(coreMetric?.detail, "48 physical · 16 over-licensed (16-core min)")
    }

    func testAzureLocalFixedClusterUsesNMinusOneCPUBoundary() throws {
        let packageRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let packURL = packageRoot.appendingPathComponent("examples/solutions/odin-azure-local.rvasolution", isDirectory: true)
        let solution = try SolutionLibrary.loadPack(packURL)
        let values = ParamValues(values: ["sizingMode": .choice(1), "growth": .choice(0)])
        var inventory = Inventory()

        var vm = VM(id: "vm01")
        vm.name = "app01"
        vm.powerState = .on
        vm.powerState = .on
        vm.cpus = 168
        vm.memoryMiB = 1024
        inventory.vms = [vm]

        let atCapacity = solution.run(vms: [vm], inventory: inventory, values: values)
        vm.cpus = 169
        inventory.vms = [vm]
        let aboveCapacity = solution.run(vms: [vm], inventory: inventory, values: values)

        // Two 24-core sockets, less five reserved host cores, one N+1 survivor at 4:1, less 4 ARB vCPU = 168.
        let exactRow = try nodeRow(atCapacity, count: "2")
        XCTAssertEqual(exactRow[4], "100%")
        XCTAssertEqual(exactRow[8], "Yes")
        let overRow = try nodeRow(aboveCapacity, count: "2")
        XCTAssertEqual(overRow[4], "101%")
        XCTAssertEqual(overRow[8], "No")
        XCTAssertEqual(overRow[9], "CPU")
    }

    private func makeHost(_ name: String, cluster: Cluster, sockets: Int, coresPerSocket: Int) -> RVToolsCore.Host {
        var host = RVToolsCore.Host(id: "vc01|\(name)")
        host.name = name
        host.vcenter = cluster.vcenter.isEmpty ? "vc01" : cluster.vcenter
        host.datacenter = "DC1"
        host.cluster = cluster.name
        host.clusterKey = cluster.id
        host.sockets = sockets
        host.coresPerSocket = coresPerSocket
        host.cores = sockets * coresPerSocket
        host.memoryMiB = 131_072
        host.cpuModel = "Intel Xeon Gold 6338"
        host.esxVersion = "8.0.2"
        host.ntpServers = "ntp.example"
        host.ntpdRunning = true
        return host
    }

    private func nodeRow(_ result: SolutionResult, count: String) throws -> [String] {
        let table = try XCTUnwrap(result.sections.compactMap { section -> SolutionTable? in
            guard case .table(let table) = section, table.id == "nodes" else { return nil }
            return table
        }.first)
        return try XCTUnwrap(table.rows.first { $0.first == count })
    }
}
