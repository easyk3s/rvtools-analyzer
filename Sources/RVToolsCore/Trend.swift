import Foundation

// Trend mode: several RVTools exports of the *same* environment taken at different times, compared as a
// time series. (Single-snapshot mode, which merges exports of different vCenters, is separate and unchanged.)

public struct TrendSnapshot: Identifiable, Sendable {
    public let id: Int
    public let date: Date
    public let dataset: Dataset
    public let inventory: Inventory
    public var sources: [URL] { dataset.sources }
    public var rvtoolsVersion: String { dataset.rvtoolsVersion }
    public var vcenters: [String] { inventory.vcenters.map(\.server).sorted() }
}

public enum TrendLoader {
    /// Exports of different vCenters taken within this window form one snapshot.
    public static let combineWindow: TimeInterval = 12 * 3600

    /// Expands folders that hold several exports into those exports (a folder of RVTools_tab*.csv stays one export).
    public static func expand(_ urls: [URL]) -> [URL] {
        let fm = FileManager.default
        return urls.flatMap { url -> [URL] in
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue, !ProjectFile.isProject(url) else { return [url] }
            let items = (try? fm.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)) ?? []
            if items.contains(where: { $0.pathExtension.lowercased() == "csv" }) { return [url] }
            let workbooks = items.filter { ["xlsx", "xlsm"].contains($0.pathExtension.lowercased()) }
            let csvFolders = items.filter { item in
                var d: ObjCBool = false
                guard fm.fileExists(atPath: item.path, isDirectory: &d), d.boolValue else { return false }
                return ((try? fm.contentsOfDirectory(atPath: item.path)) ?? []).contains { $0.lowercased().hasSuffix(".csv") }
            }
            let found = (workbooks + csvFolders).sorted { $0.lastPathComponent < $1.lastPathComponent }
            return found.isEmpty ? [url] : found
        }
    }

    /// Loads each export on its own, then groups them into snapshots by export time.
    public static func load(_ urls: [URL]) throws -> [TrendSnapshot] {
        let loaded = try loadEach(expand(urls).map { [$0] }).sorted { $0.0.reportDate < $1.0.reportDate }
        let ids = TrendAnalyzer.serverIdentities(loaded.map { TrendSnapshot(id: 0, date: $0.0.reportDate, dataset: $0.0, inventory: $0.1) })
        var groups: [[(Dataset, Inventory)]] = []
        for item in loaded {
            // Exports of different hosts under one inferred vCenter are still different parts of the environment.
            func parts(_ inv: Inventory) -> Set<String> {
                Set(inv.vcenters.flatMap { $0.kind == .inferred ? $0.sourceHosts : [TrendAnalyzer.canonicalServer($0.server, identities: ids)] })
            }
            let servers = parts(item.1)
            if let group = groups.last, let first = group.first,
               item.0.reportDate.timeIntervalSince(first.0.reportDate) <= combineWindow,
               group.allSatisfy({ parts($0.1).isDisjoint(with: servers) }) {
                groups[groups.count - 1].append(item)
            } else {
                groups.append([item])
            }
        }
        // Combined groups are re-read together, exactly as a single-snapshot session merges several vCenters.
        let merged = try loadEach(groups.filter { $0.count > 1 }.map { $0.flatMap { $0.0.sources } })
        var next = merged.makeIterator()
        let items = groups.compactMap { $0.count == 1 ? $0[0] : next.next() }
        return snapshots(items)
    }

    /// One snapshot per group of files (saved trend projects).
    public static func load(groups: [[URL]]) throws -> [TrendSnapshot] {
        snapshots(try loadEach(groups))
    }

    static func snapshots(_ items: [(Dataset, Inventory)]) -> [TrendSnapshot] {
        items.sorted { $0.0.reportDate < $1.0.reportDate }.enumerated().map {
            TrendSnapshot(id: $0.offset, date: $0.element.0.reportDate, dataset: $0.element.0, inventory: $0.element.1)
        }
    }

    static func loadEach(_ groups: [[URL]]) throws -> [(Dataset, Inventory)] {
        final class Box: @unchecked Sendable {
            var items: [(Dataset, Inventory)?]
            var error: Error?
            let lock = NSLock()
            init(_ n: Int) { items = Array(repeating: nil, count: n) }
        }
        let box = Box(groups.count)
        DispatchQueue.concurrentPerform(iterations: groups.count) { i in
            do {
                let ds = try Dataset.load(groups[i])
                let inv = InventoryBuilder.build(ds)
                box.lock.lock(); box.items[i] = (ds, inv); box.lock.unlock()
            } catch {
                box.lock.lock(); box.error = error; box.lock.unlock()
            }
        }
        if let error = box.error { throw error }
        return box.items.compactMap { $0 }
    }
}

// MARK: - Report types

public enum TrendFormat: Sendable {
    case count, capacityMiB, percent
}

public enum TrendMetric: String, CaseIterable, Sendable {
    case vms = "VMs"
    case vmsOn = "Powered-on VMs"
    case vcpu = "vCPU"
    case vram = "vRAM"
    case provisioned = "VM provisioned storage"
    case data = "VM data in use"
    case snapshotData = "Snapshot storage"
    case dsCapacity = "Datastore capacity"
    case dsUsed = "Datastore used"
    case hosts = "Hosts"
    case cores = "Physical cores"
    case physMem = "Physical memory"
    case hostCPU = "Host CPU usage"
    case hostMem = "Host memory usage"

