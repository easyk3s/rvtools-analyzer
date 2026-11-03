import Foundation

public struct CountItem: Identifiable, Hashable, Sendable {
    public var id: String { label }
    public var label: String
    public var count: Int
    /// A second magnitude (capacity, powered-off count, ...), meaning depends on the distribution.
    public var value: Double = 0

    public init(label: String, count: Int, value: Double = 0) {
        self.label = label
        self.count = count
        self.value = value
    }
}

public struct Totals: Sendable {
    public var vcenters = 0, datacenters = 0, clusters = 0, hosts = 0, hostsInMaintenance = 0
    public var vms = 0, vmsOn = 0, vmsOff = 0, vmsSuspended = 0, templates = 0, srmPlaceholders = 0
    public var sockets = 0, cores = 0, threads = 0
    public var physMemMiB = 0.0, cpuMHz = 0.0, cpuUsedMHz = 0.0, memUsedMiB = 0.0
    public var vcpuAll = 0, vcpuOn = 0, vramAllMiB = 0.0, vramOnMiB = 0.0
    public var datastores = 0, dsCapacityMiB = 0.0, dsFreeMiB = 0.0, dsProvisionedMiB = 0.0
    /// False when no datastore in scope has a provisioned figure.
    public var dsProvisionedKnown = true
    public var vmProvisionedMiB = 0.0, vmInUseMiB = 0.0, guestCapacityMiB = 0.0, guestConsumedMiB = 0.0
    public var snapshots = 0, snapshotMiB = 0.0
    public var portGroups = 0, vlans = 0, disks = 0, nics = 0
    public var critical = 0, warning = 0, info = 0

    public var vcpuPerCore: Double { cores > 0 ? Double(vcpuOn) / Double(cores) : 0 }
    public var vramPerPhysical: Double { physMemMiB > 0 ? vramOnMiB / physMemMiB : 0 }
    public var cpuUsagePct: Double { cpuMHz > 0 ? cpuUsedMHz / cpuMHz * 100 : 0 }
    public var memUsagePct: Double { physMemMiB > 0 ? memUsedMiB / physMemMiB * 100 : 0 }
    public var dsUsedMiB: Double { dsCapacityMiB - dsFreeMiB }
    public var dsUsedPct: Double { dsCapacityMiB > 0 ? dsUsedMiB / dsCapacityMiB * 100 : 0 }
    public var findings: Int { critical + warning + info }
}

public struct Distributions: Sendable {
    public var powerState: [CountItem] = []
    public var osFamily: [CountItem] = []
    public var osName: [CountItem] = []
    public var osLifecycle: [CountItem] = []
    public var hwVersion: [CountItem] = []
    public var toolsStatus: [CountItem] = []
    public var firmware: [CountItem] = []
    public var vcpuSize: [CountItem] = []
    public var memorySize: [CountItem] = []
    /// count = powered on, value = powered off
    public var vmsByCluster: [CountItem] = []
    public var creationYear: [CountItem] = []
    public var esxiVersion: [CountItem] = []
    public var cpuModel: [CountItem] = []
    public var hostModel: [CountItem] = []
    /// value = capacity MiB
    public var datastoreType: [CountItem] = []
    /// value = capacity MiB
    public var diskProvisioning: [CountItem] = []
    public var diskController: [CountItem] = []
    public var nicAdapter: [CountItem] = []
    /// value = size MiB
    public var snapshotAge: [CountItem] = []
    public var guestFree: [CountItem] = []
    public var portGroupKind: [CountItem] = []
    public var topNetworks: [CountItem] = []
    public var pnicSpeed: [CountItem] = []
    public var findingsByCategory: [(category: FindingCategory, counts: [Severity: Int])] = []
}

public struct StorageRollup: Sendable {
    public var poweredOffProvisionedMiB = 0.0
    public var poweredOffInUseMiB = 0.0
    public var templateProvisionedMiB = 0.0
    public var snapshotMiB = 0.0
    public var guestFreeMiB = 0.0
    public var thinMiB = 0.0
    public var thickMiB = 0.0
    public var rdmMiB = 0.0
    public var zombieFiles = 0
}

