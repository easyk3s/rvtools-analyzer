import Foundation

/// Where a key figure came from. RVTools sometimes writes blanks or zeros into a column (permissions, a vCenter
/// that timed out, a trimmed export) while another tab still carries the same fact, so the builder fills the gap
/// and records the substitute here.
public enum FigureSource: String, Sendable {
    /// The column RVTools normally reports it in.
    case reported
    case vDisk = "Σ vDisk capacity"
    /// In use taken as the full disk capacity: an upper bound, used when no guest usage is available either.
    case vDiskFull = "Σ vDisk capacity (assumed full)"
    case vInfoDiskTotal = "vInfo total disk capacity"
    case vPartition = "Σ vPartition consumed"
    case vPartitionCapacity = "Σ vPartition capacity"
    case vCPU = "vCPU tab"
    case vMemory = "vMemory tab"
    case freePlusUsed = "free + in use"
    /// Blank or zero everywhere: roll-ups built on it are understated.
    case missing = "not in export"

    public var isDerived: Bool { self != .reported && self != .missing }
}

public struct DataGap: Identifiable, Sendable {
    public enum Kind: Int, Sendable, Comparable {
        /// No usable value anywhere; the figure counts as zero.
        case missing = 0
        /// Recovered from another tab; close to, but not exactly, what RVTools would report.
        case derived = 1
        /// Supporting detail absent; headline figures are unaffected.
        case note = 2
        public static func < (a: Kind, b: Kind) -> Bool { a.rawValue < b.rawValue }
    }

    public var id: String { area + "|" + title + "|" + fallback }
    public var kind: Kind
    public var area: String
    public var title: String
    public var affected: Int
    public var total: Int
    /// What was used instead (empty for missing figures and absent tabs).
    public var fallback: String
    public var impact: String
}

/// How much of the export's key figures (VM vCPU, memory, provisioned and in-use storage; host cores and memory;
/// datastore capacity) came straight from the export, were derived from another tab, or are missing.
public struct DataQuality: Sendable {
    public enum Level: Sendable { case complete, derived, incomplete }

    public var reported = 0
    public var derived = 0
    public var missing = 0
    public var gaps: [DataGap] = []
    /// False when every host in scope lacks cores and memory (e.g. no vHost tab): capacity figures show as unknown, not zero.
    public var hostCapacityKnown = true
    public var datastoreCapacityKnown = true
    var tabsPresent: Set<String> = []
    public internal(set) var sourceToolNames: [String] = []

    /// Whether the export has this tab (always true for inventories not built from a dataset).
    public func has(_ tab: String) -> Bool { tabsPresent.isEmpty || tabsPresent.contains(tab.lowercased()) }
    /// "vDisk tab not in export", or "vDisk not collected by Live Optics" when the data was translated from another tool.
    public func absent(_ tab: String) -> String {
        sourceToolNames.isEmpty ? "\(tab) tab not in export" : "\(tab) not collected by " + sourceToolNames.joined(separator: " / ")
    }

    public var total: Int { reported + derived + missing }
    /// Share of key figures that have a value, reported or derived (0–100).
    public var score: Double { total > 0 ? Double(reported + derived) / Double(total) * 100 : 100 }
    public var level: Level {
        if missing > 0 || gaps.contains(where: { $0.kind == .missing }) { return .incomplete }
        return gaps.contains(where: { $0.kind == .derived }) ? .derived : .complete
    }
    /// Gaps worth a banner: anything that changed or is absent from a headline figure.
    public var headline: [DataGap] { gaps.filter { $0.kind != .note } }

    static let coreTabs: [(tab: String, impact: String)] = [
        ("vHost", "Hosts known only by name from vInfo: no cores, memory, ESXi version or hardware, so vCPU:core, N+1 and host checks are unavailable"),
        ("vDatastore", "Datastores known only from VM file paths: no capacity, free space, type or host mounts"),
    ]
    static let detailTabs: [(tab: String, impact: String)] = [
        ("vDisk", "No per-disk sizes, provisioning type or VM ↔ datastore links beyond the .vmx path"),
        ("vPartition", "No guest file-system usage; sizing falls back to datastore in-use"),
        ("vCPU", "No CPU reservations, limits or hot-add settings"),
        ("vMemory", "No memory reservations, limits, ballooning or consumed memory"),
        ("vNetwork", "No per-NIC detail; networks come from vInfo only"),
        ("vCluster", "No HA / DRS settings"),
        ("vSnapshot", "No snapshot data: snapshot counts and ages show none, which may not be true"),
        ("vTools", "No VMware Tools status or version"),
    ]