    public var format: TrendFormat {
        switch self {
        case .vms, .vmsOn, .vcpu, .hosts, .cores: return .count
        case .hostCPU, .hostMem: return .percent
        default: return .capacityMiB
        }
    }
}

public struct TrendPoint: Identifiable, Sendable {
    public var id: Int { snapshot }
    public let snapshot: Int
    public let date: Date
    public let value: Double
    public init(snapshot: Int, date: Date, value: Double) {
        self.snapshot = snapshot
        self.date = date
        self.value = value
    }
}

public struct TrendSeries: Identifiable, Sendable {
    public var id: String { metric.rawValue }
    public let metric: TrendMetric
    public let points: [TrendPoint]
    public var first: Double { points.first?.value ?? 0 }
    public var last: Double { points.last?.value ?? 0 }
}

public struct GrowthStat: Identifiable, Sendable {
    public var id: String { label }
    public let label: String
    public let format: TrendFormat
    public let first: Double
    public let last: Double
    /// Linear-regression slope across all snapshots.
    public let perDay: Double
    /// Compound annualised growth from first to last (nil when not meaningful).
    public let annualPct: Double?
    public var change: Double { last - first }
}

public enum ChangeKind: String, CaseIterable, Identifiable, Sendable {
    case added = "Added"
    case removed = "Removed"
    case renamed = "Renamed"
    case resized = "Resized"
    case storage = "Disks changed"
    case clusterMove = "Moved cluster"
    case hostMove = "Moved host"
    case datastoreMove = "Moved datastore"
    case power = "Power state"
    case upgraded = "Upgraded"
    case network = "Network changed"
    case snapshots = "Snapshots"

    public var id: String { rawValue }
    public var symbol: String {
        switch self {
        case .added: return "plus.circle"
        case .removed: return "minus.circle"
        case .renamed: return "character.cursor.ibeam"
        case .resized: return "arrow.up.left.and.arrow.down.right"
        case .storage: return "internaldrive"
        case .clusterMove: return "arrow.left.arrow.right.square"
        case .hostMove: return "arrow.left.arrow.right"
        case .datastoreMove: return "externaldrive.badge.checkmark"
        case .power: return "power"
        case .upgraded: return "arrow.up.circle"
        case .network: return "network"
        case .snapshots: return "camera.on.rectangle"
        }
    }
}

public struct VMChange: Identifiable, Sendable {
    public let id: Int
    /// Index of the later snapshot in the pair.
    public let snapshot: Int
    public let date: Date
    public let key: String
    /// VM id in the snapshot it's shown from (later one; earlier one for removals).
    public let vmID: String
    public let name: String
    public let cluster: String
    public let kind: ChangeKind
    public let detail: String
    public let magnitude: Double
    public var kindLabel: String { kind.rawValue }
}

public struct InfraChange: Identifiable, Sendable {
    public let id: Int
    public let snapshot: Int
    public let date: Date
    public let kind: ObjectKind
    public let name: String
    public let change: String
    public let detail: String
    public var kindLabel: String { kind.rawValue }
}

public struct IntervalSummary: Identifiable, Sendable {
    public var id: Int { snapshot }
    public let snapshot: Int
    public let from: Date
    public let to: Date
    public let counts: [ChangeKind: Int]
    public let netVMs: Int
    public let netVCPU: Int
    public let netVRAMMiB: Double
    public let dataGrowthMiB: Double
    public var days: Double { to.timeIntervalSince(from) / 86_400 }
}

public struct VMGrowth: Identifiable, Sendable {
    public var id: String { key }
    public let key: String
    public let vmID: String
    public let name: String
    public let cluster: String
    public let firstDataMiB: Double
    public let lastDataMiB: Double
    public let perDayMiB: Double
    public let annualPct: Double?
    public let firstCPU: Int
    public let lastCPU: Int
    public let firstMemMiB: Double
    public let lastMemMiB: Double
    public let changes: Int
    public var deltaMiB: Double { lastDataMiB - firstDataMiB }
    public var annualSort: Double { annualPct ?? -.greatestFiniteMagnitude }
    public var perMonthMiB: Double { perDayMiB * 30.4 }
}

public struct DatastoreTrend: Identifiable, Sendable {
    public var id: String { key }
    public let key: String
    public let datastoreID: String
    public let name: String
    public let capacityFirst: Double
    public let capacityLast: Double
    public let usedFirst: Double
    public let usedLast: Double
    public let perDayMiB: Double
    public let daysToFull: Double?
    public let fullDate: Date?
    public var usedPctLast: Double { capacityLast > 0 ? usedLast / capacityLast * 100 : 0 }
    public var perMonthMiB: Double { perDayMiB * 30.4 }
    public var sortDays: Double { daysToFull ?? .greatestFiniteMagnitude }
}