public struct Report: Sendable {
    public var inventory: Inventory
    public var totals: Totals
    public var findings: [Finding]
    public var groups: [FindingGroup]
    public var dist: Distributions
    public var storage: StorageRollup
    public var thresholds: Thresholds
    public var findingsByObject: [String: [Finding]]
    /// Host-local datastores with no VM files. Left out of `inventory` when `thresholds.ignoreUnusedLocalDatastores`.
    public var unusedLocalDatastores: [Datastore] = []
    /// VMC management datastores (duplicate vSAN capacity). Left out when `thresholds.ignoreVMCManagementDatastore`.
    public var vmcManagementDatastores: [Datastore] = []
    /// Findings covered by an acknowledgement: left out of `findings`, `groups`, totals, inspectors and exports.
    public var acknowledgedFindings: [Finding] = []
    public var acknowledgedGroups: [FindingGroup] = []
    public var acknowledgements: [Acknowledgement] = []
    /// Where the key figures in scope came from: reported, derived from another tab, or missing.
    public var dataQuality = DataQuality()
}

public enum Analyzer {
    public static func run(_ source: Inventory, thresholds: Thresholds = Thresholds(), acknowledgements: [Acknowledgement] = []) -> Report {
        let unusedLocal = source.unusedLocalDatastores
        let vmcManagement = source.vmcManagementDatastores
        var hidden = thresholds.ignoreUnusedLocalDatastores ? Set(unusedLocal.map(\.id)) : []
        if thresholds.ignoreVMCManagementDatastore { hidden.formUnion(vmcManagement.map(\.id)) }
        var inv = source.removingDatastores(hidden)
        let (allFindings, catalog) = Rules.evaluate(inv, thresholds)
        let (findings, acknowledged) = acknowledgements.partition(allFindings)

        var byObject: [String: [Finding]] = [:]
        for f in findings where !f.objectID.isEmpty { byObject[f.objectID, default: []].append(f) }
        for i in inv.vms.indices {
            let fs = byObject[inv.vms[i].id] ?? []
            inv.vms[i].issueCount = fs.count
            inv.vms[i].worstSeverity = fs.map(\.severity.rawValue).min() ?? 3
        }
        for i in inv.hosts.indices { inv.hosts[i].issueCount = byObject[inv.hosts[i].id]?.count ?? 0 }
        for i in inv.clusters.indices { inv.clusters[i].issueCount = byObject[inv.clusters[i].id]?.count ?? 0 }
        for i in inv.datastores.indices { inv.datastores[i].issueCount = byObject[inv.datastores[i].id]?.count ?? 0 }

        let groupList = groupFindings(findings, catalog)

        return Report(inventory: inv, totals: totals(inv, findings), findings: findings, groups: groupList,
                      dist: distributions(inv, findings), storage: storage(inv), thresholds: thresholds, findingsByObject: byObject,
                      unusedLocalDatastores: unusedLocal, vmcManagementDatastores: vmcManagement, acknowledgedFindings: acknowledged,
                      acknowledgedGroups: groupFindings(acknowledged, catalog), acknowledgements: acknowledgements,
                      dataQuality: DataQuality.evaluate(inv))
    }

    static func groupFindings(_ findings: [Finding], _ catalog: [String: RuleDef]) -> [FindingGroup] {
        var groups: [String: [Finding]] = [:]
        for f in findings { groups[f.rule, default: []].append(f) }
        return groups.map { rule, fs in
            let def = catalog[rule]
            return FindingGroup(rule: rule, title: def?.title ?? rule, severity: def?.severity ?? .info, category: def?.category ?? .configuration,
                                recommendation: def?.recommendation ?? "", findings: fs.sorted { $0.objectName.localizedStandardCompare($1.objectName) == .orderedAscending })
        }.sorted { ($0.severity.rawValue, -$0.count, $0.title) < ($1.severity.rawValue, -$1.count, $1.title) }
    }

