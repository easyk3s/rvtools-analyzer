import Foundation

/// Validates today's vSphere workload clusters and plans a tighter layout on the hosts the customer already has: which
/// clusters to merge, where memory needs adding, which hosts to move so each cluster runs one CPU family, and which hosts
/// a cluster doesn't need. Workload clusters only: the VCF management domain is assumed to run elsewhere already.
///
/// Recommendations are made automatically (each kind can be turned off) and overrides always win: merge groups, clusters
/// kept standalone, memory per host and host moves. Results offer one-click changes that write those overrides.
public struct WorkloadConsolidation: Solution {
    public init() {}
    public var id: String { "consolidation" }
    public var title: String { "Workload Consolidation" }
    public var symbol: String { "rectangle.compress.vertical" }
    public var summary: String { "Validate today's vSphere clusters and plan a tighter layout on the existing hosts: merges, memory upgrades, CPU family alignment and hosts to release. Workload clusters only; management runs elsewhere." }

    /// Memory sizes a host can be upgraded to, in GiB.
    static let ramSizes: [Double] = [256, 384, 512, 768, 1024, 1536, 2048, 3072, 4096, 6144, 8192]
    static func ramLabel(_ gib: Double) -> String {
        let g = gib.rounded()
        if g < 1024 || g.truncatingRemainder(dividingBy: 512) != 0 { return Fmt.int(Int(g)) + " GiB" }
        return String(format: "%g", g / 1024) + " TiB"
    }

    public var parameters: [SolutionParameter] {
        let sizes = WorkloadConsolidation.ramSizes
        return [
            .choice("mode", "Plan", "Plan", [
                "Recommended changes, plus my overrides",
                "Only my overrides (validate today's layout)",
            ], help: "Recommended changes merge clusters, add memory, align CPU families and release hosts, as the options below allow. Your overrides always apply."),
            .choice("approach", "Plan", "Approach", [
                "Balanced",
                "Aggressive — fewest clusters",
                "Conservative — keep like hosts together",
            ], help: "Balanced merges clusters of one CPU family and environment when that saves a host. Aggressive merges every cluster of the same CPU vendor in a datacenter, across families (EVC applies), environments and desktop clusters, whenever it doesn't cost hosts; database, licensing and recovery clusters still stay apart. Conservative only merges clusters whose hosts match (CPU family, cores and memory), and never when VMs' storage would have to move."),
            .choice("goal", "Plan", "Primary goal", [
                "Balanced",
                "Cut licensed cores",
                "Hardware refresh — oldest hosts go first",
            ], help: "Decides which hosts a cluster gives up. Cutting licensed cores releases the hosts with the most licensed cores first, and adds memory wherever that releases hosts (unless memory upgrades are set to Never). Hardware refresh releases the oldest CPU generations first. Balanced releases hosts outside a cluster's main CPU family first, then the oldest and smallest."),
            .toggle("autoMerge", "Plan", "Merge clusters when that saves hosts", true,
                    help: "Only clusters in the same datacenter and vCenter, with the same CPU vendor and family and the same environment (production, test or development). Clusters named for a role stay separate unless you merge them below: SQL, Oracle or DB (database licensing), NoMS, Linux or RHEL (OS licensing), CTX, Citrix, VDI or Horizon (desktops), Recovery, DR or SRM, and management."),
            .choice("autoRAM", "Plan", "Memory upgrades", [
                "Where a cluster is short of memory",
                "Also where more memory releases hosts",
                "Never",
            ], help: "A cluster short of memory whose CPU has room gets the smallest upgrade that fits, rather than more hosts. Every host below the new size is upgraded to it."),
            .toggle("autoAlign", "Plan", "Move hosts to a cluster of their CPU family", true,
                    help: "When a cluster mixes CPU families (Xeon Scalable 2nd and 4th gen, say), its minority hosts move to a cluster of their family in the same datacenter, if the cluster still fits without them. Database, licensing and recovery clusters don't receive hosts this way. Otherwise the results suggest an EVC mode."),
            .toggle("autoRelease", "Plan", "Release hosts a cluster doesn't need", true,
                    help: "Hosts beyond what a cluster needs at the load limit, with failures held in reserve, go to a spare pool: hosts in maintenance mode first, then hosts outside the cluster's main CPU family, then the oldest and smallest."),
            .toggle("rebalance", "Plan", "Use spare hosts before adding new ones", true,
                    help: "A cluster that's short takes released hosts from the same datacenter and CPU vendor first, its own CPU family first."),
            .choice("minIntel", "Retirement", "Oldest Intel generation to keep", ["Keep every Intel host"] + CPURetirement.intel.map(\.name),
                    help: "Hosts of older generations are retired: they leave their clusters and aren't reused. What's left must carry the workloads, with memory upgrades, spare hosts or new hosts as needed. For ESX 9, Broadcom blocks Broadwell and older, allows Skylake-SP only with an override on listed servers, and deprecates Cascade Lake (it installs with a warning); check KB 318697 for the current list."),
            .choice("minAMD", "Retirement", "Oldest AMD generation to keep", ["Keep every AMD host"] + CPURetirement.amd.map(\.name)),
            .number("minCores", "Retirement", "Retire hosts with fewer cores per CPU than", 0, min: 0, max: 64, step: 2, unit: "cores",
                    help: "0 keeps every host. Small hosts cost a licensing minimum per CPU (often 16 cores) whatever their real core count, so 8-core hosts pay for twice what they run."),
            .hostList("retire", "Retirement", "Retire these hosts", help: "Individual hosts to decommission, whatever their CPU."),
            .toggle("suggestRetire", "Retirement", "Suggest retiring the oldest CPU generation", true,
                    help: "Tries retiring each vendor's oldest generation in scope and reports whether the remaining hosts can take over, and at what cost in memory, new hosts and VM moves."),
            .clusterGroups("merge", "Overrides", "Merge these clusters",
                           help: "Each group becomes one cluster, whatever the recommendations say."),
            .clusters("solo", "Overrides", "Keep standalone", multi: true, none: "None",
                      help: "Never merged, and CPU alignment neither moves its hosts out nor moves hosts in. For example, a database cluster licensed by its hosts. Memory upgrades and releasing hosts still apply."),
            .clusters("newest", "Overrides", "Give these clusters the newest hosts", multi: true, none: "None",
                      help: "Swaps a cluster's oldest hosts, one for one, for the newest of the same CPU vendor elsewhere in its datacenter, closest in cores first. For clusters that need the fastest CPUs, such as databases licensed per core. Clusters kept standalone don't give up hosts."),
            .choice("ramTarget", "Overrides", "Bring every host to at least", ["No target"] + sizes.map(WorkloadConsolidation.ramLabel),
                    help: "Memory bought for the hosts that stay: every remaining host below it is upgraded, then hosts the extra memory makes unnecessary are released. Memory per host set for a cluster below wins. Capped at the most memory a host takes."),
            .clusterValues("ram", "Overrides", "Memory per host", values: [0] + sizes, labels: ["No upgrade"] + sizes.map(WorkloadConsolidation.ramLabel),
                           help: "Hosts with less memory are upgraded to this size. No upgrade stops a recommended one. In a merged cluster, the largest size set for any of its clusters applies."),
            .hostMoves("moves", "Overrides", "Move hosts",
                       help: "Move a cluster's hosts of one CPU family, or all of them, to another cluster, release them to the spare pool or retire them. Keep in place stops recommendations from moving or releasing them."),
            .toggle("includeMgmt", "Capacity", "Include management clusters", false,
                    help: "Off by default: VCF management is assumed to run on its own clusters already. Clusters named mgmt or management are left out unless this is on."),
            .choice("basis", "Capacity", "Size workloads from", [
                "Measured host usage (vHost CPU and memory %)",
                "Configured vCPU and memory of the selected powered-on VMs",
            ], help: "Measured usage is each host's CPU and memory use, scaled to the selected VMs' share of it. It stays with the cluster when hosts move."),
            .number("ratio", "Capacity", "vCPU per core", 4, min: 0.5, max: 20, step: 0.5, unit: ": 1",
                    help: "Sizes CPU when sizing from configured vCPU. Either way, planned clusters above it are flagged."),
            .number("memRatio", "Capacity", "Configured memory per physical memory", 100, min: 50, max: 300, step: 5, unit: "%",
                    help: "Only for configured sizes: 100% means no memory overcommit."),
            .number("spare", "Capacity", "Host failures to tolerate", 1, min: 0, max: 3,
                    help: "Hosts held back in every cluster for failures and maintenance; the largest hosts are assumed down."),
            .number("maxLoad", "Capacity", "Max CPU / memory load with those hosts down", 80, min: 50, max: 100, unit: "%"),
            .number("growth", "Capacity", "Growth to plan for", 0, min: 0, max: 200, unit: "%"),
            .number("minHosts", "Capacity", "Minimum hosts per cluster", 2, min: 1, max: 16, help: "vSAN clusters keep at least 3."),
            .number("maxHosts", "Capacity", "Most hosts per cluster", 64, min: 2, max: 96,
                    help: "vSphere 8 allows 96 hosts per cluster and vSAN 64. Merges that would pass this aren't recommended."),
            .choice("maxRAM", "Hardware", "Most memory a host takes", sizes.map(WorkloadConsolidation.ramLabel), selected: sizes.firstIndex(of: 3072) ?? 0,
                    help: "Upgrades stop at this size. It depends on the server: a Cisco UCS B200 M5 takes 3 TiB with 128 GiB DIMMs, an X210c M7 8 TiB. Check the vendor's memory guide, and that every host has free slots or that its DIMMs can be swapped."),
            .number("coreMin", "Licensing", "Licensed cores minimum per CPU", 16, min: 1, max: 64,
                    help: "VMware licenses cores with a per-CPU minimum, so releasing hosts saves licensed cores. Verify current terms."),
            .number("licCost", "Licensing", "Subscription price per core per year", 0, min: 0, max: 5000, step: 5, unit: "USD",
                    help: "The customer's VCF or VVF price per core. 0 shows cores only."),
            .number("licYears", "Licensing", "Term", 3, min: 1, max: 10, unit: "years"),
        ]
    }

    public func defaultSelection(_ inventory: Inventory) -> Set<String> {
        Set(inventory.workloadVMs.map(\.id))
    }

    // MARK: - Roles

    enum Role: String {
        case general, database, licensing, vdi, recovery, management
        var label: String {
            switch self {
            case .general: return ""
            case .database: return "Database"
            case .licensing: return "OS licensing"
            case .vdi: return "Desktops"
            case .recovery: return "Recovery"
            case .management: return "Management"
            }
        }
        var phrase: String {
            switch self {
            case .general: return "a general cluster"
            case .database: return "a database cluster"
            case .licensing: return "an OS licensing cluster"
            case .vdi: return "a desktop cluster"
            case .recovery: return "a recovery cluster"
            case .management: return "a management cluster"
            }
        }
        /// Roles that don't take hosts from CPU alignment.
        var receivesHosts: Bool { ![.database, .licensing, .recovery, .management].contains(self) }
    }