public struct ClusterTrend: Identifiable, Sendable {
    public var id: String { key }
    public let key: String
    public let name: String
    public let hostsFirst: Int, hostsLast: Int
    public let vmsFirst: Int, vmsLast: Int
    public let vcpuFirst: Int, vcpuLast: Int
    public let memPctFirst: Double, memPctLast: Double
    public let cpuPctFirst: Double, cpuPctLast: Double
    public let dataFirst: Double, dataLast: Double
}

public struct TrendReport: Sendable {
    public let snapshots: [TrendSnapshot]
    public let series: [TrendSeries]
    public let growth: [GrowthStat]
    public let changes: [VMChange]
    public let infra: [InfraChange]
    public let intervals: [IntervalSummary]
    public let vmGrowth: [VMGrowth]
    public let datastores: [DatastoreTrend]
    public let clusters: [ClusterTrend]
    public let warnings: [String]
    /// vCenter address → instance UUID, used to build VM keys (see `TrendAnalyzer.vmKey`).
    public let serverIdentities: [String: String]
    let index: [[String: VM]]

    public var first: TrendSnapshot { snapshots[0] }
    public var last: TrendSnapshot { snapshots[snapshots.count - 1] }
    public var spanDays: Double { last.date.timeIntervalSince(first.date) / 86_400 }

    /// This trend's key for a VM, for `history(_:)` and change lookups.
    public func key(_ vm: VM) -> String { TrendAnalyzer.vmKey(vm, identities: serverIdentities) }

    public func series(_ m: TrendMetric) -> TrendSeries? { series.first { $0.metric == m } }
    public func count(_ kind: ChangeKind) -> Int { changes.filter { $0.kind == kind }.count }

    /// A VM's state in every snapshot (nil where it didn't exist).
    public func history(_ key: String) -> [(snapshot: TrendSnapshot, vm: VM?)] {
        snapshots.map { ($0, index[$0.id][key]) }
    }

    public var netData: GrowthStat? { growth.first { $0.label == TrendAnalyzer.netDataLabel } }
    public var organicData: GrowthStat? { growth.first { $0.label == TrendAnalyzer.organicDataLabel } }
    public var datastoreUsed: GrowthStat? { growth.first { $0.label == TrendAnalyzer.datastoreUsedLabel } }

    /// Net annual growth of VM data in use — suggested replacement for the "annual growth" assumptions.
    public var suggestedGrowthPct: Double? {
        guard spanDays >= 14 else { return nil }
        return netData?.annualPct
    }

    /// Annual growth of data on VMs present throughout (organic growth, excluding new and retired VMs).
    public var organicGrowthPct: Double? {
        guard spanDays >= 14 else { return nil }
        return growth.first { $0.label == TrendAnalyzer.organicDataLabel }?.annualPct
    }

    /// Net daily growth of existing VMs' data as a percentage — a lower bound for the daily change rate
    /// (blocks that are rewritten or deleted and re-written don't show up as growth).
    public var netDailyGrowthPct: Double? {
        guard spanDays >= 1, let g = growth.first(where: { $0.label == TrendAnalyzer.organicDataLabel }), g.last > 0 else { return nil }
        return g.perDay / g.last * 100
    }

    /// The measured rates, as custom solutions receive them (`context.trend`).
    public var rates: TrendRates {
        TrendRates(snapshots: snapshots.count, from: first.date, to: last.date, spanDays: spanDays,
                   annualGrowthPct: suggestedGrowthPct, organicGrowthPct: organicGrowthPct, netDailyGrowthPct: netDailyGrowthPct)
    }
}

/// Rates measured across a trend's snapshots. Each is nil when the trend is too short to measure it.
public struct TrendRates: Hashable, Sendable {
    public let snapshots: Int
    public let from: Date
    public let to: Date
    public let spanDays: Double
    /// Net annual growth of VM data in use (`TrendReport.suggestedGrowthPct`).
    public let annualGrowthPct: Double?
    /// Annual growth of data on VMs present in every snapshot.
    public let organicGrowthPct: Double?
    /// Net daily growth of existing VMs' data: a lower bound for the daily change rate, not a measurement of it.
    public let netDailyGrowthPct: Double?
}

// MARK: - Analyzer

public enum TrendAnalyzer {
    static let netDataLabel = "VM data in use (all VMs)"
    static let organicDataLabel = "VM data in use (VMs in every snapshot)"
    static let datastoreUsedLabel = "Datastore used"

    /// Instance UUID per vCenter address, across every snapshot: RVTools records the address it connected to, which
    /// can be an IP in one export and an FQDN in the next, while the UUID identifies the vCenter itself.
    static func serverIdentities(_ snapshots: [TrendSnapshot]) -> [String: String] {
        var out: [String: String] = [:]
        for s in snapshots {
            for vc in s.inventory.vcenters where !vc.instanceUUID.isEmpty {
                out[canonicalServer(vc.server)] = "uuid:" + vc.instanceUUID.lowercased()
            }
        }
        return out
    }

