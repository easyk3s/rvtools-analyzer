import XCTest
@testable import RVToolsCore

final class ImportCorrelationTests: XCTestCase {
    func testNonstandardCSVColumnsProduceEquivalentCorrelatedInventory() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let canonicalDirectory = root.appendingPathComponent("canonical", isDirectory: true)
        let mappedDirectory = root.appendingPathComponent("mapped", isDirectory: true)
        try FileManager.default.createDirectory(at: canonicalDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: mappedDirectory, withIntermediateDirectories: true)

        let canonicalInfo = """
        VM,Powerstate,CPUs,Memory,Provisioned MiB,In Use MiB,Datacenter,Cluster,Host,VI SDK Server
        app01,Powered on,4,8192,40960,10240,DC1,Compute,esx01,vc01
        """
        let mappedInfo = """
        VMName,Powerstate,CPUs,Memory,Provisioned,InUse,Datacenter,Cluster,Host,SDKServer
        app01,Powered on,4,8192,40960,10240,DC1,Compute,esx01,vc01
        """
        let hosts = """
        Host,Datacenter,Cluster,# Cores,# Memory,VI SDK Server
        esx01,DC1,Compute,16,131072,vc01
        """
        try writeCSV("RVTools_tabvInfo.csv", contents: canonicalInfo, in: canonicalDirectory)
        try writeCSV("RVTools_tabvHost.csv", contents: hosts, in: canonicalDirectory)
        try writeCSV("RVTools_tabvInfo.csv", contents: mappedInfo, in: mappedDirectory)
        try writeCSV("RVTools_tabvHost.csv", contents: hosts, in: mappedDirectory)

        let canonical = InventoryBuilder.build(try Dataset.load([canonicalDirectory]))
        let mappedDataset = try Dataset.load([mappedDirectory])
        let mapped = InventoryBuilder.build(mappedDataset)

        XCTAssertEqual(mappedDataset.table("vInfo")?.col("VM"), 0)
        XCTAssertEqual(mappedDataset.columnPlans.first?.tabs.first?.matches.first?.target, "VM")
        XCTAssertEqual(correlatedVMs(mapped), correlatedVMs(canonical))
        XCTAssertEqual(mapped.hosts.map(\.id), canonical.hosts.map(\.id))
    }

    func testVMFoundOnlyOnOtherTabIsReportedAndRebuilt() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        try writeCSV("RVTools_tabvInfo.csv", contents: """
        VM,Powerstate,CPUs,Memory,VI SDK Server
        present,Powered on,2,4096,vc01
        """, in: directory)
        try writeCSV("RVTools_tabvCPU.csv", contents: """
        VM,Powerstate,CPUs,VI SDK Server
        present,Powered on,2,vc01
        missing,Powered off,4,vc01
        """, in: directory)

        let dataset = try Dataset.load([directory])
        let inventory = InventoryBuilder.build(dataset)

        XCTAssertTrue(dataset.sourceIssues.contains { $0.message.contains("aren't in vInfo") })
        let restored = try XCTUnwrap(inventory.vms.first { $0.name == "missing" })
        XCTAssertTrue(restored.notInVInfo)
        XCTAssertEqual(restored.cpus, 4)
    }

    func testDuplicateRowsFromSeparateExportsAreCountedOnceAndWarned() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let first = root.appendingPathComponent("first", isDirectory: true)
        let second = root.appendingPathComponent("second", isDirectory: true)
        try FileManager.default.createDirectory(at: first, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: second, withIntermediateDirectories: true)
        let info = """
        VM,Powerstate,CPUs,Memory,VI SDK Server
        app01,Powered on,4,8192,vc01
        """
        try writeCSV("RVTools_tabvInfo.csv", contents: info, in: first)
        try writeCSV("RVTools_tabvInfo.csv", contents: info, in: second)

        let dataset = try Dataset.load([first, second])
        let inventory = InventoryBuilder.build(dataset)

        XCTAssertEqual(dataset.table("vInfo")?.rows.count, 1)
        XCTAssertEqual(inventory.vms.map(\.name), ["app01"])
        XCTAssertTrue(dataset.warnings.contains { $0.contains("1 row(s) were already loaded from another file") })
    }

    private func makeTemporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func writeCSV(_ name: String, contents: String, in directory: URL) throws {
        try contents.write(to: directory.appendingPathComponent(name), atomically: true, encoding: .utf8)
    }

    private func correlatedVMs(_ inventory: Inventory) -> [CorrelatedVM] {
        inventory.vms.map {
            CorrelatedVM(id: $0.id, hostKey: $0.hostKey, cpus: $0.cpus, memoryMiB: $0.memoryMiB,
                         provisionedMiB: $0.provisionedMiB, inUseMiB: $0.inUseMiB)
        }
    }

    private struct CorrelatedVM: Equatable {
        let id: String
        let hostKey: String
        let cpus: Int
        let memoryMiB: Double
        let provisionedMiB: Double
        let inUseMiB: Double
    }
}