    static func tokens(_ name: String) -> [String] {
        name.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init)
    }

    /// A role guessed from the cluster name.
    static func role(_ name: String) -> Role {
        let t = tokens(name)
        func any(_ words: [String]) -> Bool { t.contains { words.contains($0) } }
        if t.contains(where: { $0.hasPrefix("sql") || $0.hasPrefix("mssql") || $0.contains("oracle") || $0 == "ora" || $0 == "db" || $0 == "database" || $0 == "databases" }) {
            return .database
        }
        if any(["noms", "nonms", "linux", "rhel", "lic", "licensing", "licensed"]) { return .licensing }
        if any(["ctx", "citrix", "vdi", "horizon", "xenapp", "xendesktop", "avd", "euc", "rds", "wvd"]) { return .vdi }
        if any(["recovery", "dr", "srm", "failover", "standby", "bcp"]) { return .recovery }
        if any(["mgmt", "management", "mgt"]) { return .management }
        return .general
    }

    /// "prod" unless the name says test or development.
    static func environment(_ name: String) -> String {
        let t = tokens(name)
        if t.contains(where: { ["test", "tst", "qa", "uat", "stage", "staging", "nonprod", "preprod", "np"].contains($0) }) { return "test" }
        if t.contains(where: { ["dev", "development", "sandbox", "lab"].contains($0) }) { return "dev" }
        return "prod"
    }

    // MARK: - Model

    struct Demand {
        var cores = 0.0, ramGiB = 0.0
        var isEmpty: Bool { cores <= 0 && ramGiB <= 0 }
        static func + (a: Demand, b: Demand) -> Demand { Demand(cores: a.cores + b.cores, ramGiB: a.ramGiB + b.ramGiB) }
        static func * (a: Demand, f: Double) -> Demand { Demand(cores: a.cores * f, ramGiB: a.ramGiB * f) }
    }

    struct WHost {
        var id: String
        var name: String
        /// The cluster the host is in today; "" for a new host.
        var origin: String
        var originName: String
        /// The planned cluster.
        var cluster: String
        var cores: Double
        var threads: Int
        var sockets: Int
        var coresPerSocket: Int
        var reportedGiB: Double
        var ramGiB: Double
        var gen: CPUBaseline
        var evcCurrent: String
        var esx: String
        var maintenance = false
        var isNew = false
        /// Recommendations don't move or release it.
        var pinned = false
        var released = false
        var releasedBy = ""
        /// Decommissioned: out of the plan and never reused.
        var retired = false
        var retiredBy = ""
        var movedBy = ""
        var fromPool = false
        /// Swapped into a cluster that gets the newest hosts: released last there.
        var newestIn = false
        /// Memory before an upgrade, nominal GiB; 0 when not upgraded.
        var upgradedFrom = 0.0
        /// Installed memory as sold (768 GiB rather than the 766.7 the host reports).
        var nominalGiB: Double { max(32, (reportedGiB / 32).rounded(.up) * 32) }

        func licensed(_ coreMin: Double) -> Double {
            sockets > 0 ? Double(sockets) * max(coreMin, Double(coresPerSocket)) : max(coreMin, cores)
        }
    }

    struct PCluster {
        var id: String
        var name: String
        var members: [Cluster]
        var site: String
        var siteName: String
        var demand: Demand
        var vms: [VM]
        var role: Role
        var env: String
        var solo: Bool
        var vsan: Bool
        var forced = false
        var auto = false
        var ramFloor = 0.0
        var ramSetByYou = false
        var ramReason = ""
        var isMerged: Bool { members.count > 1 }
    }

    struct Load {
        var cpu = 0.0, mem = 0.0
        var worst: Double { max(cpu, mem) }
    }

    /// CPU and memory load once the `spare` largest hosts are out; infinity if too few hosts remain for the demand.
    static func load(_ hosts: [WHost], _ d: Demand, spare: Int) -> Load {
        if d.isEmpty { return Load() }
        guard hosts.count > spare else { return Load(cpu: .infinity, mem: .infinity) }
        let cores = hosts.map(\.cores).sorted(by: >).dropFirst(spare).reduce(0, +)
        let ram = hosts.map(\.ramGiB).sorted(by: >).dropFirst(spare).reduce(0, +)
        let cpu = cores > 0 ? d.cores / cores : (d.cores > 0 ? Double.infinity : 0)
        let mem = ram > 0 ? d.ramGiB / ram : (d.ramGiB > 0 ? Double.infinity : 0)
        return Load(cpu: cpu, mem: mem)
    }

    /// The family most hosts have (the newest on a tie).
    static func majority(_ hosts: [WHost]) -> String {
        let counts = Dictionary(grouping: hosts.filter { !$0.isNew }, by: \.gen.family).mapValues(\.count)
        let ranks = Dictionary(hosts.map { ($0.gen.family, $0.gen.rank) }, uniquingKeysWith: max)
        return counts.max { ($0.value, ranks[$0.key] ?? 0) < ($1.value, ranks[$1.key] ?? 0) }?.key ?? CPUFamily.unknown
    }

    static func majorityVendor(_ hosts: [WHost]) -> String {
        let counts = Dictionary(grouping: hosts, by: \.gen.vendor).mapValues(\.count)
        return counts.max { ($0.value, $0.key) < ($1.value, $1.key) }?.key ?? ""
    }

    /// The median host by memory, the model for new hosts.
    static func typical(_ hosts: [WHost]) -> WHost? {
        let sorted = hosts.filter { !$0.isNew }.sorted { ($0.ramGiB, $0.cores, $0.name) < ($1.ramGiB, $1.cores, $1.name) }
        return sorted.isEmpty ? nil : sorted[sorted.count / 2]
    }

    static func withMemory(_ hosts: [WHost], floor: Double) -> [WHost] {
        guard floor > 0 else { return hosts }
        return hosts.map { h in
            var h = h
            if h.nominalGiB < floor {
                h.upgradedFrom = h.upgradedFrom > 0 ? h.upgradedFrom : h.nominalGiB
                h.ramGiB = floor * h.reportedGiB / h.nominalGiB
            }
            return h
        }
    }

    /// "768 GiB ×7, 1 TiB ×2"
    static func memoryMix(_ hosts: [WHost]) -> String {
        let counts = Dictionary(grouping: hosts) { ($0.upgradedFrom > 0 ? ($0.ramGiB * $0.nominalGiB / $0.reportedGiB) : $0.nominalGiB).rounded() }.mapValues(\.count)
        return counts.sorted { $0.key < $1.key }.map { "\(ramLabel($0.key)) ×\($0.value)" }.joined(separator: ", ")
    }

    static func familyMix(_ hosts: [WHost]) -> String {
        let counts = Dictionary(grouping: hosts, by: \.gen.family).mapValues(\.count)
        return counts.sorted { ($1.value, $0.key) < ($0.value, $1.key) }.map { "\(CPUFamily.short($0.key)) ×\($0.value)" }.joined(separator: ", ")
    }

    static func pct(_ x: Double) -> String { x.isFinite ? "\(Int((x * 100).rounded()))%" : "—" }

    /// What it takes to carry out a plan: hosts whose VMs must be evacuated, VMs to power-cycle for EVC, and VM storage
    /// that must move to another datastore.
    struct Impact {
        var hosts = 0
        var vmotions = 0
        var powerCycles = 0
        var storageMiB = 0.0
        var storageUnknown = false
        var runningVMs = 0

        /// 0–100: a live vMotion counts a quarter of a VM power cycle (downtime); each TiB of storage to move adds a point.
        var score: Int {
            guard vmotions + powerCycles > 0 || storageMiB > 0 else { return 0 }
            let vmPart = runningVMs > 0 ? 100 * (0.25 * Double(vmotions) + Double(powerCycles)) / Double(runningVMs) : 0
            return max(1, min(100, Int((vmPart + storageMiB / 1_048_576).rounded())))
        }
        var level: String {
            let s = score
            return s == 0 ? "None" : (s < 10 ? "Low" : (s < 30 ? "Medium" : "High"))
        }
        var text: String {
            var parts = ["\(Fmt.int(vmotions)) VM move\(vmotions == 1 ? "" : "s")", "\(Fmt.int(hosts)) host\(hosts == 1 ? "" : "s") touched"]
            if powerCycles > 0 { parts.append("\(Fmt.int(powerCycles)) power cycle\(powerCycles == 1 ? "" : "s") for EVC") }
            if storageMiB > 0 { parts.append(Fmt.capacity(mib: storageMiB) + " of storage to move") }
            return parts.joined(separator: ", ")
        }
    }

    /// The headline figures of a plan, for comparing what-ifs.
    struct Outcome {
        var hosts = 0, newHosts = 0, shortfalls = 0, retired = 0, upgraded = 0
        var addedGiB = 0.0, licensed = 0.0
        var impact = Impact()
    }

    // MARK: - Run

    public func run(vms: [VM], inventory inv: Inventory, params p: Params) -> SolutionResult {
        evaluate(vms: vms, inventory: inv, params: p, probe: false).result
    }

    /// Plans and reports. A probe is a what-if run for another plan's suggestions: it skips its own suggestions.
    func evaluate(vms: [VM], inventory inv: Inventory, params p: Params, probe: Bool) -> (result: SolutionResult, outcome: Outcome) {
        typealias W = WorkloadConsolidation
        let recommend = p.choice("mode") == 0
        let approach = recommend ? p.choice("approach") : 0
        let goal = p.choice("goal")
        let spare = max(Int(p.num("spare")), 0)
        let maxLoad = max(p.num("maxLoad"), 1) / 100
        let measured = p.choice("basis") == 0
        let ratio = max(p.num("ratio"), 0.1)
        let memRatio = max(p.num("memRatio"), 1) / 100
        let growth = 1 + max(p.num("growth"), 0) / 100
        let minHostsParam = max(Int(p.num("minHosts")), 1)
        let maxHosts = max(Int(p.num("maxHosts")), 2)
        let maxRAM = W.ramSizes[min(max(p.choice("maxRAM"), 0), W.ramSizes.count - 1)]
        let coreMin = max(p.num("coreMin"), 1)
        // Cutting licensed cores trades memory for hosts wherever that releases one.
        let autoRAM = recommend ? (goal == 1 && p.choice("autoRAM") == 0 ? 1 : p.choice("autoRAM")) : 2
        let licCost = max(p.num("licCost"), 0), licYears = max(p.num("licYears"), 1)
        let autoRelease = recommend && p.flag("autoRelease")
        let downText = spare == 0 ? "with no hosts down" : "with \(spare) host\(spare == 1 ? "" : "s") down"

        func resolve(_ ref: String) -> Cluster? {
            inv.clusters.first { $0.id == ref } ?? inv.clusters.first { $0.name.lowercased() == ref.lowercased() && !$0.isStandalone }
        }

        // Scope: the clusters behind the selected VMs, plus idle clusters in the same datacenters.
        let realHosts = inv.hosts.filter { !$0.isVirtual }
        let hostsByCluster = Dictionary(grouping: realHosts, by: \.clusterKey)
        let vmsByCluster = Dictionary(grouping: vms, by: \.clusterKey)
        let allVMsByCluster = Dictionary(grouping: inv.vms.filter(\.isVM), by: \.clusterKey)
        func siteKey(_ c: Cluster) -> String { c.vcenter.lowercased() + "|" + c.datacenter.lowercased() }
        func siteName(_ c: Cluster) -> String {
            [c.datacenter, c.vcenter].filter { !$0.isEmpty }.joined(separator: " · ")
        }
        let selectedSites = Set(inv.clusters.filter { vmsByCluster[$0.id] != nil }.map(siteKey))
        let includeMgmt = p.flag("includeMgmt")
        let mgmtLeftOut = inv.clusters.filter { !$0.isStandalone && vmsByCluster[$0.id] != nil && W.role($0.name) == .management && !includeMgmt }
        let scope = inv.clusters.filter { c in
            !c.isStandalone && !(hostsByCluster[c.id] ?? []).isEmpty && (includeMgmt || W.role(c.name) != .management)
                && (vmsByCluster[c.id] != nil || ((allVMsByCluster[c.id] ?? []).isEmpty && selectedSites.contains(siteKey(c))))
        }.sorted { (siteKey($0), $0.name.lowercased()) < (siteKey($1), $1.name.lowercased()) }
        let scopeIDs = Set(scope.map(\.id))
        let mgmtIDs = Set(mgmtLeftOut.map(\.id))
        let outsideVMs = vms.filter { !scopeIDs.contains($0.clusterKey) && !mgmtIDs.contains($0.clusterKey) }

        guard !scope.isEmpty else {
            return (SolutionResult(headline: "No clusters with hosts in scope", sections: [
                .notes("Nothing to plan", ["Select VMs that run in a cluster on the Select VMs step. Standalone hosts aren't planned."]),
            ]), Outcome())
        }

        // Demand of each cluster today, which stays with the cluster wherever its hosts go.
        var basisFallback: [String] = []
        var demandByCluster: [String: Demand] = [:]
        for c in scope {
            let selected = (vmsByCluster[c.id] ?? []).filter(\.isRunning)
            if selected.isEmpty { demandByCluster[c.id] = Demand(); continue }
            let configured = Demand(cores: Double(selected.reduce(0) { $0 + $1.cpus }) / ratio,
                                    ramGiB: selected.reduce(0) { $0 + $1.memoryMiB } / 1024 / memRatio)
            guard measured else { demandByCluster[c.id] = configured * growth; continue }
            let hs = (hostsByCluster[c.id] ?? []).filter { !$0.inferred }
            let d = Demand(cores: hs.reduce(0) { $0 + Double($1.cores) * $1.cpuUsagePct / 100 },
                           ramGiB: hs.reduce(0) { $0 + $1.memoryMiB / 1024 * $1.memUsagePct / 100 })
            if d.isEmpty && !configured.isEmpty {
                basisFallback.append(c.name)
                demandByCluster[c.id] = configured * growth
                continue
            }
            // Host usage covers every VM on the hosts; keep the selected VMs' share of it.
            let all = (allVMsByCluster[c.id] ?? []).filter(\.isRunning)
            func share(_ value: (VM) -> Double) -> Double? {
                let total = all.reduce(0) { $0 + value($1) }
                return total > 0 ? min(1, selected.reduce(0) { $0 + value($1) } / total) : nil
            }
            let cpuShare = share(\.cpuUsageMHz) ?? share { Double($0.cpus) } ?? 1
            let memShare = share(\.memConsumedMiB) ?? share(\.memoryMiB) ?? 1
            demandByCluster[c.id] = Demand(cores: d.cores * cpuShare, ramGiB: d.ramGiB * memShare) * growth
        }

        // Hosts.
        var hosts: [WHost] = []
        var unknownHosts: [Host] = []
        for c in scope {
            for h in (hostsByCluster[c.id] ?? []).sorted(by: { $0.name < $1.name }) {
                guard !h.inferred, h.cores > 0, h.memoryMiB > 0 else { unknownHosts.append(h); continue }
                hosts.append(WHost(id: h.id, name: h.name, origin: c.id, originName: c.name, cluster: c.id, cores: Double(h.cores),
                                   threads: h.threads, sockets: h.sockets, coresPerSocket: h.coresPerSocket,
                                   reportedGiB: h.memoryMiB / 1024, ramGiB: h.memoryMiB / 1024, gen: CPUBaseline.of(h),
                                   evcCurrent: h.evcCurrent, esx: h.esxShort, maintenance: h.maintenance))
            }
        }
        let todayHosts = hosts
        func vsan(_ ids: [String]) -> Bool {
            inv.datastores.contains { $0.type.lowercased() == "vsan" && $0.clusterKeys.contains(where: ids.contains) }
        }
        func minHosts(_ isVSAN: Bool) -> Int { max(minHostsParam, isVSAN ? 3 : 1) }
        func fits(_ hs: [WHost], _ d: Demand, _ minimum: Int) -> Bool {
            hs.count >= minimum && W.load(hs, d, spare: spare).worst <= maxLoad
        }
        /// Releases hosts one at a time while the rest still fit: maintenance mode first, then hosts outside the main
        /// family, then the oldest and smallest. Pinned and new hosts stay.
        func trim(_ hs: [WHost], _ d: Demand, _ minimum: Int) -> (kept: [WHost], released: [WHost]) {
            guard fits(hs, d, minimum) else { return (hs, []) }
            let major = W.majority(hs)
            func rank(_ h: WHost) -> (Int, Int, Int, Double, Double, String) {
                let m = h.maintenance ? 0 : (h.newestIn ? 2 : 1), onMajor = h.gen.family == major ? 1 : 0
                switch goal {
                case 1: return (m, -Int(h.licensed(coreMin)), onMajor, h.ramGiB, h.cores, h.name)
                case 2: return (m, h.gen.rank, onMajor, h.ramGiB, h.cores, h.name)
                default: return (m, onMajor, h.gen.rank, h.ramGiB, h.cores, h.name)
                }
            }
            let order = hs.filter { !$0.pinned && !$0.isNew }.sorted { rank($0) < rank($1) }
            var kept = hs
            var released: [WHost] = []
            for h in order {
                let trial = kept.filter { $0.id != h.id }
                if fits(trial, d, minimum) { kept = trial; released.append(h) }
            }
            return (kept, released)
        }
        /// New hosts like the typical one needed until the demand fits; nil if no number does.
        func additions(_ hs: [WHost], _ d: Demand, _ minimum: Int, floor: Double = 0, like fallback: WHost? = nil) -> Int? {
            guard let t = W.typical(hs) ?? fallback else { return nil }
            var pool = hs
            var model = t
            model.isNew = true
            model = W.withMemory([model], floor: floor)[0]
            for k in 0...256 {
                if fits(pool, d, minimum) { return k }
                pool.append(model)
            }
            return nil
        }
        /// Hosts the demand needs: after releasing what it doesn't, or with new hosts added.
        func needed(_ hs: [WHost], _ d: Demand, _ minimum: Int, like fallback: WHost? = nil) -> Int {
            if fits(hs, d, minimum) { return trim(hs, d, minimum).kept.count }
            return hs.count + (additions(hs, d, minimum, like: fallback) ?? 999)
        }

        // Overrides already set, for building one-click changes.
        let soloNames = p.names("solo"), mergeNames = p.names("merge"), ramNames = p.names("ram"), moveNames = p.names("moves")
        let soloIDs = Set(soloNames.compactMap(resolve).map(\.id))
        var notes: [String] = []

        // 1. Retirement: below the oldest generation to keep, or chosen by you. Retired hosts are gone for good.
        let minIntel = p.choice("minIntel"), minAMD = p.choice("minAMD")
        let minCores = max(0, Int(p.num("minCores")))
        let retireNames = p.names("retire")
        let retireIDs = Set(retireNames.compactMap { HostSpecs.resolve($0, in: inv)?.id })
        func belowMinimum(_ g: CPUBaseline) -> Bool {
            CPURetirement.isRetired(g, choice: g.vendor == "Intel" ? minIntel : (g.vendor == "AMD" ? minAMD : 0))
        }
        func retire(_ i: Int, by who: String) {
            hosts[i].retired = true
            hosts[i].retiredBy = who
            hosts[i].released = true
            hosts[i].releasedBy = "retired"
            hosts[i].pinned = true
        }
        for i in hosts.indices {
            if retireIDs.contains(hosts[i].id) { retire(i, by: "you") } else if belowMinimum(hosts[i].gen) {
                retire(i, by: "minimum family")
            } else if minCores > 0 && hosts[i].coresPerSocket > 0 && hosts[i].coresPerSocket < minCores {
                retire(i, by: "cores")
            }
        }

        // 2. Your host moves, on today's clusters.
        var invalidMoves = 0
        for e in moveNames {
            let parts = PlanEntry.parts(e)
            guard parts.count == 3, let src = resolve(parts[0]), scopeIDs.contains(src.id) else { invalidMoves += 1; continue }
            let fam = parts[1], dst = parts[2]
            var target: Cluster?
            if dst != HostMove.release && dst != HostMove.keep && dst != HostMove.retire {
                guard let t = resolve(dst), scopeIDs.contains(t.id), t.id != src.id else { invalidMoves += 1; continue }
                target = t
            }
            for i in hosts.indices where hosts[i].origin == src.id && !hosts[i].retired && (fam == HostMove.all || hosts[i].gen.family == fam) {
                hosts[i].pinned = true
                if dst == HostMove.retire {
                    retire(i, by: "you")
                } else if dst == HostMove.release {
                    hosts[i].released = true
                    hosts[i].releasedBy = "you"
                } else if let target {
                    hosts[i].cluster = target.id
                    hosts[i].movedBy = "you"
                }
            }
        }
        if invalidMoves > 0 { notes.append("\(invalidMoves) host move(s) name a cluster that isn't in scope, and were skipped.") }

        // Today's clusters after your moves: merges are judged on these.
        let baseHosts = hosts
        func hostsOf(_ clusterIDs: [String]) -> [WHost] { baseHosts.filter { !$0.released && clusterIDs.contains($0.cluster) } }

        // 2. Merges: yours, then recommended.
        var groups: [(members: [Cluster], forced: Bool)] = []
        var grouped = Set<String>()
        var soloInMerge: [String] = []
        for e in mergeNames {
            var members: [Cluster] = []
            for ref in PlanEntry.parts(e) {
                guard let c = resolve(ref), scopeIDs.contains(c.id), !grouped.contains(c.id), !members.contains(where: { $0.id == c.id }) else { continue }
                if soloIDs.contains(c.id) { soloInMerge.append(c.name); continue }
                members.append(c)
            }
            if members.count > 1 { groups.append((members, true)); grouped.formUnion(members.map(\.id)) }
        }
        func roleOf(_ c: Cluster) -> Role { W.role(c.name) }
        /// A cluster retirement left without hosts: its workloads still need a home.
        func emptied(_ c: Cluster) -> Bool { hostsOf([c.id]).isEmpty && baseHosts.contains { $0.origin == c.id && $0.retired } }
        /// A cluster's hosts, or the ones it had before retirement when none are left.
        func hostsOrOriginal(_ c: Cluster) -> [WHost] {
            let hs = hostsOf([c.id])
            return hs.isEmpty ? baseHosts.filter { $0.origin == c.id } : hs
        }
        func clusterFamily(_ c: Cluster) -> String { W.majority(hostsOrOriginal(c)) }
        func clusterVendor(_ c: Cluster) -> String { W.majorityVendor(hostsOrOriginal(c)) }
        /// What new hosts would look like in a cluster's datacenter: the typical host of the newest family kept there.
        func siteTypical(_ c: Cluster) -> WHost? {
            let site = siteKey(c)
            let kept = baseHosts.filter { h in !h.retired && !h.isNew && scope.contains { $0.id == h.origin && siteKey($0) == site } }
            guard let newest = kept.compactMap({ CPUFamily.index($0.gen.family) }).max() else { return nil }
            return W.typical(kept.filter { CPUFamily.index($0.gen.family) == newest })
        }
        func demandOf(_ cs: [Cluster]) -> Demand { cs.reduce(Demand()) { $0 + (demandByCluster[$1.id] ?? Demand()) } }
        func mergeSaving(_ cs: [Cluster]) -> Int {
            let apart = cs.reduce(0) { n, c in
                let hs = hostsOf([c.id])
                return n + needed(hs, demandOf([c]), minHosts(vsan([c.id])), like: hs.isEmpty ? siteTypical(c) : nil)
            }
            let together = needed(hostsOf(cs.map(\.id)), demandOf(cs), minHosts(vsan(cs.map(\.id))))
            return apart - together
        }
        /// Whether VMs' storage can stay put when these clusters merge: false when they share no datastore or any runs vSAN,
        /// nil when the export doesn't map datastores to hosts.
        func storageStays(_ ids: [String]) -> Bool? {
            if vsan(ids) { return false }
            guard ids.allSatisfy({ id in inv.datastores.contains { $0.clusterKeys.contains(id) } }) else { return nil }
            return inv.datastores.contains { d in !d.isLocal && ids.allSatisfy { d.clusterKeys.contains($0) } }
        }
        /// "48 cores · 768 GiB", the most common host in the cluster.
        func hostShape(_ c: Cluster) -> String {
            let counts = Dictionary(grouping: hostsOf([c.id])) { "\(Int($0.cores))|\(Int($0.nominalGiB))" }.mapValues(\.count)
            return counts.max { ($0.value, $0.key) < ($1.value, $1.key) }?.key ?? ""
        }
        if recommend && p.flag("autoMerge") {
            let eligible = scope.filter {
                !grouped.contains($0.id) && !soloIDs.contains($0.id) && vmsByCluster[$0.id] != nil && (!hostsOf([$0.id]).isEmpty || emptied($0))
                    && (roleOf($0) == .general || (approach == 1 && roleOf($0) == .vdi))
            }
            let buckets = Dictionary(grouping: eligible) { c -> String in
                switch approach {
                case 1: return [siteKey(c), clusterVendor(c)].joined(separator: "#")
                case 2: return [siteKey(c), W.environment(c.name), clusterVendor(c), clusterFamily(c), hostShape(c)].joined(separator: "#")
                default: return [siteKey(c), W.environment(c.name), clusterVendor(c), clusterFamily(c)].joined(separator: "#")
                }
            }
            for key in buckets.keys.sorted() {
                guard !key.contains("#" + CPUFamily.unknown) else { continue }
                var members: [Cluster] = []
                var count = 0
                for c in buckets[key]!.sorted(by: { (hostsOf([$0.id]).count, $0.name) < (hostsOf([$1.id]).count, $1.name) }) {
                    let n = hostsOf([c.id]).count
                    if count + n <= maxHosts { members.append(c); count += n }
                }
                guard members.count > 1, mergeSaving(members) >= (approach == 1 ? 0 : 1) else { continue }
                if approach == 2 && storageStays(members.map(\.id)) == false { continue }
                groups.append((members, false))
                grouped.formUnion(members.map(\.id))
            }
        }

        // The planned clusters.
        var plan: [PCluster] = []
        var planIDOf: [String: String] = [:]
        func makeCluster(_ members: [Cluster], forced: Bool, auto: Bool) -> PCluster {
            let id = members.count == 1 ? members[0].id : "merged|" + members.map(\.id).joined(separator: ",")
            let sites = Set(members.map(siteKey))
            let roles = Set(members.map(roleOf))
            return PCluster(id: id, name: members.map(\.name).joined(separator: " + "), members: members,
                            site: sites.count == 1 ? sites.first! : "mixed",
                            siteName: Array(Set(members.map(siteName))).sorted().joined(separator: ", "),
                            demand: demandOf(members), vms: members.flatMap { vmsByCluster[$0.id] ?? [] },
                            role: roles.count == 1 ? roles.first! : .general, env: W.environment(members[0].name),
                            solo: members.count == 1 && soloIDs.contains(members[0].id), vsan: vsan(members.map(\.id)), forced: forced, auto: auto)
        }
        for g in groups {
            let c = makeCluster(g.members, forced: g.forced, auto: !g.forced)
            plan.append(c)
            for m in g.members { planIDOf[m.id] = c.id }
        }
        for c in scope where planIDOf[c.id] == nil {
            plan.append(makeCluster([c], forced: false, auto: false))
            planIDOf[c.id] = c.id
        }
        plan.sort { ($0.site, $0.name.lowercased()) < ($1.site, $1.name.lowercased()) }
        for i in hosts.indices { hosts[i].cluster = planIDOf[hosts[i].cluster] ?? hosts[i].cluster }
        func members(_ ci: Int) -> [WHost] { hosts.filter { !$0.released && $0.cluster == plan[ci].id } }
        func minHosts(_ ci: Int) -> Int { minHosts(plan[ci].vsan) }

        // 3. CPU alignment.
        struct AlignMove { let from: Int, to: Int, family: String, ids: [String] }
        struct AlignBlock { let cluster: Int, family: String, reason: String, target: Int? }
        var alignMoves: [AlignMove] = []
        var alignBlocks: [AlignBlock] = []
        for ci in plan.indices {
            let hs = members(ci)
            let families = Set(hs.map(\.gen.family)).subtracting([CPUFamily.unknown])
            guard families.count > 1 else { continue }
            let major = W.majority(hs)
            for fam in families.sorted() where fam != major {
                let movers = hs.filter { $0.gen.family == fam && !$0.pinned }
                guard !movers.isEmpty else { continue }
                let sameFamily = plan.indices.filter { $0 != ci && plan[$0].site == plan[ci].site && W.majority(members($0)) == fam }
                let targets = sameFamily.filter { !plan[$0].solo && plan[$0].role.receivesHosts }
                guard recommend && p.flag("autoAlign") else {
                    alignBlocks.append(AlignBlock(cluster: ci, family: fam, reason: "", target: sameFamily.first))
                    continue
                }
                if plan[ci].solo {
                    alignBlocks.append(AlignBlock(cluster: ci, family: fam, reason: "it's kept standalone", target: sameFamily.first))
                    continue
                }
                guard let t = targets.max(by: { W.load(members($0), plan[$0].demand, spare: spare).worst < W.load(members($1), plan[$1].demand, spare: spare).worst }) else {
                    let why = sameFamily.isEmpty ? "no other cluster in its datacenter runs that family"
                        : "the only cluster of that family, \(plan[sameFamily[0]].name), is \(plan[sameFamily[0]].solo ? "kept standalone" : plan[sameFamily[0]].role.phrase)"
                    alignBlocks.append(AlignBlock(cluster: ci, family: fam, reason: why, target: sameFamily.first))
                    continue
                }
                let ids = Set(movers.map(\.id))
                let rest = hs.filter { !ids.contains($0.id) }
                guard fits(rest, plan[ci].demand, minHosts(ci)) else {
                    alignBlocks.append(AlignBlock(cluster: ci, family: fam, reason: "\(plan[ci].name) needs those hosts", target: t))
                    continue
                }
                for i in hosts.indices where ids.contains(hosts[i].id) {
                    hosts[i].cluster = plan[t].id
                    hosts[i].movedBy = "CPU alignment"
                }
                alignMoves.append(AlignMove(from: ci, to: t, family: fam, ids: movers.map(\.id)))
            }
        }

        // 3b. Newest hosts to the clusters you chose: their oldest hosts swap, one for one, with the newest elsewhere in the datacenter.
        struct Swap { let cluster: Int; let inID: String; let outID: String; let donor: Int }
        var swaps: [Swap] = []
        let newestIDs = p.names("newest").compactMap(resolve).map(\.id)
        var priority: [Int] = []
        for id in newestIDs {
            if let ci = plan.firstIndex(where: { pc in pc.members.contains { $0.id == id } }), !priority.contains(ci) { priority.append(ci) }
        }
        let priorityIDs = Set(priority.map { plan[$0].id })
        func older(_ a: WHost, _ b: WHost) -> Bool { (a.gen.rank, a.cores, a.name) < (b.gen.rank, b.cores, b.name) }
        for ci in priority {
            let vendor = W.majorityVendor(members(ci))
            let ownIDs = members(ci).filter { !$0.pinned && !$0.isNew && $0.gen.vendor == vendor }.sorted(by: older).map(\.id)
            for hid in ownIDs {
                guard let hi = hosts.firstIndex(where: { $0.id == hid }) else { continue }
                let mine = hosts[hi]
                var best: Int?
                for di in hosts.indices {
                    let d = hosts[di]
                    guard !d.released, !d.pinned, !d.isNew, d.gen.vendor == vendor, d.gen.rank > mine.gen.rank,
                          !priorityIDs.contains(d.cluster), let dc = plan.firstIndex(where: { $0.id == d.cluster }),
                          plan[dc].site == plan[ci].site, !plan[dc].solo else { continue }
                    if let b = best {
                        let cur = hosts[b]
                        let better = d.gen.rank != cur.gen.rank ? d.gen.rank > cur.gen.rank
                            : (abs(d.cores - mine.cores) != abs(cur.cores - mine.cores) ? abs(d.cores - mine.cores) < abs(cur.cores - mine.cores) : d.ramGiB > cur.ramGiB)
                        if better { best = di }
                    } else {
                        best = di
                    }
                }
                guard let di = best, let dc = plan.firstIndex(where: { $0.id == hosts[di].cluster }) else { break }
                hosts[di].cluster = plan[ci].id
                hosts[di].movedBy = "newest hosts"
                hosts[di].newestIn = true
                hosts[hi].cluster = plan[dc].id
                hosts[hi].movedBy = "newest hosts"
                swaps.append(Swap(cluster: ci, inID: hosts[di].id, outID: hid, donor: dc))
            }
        }

        // 4. Memory.
        var ramByCluster: [String: Double] = [:]
        for e in ramNames {
            let parts = PlanEntry.parts(e)
            if parts.count == 2, let c = resolve(parts[0]), let v = Double(parts[1]) { ramByCluster[c.id] = v }
        }
        /// The smallest upgrade that makes the hosts fit, if CPU isn't what's short.
        func memoryFix(_ hs: [WHost], _ d: Demand, _ minimum: Int) -> Double? {
            let l = W.load(hs, d, spare: spare)
            guard l.mem > maxLoad, l.cpu <= maxLoad, hs.count >= minimum, let low = hs.map(\.nominalGiB).min() else { return nil }
            return W.ramSizes.first { $0 > low && $0 <= maxRAM && fits(W.withMemory(hs, floor: $0), d, minimum) }
        }
        let ramTargetChoice = p.choice("ramTarget")
        let ramTarget = ramTargetChoice > 0 && ramTargetChoice <= W.ramSizes.count ? min(W.ramSizes[ramTargetChoice - 1], maxRAM) : 0
        for ci in plan.indices {
            let set = plan[ci].members.compactMap { ramByCluster[$0.id] }
            if let v = set.max() {
                plan[ci].ramFloor = v
                plan[ci].ramSetByYou = true
            } else {
                if ramTarget > 0 {
                    plan[ci].ramFloor = ramTarget
                    plan[ci].ramReason = "the memory target"
                }
            }
            if set.isEmpty && autoRAM < 2 {
                let hs = W.withMemory(members(ci), floor: ramTarget), d = plan[ci].demand, minimum = minHosts(ci)
                if let s = memoryFix(hs, d, minimum) {
                    plan[ci].ramFloor = s
                    plan[ci].ramReason = "short of memory"
                }
                if autoRAM == 1 && autoRelease, let low = hs.map(\.nominalGiB).min() {
                    let base = W.withMemory(hs, floor: plan[ci].ramFloor)
                    let baseCount = fits(base, d, minimum) ? trim(base, d, minimum).kept.count : Int.max
                    var best: (size: Double, count: Int)?
                    for s in W.ramSizes where s > max(low, plan[ci].ramFloor) && s <= maxRAM {
                        let up = W.withMemory(hs, floor: s)
                        guard fits(up, d, minimum) else { continue }
                        let n = trim(up, d, minimum).kept.count
                        if n < (best?.count ?? baseCount) { best = (s, n) }
                    }
                    if let best {
                        let n = baseCount == Int.max ? hs.count - best.count : baseCount - best.count
                        plan[ci].ramReason = "releases \(n) host\(n == 1 ? "" : "s")"
                        plan[ci].ramFloor = best.size
                    }
                }
            }
            guard plan[ci].ramFloor > 0 else { continue }
            let floor = plan[ci].ramFloor
            for i in hosts.indices where !hosts[i].released && hosts[i].cluster == plan[ci].id {
                hosts[i] = W.withMemory([hosts[i]], floor: floor)[0]
            }
        }

        // 5. Release what each cluster doesn't need; upgrades on released hosts are undone.
        if autoRelease {
            for ci in plan.indices {
                let out = trim(members(ci), plan[ci].demand, minHosts(ci)).released
                let ids = Set(out.map(\.id))
                for i in hosts.indices where ids.contains(hosts[i].id) {
                    hosts[i].released = true
                    hosts[i].releasedBy = "not needed"
                    hosts[i].ramGiB = hosts[i].reportedGiB
                    hosts[i].upgradedFrom = 0
                }
            }
        }

        // 6. Shortfalls: spare hosts first, then new hosts.
        var newHosts: [Int: Int] = [:]
        var shortfalls: [Int] = []
        var siteOfCluster: [String: String] = [:]
        for c in scope { siteOfCluster[c.id] = siteKey(c) }
        /// The model for new hosts in a cluster that has none left: a typical host of the newest family kept in its datacenter.
        func siteModel(_ ci: Int) -> WHost? {
            let kept = hosts.filter { !$0.retired && !$0.isNew && siteOfCluster[$0.origin] == plan[ci].site }
            guard let newest = kept.compactMap({ CPUFamily.index($0.gen.family) }).max() else { return nil }
            return W.typical(kept.filter { CPUFamily.index($0.gen.family) == newest })
        }
        for ci in plan.indices {
            let d = plan[ci].demand, minimum = minHosts(ci)
            // A cluster whose hosts all left and that has nothing to run is gone.
            if members(ci).isEmpty && d.isEmpty { continue }
            guard !fits(members(ci), d, minimum) else { continue }
            guard recommend else { shortfalls.append(ci); continue }
            let fallback = siteModel(ci)
            let major = members(ci).isEmpty ? (fallback?.gen.family ?? "") : W.majority(members(ci))
            let vendor = members(ci).isEmpty ? (fallback?.gen.vendor ?? "") : W.majorityVendor(members(ci))
            if p.flag("rebalance") {
                while !fits(members(ci), d, minimum) {
                    let site = plan[ci].site
                    let pool = hosts.indices.filter { i in
                        hosts[i].released && !hosts[i].retired && !hosts[i].isNew && hosts[i].gen.vendor == vendor && siteOfCluster[hosts[i].origin] == site
                    }
                    func rank(_ i: Int) -> (Int, Double, Double, String) {
                        let h = hosts[i]
                        return (h.gen.family == major ? 0 : 1, -h.ramGiB, -h.cores, h.name)
                    }
                    guard let i = pool.min(by: { rank($0) < rank($1) }) else { break }
                    hosts[i].released = false
                    hosts[i].releasedBy = ""
                    hosts[i].fromPool = true
                    hosts[i].cluster = plan[ci].id
                    hosts[i] = W.withMemory([hosts[i]], floor: plan[ci].ramFloor)[0]
                }
            }
            guard !fits(members(ci), d, minimum) else { continue }
            if let k = additions(members(ci), d, minimum, floor: plan[ci].ramFloor, like: fallback), k > 0, var model = W.typical(members(ci)) ?? fallback {
                model = W.withMemory([model], floor: plan[ci].ramFloor)[0]
                for n in 1...k {
                    var h = model
                    h.id = "new|\(plan[ci].id)|\(n)"
                    h.name = "New host \(n) (like \(model.name))"
                    h.origin = ""
                    h.originName = ""
                    h.cluster = plan[ci].id
                    h.isNew = true
                    h.pinned = false
                    h.maintenance = false
                    h.fromPool = false
                    h.movedBy = ""
                    hosts.append(h)
                }
                newHosts[ci] = k
            } else {
                shortfalls.append(ci)
            }
        }

        // MARK: Results

        let planned = hosts.filter { !$0.released }
        let spareHosts = hosts.filter { $0.released && !$0.retired }
        let retiredHosts = hosts.filter(\.retired)
        let upgraded = planned.filter { $0.upgradedFrom > 0 }
        let addedGiB = upgraded.reduce(0.0) { $0 + ($1.ramGiB * $1.nominalGiB / $1.reportedGiB - $1.upgradedFrom) }
        let newCount = planned.filter(\.isNew).count
        let licToday = todayHosts.reduce(0.0) { $0 + $1.licensed(coreMin) }
        let licPlan = planned.reduce(0.0) { $0 + $1.licensed(coreMin) }
        let nonEmptyPlan = plan.indices.filter { !members($0).isEmpty }

        // Impact: hosts whose VMs must be evacuated (moved, merged in, released, retired, upgraded), VMs to power-cycle where
        // the plan puts CPU generations together that need a lower EVC mode, and storage that must move.
        let vmsByHost = Dictionary(grouping: inv.vms.filter(\.isVM), by: \.hostKey)
        func runningOn(_ hs: [WHost]) -> Int { hs.reduce(0) { $0 + (vmsByHost[$1.id] ?? []).filter(\.isRunning).count } }
        func primaryMember(_ c: PCluster) -> String {
            c.members.max { (hostsOf([$0.id]).count, $1.name) < (hostsOf([$1.id]).count, $0.name) }?.id ?? c.members[0].id
        }
        func vsanShareMiB(_ origin: String) -> Double {
            let used = inv.datastores.filter { $0.type.lowercased() == "vsan" && $0.clusterKeys.contains(origin) }
                .reduce(0.0) { $0 + max(0, $1.capacityMiB - $1.freeMiB) }
            let n = todayHosts.filter { $0.origin == origin }.count
            return n > 0 ? used / Double(n) : 0
        }
        /// The EVC mode hosts of several generations need, and whether the mode they run already covers them.
        func evcNeeded(_ hs: [WHost]) -> (base: CPUBaseline, covered: Bool)? {
            let real = hs.filter { !$0.isNew }
            let vendors = Set(real.map(\.gen.vendor)).subtracting([""])
            let gens = Set(real.map(\.gen.evc)).subtracting([""])
            guard vendors.count == 1, gens.count > 1, let base = real.filter({ !$0.gen.evc.isEmpty }).min(by: { $0.gen.rank < $1.gen.rank })?.gen else { return nil }
            let current = Set(real.map { $0.evcCurrent.lowercased() })
            let ranks = current.compactMap { CPUBaseline.fromEVC($0)?.rank }
            let covered = !current.contains("") && !current.contains("disabled") && ranks.count == current.count && (ranks.max() ?? 99) <= base.rank
            return (base, covered)
        }
        func touched(_ h: WHost) -> Bool {
            guard !h.isNew, !h.origin.isEmpty else { return false }
            if h.released || h.upgradedFrom > 0 || h.fromPool || planIDOf[h.origin] != h.cluster { return true }
            guard let c = plan.first(where: { $0.id == h.cluster }), c.isMerged else { return false }
            return h.origin != primaryMember(c)
        }
        var impact = Impact(runningVMs: vms.filter(\.isRunning).count)
        let touchedHosts = hosts.filter(touched)
        impact.hosts = touchedHosts.count
        impact.vmotions = runningOn(touchedHosts)
        for h in touchedHosts where h.released && vsan([h.origin]) { impact.storageMiB += vsanShareMiB(h.origin) }
        /// VM storage that has to change datastore for a merge.
        func mergeStorage(_ c: PCluster) -> (mib: Double, unknown: Bool) {
            let main = primaryMember(c)
            var mib = 0.0, unknown = false
            for m in c.members where m.id != main {
                switch storageStays([main, m.id]) {
                case false?: mib += (allVMsByCluster[m.id] ?? []).reduce(0) { $0 + $1.inUseMiB }
                case nil: unknown = true
                default: break
                }
            }
            return (mib, unknown)
        }
        for c in plan where c.isMerged {
            let m = mergeStorage(c)
            impact.storageMiB += m.mib
            impact.storageUnknown = impact.storageUnknown || m.unknown
        }
        /// Running VMs on hosts above the EVC mode a changed cluster now needs.
        func evcPowerCycles(_ ci: Int) -> Int {
            let hs = members(ci)
            let changed = plan[ci].isMerged || hs.contains { !$0.isNew && $0.origin != plan[ci].members[0].id }
            guard changed, let e = evcNeeded(hs), !e.covered else { return 0 }
            return runningOn(hs.filter { $0.gen.vendor == e.base.vendor && $0.gen.rank > e.base.rank })
        }
        for ci in nonEmptyPlan { impact.powerCycles += evcPowerCycles(ci) }

        let outcome = Outcome(hosts: planned.count, newHosts: newCount, shortfalls: shortfalls.count, retired: retiredHosts.count,
                              upgraded: upgraded.count, addedGiB: addedGiB, licensed: licPlan, impact: impact)
        if probe { return (SolutionResult(headline: "", sections: []), outcome) }
        func movesText(_ hs: [WHost]) -> String {
            let n = runningOn(hs)
            return n == 0 ? "No running VMs to move." : "Moves \(Fmt.int(n)) running VM\(n == 1 ? "" : "s") off \(n == 1 ? "its host" : "the hosts")."
        }

        func cref(_ c: PCluster, _ detail: String = "") -> AffectedObject {
            AffectedObject(kind: c.isMerged ? .other : .cluster, id: c.isMerged ? c.id : c.members[0].id, name: c.name, detail: detail)
        }
        func hostRef(_ h: WHost, _ detail: String) -> AffectedObject {
            AffectedObject(kind: h.isNew ? .other : .host, id: h.id, name: h.name, detail: detail)
        }

        // Override builders for one-click changes.
        func keepSeparate(_ c: Cluster) -> SolutionAction {
            SolutionAction("Keep \(c.name) separate", symbol: "square.split.2x1", help: "Adds it to Keep standalone, so it isn't merged.",
                           set: ["solo": .names(soloNames + [c.id])])
        }
        func unmerge(_ c: PCluster) -> SolutionAction {
            let ids = Set(c.members.map(\.id))
            let rest = mergeNames.filter { e in !PlanEntry.parts(e).contains { resolve($0).map { ids.contains($0.id) } ?? false } }
            return SolutionAction("Unmerge", symbol: "square.split.2x1", help: "Removes this group from Merge these clusters.", set: ["merge": .names(rest)])
        }
        func mergeAction(_ cs: [Cluster], label: String) -> SolutionAction {
            SolutionAction(label, symbol: "square.stack.3d.down.forward", help: "Adds the group to Merge these clusters.",
                           set: ["merge": .names(mergeNames + [PlanEntry.join(cs.map(\.id))])])
        }
        func ramAction(_ c: PCluster, _ size: Double, label: String? = nil) -> SolutionAction {
            let ids = Set(c.members.map(\.id))
            let rest = ramNames.filter { e in resolve(PlanEntry.parts(e)[0]).map { !ids.contains($0.id) } ?? true }
            let text = label ?? (size == 0 ? "Don't upgrade memory" : "Use \(W.ramLabel(size)) per host")
            return SolutionAction(text, symbol: "memorychip", help: "Sets Memory per host for this cluster.",
                                  set: ["ram": .names(size < 0 ? rest : rest + c.members.map { PlanEntry.join([$0.id, String(format: "%g", size)]) })])
        }
        func moveAction(_ entries: [(origin: String, family: String, to: String)], label: String, symbol: String = "arrow.right.square") -> SolutionAction {
            let keys = Set(entries.map { $0.origin + "\n" + $0.family })
            let rest = moveNames.filter { e in
                let parts = PlanEntry.parts(e)
                return parts.count != 3 || !keys.contains((resolve(parts[0])?.id ?? parts[0]) + "\n" + parts[1])
            }
            return SolutionAction(label, symbol: symbol, help: "Sets Move hosts.",
                                  set: ["moves": .names(rest + entries.map { PlanEntry.join([$0.origin, $0.family, $0.to]) })])
        }
        func keepAction(_ hs: [WHost], label: String) -> SolutionAction {
            let pairs = Set(hs.filter { !$0.origin.isEmpty }.map { $0.origin + "\n" + $0.gen.family }).sorted()
            return moveAction(pairs.map { k in
                let parts = PlanEntry.parts(k)
                return (parts[0], parts[1], HostMove.keep)
            }, label: label, symbol: "pin")
        }

        // Today, cluster by cluster.
        var todayRows: [[String]] = []
        var todayRefs: [AffectedObject?] = []
        var shortToday: [String] = []
        var surplusToday = 0
        for c in scope {
            let hs = todayHosts.filter { $0.origin == c.id }
            let d = demandByCluster[c.id] ?? Demand()
            let minimum = minHosts(vsan([c.id]))
            let l = W.load(hs, d, spare: spare)
            let vcpu = (vmsByCluster[c.id] ?? []).filter(\.isRunning).reduce(0) { $0 + $1.cpus }
            let cores = hs.reduce(0.0) { $0 + $1.cores }
            var verdict: String
            if hs.isEmpty {
                verdict = "No host capacity in export"
            } else if !fits(hs, d, minimum) {
                shortToday.append(c.name)
                if hs.count < minimum && l.worst <= maxLoad { verdict = "Below \(minimum) hosts" }
                else if l.mem > maxLoad && l.cpu <= maxLoad { verdict = "Short of memory" + (memoryFix(hs, d, minimum).map { " — \(W.ramLabel($0)) per host fits" } ?? "") }
                else if l.cpu > maxLoad && l.mem <= maxLoad { verdict = "Short of CPU" }
                else { verdict = "Short of CPU and memory" }
            } else {
                let spareN = hs.count - trim(hs.map { var h = $0; h.pinned = false; return h }, d, minimum).kept.count
                surplusToday += spareN
                verdict = d.isEmpty ? "Idle — no running VMs selected" : (spareN > 0 ? "Fits; \(spareN) host\(spareN == 1 ? "" : "s") more than needed" : (l.worst > maxLoad - 0.1 ? "Fits, tight" : "Fits"))
            }
            let role = roleOf(c)
            todayRows.append([c.name, siteName(c), role.label, Fmt.int(hs.count), W.familyMix(hs), W.memoryMix(hs),
                              Fmt.int((vmsByCluster[c.id] ?? []).count), cores > 0 ? Fmt.ratio(Double(vcpu) / cores) : "—",
                              W.pct(l.cpu), W.pct(l.mem), verdict])
            todayRefs.append(AffectedObject(kind: .cluster, id: c.id, name: c.name))
        }

        // Plan changes.
        var changes = CheckBuilder()
        for (ci, c) in plan.enumerated() where c.isMerged {
            let before = c.members.reduce(0) { n, m in n + todayHosts.filter { $0.origin == m.id }.count }
            let saving = mergeSaving(c.members)
            let main = primaryMember(c)
            let joining = hosts.filter { h in !h.isNew && c.members.contains { $0.id == h.origin && $0.id != main } }
            let st = mergeStorage(c)
            let why = c.forced ? "Merged by you. " : (approach == 1 ? "Same datacenter and CPU vendor (aggressive). " : (approach == 2 ? "Matching hosts in the same datacenter (conservative). " : "Same datacenter, CPU family and environment. "))
            let gone = c.members.filter { m in todayHosts.contains { $0.origin == m.id } && !hosts.contains { !$0.retired && $0.origin == m.id } }
            let goneNames: String = gone.map(\.name).joined(separator: " and ")
            let goneText: String = gone.isEmpty ? "" : " \(goneNames) \(gone.count == 1 ? "has" : "have") no hosts left after retirement."
            let summary = why
                + (saving > 0 ? "Needs \(saving) host\(saving == 1 ? "" : "s") fewer than apart (one set of failover hosts instead of \(c.members.count))." : "Saves no hosts at these settings, but leaves one cluster fewer.")
                + goneText
                + " \(before) hosts today. The others join \(c.members.first { $0.id == main }?.name ?? ""): " + movesText(joining)
                + (st.mib > 0 ? " \(Fmt.capacity(mib: st.mib)) of VM storage moves too." : (st.unknown ? " Whether storage moves isn't in the export." : ""))
            let actions = c.forced ? [unmerge(c)] : c.members.prefix(3).map(keepSeparate)
            changes.add("merge-\(ci)", "Merges", "Merge \(c.name)", .info, summary, affected: c.members.map { AffectedObject(kind: .cluster, id: $0.id, name: $0.name) },
                        actions: actions)
        }
        for m in alignMoves {
            let hs = hosts.filter { m.ids.contains($0.id) }
            changes.add("align-\(m.from)-\(m.family)", "CPU alignment",
                        "Move \(hs.count) \(CPUFamily.short(m.family)) host\(hs.count == 1 ? "" : "s") from \(plan[m.from].name) to \(plan[m.to].name)",
                        .info, "\(plan[m.from].name) runs mostly \(CPUFamily.label(W.majority(members(m.from)))) and still fits without them; \(plan[m.to].name) runs \(CPUFamily.label(m.family)). " + movesText(hs),
                        affected: hs.map { hostRef($0, $0.gen.name) }, actions: [keepAction(hs, label: "Keep them in \(plan[m.from].name)")])
        }
        let newestNames = p.names("newest")
        for ci in priority {
            let mine = swaps.filter { $0.cluster == ci }
            let c = plan[ci]
            let undo = SolutionAction("Don't swap hosts", symbol: "arrow.uturn.backward", help: "Removes \(c.name) from Give these clusters the newest hosts.",
                                      set: ["newest": .names(newestNames.filter { n in resolve(n).map { r in !c.members.contains { $0.id == r.id } } ?? true })])
            guard !mine.isEmpty else {
                changes.add("newest-\(ci)", "Newest hosts", "\(c.name) already has the newest hosts", .info,
                            "No host of its CPU vendor elsewhere in \(c.siteName) is newer than its oldest.", affected: [cref(c)], actions: [undo])
                continue
            }
            let byID = Dictionary(hosts.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
            let ins = mine.compactMap { byID[$0.inID] }, outs = mine.compactMap { byID[$0.outID] }
            let coreIn = ins.reduce(0.0) { $0 + $1.licensed(coreMin) }, coreOut = outs.reduce(0.0) { $0 + $1.licensed(coreMin) }
            let gensIn = Array(Set(ins.map(\.gen.name))).sorted().joined(separator: ", ")
            let gensOut = Array(Set(outs.map(\.gen.name))).sorted().joined(separator: ", ")
            var text = "\(gensOut) out, \(gensIn) in, one for one with \(Array(Set(mine.map { plan[$0.donor].name })).sorted().joined(separator: ", "))."
            if coreIn != coreOut { text += " Licensed cores in \(c.name) \(coreIn > coreOut ? "rise" : "fall") by \(Fmt.int(Int(abs(coreIn - coreOut)))), which matters where its workloads are licensed per core." }
            text += " " + movesText(ins + outs)
            changes.add("newest-\(ci)", "Newest hosts", "Swap \(mine.count) host\(mine.count == 1 ? "" : "s") into \(c.name) for newer ones", .info, text,
                        affected: mine.compactMap { sw in byID[sw.inID].map { hostRef($0, "\($0.originName), \($0.gen.name) in; \(byID[sw.outID]?.gen.name ?? "") out") } },
                        actions: [undo])
        }
        for (ci, c) in plan.enumerated() where c.ramFloor > 0 {
            let up = planned.filter { $0.cluster == c.id && $0.upgradedFrom > 0 }
            guard !up.isEmpty else { continue }
            let gib = up.reduce(0.0) { $0 + ($1.ramGiB * $1.nominalGiB / $1.reportedGiB - $1.upgradedFrom) }
            var actions: [SolutionAction] = []
            if c.ramSetByYou {
                actions.append(ramAction(c, -1, label: "Remove my memory setting"))
            } else if c.ramReason == "the memory target" {
                actions.append(SolutionAction("No memory target", symbol: "arrow.uturn.backward", help: "Clears Bring every host to at least.", set: ["ramTarget": .choice(0)]))
            } else {
                actions.append(ramAction(c, 0))
                let next = W.ramSizes.filter { $0 > c.ramFloor && $0 <= maxRAM }.prefix(1)
                actions += next.map { ramAction(c, $0) }
            }
            changes.add("ram-\(ci)", "Memory", "Upgrade \(up.count) host\(up.count == 1 ? "" : "s") in \(c.name) to \(W.ramLabel(c.ramFloor))",
                        .warning, "+\(Fmt.memory(mib: gib * 1024)) in all; " + (c.ramSetByYou ? "set by you. " : (c.ramReason == "the memory target" ? "the memory target for every host. " : "\(c.ramReason), and the CPU has room. ")) + movesText(up),
                        affected: up.map { hostRef($0, "\(W.ramLabel($0.upgradedFrom)) → \(W.ramLabel(c.ramFloor))") }, actions: actions)
        }
        let releasedAuto = spareHosts.filter { $0.releasedBy == "not needed" }
        for (origin, hs) in Dictionary(grouping: releasedAuto, by: \.origin).sorted(by: { $0.key < $1.key }) {
            let name = hs[0].originName
            changes.add("release-\(origin)", "Hosts", "Release \(hs.count) host\(hs.count == 1 ? "" : "s") from \(name)", .info,
                        "Not needed at \(SFmt.num(maxLoad * 100))% load \(downText). They go to the spare pool, saving \(Fmt.int(Int(hs.reduce(0.0) { $0 + $1.licensed(coreMin) }))) licensed cores. " + movesText(hs),
                        affected: hs.map { hostRef($0, "\($0.gen.name), \(W.ramLabel($0.nominalGiB))" + ($0.maintenance ? ", in maintenance mode" : "")) },
                        actions: [keepAction(hs, label: "Keep them in \(name)")])
        }
        let releasedByYou = spareHosts.filter { $0.releasedBy == "you" }
        if !releasedByYou.isEmpty {
            changes.add("release-you", "Hosts", "Release \(releasedByYou.count) host\(releasedByYou.count == 1 ? "" : "s") (set by you)", .info,
                        "They go to the spare pool.", affected: releasedByYou.map { hostRef($0, $0.originName) })
        }
        let movedByYou = planned.filter { $0.movedBy == "you" }
        if !movedByYou.isEmpty {
            changes.add("move-you", "Hosts", "Move \(movedByYou.count) host\(movedByYou.count == 1 ? "" : "s") (set by you)", .info,
                        "As set under Move hosts.", affected: movedByYou.map { h in hostRef(h, "\(h.originName) → \(plan.first { $0.id == h.cluster }?.name ?? "")") })
        }
        let pooled = planned.filter(\.fromPool)
        for (cid, hs) in Dictionary(grouping: pooled, by: \.cluster).sorted(by: { $0.key < $1.key }) {
            guard let c = plan.first(where: { $0.id == cid }) else { continue }
            changes.add("pool-\(cid)", "Hosts", "Reuse \(hs.count) spare host\(hs.count == 1 ? "" : "s") in \(c.name)", .info,
                        "\(c.name) is short without them; they were released elsewhere in the same datacenter.",
                        affected: hs.map { hostRef($0, "from \($0.originName), \($0.gen.name)") }, actions: [keepAction(hs, label: "Keep them where they are")])
        }
        func licensedText(_ hs: [WHost]) -> String {
            let cores = hs.reduce(0.0) { $0 + $1.licensed(coreMin) }
            return "\(Fmt.int(Int(cores))) licensed cores" + (licCost > 0 ? " (\(SFmt.usd(cores * licCost)) a year)" : "")
        }
        let byTier = Dictionary(grouping: retiredHosts.filter { $0.retiredBy == "minimum family" }) { h in "\(h.gen.vendor)|\(CPURetirement.tier(h.gen) ?? 0)" }
        for key in byTier.keys.sorted() {
            let hs = byTier[key] ?? []
            let vendor = hs[0].gen.vendor, tier = CPURetirement.tier(hs[0].gen) ?? 0
            let name = CPURetirement.short(vendor, tier: tier)
            changes.add("retire-\(key)", "Retirement", "Retire \(hs.count) \(name) host\(hs.count == 1 ? "" : "s")", .info,
                        "Older than the oldest \(vendor) generation to keep. Frees \(licensedText(hs)). " + movesText(hs),
                        affected: hs.map { hostRef($0, "\($0.originName), \($0.gen.name)") },
                        actions: [SolutionAction("Keep \(name) hosts", symbol: "arrow.uturn.backward", help: "Lowers the oldest generation to keep.",
                                                 set: [vendor == "AMD" ? "minAMD" : "minIntel": .choice(tier)])])
        }
        let retiredSmall = retiredHosts.filter { $0.retiredBy == "cores" }
        if !retiredSmall.isEmpty {
            let smallReal = retiredSmall.reduce(0.0) { $0 + $1.cores }, smallPaid = retiredSmall.reduce(0.0) { $0 + $1.licensed(coreMin) }
            let counts = Dictionary(grouping: retiredSmall, by: \.coresPerSocket).sorted { $0.key < $1.key }.map { "\($0.value.count) with \($0.key) cores" }
            changes.add("retire-cores", "Retirement", "Retire \(retiredSmall.count) host\(retiredSmall.count == 1 ? "" : "s") under \(minCores) cores per CPU", .info,
                        "\(counts.joined(separator: ", ")) per CPU. Frees \(licensedText(retiredSmall))"
                            + (smallReal < smallPaid ? " for \(Fmt.int(Int(smallReal))) real cores. " : ". ")
                            + movesText(retiredSmall),
                        affected: retiredSmall.map { hostRef($0, "\($0.originName), \($0.coresPerSocket) cores × \($0.sockets)") },
                        actions: [SolutionAction("Keep them", symbol: "arrow.uturn.backward", help: "Sets the minimum cores per CPU to 0.", set: ["minCores": .number(0)])])
        }
        let retiredByYou = retiredHosts.filter { $0.retiredBy == "you" }
        if !retiredByYou.isEmpty {
            changes.add("retire-you", "Retirement", "Retire \(retiredByYou.count) host\(retiredByYou.count == 1 ? "" : "s") (set by you)", .info,
                        "Frees \(licensedText(retiredByYou)). " + movesText(retiredByYou),
                        affected: retiredByYou.map { hostRef($0, $0.originName) },
                        actions: retireNames.isEmpty ? [] : [SolutionAction("Don't retire them", symbol: "arrow.uturn.backward", help: "Clears Retire these hosts.", set: ["retire": .names([])])])
        }
        if recommend && !spareHosts.isEmpty {
            changes.add("spare-pool", "Retirement", "\(spareHosts.count) host\(spareHosts.count == 1 ? "" : "s") left in the spare pool", .info,
                        "No cluster needs them, so they aren't licensed in this plan. Retire them, keep a few as cold spares, or reuse them for a new cluster or the VCF management domain.",
                        affected: spareHosts.map { hostRef($0, "\($0.originName), \($0.gen.name), \(W.ramLabel($0.nominalGiB))") },
                        actions: [SolutionAction("Retire them", symbol: "trash", help: "Adds them to Retire these hosts.",
                                                 set: ["retire": .names(retireNames + spareHosts.map(\.id))])])
        }
        for (ci, k) in newHosts.sorted(by: { $0.key < $1.key }) {
            let c = plan[ci]
            let model = planned.first { $0.cluster == c.id && $0.isNew }
            var actions: [SolutionAction] = []
            let existing = members(ci).filter { !$0.isNew }
            if let s = memoryFix(existing, c.demand, minHosts(ci)) { actions.append(ramAction(c, s, label: "Upgrade memory to \(W.ramLabel(s)) instead")) }
            changes.add("new-\(ci)", "Hosts", "Add \(k) new host\(k == 1 ? "" : "s") to \(c.name)", .warning,
                        "Short at \(SFmt.num(maxLoad * 100))% load \(downText), with no spare host of its CPU vendor in the datacenter. Sized like \(model.map { "\(Int($0.cores)) cores, \(W.ramLabel($0.ramGiB.rounded()))" } ?? "its typical host").",
                        affected: [cref(c)], actions: actions)
        }
        if changes.checks.isEmpty {
            changes.add("none", "Plan", recommend ? "No changes recommended" : "No overrides set", .ready,
                        recommend ? "Every cluster fits and none can give up hosts or merge at these settings." : "Validating today's layout as it is.")
        }

        // Merges that weren't made, for what-ifs.
        var candidates: [(a: Cluster, b: Cluster, saving: Int, why: String)] = []
        let singles = plan.filter { !$0.isMerged && !$0.vms.isEmpty && ![.recovery, .management].contains($0.role) }.map { $0.members[0] }
        if singles.count <= 60 {
            for i in singles.indices {
                for j in singles.indices where j > i {
                    let a = singles[i], b = singles[j]
                    guard siteKey(a) == siteKey(b), clusterVendor(a) == clusterVendor(b), !clusterVendor(a).isEmpty else { continue }
                    let s = mergeSaving([a, b])
                    guard s > 0 else { continue }
                    var why: [String] = []
                    if soloIDs.contains(a.id) || soloIDs.contains(b.id) { why.append("kept standalone") }
                    for c in [a, b] where roleOf(c) != .general { why.append("\(c.name) looks like \(roleOf(c).phrase)") }
                    if W.environment(a.name) != W.environment(b.name) { why.append("different environments") }
                    if clusterFamily(a) != clusterFamily(b) { why.append("different CPU families, so EVC would apply") }
                    if !recommend || !p.flag("autoMerge") { why.append("recommended merges are off") }
                    candidates.append((a, b, s, why.isEmpty ? "too large together" : why.joined(separator: "; ")))
                }
            }
        }
        candidates.sort { ($1.saving, $0.a.name) < ($0.saving, $1.a.name) }
        var opportunities = CheckBuilder()
        for (k, c) in candidates.prefix(8).enumerated() {
            opportunities.add("candidate-\(k)", "Other merges", "\(c.a.name) + \(c.b.name)", .info,
                              "Would need \(c.saving) host\(c.saving == 1 ? "" : "s") fewer. Not recommended: \(c.why).",
                              affected: [AffectedObject(kind: .cluster, id: c.a.id, name: c.a.name), AffectedObject(kind: .cluster, id: c.b.id, name: c.b.name)],
                              actions: [mergeAction([c.a, c.b], label: "Merge")])
        }
        // Database clusters on older CPUs than others in their datacenter: newer hosts are worth more where licensing is per core.
        for (ci, c) in plan.enumerated() where c.role == .database && !priority.contains(ci) {
            let hs = members(ci).filter { !$0.isNew }
            let vendor = W.majorityVendor(hs)
            guard let oldest = hs.filter({ $0.gen.vendor == vendor }).map(\.gen.rank).min() else { continue }
            let newer = planned.filter { h in
                !h.isNew && h.gen.vendor == vendor && h.gen.rank > oldest && h.cluster != c.id
                    && plan.contains { $0.id == h.cluster && $0.site == c.site && !$0.solo }
            }
            guard let top = newer.max(by: { $0.gen.rank < $1.gen.rank }) else { continue }
            let olderN = hs.filter { $0.gen.vendor == vendor && $0.gen.rank < top.gen.rank }.count
            opportunities.add("newest-idea-\(ci)", "Newest hosts", "Give \(c.name) the newest hosts?", .info,
                              "\(olderN) of its hosts are older than the \(top.gen.name) hosts elsewhere in \(c.siteName). Database licensing is usually per core, so the fastest cores go furthest there.",
                              affected: [cref(c)],
                              actions: [SolutionAction("Swap in newer hosts", symbol: "arrow.up.circle", help: "Adds \(c.name) to Give these clusters the newest hosts.",
                                                       set: ["newest": .names(newestNames + [c.members[0].id])])])
        }

        // Validation of the planned clusters.
        var v = CheckBuilder()
        var evcRows: [String: String] = [:]
        for ci in nonEmptyPlan {
            let c = plan[ci]
            let hs = members(ci)
            let real = hs.filter { !$0.isNew }
            let l = W.load(hs, c.demand, spare: spare)
            let vendors = Set(hs.map(\.gen.vendor)).subtracting([""])
            if vendors.count > 1 {
                v.add("vendor-\(ci)", "CPU", "\(c.name) mixes Intel and AMD", .blocker, "vMotion can't move a running VM between CPU vendors, and EVC can't bridge them.",
                      remediation: "Keep Intel and AMD hosts in separate clusters.", affected: [cref(c)])
            }
            if let e = evcNeeded(real) {
                let base = e.base, covered = e.covered
                let current = Set(real.map { $0.evcCurrent.lowercased() })
                evcRows[c.id] = covered ? base.evc : "set " + base.evc
                let families = Set(real.map(\.gen.family))
                let block = alignBlocks.first { $0.cluster == ci }
                var actions: [SolutionAction] = []
                if let block, let t = block.target {
                    let movers = real.filter { $0.gen.family == block.family }
                    let origins = Set(movers.map(\.origin)).sorted()
                    let dest = plan[t].members[0].id
                    actions.append(moveAction(origins.map { ($0, block.family, dest) },
                                              label: "Move the \(CPUFamily.short(block.family)) hosts to \(plan[t].name)"))
                }
                let mix = W.familyMix(real)
                if covered {
                    if families.count > 1 { v.add("evc-\(ci)", "CPU", "\(c.name) runs EVC \(base.evc)", families.count > 1 ? .info : .ready,
                          "Mixed CPU families (\(mix)) under an EVC mode that covers them.", affected: [cref(c)], actions: actions) }
                } else {
                    let why = block.map { $0.reason.isEmpty ? "" : " The \(CPUFamily.short($0.family)) hosts weren't moved: \($0.reason)." } ?? ""
                    v.add("evc-\(ci)", "CPU", "Set EVC to \(base.evc) on \(c.name)", families.count > 1 ? .warning : .info,
                          "Its hosts span \(Set(real.map(\.gen.name)).sorted().joined(separator: ", ")) (\(mix)), and EVC "
                            + (current.contains("") || current.contains("disabled") ? "is off on some or all of them" : "is set above the oldest host") + ", so vMotion can fail between them.\(why)",
                          remediation: "EVC at \(base.name) hides newer CPU features from VMs; a VM picks up the lower mode at its next power cycle. Or keep each CPU family in its own cluster.",
                          affected: [cref(c)], actions: actions)
                }
            }
            if l.worst > maxLoad || hs.count < minHosts(ci) {
                let fix = memoryFix(hs, c.demand, minHosts(ci))
                v.add("short-\(ci)", "Capacity", "\(c.name) is short", recommend ? .blocker : .warning,
                      "\(SFmt.num((l.cpu * 100).rounded()))% CPU and \(SFmt.num((l.mem * 100).rounded()))% memory \(downText), above \(SFmt.num(maxLoad * 100))%"
                        + (hs.count < minHosts(ci) ? ", and fewer than \(minHosts(ci)) hosts" : "") + ".",
                      remediation: fix.map { "Upgrading to \(W.ramLabel($0)) per host fits." } ?? (recommend ? "Allow more memory per host, or add hosts." : "Switch Plan to Recommended to see the hosts or memory it needs."),
                      affected: [cref(c)], actions: fix.map { [ramAction(c, $0, label: "Upgrade to \(W.ramLabel($0))")] } ?? [])
            }
            if hs.count > maxHosts {
                v.add("max-\(ci)", "Capacity", "\(c.name) has \(hs.count) hosts", .blocker, "More than \(maxHosts) hosts per cluster.",
                      remediation: "Split the merge.", affected: [cref(c)], actions: c.forced ? [unmerge(c)] : [])
            }
            let cores = hs.reduce(0.0) { $0 + $1.cores }
            let vcpu = c.vms.filter(\.isRunning).reduce(0) { $0 + $1.cpus }
            if cores > 0 && Double(vcpu) / cores > ratio {
                v.add("ratio-\(ci)", "Capacity", "\(c.name) at \(Fmt.ratio(Double(vcpu) / cores)) vCPU per core", .warning,
                      "Above the \(Fmt.ratio(ratio)) set under Capacity. Watch CPU ready time.", affected: [cref(c)])
            }
            if let smallest = hs.min(by: { ($0.threads, $0.ramGiB) < ($1.threads, $1.ramGiB) }) {
                let minRAM = hs.map(\.ramGiB).min() ?? 0, minThreads = hs.map(\.threads).min() ?? 0
                let big = c.vms.filter { $0.cpus > minThreads || $0.memoryMiB / 1024 > minRAM }
                if !big.isEmpty {
                    v.list("bigvm-\(ci)", "Capacity", "VMs larger than \(c.name)'s smallest host", .warning, noun: "VMs",
                           affected: big.map { $0.ref("\($0.cpus) vCPU, \(Fmt.memory(mib: $0.memoryMiB))") }, ready: "",
                           remediation: "\(smallest.name) has \(minThreads) threads and \(W.ramLabel(minRAM.rounded())). DRS can't place these VMs on it; size the hosts for them or keep them on larger hosts with a rule.")
                }
            }
            if c.isMerged {
                let sites = Set(c.members.map(siteKey))
                if sites.count > 1 {
                    v.add("site-\(ci)", "Merge", "\(c.name) spans datacenters or vCenters", .warning, c.siteName,
                          remediation: "A cluster lives in one datacenter of one vCenter: hosts must be moved and VMs migrated across. Confirm the sites are really one location.",
                          affected: [cref(c)], actions: c.forced ? [unmerge(c)] : [])
                }
                let memberIDs = c.members.map(\.id)
                let mapped = memberIDs.allSatisfy { id in inv.datastores.contains { $0.clusterKeys.contains(id) } }
                let shared = inv.datastores.contains { d in !d.isLocal && memberIDs.allSatisfy { d.clusterKeys.contains($0) } }
                if !mapped {
                    v.add("storage-\(ci)", "Merge", "Check storage for \(c.name)", .info,
                          "The export doesn't show which hosts mount which datastores (vDatastore without its Hosts column).",
                          remediation: "Confirm every merged host can reach the datastores, or plan Storage vMotion.", affected: [cref(c)])
                } else if !shared {
                    v.add("storage-\(ci)", "Merge", "No datastore shared by every cluster in \(c.name)", .warning,
                          "Each cluster sees its own storage today.",
                          remediation: "Present the datastores to all the merged hosts (zoning, masking, NFS exports), or Storage vMotion the VMs first.", affected: [cref(c)])
                }
                if c.vsan {
                    v.add("vsan-\(ci)", "Merge", "\(c.name) includes vSAN", .warning, "vSAN datastores belong to their cluster.",
                          remediation: "Plan how the vSAN data moves: evacuate to shared storage, or rebuild the merged cluster's vSAN as hosts join.", affected: [cref(c)])
                }
            }
            let esx = Set(real.map(\.esx))
            if esx.count > 1 {
                v.add("esx-\(ci)", "Lifecycle", "\(c.name) runs \(esx.count) ESXi versions", .info, esx.sorted().joined(separator: ", "),
                      remediation: "Bring the hosts to one version and image before or as they join.", affected: [cref(c)])
            }
            if !c.isMerged && c.vms.isEmpty && (allVMsByCluster[c.members[0].id] ?? []).isEmpty && !real.isEmpty {
                v.add("idle-\(ci)", "Hosts", "\(c.name) runs no VMs", .info,
                      "\(real.count) host\(real.count == 1 ? "" : "s") with nothing on them" + (c.role == .recovery ? ", likely held for recovery." : "."),
                      remediation: "If it isn't reserved for failover or recovery, release its hosts to the spare pool.", affected: [cref(c)],
                      actions: [moveAction([(c.members[0].id, HostMove.all, HostMove.release)], label: "Release all its hosts", symbol: "tray.and.arrow.up")])
            }
            let maint = real.filter(\.maintenance)
            if !maint.isEmpty {
                v.list("maint-\(ci)", "Hosts", "Hosts in maintenance mode in \(c.name)", .info, noun: "hosts",
                       affected: maint.map { hostRef($0, "") }, ready: "", remediation: "They count as capacity. Check whether they're failing or being retired.")
            }
        }
        if !unknownHosts.isEmpty {
            v.list("unknown-hosts", "Hosts", "Hosts without cores or memory in the export", .warning, noun: "hosts",
                   affected: unknownHosts.map { $0.ref($0.cluster) }, ready: "", remediation: "They aren't counted. Include the vHost tab.")
        }
        let unknownCPU = planned.filter { $0.gen.family == CPUFamily.unknown && !$0.isNew }
        if !unknownCPU.isEmpty {
            v.list("unknown-cpu", "CPU", "Hosts whose CPU family isn't recognised", .info, noun: "hosts",
                   affected: unknownCPU.map { hostRef($0, "") }, ready: "", remediation: "They're left out of CPU alignment and EVC suggestions.")
        }
        for name in soloInMerge {
            v.add("solo-merge-\(name)", "Merge", "\(name) is kept standalone", .info, "It's also in a merge group, and was left out of it.",
                  remediation: "Remove it from Keep standalone to merge it.")
        }

        func currentEVC(_ hs: [WHost]) -> String {
            let modes = Set(hs.filter { !$0.isNew }.map { $0.evcCurrent.lowercased() })
            if modes.isEmpty { return "—" }
            if modes.contains("") || modes.contains("disabled") { return modes.count == 1 ? "off" : "mixed" }
            return modes.count == 1 ? modes.first! : "mixed"
        }

        // Planned clusters.
        var planRows: [[String]] = []
        var planRefs: [AffectedObject?] = []
        var planActions: [[SolutionAction]] = []
        var worst: (load: Double, what: String) = (0, "")
        for ci in nonEmptyPlan {
            let c = plan[ci]
            let hs = members(ci)
            let before = c.members.reduce(0) { n, m in n + todayHosts.filter { $0.origin == m.id }.count }
            let l = W.load(hs, c.demand, spare: spare)
            if l.worst > worst.load { worst = (l.worst, "\(l.mem >= l.cpu ? "memory" : "CPU") · \(c.name)") }
            let cores = hs.reduce(0.0) { $0 + $1.cores }
            let vcpu = c.vms.filter(\.isRunning).reduce(0) { $0 + $1.cpus }
            var what: [String] = []
            if c.isMerged { what.append(c.forced ? "merged by you" : "merged") }
            let movedIn = hs.filter { h in !h.isNew && !c.members.contains { $0.id == h.origin } }.count
            let movedOut = hosts.filter { h in c.members.contains { $0.id == h.origin } && !h.released && h.cluster != c.id }.count
            let releasedN = spareHosts.filter { h in c.members.contains { $0.id == h.origin } }.count
            if movedIn > 0 { what.append("+\(movedIn) moved in") }
            if movedOut > 0 { what.append("−\(movedOut) moved out") }
            if releasedN > 0 { what.append("−\(releasedN) released") }
            let retiredN = retiredHosts.filter { h in c.members.contains { $0.id == h.origin } }.count
            if retiredN > 0 { what.append("−\(retiredN) retired") }
            if let k = newHosts[ci] { what.append("+\(k) new") }
            let up = hs.filter { $0.upgradedFrom > 0 }.count
            if up > 0 { what.append("\(up) memory upgrade\(up == 1 ? "" : "s")") }
            if c.solo { what.append("kept standalone") }
            let licBefore = todayHosts.filter { h in c.members.contains { $0.id == h.origin } }.reduce(0.0) { $0 + $1.licensed(coreMin) }
            let licAfter = hs.reduce(0.0) { $0 + $1.licensed(coreMin) }
            planRows.append([c.name, c.role.label, "\(before) → \(hs.count)", "\(Fmt.int(Int(licBefore))) → \(Fmt.int(Int(licAfter)))", W.familyMix(hs), W.memoryMix(hs),
                             W.pct(l.cpu), W.pct(l.mem), cores > 0 ? Fmt.ratio(Double(vcpu) / cores) : "—",
                             evcRows[c.id] ?? currentEVC(hs), what.isEmpty ? "No change" : what.joined(separator: ", ")])
            planRefs.append(cref(c))
            planActions.append(c.isMerged ? (c.forced ? [unmerge(c)] : []) : [])
        }

        // Host changes.
        var hostRows: [[String]] = []
        var hostRefs: [AffectedObject?] = []
        let planName = Dictionary(plan.map { ($0.id, $0.name) }, uniquingKeysWith: { a, _ in a })
        for h in hosts.sorted(by: { ($0.originName, $0.name) < ($1.originName, $1.name) }) {
            var change: [String] = []
            let inPlan = h.retired ? "Retired" : (h.released ? "Spare pool" : (planName[h.cluster] ?? ""))
            if h.isNew { change.append("new") }
            if h.retired {
                change.append(h.retiredBy == "you" ? "retired by you"
                              : (h.retiredBy == "cores" ? "retired, \(h.coresPerSocket) cores per CPU" : "retired, older than the generation to keep"))
            } else if h.released {
                change.append(h.releasedBy == "you" ? "released by you" : "released, not needed")
            }
            if h.fromPool { change.append("reused spare") }
            if !h.movedBy.isEmpty && !h.fromPool { change.append(h.movedBy == "you" ? "moved by you" : (h.movedBy == "newest hosts" ? "swapped for newer hosts" : "moved for CPU alignment")) }
            if h.upgradedFrom > 0 { change.append("memory upgrade") }
            if !h.released && !h.isNew && planIDOf[h.origin] != h.cluster && h.movedBy.isEmpty && !h.fromPool { change.append("moved") }
            guard !change.isEmpty else { continue }
            let mem = h.upgradedFrom > 0 ? "\(W.ramLabel(h.upgradedFrom)) → \(W.ramLabel((h.ramGiB * h.nominalGiB / h.reportedGiB).rounded()))" : W.ramLabel(h.nominalGiB)
            hostRows.append([h.name, h.isNew ? "—" : h.originName, inPlan, change.joined(separator: ", "), "\(h.gen.name), \(Int(h.cores)) cores", mem])
            hostRefs.append(hostRef(h, ""))
        }

        // Summary.
        let clustersToday = scope.count, clustersPlan = nonEmptyPlan.count
        // Each cluster is judged on its own hosts: HA restarts VMs only inside their cluster, so room elsewhere doesn't help.
        let gapLabel = spare == 0 ? "Capacity gaps today" : "Failover gaps today"
        let hostsDown = spare == 1 ? "1 host" : "\(spare) hosts"
        let maxText = SFmt.num(maxLoad * 100) + "%"
        let gapWhy = spare == 0 ? "over \(maxText) on their own hosts" : "can't lose \(hostsDown) and stay under \(maxText)"
        let gapNames = shortToday.prefix(3).joined(separator: ", ") + (shortToday.count > 3 ? "…" : "")
        var metrics: [SolutionMetric] = [
            SolutionMetric("Clusters", clustersToday == clustersPlan ? Fmt.int(clustersToday) : "\(clustersToday) → \(clustersPlan)",
                           plan.filter(\.isMerged).isEmpty ? "no merges" : "\(plan.filter(\.isMerged).count) merge\(plan.filter(\.isMerged).count == 1 ? "" : "s")",
                           symbol: "square.stack.3d.up"),
            SolutionMetric("Hosts", "\(todayHosts.count) → \(planned.count)",
                           [spareHosts.isEmpty ? nil : "\(spareHosts.count) to the spare pool", retiredHosts.isEmpty ? nil : "\(retiredHosts.count) retired",
                            newCount > 0 ? "\(newCount) new" : nil].compactMap { $0 }.joined(separator: ", ").ifEmpty("no change"),
                           symbol: "server.rack", status: newCount > 0 ? .warning : nil),
            SolutionMetric("Memory upgrades", upgraded.isEmpty ? "None" : "\(upgraded.count) host\(upgraded.count == 1 ? "" : "s")",
                           upgraded.isEmpty ? "no cluster needs more memory" : "+\(Fmt.memory(mib: addedGiB * 1024)) in all", symbol: "memorychip",
                           status: upgraded.isEmpty ? nil : .warning),
            SolutionMetric(gapLabel, shortToday.isEmpty ? "None" : "\(shortToday.count) of \(clustersToday) clusters",
                           shortToday.isEmpty ? "every cluster fits \(downText)" : gapWhy + ": " + gapNames,
                           symbol: "exclamationmark.triangle", status: shortToday.isEmpty ? nil : .warning),
            SolutionMetric("Busiest planned cluster", W.pct(worst.load), worst.what.isEmpty ? downText : "\(worst.what), \(downText)", symbol: "gauge.with.dots.needle.67percent",
                           status: worst.load > maxLoad ? .blocker : nil),
        ]

        // Licensing first when it's the goal.
        let licSaved = licToday - licPlan
        var licMetrics = [SolutionMetric("Licensed cores", licSaved == 0 ? Fmt.int(Int(licToday)) : "\(Fmt.int(Int(licToday))) → \(Fmt.int(Int(licPlan)))",
                                         (licSaved > 0 ? "−\(Fmt.int(Int(licSaved))) (\(W.pct(licSaved / max(licToday, 1)))), " : (licSaved < 0 ? "+\(Fmt.int(Int(-licSaved))), " : ""))
                                            + "at \(SFmt.num(coreMin)) cores minimum per CPU",
                                         symbol: "checkmark.seal", status: licSaved < 0 ? .warning : nil)]
        if licCost > 0 {
            licMetrics.append(SolutionMetric("Licensing", licSaved >= 0 ? "\(SFmt.usd(licSaved * licCost)) a year saved" : "\(SFmt.usd(-licSaved * licCost)) a year more",
                                             "\(SFmt.usd(licSaved * licCost * licYears)) over \(SFmt.num(licYears)) years at \(SFmt.usd(licCost)) per core; "
                                                + "\(SFmt.usd(licPlan * licCost)) a year in all", symbol: "dollarsign.circle", status: licSaved < 0 ? .warning : nil))
        }
        let impactMetric = SolutionMetric("Impact", impact.score == 0 ? "None" : "\(impact.level) (\(impact.score) of 100)", impact.text + (impact.storageUnknown ? "; storage moves for merges not in the export" : ""),
                                          symbol: "arrow.left.arrow.right", status: impact.level == "High" ? .warning : nil)
        metrics = goal == 1 ? licMetrics + metrics + [impactMetric] : Array(metrics.prefix(3)) + licMetrics + [impactMetric] + Array(metrics.dropFirst(3))

        let headline: String
        if recommend {
            var parts: [String] = []
            if clustersPlan != clustersToday { parts.append("\(clustersToday) clusters → \(clustersPlan)") }
            if !spareHosts.isEmpty { parts.append("\(spareHosts.count) host\(spareHosts.count == 1 ? "" : "s") released") }
            if !retiredHosts.isEmpty { parts.append("\(retiredHosts.count) retired") }
            if newCount > 0 { parts.append("\(newCount) new host\(newCount == 1 ? "" : "s") needed") }
            if !upgraded.isEmpty { parts.append("memory added to \(upgraded.count) host\(upgraded.count == 1 ? "" : "s") (+\(Fmt.memory(mib: addedGiB * 1024)))") }
            if goal == 1 && licSaved != 0 { parts.insert("licensed cores \(Fmt.int(Int(licToday))) → \(Fmt.int(Int(licPlan)))", at: 0) }
            headline = "\(todayHosts.count) hosts in \(clustersToday) clusters: " + (parts.isEmpty ? "no changes needed" : parts.joined(separator: ", "))
                + (shortfalls.isEmpty ? "" : "; \(shortfalls.count) cluster\(shortfalls.count == 1 ? "" : "s") still short")
                + (impact.level == "None" ? "" : ". Impact: \(impact.level.lowercased())")
        } else {
            headline = shortToday.isEmpty
                ? "All \(clustersToday) clusters fit \(downText)" + (surplusToday > 0 ? "; \(surplusToday) hosts more than needed" : "")
                : "\(shortToday.count) of \(clustersToday) clusters \(gapWhy) today: \(shortToday.prefix(4).joined(separator: ", "))"
        }

        var method = [
            "Workload clusters only. The VCF management domain is assumed to run on other clusters already, so no management appliances are sized here.",
            measured ? "Demand is measured host CPU and memory use (vHost), scaled to the selected VMs' share, plus \(SFmt.num((growth - 1) * 100))% growth. It stays with its cluster when hosts move or merge."
                : "Demand is the selected powered-on VMs' vCPU at \(Fmt.ratio(ratio)) and their memory at \(SFmt.num(memRatio * 100))% of physical, plus \(SFmt.num((growth - 1) * 100))% growth.",
            "A cluster fits when CPU and memory stay at or below \(SFmt.num(maxLoad * 100))% \(downText) (the largest hosts out), with at least \(minHostsParam) hosts (3 on vSAN).",
            "CPU families come from each host's highest EVC mode, or its CPU model. Skylake and Cascade Lake are one family (Xeon Scalable 1st–2nd gen), as are Sapphire and Emerald Rapids.",
            "Roles and environments are guessed from cluster names; use the overrides when a guess is wrong.",
            "Impact counts running VMs on every host that is moved, merged into another cluster, released, retired or upgraded (each host is evacuated into maintenance mode), VMs to power-cycle where the plan puts newer CPUs under a lower EVC mode, and VM storage that must change datastore: a merge with vSAN or with no datastore shared, and a vSAN host's share when it leaves. The score out of 100 counts each live vMotion as a quarter of a power cycle, as a share of running VMs, plus a point per TiB of storage to move: Low is under 10, Medium under 30.",
            "Memory sizes are nominal (a host reporting 766.7 GiB has 768 GiB installed). Upgrades assume every host can reach the new size; check DIMM slots and the vendor's population rules.",
        ]
        if !basisFallback.isEmpty { method.append("No host usage for \(basisFallback.joined(separator: ", ")): sized from configured vCPU and memory.") }
        if !mgmtLeftOut.isEmpty {
            method.append("Left out as management clusters: \(mgmtLeftOut.map(\.name).joined(separator: ", ")). Turn on Include management clusters to plan them too.")
        }
        if !outsideVMs.isEmpty { method.append("\(outsideVMs.count) selected VMs run outside a cluster in scope (standalone hosts) and aren't planned.") }
        method += notes

        // Retiring each vendor's oldest family, tried as a what-if.
        var retireIdeas = CheckBuilder()
        if recommend && p.flag("suggestRetire") {
            for (vendor, param) in [("Intel", "minIntel"), ("AMD", "minAMD")] {
                let present = hosts.filter { !$0.retired && !$0.isNew && $0.gen.vendor == vendor }
                let tiers = Set(present.compactMap { CPURetirement.tier($0.gen) })
                guard let oldest = tiers.min(), tiers.count > 1 else { continue }
                let fam = CPURetirement.short(vendor, tier: oldest)
                let going = present.filter { CPURetirement.tier($0.gen) == oldest }
                let o = evaluate(vms: vms, inventory: inv, params: p.setting(param, .choice(oldest + 1)), probe: true).outcome
                let fine = o.newHosts == 0 && o.shortfalls == 0
                let title = fine ? "Retire all \(going.count) \(fam) hosts" : "Retiring all \(going.count) \(fam) hosts needs \(o.newHosts) new host\(o.newHosts == 1 ? "" : "s")"
                var parts = [fine ? "The remaining hosts can carry their workloads." : "The remaining hosts can't carry everything.",
                             "Hosts \(planned.count) → \(o.hosts), licensed cores \(Fmt.int(Int(licPlan))) → \(Fmt.int(Int(o.licensed)))"
                                + (licCost > 0 && o.licensed < licPlan ? " (\(SFmt.usd((licPlan - o.licensed) * licCost)) a year less)" : "") + "."]
                if o.upgraded > upgraded.count { parts.append("Memory upgrades on \(o.upgraded) hosts (+\(Fmt.memory(mib: o.addedGiB * 1024))).") }
                parts.append("Impact: \(o.impact.level.lowercased()) (\(o.impact.score) of 100), \(o.impact.text).")
                retireIdeas.add("retire-idea-\(vendor)", "Retirement", title, fine ? .info : .warning, parts.joined(separator: " "),
                                remediation: "\(fam) is the oldest \(vendor) generation here. Retiring it also lifts the EVC mode its clusters need.",
                                affected: going.map { hostRef($0, "\($0.originName), \($0.gen.name)") },
                                actions: [SolutionAction("Retire them", symbol: "trash", help: "Sets the oldest \(vendor) generation to keep.", set: [param: .choice(oldest + 1)])])
            }
            // Hosts below the licensing minimum per CPU pay for cores they don't have.
            let small = hosts.filter { !$0.retired && !$0.isNew && $0.coresPerSocket > 0 && Double($0.coresPerSocket) < coreMin }
            if minCores == 0 && !small.isEmpty && small.count < hosts.filter({ !$0.retired && !$0.isNew }).count {
                let target = Int(coreMin)
                let o = evaluate(vms: vms, inventory: inv, params: p.setting("minCores", .number(Double(target))), probe: true).outcome
                let fine = o.newHosts == 0 && o.shortfalls == 0
                let paid = small.reduce(0.0) { $0 + $1.licensed(coreMin) }, real = small.reduce(0.0) { $0 + $1.cores }
                let title = fine ? "Retire the \(small.count) host\(small.count == 1 ? "" : "s") under \(target) cores per CPU"
                    : "Retiring the \(small.count) host\(small.count == 1 ? "" : "s") under \(target) cores per CPU needs \(o.newHosts) new host\(o.newHosts == 1 ? "" : "s")"
                var parts = ["They license \(Fmt.int(Int(paid))) cores for \(Fmt.int(Int(real))) real ones.",
                             fine ? "The remaining hosts can carry their workloads." : "The remaining hosts can't carry everything.",
                             "Hosts \(planned.count) → \(o.hosts), licensed cores \(Fmt.int(Int(licPlan))) → \(Fmt.int(Int(o.licensed)))"
                                + (licCost > 0 && o.licensed < licPlan ? " (\(SFmt.usd((licPlan - o.licensed) * licCost)) a year less)" : "") + "."]
                if o.upgraded > upgraded.count { parts.append("Memory upgrades on \(o.upgraded) hosts (+\(Fmt.memory(mib: o.addedGiB * 1024))).") }
                parts.append("Impact: \(o.impact.level.lowercased()) (\(o.impact.score) of 100), \(o.impact.text).")
                retireIdeas.add("retire-idea-cores", "Retirement", title, fine ? .info : .warning, parts.joined(separator: " "),
                                remediation: "Below the \(target)-core licensing minimum, a host is licensed for cores it doesn't have.",
                                affected: small.map { hostRef($0, "\($0.originName), \($0.coresPerSocket) cores × \($0.sockets)") },
                                actions: [SolutionAction("Retire them", symbol: "trash", help: "Sets the minimum cores per CPU to \(target).", set: ["minCores": .number(Double(target))])])
            }
        }

        let todaySubtitle = "Each cluster on its own hosts, since HA restarts VMs only within their cluster. Load is CPU and memory \(downText), against \(maxText)."
        var sections: [SolutionSection] = [.metrics("Summary", metrics)]
        sections.append(.table(SolutionTable(id: "today", title: "Today", subtitle: todaySubtitle,
                                             columns: ["Cluster", "Datacenter", "Role", "Hosts", "CPU", "Memory per host", "VMs", "vCPU:core", "CPU", "Memory", "Verdict"],
                                             numeric: [3, 6, 7, 8, 9], rows: todayRows, rowRefs: todayRefs)))
        sections.append(.checks(recommend ? "Plan changes" : "Your overrides", changes.checks,
                                subtitle: "Each change can be undone here; it's then kept as an override under Assumptions."))
        sections.append(.table(SolutionTable(id: "plan", title: "Planned clusters", subtitle: "Load \(downText), against \(SFmt.num(maxLoad * 100))%.",
                                             columns: ["Cluster", "Role", "Hosts", "Licensed cores", "CPU", "Memory per host", "CPU", "Memory", "vCPU:core", "EVC", "Changes"],
                                             numeric: [3, 6, 7, 8], rows: planRows, rowRefs: planRefs, rowActions: planActions)))
        sections.append(.checks("Validation", v.checks.isEmpty ? [SolutionCheck(id: "ok", area: "Plan", title: "No issues found", status: .ready, summary: "The planned clusters pass every check.", remediation: "", affected: [])] : v.checks))
        if !retireIdeas.checks.isEmpty {
            sections.append(.checks("Retire the oldest hosts?", retireIdeas.checks,
                                    subtitle: "What this plan would look like with each CPU vendor's oldest generation, or hosts below the licensing minimum, retired."))
        }
        if !opportunities.checks.isEmpty {
            sections.append(.checks("Other ideas to try", opportunities.checks, subtitle: "Merges in the same datacenter that would need fewer hosts but weren't recommended, and clusters that could use newer hosts."))
        }
        if !hostRows.isEmpty {
            sections.append(.table(SolutionTable(id: "hosts", title: "Host changes", columns: ["Host", "Today in", "Planned", "Change", "CPU", "Memory"],
                                                 rows: hostRows, rowRefs: hostRefs)))
        }
        sections.append(.notes("Method", method))
        return (SolutionResult(headline: headline, sections: sections), outcome)
    }
}

private extension String {
    func ifEmpty(_ fallback: String) -> String { isEmpty ? fallback : self }
}