    /// A vCenter's name for matching across exports: RVTools may record it by short name in one export and by FQDN
    /// in another (e.g. "vc01" vs "vc01.corp.example"). IP addresses are kept whole.
    public static func canonicalServer(_ server: String, identities: [String: String] = [:]) -> String {
        let s = server.lowercased().trimmingCharacters(in: .whitespaces)
        let name: String
        if s.split(separator: ".").allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isNumber) }) || s.contains(":") { name = s }
        else { name = s.split(separator: ".").first.map(String.init) ?? s }
        return identities[name] ?? name
    }

    /// An inventory id ("server|name") with its vCenter part canonicalised, for matching objects across exports.
    static func canonicalID(_ id: String, _ identities: [String: String] = [:]) -> String {
        guard let bar = id.firstIndex(of: "|") else { return canonicalServer(id, identities: identities) }
        return canonicalServer(String(id[..<bar]), identities: identities) + id[bar...]
    }

    /// Stable identity across exports: vCenter + VM UUID, then VM ID (moref), then name.
    public static func vmKey(_ vm: VM, identities: [String: String] = [:]) -> String {
        let server = canonicalServer(vm.vcenter, identities: identities)
        if !vm.uuid.isEmpty { return server + "|u:" + vm.uuid.lowercased() }
        if !vm.vmID.isEmpty { return server + "|m:" + vm.vmID.lowercased() }
        return server + "|n:" + vm.name.lowercased()
    }

    /// Guest data on VMDKs: in-use minus the swap file and snapshot deltas.
    public static func data(_ vm: VM) -> Double { max(0, vm.inUseExcludingSwapMiB - vm.snapshotSizeMiB) }

    static func slope(_ points: [(Double, Double)]) -> Double {
        guard points.count >= 2 else { return 0 }
        let mx = points.map(\.0).reduce(0, +) / Double(points.count)
        let my = points.map(\.1).reduce(0, +) / Double(points.count)
        let den = points.reduce(0) { $0 + ($1.0 - mx) * ($1.0 - mx) }
        return den > 0 ? points.reduce(0) { $0 + ($1.0 - mx) * ($1.1 - my) } / den : 0
    }

    static func annualised(_ first: Double, _ last: Double, days: Double) -> Double? {
        guard first > 0, last > 0, days >= 1 else { return nil }
        return (pow(last / first, 365 / days) - 1) * 100
    }

    static func shortHost(_ s: String) -> String { s.split(separator: ".").first.map(String.init) ?? s }

    static func diff(_ a: VM, _ b: VM, _ identities: [String: String]) -> [(ChangeKind, String, Double)] {
        var out: [(ChangeKind, String, Double)] = []
        if a.name != b.name { out.append((.renamed, "\(a.name) → \(b.name)", 0)) }
        var size: [String] = []
        if a.cpus != b.cpus { size.append("\(a.cpus) → \(b.cpus) vCPU") }
        if abs(a.memoryMiB - b.memoryMiB) >= 1 { size.append("\(Fmt.memory(mib: a.memoryMiB)) → \(Fmt.memory(mib: b.memoryMiB)) memory") }
        if !size.isEmpty { out.append((.resized, size.joined(separator: ", "), Double(b.cpus - a.cpus) + (b.memoryMiB - a.memoryMiB) / 1024)) }
        let capA = a.disks.isEmpty ? a.provisionedMiB : a.diskCapacityMiB, capB = b.disks.isEmpty ? b.provisionedMiB : b.diskCapacityMiB
        if (!a.disks.isEmpty && !b.disks.isEmpty && a.disks.count != b.disks.count) || abs(capA - capB) >= 1024 {
            out.append((.storage, "\(a.disks.count) → \(b.disks.count) disks, \(Fmt.capacity(mib: capA)) → \(Fmt.capacity(mib: capB)) provisioned", capB - capA))
        }
        if canonicalID(a.clusterKey, identities) != canonicalID(b.clusterKey, identities) {
            out.append((.clusterMove, "\(a.cluster.isEmpty ? "standalone" : a.cluster) → \(b.cluster.isEmpty ? "standalone" : b.cluster)", 0))
        } else if canonicalID(a.hostKey, identities) != canonicalID(b.hostKey, identities) {
            out.append((.hostMove, "\(shortHost(a.host)) → \(shortHost(b.host))", 0))
        }
        if !a.datastores.isEmpty, !b.datastores.isEmpty, Set(a.datastores) != Set(b.datastores) {
            out.append((.datastoreMove, "\(a.datastoreList) → \(b.datastoreList)", 0))
        }
        if a.powerState != b.powerState { out.append((.power, "\(a.powerState.rawValue) → \(b.powerState.rawValue)", 0)) }
        var upgrades: [String] = []
        if a.hwVersion > 0, b.hwVersion > 0, a.hwVersion != b.hwVersion { upgrades.append("vmx-\(a.hwVersion) → vmx-\(b.hwVersion)") }
        if !a.toolsVersion.isEmpty, !b.toolsVersion.isEmpty, a.toolsVersion != b.toolsVersion, a.toolsVersion != "0", b.toolsVersion != "0" {
            upgrades.append("Tools \(a.toolsVersion) → \(b.toolsVersion)")
        }
        if a.isRunning, b.isRunning, a.os.family != .other, b.os.family != .other, a.os.name != b.os.name { upgrades.append("\(a.os.name) → \(b.os.name)") }
        if !upgrades.isEmpty { out.append((.upgraded, upgrades.joined(separator: ", "), 0)) }
        if !a.networks.isEmpty, !b.networks.isEmpty, Set(a.networks) != Set(b.networks) {
            out.append((.network, "\(a.networkList) → \(b.networkList)", 0))
        }
        if a.snapshots.count != b.snapshots.count {
            out.append((.snapshots, "\(a.snapshots.count) → \(b.snapshots.count) snapshots", Double(b.snapshots.count - a.snapshots.count)))
        }
        return out
    }

    public static func run(_ snapshots: [TrendSnapshot], ignoreUnusedLocalDatastores: Bool = true,
                           ignoreVMCManagementDatastore: Bool = true) -> TrendReport {
        precondition(!snapshots.isEmpty)
        // The same vCenter can appear under different addresses in different exports; match it by instance UUID.
        let ids = serverIdentities(snapshots)
        func canonicalID(_ id: String) -> String { TrendAnalyzer.canonicalID(id, ids) }
        func canonicalServer(_ server: String) -> String { TrendAnalyzer.canonicalServer(server, identities: ids) }

        // As in the dashboards, host-local datastores that no VM used in any snapshot are left out.
        var unusedLocal = Set<String>(), used = Set<String>()
        for s in snapshots {
            for d in s.inventory.datastores {
                if d.isUnusedLocal { unusedLocal.insert(canonicalID(d.id)) } else { used.insert(canonicalID(d.id)) }
            }
        }
        let hiddenCanonical = ignoreUnusedLocalDatastores ? unusedLocal.subtracting(used) : []
        var hiddenDatastores = Set(snapshots.flatMap { $0.inventory.datastores.map(\.id) }.filter { hiddenCanonical.contains(canonicalID($0)) })
        if ignoreVMCManagementDatastore {
            hiddenDatastores.formUnion(snapshots.flatMap { $0.inventory.vmcManagementDatastores.map(\.id) })
        }
        var warnings: [String] = []
        var nameKeyed = 0

        // Index VMs (templates excluded) per snapshot.
        let index: [[String: VM]] = snapshots.map { snap in
            var map: [String: VM] = [:]
            for vm in snap.inventory.vms where vm.isVM {
                var key = vmKey(vm, identities: ids)
                if key.contains("|n:") { nameKeyed += 1 }
                if map[key] != nil { key += "|" + vm.name.lowercased() }
                map[key] = vm
            }
            return map
        }
        let totals = snapshots.map { Analyzer.totals($0.inventory.removingDatastores(hiddenDatastores), []) }
        let dataTotals = snapshots.map { s in s.inventory.vms.filter(\.isVM).reduce(0) { $0 + data($1) } }
        let days = snapshots.map { $0.date.timeIntervalSince(snapshots[0].date) / 86_400 }

        // Series
        func values(_ m: TrendMetric) -> [Double] {
            totals.indices.map { i in
                let t = totals[i]
                switch m {
                case .vms: return Double(t.vms)
                case .vmsOn: return Double(t.vmsOn)
                case .vcpu: return Double(t.vcpuAll)
                case .vram: return t.vramAllMiB
                case .provisioned: return t.vmProvisionedMiB
                case .data: return dataTotals[i]
                case .snapshotData: return t.snapshotMiB
                case .dsCapacity: return t.dsCapacityMiB
                case .dsUsed: return t.dsUsedMiB
                case .hosts: return Double(t.hosts)
                case .cores: return Double(t.cores)
                case .physMem: return t.physMemMiB
                case .hostCPU: return t.cpuUsagePct
                case .hostMem: return t.memUsagePct
                }
            }
        }
        let series = TrendMetric.allCases.map { m in
            TrendSeries(metric: m, points: values(m).enumerated().map { TrendPoint(snapshot: $0.offset, date: snapshots[$0.offset].date, value: $0.element) })
        }

        // Growth
        let span = days.last ?? 0
        func stat(_ label: String, _ format: TrendFormat, _ ys: [Double]) -> GrowthStat {
            GrowthStat(label: label, format: format, first: ys.first ?? 0, last: ys.last ?? 0,
                       perDay: slope(zip(days, ys).map { ($0, $1) }), annualPct: annualised(ys.first ?? 0, ys.last ?? 0, days: span))
        }
        let firstIdx = index.first ?? [:], lastIdx = index.last ?? [:]
        let common = Set(firstIdx.keys).intersection(lastIdx.keys)
        let organic = index.map { idx in common.reduce(0) { $0 + (idx[$1].map(data) ?? 0) } }
        let growth = [
            stat(netDataLabel, .capacityMiB, dataTotals),
            stat(organicDataLabel, .capacityMiB, organic),
            stat("VM provisioned storage", .capacityMiB, values(.provisioned)),
            stat(datastoreUsedLabel, .capacityMiB, values(.dsUsed)),
            stat("VMs", .count, values(.vms)),
            stat("vCPU", .count, values(.vcpu)),
            stat("vRAM", .capacityMiB, values(.vram)),
        ]

        // VM changes per consecutive pair
        var changes: [VMChange] = []
        var intervals: [IntervalSummary] = []
        let clusterNames: [[String: String]] = snapshots.map { s in Dictionary(s.inventory.clusters.map { ($0.id, $0.name) }, uniquingKeysWith: { a, _ in a }) }
        for i in snapshots.indices.dropFirst() {
            let a = index[i - 1], b = index[i]
            let date = snapshots[i].date
            var counts: [ChangeKind: Int] = [:]
            func add(_ key: String, _ vm: VM, _ kind: ChangeKind, _ detail: String, _ magnitude: Double, cluster: String) {
                changes.append(VMChange(id: changes.count, snapshot: i, date: date, key: key, vmID: vm.id, name: vm.name, cluster: cluster,
                                        kind: kind, detail: detail, magnitude: magnitude))
                counts[kind, default: 0] += 1
            }
            for (key, vm) in b where a[key] == nil {
                let created = vm.creationDate.map { " · created \(Fmt.date($0))" } ?? ""
                add(key, vm, .added, "\(vm.cpus) vCPU, \(Fmt.memory(mib: vm.memoryMiB)), \(Fmt.capacity(mib: vm.provisionedMiB)) provisioned\(created)",
                    vm.provisionedMiB, cluster: clusterNames[i][vm.clusterKey] ?? vm.cluster)
            }
            for (key, vm) in a where b[key] == nil {
                add(key, vm, .removed, "was \(vm.cpus) vCPU, \(Fmt.memory(mib: vm.memoryMiB)), \(vm.powerLabel.lowercased())", -vm.provisionedMiB,
                    cluster: clusterNames[i - 1][vm.clusterKey] ?? vm.cluster)
            }
            for (key, new) in b {
                guard let old = a[key] else { continue }
                for (kind, detail, magnitude) in diff(old, new, ids) { add(key, new, kind, detail, magnitude, cluster: clusterNames[i][new.clusterKey] ?? new.cluster) }
            }
            intervals.append(IntervalSummary(
                snapshot: i, from: snapshots[i - 1].date, to: date, counts: counts,
                netVMs: totals[i].vms - totals[i - 1].vms, netVCPU: totals[i].vcpuAll - totals[i - 1].vcpuAll,
                netVRAMMiB: totals[i].vramAllMiB - totals[i - 1].vramAllMiB, dataGrowthMiB: dataTotals[i] - dataTotals[i - 1]))

            let serversA = Set(snapshots[i - 1].vcenters.map(canonicalServer)), serversB = Set(snapshots[i].vcenters.map(canonicalServer))
            if serversA.isDisjoint(with: serversB) {
                warnings.append("Snapshot \(i + 1) (\(Fmt.date(date))) shares no vCenter with the previous one — are these exports of the same environment?")
            }
            if date.timeIntervalSince(snapshots[i - 1].date) < 3600 {
                warnings.append("Snapshots \(i) and \(i + 1) were exported less than an hour apart. To combine different vCenters into one view, use a normal (single-snapshot) session instead.")
            }
        }
        changes.sort { ($0.date, $0.kind.rawValue, $0.name) < ($1.date, $1.kind.rawValue, $1.name) }
        changes = changes.enumerated().map { i, c in
            VMChange(id: i, snapshot: c.snapshot, date: c.date, key: c.key, vmID: c.vmID, name: c.name, cluster: c.cluster, kind: c.kind, detail: c.detail, magnitude: c.magnitude)
        }

        // Per-VM growth (VMs present in the first and last snapshot)
        let changeCounts = Dictionary(grouping: changes.filter { $0.kind != .hostMove }, by: \.key).mapValues(\.count)
        let lastClusters = clusterNames.last ?? [:]
        let vmGrowth: [VMGrowth] = common.compactMap { key in
            guard let f = firstIdx[key], let l = lastIdx[key] else { return nil }
            let ys = index.indices.compactMap { i in index[i][key].map { (days[i], data($0)) } }
            return VMGrowth(key: key, vmID: l.id, name: l.name, cluster: lastClusters[l.clusterKey] ?? l.cluster, firstDataMiB: data(f), lastDataMiB: data(l),
                            perDayMiB: slope(ys), annualPct: annualised(data(f), data(l), days: span), firstCPU: f.cpus, lastCPU: l.cpus,
                            firstMemMiB: f.memoryMiB, lastMemMiB: l.memoryMiB, changes: changeCounts[key] ?? 0)
        }.sorted { $0.deltaMiB > $1.deltaMiB }

        // Datastores: growth and days-to-full at the observed rate
        let dsIndex = snapshots.map { s in
            Dictionary(s.inventory.datastores.filter { !hiddenDatastores.contains($0.id) }.map { (canonicalID($0.id), $0) }, uniquingKeysWith: { a, _ in a })
        }
        let lastDate = snapshots.last!.date
        let datastores: [DatastoreTrend] = (dsIndex.last ?? [:]).values.compactMap { d in
            let dk = canonicalID(d.id)
            let ys = dsIndex.indices.compactMap { i in dsIndex[i][dk].map { (days[i], $0.capacityMiB - $0.freeMiB) } }
            guard ys.count >= 2, let firstDS = dsIndex.first(where: { $0[dk] != nil })?[dk] else { return nil }
            let perDay = slope(ys)
            let toFull: Double? = perDay > 0.5 ? d.freeMiB / perDay : nil
            return DatastoreTrend(key: dk, datastoreID: d.id, name: d.name, capacityFirst: firstDS.capacityMiB, capacityLast: d.capacityMiB,
                                  usedFirst: firstDS.capacityMiB - firstDS.freeMiB, usedLast: d.capacityMiB - d.freeMiB, perDayMiB: perDay,
                                  daysToFull: toFull, fullDate: toFull.map { lastDate.addingTimeInterval($0 * 86_400) })
        }.sorted { ($0.sortDays, -$0.usedPctLast) < ($1.sortDays, -$1.usedPctLast) }

        // Clusters (first appearance vs last)
        let clusterIdx = snapshots.map { s in Dictionary(s.inventory.clusters.map { (canonicalID($0.id), $0) }, uniquingKeysWith: { a, _ in a }) }
        func clusterData(_ i: Int, _ id: String) -> Double { snapshots[i].inventory.vms.filter { $0.isVM && canonicalID($0.clusterKey) == id }.reduce(0) { $0 + data($1) } }
        let clusters: [ClusterTrend] = (clusterIdx.last ?? [:]).values.compactMap { c in
            let ck = canonicalID(c.id)
            guard let fi = clusterIdx.firstIndex(where: { $0[ck] != nil }), let f = clusterIdx[fi][ck] else { return nil }
            let li = snapshots.count - 1
            return ClusterTrend(key: ck, name: c.name, hostsFirst: f.hostCount, hostsLast: c.hostCount, vmsFirst: f.vmCount, vmsLast: c.vmCount,
                                vcpuFirst: f.vcpuOn, vcpuLast: c.vcpuOn, memPctFirst: f.memUsagePct, memPctLast: c.memUsagePct,
                                cpuPctFirst: f.cpuUsagePct, cpuPctLast: c.cpuUsagePct, dataFirst: clusterData(fi, ck), dataLast: clusterData(li, ck))
        }.sorted { $0.name < $1.name }

        // Infrastructure changes
        var infra: [InfraChange] = []
        func note(_ i: Int, _ kind: ObjectKind, _ name: String, _ change: String, _ detail: String) {
            infra.append(InfraChange(id: infra.count, snapshot: i, date: snapshots[i].date, kind: kind, name: name, change: change, detail: detail))
        }
        for i in snapshots.indices.dropFirst() {
            let ha = Dictionary(snapshots[i - 1].inventory.hosts.map { (canonicalID($0.id), $0) }, uniquingKeysWith: { a, _ in a })
            let hb = Dictionary(snapshots[i].inventory.hosts.map { (canonicalID($0.id), $0) }, uniquingKeysWith: { a, _ in a })
            for (id, h) in hb where ha[id] == nil { note(i, .host, h.name, "Added", "\(h.cluster.isEmpty ? "standalone" : h.cluster) · \(h.cores) cores · \(Fmt.memory(mib: h.memoryMiB)) · ESXi \(h.esxVersion)") }
            for (id, h) in ha where hb[id] == nil { note(i, .host, h.name, "Removed", "was in \(h.cluster.isEmpty ? "no cluster" : h.cluster)") }
            for (id, new) in hb {
                guard let old = ha[id] else { continue }
                if old.esxVersion != new.esxVersion || old.esxBuild != new.esxBuild {
                    note(i, .host, new.name, "ESXi updated", "\(old.esxVersion) (\(old.esxBuild)) → \(new.esxVersion) (\(new.esxBuild))")
                }
                if canonicalID(old.clusterKey) != canonicalID(new.clusterKey) { note(i, .host, new.name, "Moved", "\(old.cluster.isEmpty ? "standalone" : old.cluster) → \(new.cluster.isEmpty ? "standalone" : new.cluster)") }
                if old.cores != new.cores || abs(old.memoryMiB - new.memoryMiB) >= 1024 {
                    note(i, .host, new.name, "Hardware changed", "\(old.cores) → \(new.cores) cores, \(Fmt.memory(mib: old.memoryMiB)) → \(Fmt.memory(mib: new.memoryMiB))")
                }
                if old.maintenance != new.maintenance { note(i, .host, new.name, new.maintenance ? "Entered maintenance" : "Left maintenance", "") }
            }
            let da = dsIndex[i - 1], db = dsIndex[i]
            for (id, d) in db where da[id] == nil { note(i, .datastore, d.name, "Added", "\(d.type) · \(Fmt.capacity(mib: d.capacityMiB))") }
            for (id, d) in da where db[id] == nil { note(i, .datastore, d.name, "Removed", "\(d.type) · \(Fmt.capacity(mib: d.capacityMiB))") }
            for (id, new) in db {
                guard let old = da[id], abs(new.capacityMiB - old.capacityMiB) >= 1024 else { continue }
                note(i, .datastore, new.name, new.capacityMiB > old.capacityMiB ? "Expanded" : "Shrunk", "\(Fmt.capacity(mib: old.capacityMiB)) → \(Fmt.capacity(mib: new.capacityMiB))")
            }
            let ca = clusterIdx[i - 1], cb = clusterIdx[i]
            for (id, c) in cb where ca[id] == nil && !c.isStandalone { note(i, .cluster, c.name, "Added", "\(c.hostCount) hosts") }
            for (id, c) in ca where cb[id] == nil && !c.isStandalone { note(i, .cluster, c.name, "Removed", "") }
            for (id, new) in cb {
                guard let old = ca[id], !new.isStandalone else { continue }
                if old.haEnabled != new.haEnabled || old.drsEnabled != new.drsEnabled {
                    func s(_ b: Bool?) -> String { b.map { $0 ? "on" : "off" } ?? "?" }
                    note(i, .cluster, new.name, "Settings changed", "HA \(s(old.haEnabled)) → \(s(new.haEnabled)), DRS \(s(old.drsEnabled)) → \(s(new.drsEnabled))")
                }
            }
            let va = Dictionary(snapshots[i - 1].inventory.vcenters.map { (canonicalServer($0.id), $0) }, uniquingKeysWith: { a, _ in a })
            for vc in snapshots[i].inventory.vcenters {
                if let old = va[canonicalServer(vc.id)], !old.build.isEmpty, old.build != vc.build { note(i, .vcenter, vc.server, "Updated", "\(old.version) (\(old.build)) → \(vc.version) (\(vc.build))") }
            }
        }
        infra.sort { ($0.date, $0.kind.rawValue, $0.name) < ($1.date, $1.kind.rawValue, $1.name) }

        if span < 14 { warnings.append("The snapshots cover only \(Fmt.num(span, 1)) days — growth rates need weeks or months of history to be meaningful.") }
        if nameKeyed > 0 { warnings.append("\(nameKeyed) VM rows had no UUID or VM ID and were matched by name; renames of those VMs appear as remove + add.") }

        return TrendReport(snapshots: snapshots, series: series, growth: growth, changes: changes, infra: infra, intervals: intervals,
                           vmGrowth: vmGrowth, datastores: datastores, clusters: clusters, warnings: warnings, serverIdentities: ids, index: index)
    }
}