    static func totals(_ inv: Inventory, _ findings: [Finding]) -> Totals {
        var t = Totals()
        t.vcenters = inv.vcenters.filter { $0.kind != .esxiHost }.count
        t.datacenters = inv.datacenterCount
        t.clusters = inv.clusters.filter { !$0.isStandalone }.count
        t.hosts = inv.hosts.count
        t.hostsInMaintenance = inv.hosts.filter(\.maintenance).count
        for h in inv.hosts where !h.isVirtual {
            t.sockets += h.sockets; t.cores += h.cores; t.threads += h.threads
            t.physMemMiB += h.memoryMiB; t.cpuMHz += h.cpuCapacityMHz; t.cpuUsedMHz += h.cpuUsedMHz; t.memUsedMiB += h.memUsedMiB
        }
        for vm in inv.vms {
            if vm.isTemplate { t.templates += 1; continue }
            if vm.isSRMPlaceholder { t.srmPlaceholders += 1; continue }
            t.vms += 1
            switch vm.powerState {
            case .on: t.vmsOn += 1; t.vcpuOn += vm.cpus; t.vramOnMiB += vm.memoryMiB
            case .off: t.vmsOff += 1
            case .suspended: t.vmsSuspended += 1
            }
            t.vcpuAll += vm.cpus
            t.vramAllMiB += vm.memoryMiB
        }
        for vm in inv.vms {
            t.vmProvisionedMiB += vm.provisionedMiB
            t.vmInUseMiB += vm.inUseMiB
            t.guestCapacityMiB += vm.guestCapacityMiB
            t.guestConsumedMiB += vm.guestConsumedMiB
            t.snapshots += vm.snapshots.count
            t.snapshotMiB += vm.snapshotSizeMiB
            t.disks += vm.disks.count
            t.nics += vm.nics.count
        }
        t.datastores = inv.datastores.count
        for d in inv.datastores { t.dsCapacityMiB += d.capacityMiB; t.dsFreeMiB += d.freeMiB; t.dsProvisionedMiB += d.provisionedMiB }
        t.dsProvisionedKnown = inv.datastores.isEmpty || inv.datastores.contains(where: \.provisionedReported)
        t.portGroups = inv.portGroups.filter { !$0.isUplink }.count
        t.vlans = Set(inv.portGroups.flatMap(\.vlans).filter { $0 != "0" && !$0.isEmpty }).count
        for f in findings {
            switch f.severity { case .critical: t.critical += 1; case .warning: t.warning += 1; case .info: t.info += 1 }
        }
        return t
    }

    /// Top-N by count, the remainder folded into "Other".
    static func ranked(_ counts: [String: (Int, Double)], top: Int = 12) -> [CountItem] {
        let sorted = counts.map { CountItem(label: $0.key.isEmpty ? "Unknown" : $0.key, count: $0.value.0, value: $0.value.1) }
            .sorted { ($0.count, $1.label) > ($1.count, $0.label) }
        guard sorted.count > top else { return sorted }
        let rest = sorted[top...]
        return Array(sorted[..<top]) + [CountItem(label: "Other (\(rest.count))", count: rest.reduce(0) { $0 + $1.count }, value: rest.reduce(0) { $0 + $1.value })]
    }

    static func ordered(_ labels: [String], _ counts: [String: (Int, Double)]) -> [CountItem] {
        labels.map { CountItem(label: $0, count: counts[$0]?.0 ?? 0, value: counts[$0]?.1 ?? 0) }
    }