    public static func evaluate(_ inv: Inventory) -> DataQuality {
        var q = DataQuality()
        q.tabsPresent = inv.tabsPresent
        q.sourceToolNames = inv.sourceTools.map(\.name)
        let realHosts = inv.hosts.filter { !$0.isVirtual }
        q.hostCapacityKnown = realHosts.isEmpty ? inv.tabsPresent.isEmpty || inv.tabsPresent.contains("vhost") : realHosts.contains { $0.coresSource != .missing }
        q.datastoreCapacityKnown = inv.datastores.isEmpty ? inv.tabsPresent.isEmpty || inv.tabsPresent.contains("vdatastore")
            : inv.datastores.contains { $0.capacitySource != .missing }
        func tally(_ s: FigureSource) {
            switch s {
            case .reported: q.reported += 1
            case .missing: q.missing += 1
            default: q.derived += 1
            }
        }
        /// One gap row per (figure, source) combination that isn't `.reported`.
        func collect<T>(_ items: [T], area: String, figure: String, impact: String, source: (T) -> FigureSource) {
            var bySource: [FigureSource: Int] = [:]
            for item in items {
                let s = source(item)
                tally(s)
                if s != .reported { bySource[s, default: 0] += 1 }
            }
            for (s, count) in bySource.sorted(by: { $0.key.rawValue < $1.key.rawValue }) {
                q.gaps.append(DataGap(kind: s == .missing ? .missing : .derived, area: area, title: figure, affected: count, total: items.count,
                                      fallback: s == .missing ? "" : s.rawValue, impact: s == .missing ? impact : derivedNote(s)))
            }
        }

        let vms = inv.vms.filter { !$0.isSRMPlaceholder }
        collect(vms, area: "VMs", figure: "vCPU", impact: "vCPU totals and sizing understated", source: \.cpusSource)
        collect(vms, area: "VMs", figure: "Memory", impact: "vRAM totals and sizing understated", source: \.memorySource)
        collect(vms, area: "VM storage", figure: "Provisioned", impact: "Provisioned storage and storage sizing understated", source: \.provisionedSource)
        collect(vms, area: "VM storage", figure: "In use", impact: "In-use storage, backup and cloud sizing understated", source: \.inUseSource)
        let hosts = inv.hosts.filter { !$0.isVirtual }
        collect(hosts, area: "Hosts", figure: "Cores", impact: "Cluster CPU capacity and vCPU:core ratios wrong", source: \.coresSource)
        collect(hosts, area: "Hosts", figure: "Memory", impact: "Cluster memory capacity and N+1 figures wrong", source: \.memorySource)
        collect(inv.datastores.filter(\.accessible), area: "Datastores", figure: "Capacity", impact: "Datastore capacity and free space understated",
                source: \.capacitySource)

        let tabs = inv.tabsPresent
        if !tabs.isEmpty {
            for (tab, impact) in coreTabs where !tabs.contains(tab.lowercased()) {
                q.gaps.append(DataGap(kind: .missing, area: "Export", title: q.absent(tab), affected: 0, total: 0, fallback: "", impact: impact))
            }
            for (tab, impact) in detailTabs where !tabs.contains(tab.lowercased()) {
                q.gaps.append(DataGap(kind: .note, area: "Export", title: q.absent(tab), affected: 0, total: 0, fallback: "", impact: impact))
            }
        }

        // Guest file systems come from VMware Tools; without them backup and cloud sizing use datastore in-use instead.
        if tabs.isEmpty || tabs.contains("vpartition") {
            let running = vms.filter { $0.isVM && $0.isRunning }
            let without = running.filter(\.partitions.isEmpty)
            if !without.isEmpty {
                q.gaps.append(DataGap(kind: .note, area: "VM storage", title: "Guest file systems", affected: without.count, total: running.count,
                                      fallback: "", impact: "Powered-on VMs with no vPartition rows (VMware Tools not running or not reporting); sizing uses datastore in-use"))
            }
        }

        q.gaps.sort { ($0.kind, -$0.affected, $0.area, $0.title) < ($1.kind, -$1.affected, $1.area, $1.title) }
        // First, whatever the counts: figures above can look complete while a whole export is left out of them.
        q.gaps.insert(contentsOf: inv.sourceIssues.sorted { $0.level == .noVMsRead && $1.level != .noVMsRead }.map {
            DataGap(kind: .missing, area: "Export", title: $0.text, affected: 0, total: 0, fallback: "", impact: $0.impact)
        }, at: 0)
        return q
    }

    static func derivedNote(_ s: FigureSource) -> String {
        switch s {
        case .vDisk: return "Virtual disk capacity only: excludes swap, logs and snapshot deltas, so slightly below what vInfo reports"
        case .vDiskFull: return "No usage figure anywhere, so disks are assumed full: an upper bound for thin-provisioned VMs"
        case .vInfoDiskTotal: return "Virtual disk capacity only: excludes swap, logs and snapshot deltas"
        case .vPartitionCapacity: return "Guest file-system size: a lower bound, missing unpartitioned space, swap and snapshots"
        case .vPartition: return "Space used inside the guest: close for thin disks, below datastore usage for thick disks and snapshots"
        case .vCPU, .vMemory: return "Same configured value, read from the per-VM tab"
        case .freePlusUsed: return "Capacity rebuilt from free and in-use space"
        case .reported, .missing: return ""
        }
    }
}