// MARK: - CSV export

public enum TrendExport {
    static func csv(_ header: [String], _ rows: [[String]]) -> String {
        func quote(_ s: String) -> String {
            s.contains(where: { $0 == "," || $0 == "\"" || $0 == "\n" }) ? "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\"" : s
        }
        return ([header] + rows).map { $0.map(quote).joined(separator: ",") }.joined(separator: "\n") + "\n"
    }

    static func gib(_ mib: Double) -> String { Fmt.memoryGiB(mib: mib) }
    static func storage(_ mib: Double) -> String { Fmt.storageGB(mib: mib) }
    static func num(_ v: Double, _ digits: Int = 1) -> String { String(format: "%.\(digits)f", v) }

    /// Every metric per snapshot.
    public static func summary(_ t: TrendReport) -> String {
        let header = ["Metric", "Unit"] + t.snapshots.map { Fmt.dateTime($0.date) }
        let rows = t.series.map { (s: TrendSeries) -> [String] in
            let f = s.metric.format
            let unit = f == .capacityMiB ? Fmt.storageGBLabel : (f == .percent ? "%" : "count")
            let values = s.points.map { (p: TrendPoint) -> String in f == .capacityMiB ? storage(p.value) : num(p.value, f == .count ? 0 : 1) }
            return [s.metric.rawValue, unit] + values
        }
        return csv(header, rows)
    }