    static func distributions(_ inv: Inventory, _ findings: [Finding]) -> Distributions {
        var d = Distributions()
        let vms = inv.vms.filter(\.isVM)
        func tally<S: Sequence>(_ s: S, _ label: (S.Element) -> String, _ value: (S.Element) -> Double = { _ in 0 }) -> [String: (Int, Double)] {
            var m: [String: (Int, Double)] = [:]
            for x in s { let k = label(x); let v = m[k] ?? (0, 0); m[k] = (v.0 + 1, v.1 + value(x)) }
            return m
        }

        d.powerState = [
            CountItem(label: "Powered on", count: vms.filter { $0.powerState == .on }.count),
            CountItem(label: "Powered off", count: vms.filter { $0.powerState == .off }.count),
            CountItem(label: "Suspended", count: vms.filter { $0.powerState == .suspended }.count),
            CountItem(label: "Templates", count: inv.vms.filter(\.isTemplate).count),
        ]
        d.osFamily = ranked(tally(vms, { $0.os.family.rawValue }, { Double($0.cpus) }), top: 9)
        d.osName = ranked(tally(vms, { $0.os.name }), top: 15)
        let now = Lifecycle.supportReference(exportDate: inv.reportDate), yearAhead = now.addingTimeInterval(365 * 86_400)
        d.osLifecycle = ordered(["Past end of support", "Ends within 12 months", "Supported", "Unknown"], tally(vms) { vm in
            guard let e = vm.os.endOfSupport else { return vm.os.family == .other ? "Unknown" : "Supported" }
            return e <= now ? "Past end of support" : (e <= yearAhead ? "Ends within 12 months" : "Supported")
        })
        d.hwVersion = tally(vms, { $0.hwVersion > 0 ? "vmx-\($0.hwVersion)" : "Unknown" })
            .map { CountItem(label: $0.key, count: $0.value.0) }
            .sorted { (Parse.firstInt($0.label) ?? 0) > (Parse.firstInt($1.label) ?? 0) }
        d.toolsStatus = ranked(tally(vms.filter(\.isRunning), { $0.toolsDisplay }))
        d.firmware = ranked(tally(vms, { vm in
            let fw = vm.firmware.lowercased() == "efi" ? "EFI" : (vm.firmware.isEmpty ? "Unknown" : vm.firmware.uppercased())
            return fw == "EFI" ? (vm.secureBoot ? "EFI + Secure Boot" : "EFI") : fw
        }))
        d.vcpuSize = ordered(["1", "2", "3–4", "5–8", "9–16", "17–32", "> 32"], tally(vms) { vm in
            switch vm.cpus { case ...1: return "1"; case 2: return "2"; case 3...4: return "3–4"; case 5...8: return "5–8"
            case 9...16: return "9–16"; case 17...32: return "17–32"; default: return "> 32" }
        })
        d.memorySize = ordered(["≤ 2 GiB", "2–4 GiB", "4–8 GiB", "8–16 GiB", "16–32 GiB", "32–64 GiB", "64–128 GiB", "> 128 GiB"], tally(vms) { vm in
            let g = vm.memoryMiB / 1024
            switch g { case ...2: return "≤ 2 GiB"; case ...4: return "2–4 GiB"; case ...8: return "4–8 GiB"; case ...16: return "8–16 GiB"
            case ...32: return "16–32 GiB"; case ...64: return "32–64 GiB"; case ...128: return "64–128 GiB"; default: return "> 128 GiB" }
        })
        var byCluster: [String: (Int, Double)] = [:]
        let clusterNames = Dictionary(inv.clusters.map { ($0.id, $0.name) }, uniquingKeysWith: { a, _ in a })
        for vm in vms {
            let name = clusterNames[vm.clusterKey] ?? vm.cluster
            var v = byCluster[name] ?? (0, 0)
            if vm.isRunning { v.0 += 1 } else { v.1 += 1 }
            byCluster[name] = v
        }
        d.vmsByCluster = byCluster.map { CountItem(label: $0.key, count: $0.value.0, value: $0.value.1) }
            .sorted { Double($0.count) + $0.value > Double($1.count) + $1.value }
        let cal = Calendar(identifier: .gregorian)
        d.creationYear = tally(vms.compactMap(\.creationDate), { String(cal.component(.year, from: $0)) })
            .map { CountItem(label: $0.key, count: $0.value.0) }.sorted { $0.label < $1.label }
        d.esxiVersion = ranked(tally(inv.hosts, { $0.esxVersion.isEmpty ? "Unknown" : "ESXi \($0.esxVersion)" + ($0.esxBuild.isEmpty ? "" : " (\($0.esxBuild))") }))
        d.cpuModel = ranked(tally(inv.hosts, { $0.cpuModel.replacingOccurrences(of: "(R)", with: "").replacingOccurrences(of: "(TM)", with: "").replacingOccurrences(of: "  ", with: " ") }))
        d.hostModel = ranked(tally(inv.hosts, { [$0.vendor, $0.model].filter { !$0.isEmpty }.joined(separator: " ") }))
        d.datastoreType = ranked(tally(inv.datastores, { $0.type.isEmpty ? "Unknown" : $0.type }, { $0.capacityMiB }))
        let allDisks = inv.vms.flatMap(\.disks)
        d.diskProvisioning = ranked(tally(allDisks, { $0.provisioning }, { $0.capacityMiB }))
        d.diskController = ranked(tally(allDisks, { $0.controller }))
        d.nicAdapter = ranked(tally(inv.vms.flatMap(\.nics), { $0.adapter }))
        let snaps = inv.vms.flatMap(\.snapshots)
        d.snapshotAge = ordered(["< 1 day", "1–7 days", "7–30 days", "30–90 days", "90–365 days", "> 1 year"], tally(snaps, { s in
            let a = s.ageDays ?? 0
            switch a { case ..<1: return "< 1 day"; case ..<7: return "1–7 days"; case ..<30: return "7–30 days"
            case ..<90: return "30–90 days"; case ..<365: return "90–365 days"; default: return "> 1 year" }
        }, { $0.sizeMiB }))
        d.guestFree = ordered(["< 5%", "5–10%", "10–20%", "20–50%", "≥ 50%"], tally(inv.vms.flatMap(\.partitions).filter { $0.capacityMiB > 0 }) { p in
            switch p.freePct { case ..<5: return "< 5%"; case ..<10: return "5–10%"; case ..<20: return "10–20%"; case ..<50: return "20–50%"; default: return "≥ 50%" }
        })
        d.portGroupKind = ranked(tally(inv.portGroups.filter { !$0.isUplink }, { $0.kind }))
        d.topNetworks = inv.portGroups.filter { $0.vmCount > 0 }.sorted { $0.vmCount > $1.vmCount }.prefix(12)
            .map { CountItem(label: $0.name, count: $0.vmCount, value: Double($0.nicCount)) }
        d.pnicSpeed = tally(inv.pnics, { $0.speedMbps == 0 ? "Link down" : Fmt.rate(mbps: $0.speedMbps) })
            .map { CountItem(label: $0.key, count: $0.value.0) }.sorted { $0.count > $1.count }
        d.findingsByCategory = FindingCategory.allCases.compactMap { cat in
            let fs = findings.filter { $0.category == cat }
            guard !fs.isEmpty else { return nil }
            var m: [Severity: Int] = [:]
            for f in fs { m[f.severity, default: 0] += 1 }
            return (cat, m)
        }.sorted { $0.counts.values.reduce(0, +) > $1.counts.values.reduce(0, +) }
        return d
    }

    static func storage(_ inv: Inventory) -> StorageRollup {
        var s = StorageRollup()
        for vm in inv.vms {
            if vm.isTemplate { s.templateProvisionedMiB += vm.provisionedMiB }
            else if vm.powerState == .off { s.poweredOffProvisionedMiB += vm.provisionedMiB; s.poweredOffInUseMiB += vm.inUseMiB }
            s.snapshotMiB += vm.snapshotSizeMiB
            s.guestFreeMiB += max(0, vm.guestCapacityMiB - vm.guestConsumedMiB)
            for d in vm.disks {
                switch d.provisioning { case "Thin": s.thinMiB += d.capacityMiB; case "RDM": s.rdmMiB += d.capacityMiB; default: s.thickMiB += d.capacityMiB }
            }
        }
        s.zombieFiles = inv.health.filter { $0.type.lowercased() == "zombie" }.count
        return s
    }
}