    public static func changes(_ t: TrendReport) -> String {
        csv(["Date", "VM", "Cluster", "Change", "Detail"],
            t.changes.map { (c: VMChange) -> [String] in [Fmt.date(c.date), c.name, c.cluster, c.kind.rawValue, c.detail] })
    }

    public static func infrastructure(_ t: TrendReport) -> String {
        csv(["Date", "Type", "Name", "Change", "Detail"],
            t.infra.map { (c: InfraChange) -> [String] in [Fmt.date(c.date), c.kind.rawValue, c.name, c.change, c.detail] })
    }

    public static func vmGrowth(_ t: TrendReport) -> String {
        let u = Fmt.storageGBLabel
        let header = ["VM", "Cluster", "Data first \(u)", "Data latest \(u)", "Change \(u)", "\(u) per month", "Annual growth %",
                      "vCPU first", "vCPU latest", "Memory first GiB", "Memory latest GiB", "Changes"]
        let rows = t.vmGrowth.map { (g: VMGrowth) -> [String] in
            let annual = g.annualPct.map { num($0) } ?? ""
            return [g.name, g.cluster, storage(g.firstDataMiB), storage(g.lastDataMiB), storage(g.deltaMiB), storage(g.perMonthMiB), annual,
                    String(g.firstCPU), String(g.lastCPU), gib(g.firstMemMiB), gib(g.lastMemMiB), String(g.changes)]
        }
        return csv(header, rows)
    }

    public static func datastores(_ t: TrendReport) -> String {
        let u = Fmt.storageGBLabel
        let header = ["Datastore", "Capacity first \(u)", "Capacity latest \(u)", "Used first \(u)", "Used latest \(u)", "Used %", "\(u) per month", "Days to full", "Full by"]
        let rows = t.datastores.map { (d: DatastoreTrend) -> [String] in
            let days = d.daysToFull.map { num($0, 0) } ?? ""
            let full = d.fullDate.map { Fmt.date($0) } ?? ""
            return [d.name, storage(d.capacityFirst), storage(d.capacityLast), storage(d.usedFirst), storage(d.usedLast), num(d.usedPctLast), storage(d.perMonthMiB), days, full]
        }
        return csv(header, rows)
    }
}
