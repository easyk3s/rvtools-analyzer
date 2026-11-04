import Foundation

/// Appliance sizes from Broadcom's VCF 9.1.1 Planning and Preparation Workbook ("Management Domain Sizing" and its
/// reference tables), in GB as the workbook states them. Update these tables when a new workbook changes the numbers.
enum VCFAppliances {
    static let source = "VCF 9.1.1 Planning and Preparation Workbook"

    struct Spec {
        let cpu: Double, ram: Double, disk: Double
        init(_ cpu: Double, _ ram: Double, _ disk: Double) { self.cpu = cpu; self.ram = ram; self.disk = disk }
    }

    enum Deployment: Int, CaseIterable {
        case simple = 0, haSmall, haMedium, haLarge
        var isHA: Bool { self != .simple }
        var size: String { [.simple: "Small", .haSmall: "Small", .haMedium: "Medium", .haLarge: "Large"][self]! }
        var label: String { isHA ? "High availability · \(size)" : "Simple · Small" }
    }

    static let vcenter: [String: (cpu: Double, ram: Double)] = [
        "Tiny": (2, 14), "Small": (4, 21), "Medium": (8, 30), "Large": (16, 39), "XLarge": (24, 58),
    ]
    /// vCenter disk by appliance size and storage size.
    static let vcenterDisk: [String: [String: Double]] = [
        "Tiny": ["Default": 619, "Large": 2059, "XLarge": 4319],
        "Small": ["Default": 734, "Large": 2084, "XLarge": 4344],
        "Medium": ["Default": 933, "Large": 2233, "XLarge": 4493],
        "Large": ["Default": 1383, "Large": 2283, "XLarge": 4543],
        "XLarge": ["Default": 2308, "Large": 2408, "XLarge": 4668],
    ]
    static let vcenterLimits: [(size: String, hosts: Int, vms: Int)] = [
        ("Tiny", 10, 100), ("Small", 100, 1000), ("Medium", 400, 4000), ("Large", 1000, 10_000), ("XLarge", 2000, 35_000),
    ]
    static let nsxManager: [String: Spec] = ["Medium": Spec(6, 24, 300), "Large": Spec(12, 48, 300), "XLarge": Spec(24, 96, 400)]
    static let nsxLimits: [(size: String, hosts: Int, clusters: Int)] = [("Medium", 128, 5), ("Large", 1024, 256), ("XLarge", 2048, 512)]
    static let nsxEdge: [String: Spec] = ["Small": Spec(2, 4, 200), "Medium": Spec(4, 8, 200), "Large": Spec(8, 32, 200), "XLarge": Spec(16, 64, 200)]
    static let sddcManager = Spec(4, 16, 914)
    static let runtimeControl: [String: Spec] = ["Small": Spec(4, 10, 100), "Medium": Spec(4, 10, 100), "Large": Spec(8, 14, 100)]
    /// VCF services runtime worker nodes: vCPU and RAM per node, disk for the set.
    static let runtimeWorker: [Deployment: Spec] = [
        .simple: Spec(12, 24, 2900), .haSmall: Spec(10, 16, 2800), .haMedium: Spec(12, 24, 3300), .haLarge: Spec(16, 32, 4002),
    ]
    /// Day-0 services on the workers: Identity Broker, Software Depot, SDDC LCM, Salt, Salt RaaS, Telemetry and Fleet.
    static let runtimeServices: [Deployment: (cpu: Double, ram: Double)] = [
        .simple: (9.85, 16.1), .haSmall: (12.35, 20.1), .haMedium: (20, 26.5), .haLarge: (29.5, 52.5),
    ]
    /// Log management, per replica (disk from the VCF Operations for logs appliance).
    static let logs: [String: Spec] = ["Small": Spec(8, 16, 575), "Medium": Spec(16, 32, 575), "Large": Spec(32, 64, 575)]
    /// Real-time metrics (VODAP) on the workers.
    static let realTimeMetrics: [Deployment: Spec] = [
        .simple: Spec(16, 20, 205), .haSmall: Spec(16, 20, 205), .haMedium: Spec(31, 41, 205), .haLarge: Spec(47, 62, 205),
    ]
    static let operations: [String: Spec] = ["Small": Spec(4, 16, 274), "Medium": Spec(8, 32, 274), "Large": Spec(16, 48, 274)]
    static let licenseServer = Spec(2, 4, 12)
    static let cloudProxy: [String: Spec] = ["Small": Spec(4, 16, 264), "Standard": Spec(8, 48, 264)]
    static let automation: [String: Spec] = ["Small": Spec(24, 96, 600), "Medium": Spec(24, 96, 900), "Large": Spec(32, 128, 1200)]

    /// vSphere Foundation as the VCF Installer deploys it (VCF 9.1 docs, "Start a New vSphere Foundation Deployment by Using the
    /// VCF Installer Deployment Wizard"): simple mode, Medium vCenter, Medium VCF Operations, Small VCF management services. The
    /// workbook's sizing tab has no VVF option, so the sizes come from its tables.
    static let vvfSource = "VCF 9.1 docs (VCF Installer, vSphere Foundation) with sizes from the \(source)"
    static let vvfVCenterSize = "Medium"
    static let vvfOperationsSize = "Medium"

    /// Raw vSAN TiB included per licensed core. Verify current Broadcom terms.
    static let vsanTiBPerCoreVCF = 1.0
    static let vsanTiBPerCoreVVF = 0.25

    /// Smallest vCenter for a domain (VCF deploys Small or larger).
    static func vcenterSize(hosts: Int, vms: Int) -> String {
        vcenterLimits.dropFirst().first { hosts <= $0.hosts && vms <= $0.vms }?.size ?? "XLarge"
    }

    static func nsxSize(hosts: Int, clusters: Int) -> String {
        nsxLimits.first { hosts <= $0.hosts && clusters <= $0.clusters }?.size ?? "XLarge"
    }

    static func larger(_ a: String, _ b: String) -> String {
        let order = ["Tiny", "Small", "Medium", "Large", "XLarge"]
        return (order.firstIndex(of: a) ?? 0) >= (order.firstIndex(of: b) ?? 0) ? a : b
    }
}

/// Sizes a VCF 9 fleet on the hardware RVTools shows: which hosts can become the management domain (peeled off an
/// existing cluster, or shared with workloads in a consolidated cluster), what the management appliances need, and what
/// converging the other clusters into workload domains adds. Management appliance sizing follows the VCF 9.1.1 Planning
/// and Preparation Workbook; host fit uses the real hosts' cores and memory with host failures held in reserve.
public struct VCF9Sizing: Solution {
    public init() {}
    public var id: String { "vcfsizing" }
    public var title: String { "VCF 9 Sizing" }
    public var symbol: String { "square.stack.3d.up" }
    public var summary: String { "VCF or vSphere Foundation sizing on the existing hosts: management domain (greenfield peel-off or consolidated), workload domains, and convergence of the other clusters." }

    public var parameters: [SolutionParameter] { [
        .choice("edition", "Architecture", "Edition", [
            "VMware Cloud Foundation (VCF)",
            "VMware vSphere Foundation (VVF)",
        ], help: "VVF has no SDDC Manager, NSX, VCF Automation or workload domains: VCF Operations, the license server and VCF management services run next to the existing vCenter, deployed by the VCF Installer in simple mode."),
        .choice("arch", "Architecture", "Management domain", [
            "Dedicated — peel hosts off an existing cluster",
            "Consolidated — management and workloads share one cluster",
            "Recommended for the edition — dedicated for VCF, consolidated for VVF",
        ], selected: 2, help: "Dedicated is the VCF ideal: a new management cluster built from existing hosts, with the rest of that cluster carrying its VMs. VVF's smaller footprint usually runs in an existing cluster; a dedicated cluster is still worth it when hosts can be spared."),
        .clusters("mgmtCluster", "Architecture", "Management cluster", multi: false, none: "Best fit (automatic)",
                  help: "The cluster that gives up hosts (dedicated) or hosts the management appliances (consolidated). Best fit needs the fewest new hosts, then leaves the most headroom."),
        .choice("deploy", "Architecture", "VCF deployment model (not available with VVF)", VCFAppliances.Deployment.allCases.map { d in
            d.isHA ? "High availability — \(d.size)" : "Simple — single-node appliances (Small)"
        }, selected: 1, help: "Sets appliance sizes and node counts as the VCF Installer does. High availability needs at least 4 hosts. VVF is always simple mode."),
        .choice("storage", "Architecture", "Management domain principal storage", [
            "Auto — vSAN ESA if the cluster has vSAN, otherwise external",
            "vSAN ESA", "vSAN OSA", "External — FC / NFS",
        ]),
        .toggle("vcfOps", "Management components", "VCF Operations (with cloud proxy and license server; always on with VVF)", true,
                help: "The workbook leaves this out by default; VCF 9 uses VCF Operations for licensing and fleet management, so it's on here. VVF always includes VCF Operations and the license server."),
        .toggle("vcfAuto", "Management components", "VCF Automation (not available with VVF)", false),
        .choice("logs", "Management components", "Log management", ["None", "Small", "Medium", "Large"],
                help: "With VVF it needs the VCF management services and is deployed Day-N from VCF Operations."),
        .number("logReplicas", "Management components", "Log management replicas", 3, min: 1, max: 5),
        .toggle("rtm", "Management components", "Real-time metrics (not available with VVF)", false),
        .choice("edges", "Management components", "NSX Edges in the management domain, 2 nodes (not available with VVF)", ["None", "Small", "Medium", "Large", "XLarge"]),
        .number("extraCPU", "Management components", "Other management VMs — vCPU", 0, min: 0, max: 2000,
                help: "Anything else that will run in the management domain: directory, DNS, backup proxies, jump hosts."),
        .number("extraRAM", "Management components", "Other management VMs — memory", 0, min: 0, max: 20_000, step: 8, unit: "GB"),
        .number("extraDisk", "Management components", "Other management VMs — disk", 0, min: 0, max: 500_000, step: 100, unit: "GB"),
        .toggle("vvfServices", "vSphere Foundation", "VCF management services", true,
                help: "Only applies to VVF: VCF always deploys them. Fleet and SDDC lifecycle, software depot and telemetry on the VCF services runtime. Without them VVF is installed by hand (vCenter, VCF Operations, license server) and has no log management or software depot."),
        .choice("vvfVC", "vSphere Foundation", "vCenter", [
            "Existing vCenter (converge)",
            "New vCenter (Medium)",
        ], help: "Only applies to VVF: VCF always deploys a new management vCenter (workload domain vCenters have their own option). Converging keeps the vCenter that runs the clusters today; a new deployment adds a Medium vCenter, the VCF Installer's VVF default."),
        .toggle("vvfProxy", "vSphere Foundation", "Cloud proxy", false,
                help: "Only applies to VVF: with VCF it comes with VCF Operations. The VCF Installer doesn't deploy one for VVF; add it for remote collection."),
        .choice("wldGroup", "Workload domains", "Workload domains (not available with VVF)", ["One per vCenter", "One per cluster", "One for all clusters"],
                help: "Each workload domain adds its vCenter and NSX Managers to the management domain. VVF has no workload domains: the other clusters stay under their vCenters."),
        .choice("wldVC", "Workload domains", "Workload domain vCenters (not available with VVF)", [
            "New vCenter per workload domain, in the management domain",
            "Keep the existing vCenter (converge in place)",
        ]),
        .choice("wldNSX", "Workload domains", "Workload domain NSX (not available with VVF)", [
            "Dedicated NSX Managers (3 nodes) per workload domain",
            "Single NSX Manager per workload domain",
            "Share the management domain's NSX",
        ]),
        .clusters("merge", "Workload domains", "Merge these clusters into one workload cluster", multi: true, none: "None",
                  help: "Shows what consolidating smaller clusters saves: one set of failover hosts instead of one per cluster, and one workload domain."),
        .choice("basis", "Capacity", "Size existing workloads from", [
            "Measured host usage (vHost CPU and memory %)",
            "Configured vCPU and memory of the selected powered-on VMs",
        ], help: "Measured usage is the hosts' CPU and memory use, scaled to the selected VMs' share of it. Configured sizes use the selected VMs' vCPU and memory."),
        .number("mgmtRatio", "Capacity", "Management appliances — vCPU per core", 2, min: 0.5, max: 8, step: 0.5, unit: ": 1",
                help: "The workbook recommends 2:1 for a performant management domain."),
        .number("wlRatio", "Capacity", "Workloads — vCPU per core (configured sizes)", 4, min: 0.5, max: 20, step: 0.5, unit: ": 1"),
        .number("spare", "Capacity", "Host failures to tolerate", 1, min: 0, max: 3,
                help: "Hosts held back in every cluster for failures and rolling upgrades."),
        .number("maxLoad", "Capacity", "Max CPU / memory load with those hosts down", 80, min: 50, max: 100, unit: "%"),
        .number("reserve", "Capacity", "Storage — host rebuild and operations reserve (vSAN)", 30, min: 0, max: 100, unit: "%"),
        .number("growth", "Capacity", "Storage — estimated growth", 10, min: 0, max: 200, unit: "%"),
        .clusterPairs("pairs", "Advanced: HA cluster pairs", "HA cluster pairs",
                      help: "For clusters that are two sites of one stretched cluster. Each pair is sized as one cluster that survives losing a whole site, a 50:50 split, instead of losing hosts. RVTools can't see sites, so this rests on what you know about the environment."),
        .number("siteSpare", "Advanced: HA cluster pairs", "Host failures to tolerate on the surviving site", 0, min: 0, max: 3,
                help: "For HA cluster pairs only. Replaces the host failures above for those pairs."),
        .toggle("stretchMgmt", "Advanced: HA cluster pairs", "Stretch the management domain across the sites too", false,
                help: "For HA cluster pairs only. Sizes the dedicated management hosts for a site failure, with equal hosts per site. vSAN management storage doubles and needs a witness at a third site."),
        .number("coreMin", "Licensing", "Licensed cores minimum per CPU", 16, min: 1, max: 64,
                help: "VCF and VVF are licensed per core with a per-CPU minimum; the vSAN entitlement follows the licensed cores. Verify current terms."),
    ] }

    public func defaultSelection(_ inventory: Inventory) -> Set<String> {
        Set(inventory.workloadVMs.map(\.id))
    }

    // MARK: - Model

    struct Component {
        let name: String, nodes: Int, cpu: Double, ram: Double, disk: Double
        var note = ""
    }

    struct Demand {
        var cores = 0.0, ramGiB = 0.0
        static func + (a: Demand, b: Demand) -> Demand { Demand(cores: a.cores + b.cores, ramGiB: a.ramGiB + b.ramGiB) }
        var isEmpty: Bool { cores <= 0 && ramGiB <= 0 }
    }

    struct HostCap {
        let id: String, name: String, cores: Double, ramGiB: Double
        var isNew = false
        var vendor: String
        var cluster = ""
        /// Licensed cores: the per-CPU minimum applied to each socket.
        var licensed = 0.0
        /// Which side of an HA cluster pair this host is on; nil outside a pair.
        var site: Int?
    }

    struct Fit {
        var hosts: [HostCap]
        var newHosts: Int
        var load: Double
    }

    struct PeelPlan {
        let cluster: Cluster
        let mgmt: [HostCap]
        let remaining: [HostCap]
        let newHosts: Int
        let mgmtLoad: Double
        let remainingLoad: Double
    }

    struct WorkloadDomain {
        let name: String
        var clusters: [Cluster]
        var hosts: Int
        var vms: Int
        var vcSize = ""
        var nsxSize = ""
    }

    /// Worst CPU or memory load once the `spare` largest hosts are out; infinity if too few hosts remain.
    /// With hosts on two sites, either site can be lost, so each must carry everything with `siteSpare` of its hosts out.
    static func load(_ hosts: [HostCap], _ d: Demand, spare: Int, siteSpare: Int = 0) -> Double {
        if d.isEmpty { return 0 }
        if hosts.contains(where: { $0.site != nil }) {
            return [0, 1].map { side in
                load(hosts.filter { $0.site == side }.map { h in var h = h; h.site = nil; return h }, d, spare: siteSpare)
            }.max() ?? .infinity
        }
        guard hosts.count > spare else { return .infinity }
        let cores = hosts.map(\.cores).sorted(by: >).dropFirst(spare).reduce(0, +)
        let ram = hosts.map(\.ramGiB).sorted(by: >).dropFirst(spare).reduce(0, +)
        guard cores > 0, ram > 0 else { return .infinity }
        return max(d.cores / cores, d.ramGiB / ram)
    }

    /// Adds hosts like `typical` until the demand fits at `maxLoad` with at least `minHosts`.
    static func fit(_ hosts: [HostCap], _ d: Demand, typical: HostCap, minHosts: Int, spare: Int, siteSpare: Int = 0, maxLoad: Double) -> Fit {
        for k in 0...256 {
            let pool = adding(k, to: hosts, like: typical)
            let l = load(pool, d, spare: spare, siteSpare: siteSpare)
            if pool.count >= minHosts && l <= maxLoad { return Fit(hosts: pool, newHosts: k, load: l) }
        }
        return Fit(hosts: hosts, newHosts: -1, load: load(hosts, d, spare: spare, siteSpare: siteSpare))
    }

    /// New hosts like `typical`; in an HA cluster pair each goes to the site with fewer hosts, to keep the sites even.
    static func adding(_ count: Int, to hosts: [HostCap], like typical: HostCap) -> [HostCap] {
        var pool = hosts
        let sited = hosts.contains { $0.site != nil }
        for _ in 0..<max(count, 0) {
            var h = newHost(typical)
            if sited { h.site = pool.filter { $0.site == 0 }.count <= pool.filter { $0.site == 1 }.count ? 0 : 1 }
            pool.append(h)
        }
        return pool
    }

    /// One host less, or one per site in an HA cluster pair.
    static func fewer(_ hosts: [HostCap]) -> [HostCap] {
        guard hosts.contains(where: { $0.site != nil }) else { return Array(hosts.dropLast()) }
        var out = hosts
        for side in [0, 1] { if let i = out.lastIndex(where: { $0.site == side }) { out.remove(at: i) } }
        return out
    }

    static func newHost(_ typical: HostCap) -> HostCap {
        HostCap(id: "", name: "New host (like \(typical.name))", cores: typical.cores, ramGiB: typical.ramGiB, isNew: true, vendor: typical.vendor,
                licensed: typical.licensed)
    }

    /// Peels the smallest hosts off a cluster for the management domain, adding hosts like its typical one only when the
    /// management domain and the cluster's remaining workloads can't both fit.
    static func peel(_ cluster: Cluster, hosts: [HostCap], workload: Demand, hasVMs: Bool, mgmt: Demand, minMgmt: Int, minWorkload: Int,
                     spare: Int, siteSpare: Int = 0, stretchMgmt: Bool = false, maxLoad: Double) -> PeelPlan? {
        guard let typical = VCF9Sizing.typical(hosts) else { return nil }
        let wlMin = hasVMs || !workload.isEmpty ? minWorkload : 0
        let sited = hosts.contains { $0.site != nil }
        for k in 0...256 {
            var pool = adding(k, to: hosts, like: typical).sorted { ($0.ramGiB, $0.cores, $0.name) < ($1.ramGiB, $1.cores, $1.name) }
            // An HA cluster pair gives up hosts from both sites alike, so taking from the front stays even.
            if sited {
                let a = pool.filter { $0.site == 0 }, b = pool.filter { $0.site == 1 }
                // A plain loop, as older compilers time out type-checking this as a flatMap of conditional arrays.
                var alternating: [HostCap] = []
                for i in 0..<max(a.count, b.count) {
                    if i < a.count { alternating.append(a[i]) }
                    if i < b.count { alternating.append(b[i]) }
                }
                pool = alternating
            }
            guard pool.count - wlMin >= minMgmt else { continue }
            for n in minMgmt...(pool.count - wlMin) {
                if (sited || stretchMgmt) && n % 2 != 0 { continue }
                let m = pool[..<n].enumerated().map { i, h in var h = h; h.site = stretchMgmt ? i % 2 : nil; return h }
                let mLoad = load(m, mgmt, spare: spare, siteSpare: siteSpare)
                guard mLoad <= maxLoad else { continue }
                let rest = Array(pool[n...])
                let rLoad = load(rest, workload, spare: spare, siteSpare: siteSpare)
                if rLoad <= maxLoad {
                    return PeelPlan(cluster: cluster, mgmt: m, remaining: rest, newHosts: k, mgmtLoad: mLoad, remainingLoad: rLoad)
                }
                break  // giving the management domain more hosts only leaves less for the workloads
            }
        }
        return nil
    }

    /// The median host by memory, used as the model for any new hosts.
    static func typical(_ hosts: [HostCap]) -> HostCap? {
        let sorted = hosts.filter { !$0.isNew }.sorted { ($0.ramGiB, $0.cores) < ($1.ramGiB, $1.cores) }
        return sorted.isEmpty ? nil : sorted[sorted.count / 2]
    }

    static func vendor(_ cpuModel: String) -> String {
        let m = cpuModel.lowercased()
        return m.contains("amd") || m.contains("epyc") ? "AMD" : (m.contains("intel") || m.contains("xeon") ? "Intel" : "")
    }

    /// Management domain appliances, following the workbook's Management Domain Sizing tab (first instance).
    static func managementComponents(_ d: VCFAppliances.Deployment, vcfOps: Bool, vcfAuto: Bool, logs: String?, logReplicas: Int, rtm: Bool,
                                     edges: String?, mgmtNSXSize: String, extra: VCFAppliances.Spec,
                                     domains: [WorkloadDomain], newVCenters: Bool, wldNSXNodes: Int) -> [Component] {
        typealias A = VCFAppliances
        var c: [Component] = []
        c.append(Component(name: "SDDC Manager", nodes: 1, cpu: A.sddcManager.cpu, ram: A.sddcManager.ram, disk: A.sddcManager.disk))
        let vcSize = d.size
        let vc = A.vcenter[vcSize]!
        c.append(Component(name: "Management vCenter", nodes: 1, cpu: vc.cpu, ram: vc.ram, disk: A.vcenterDisk[vcSize]![d == .haLarge ? "XLarge" : "Large"]!,
                           note: "\(vcSize), \(d == .haLarge ? "XLarge" : "Large") storage"))
        let nsx = A.nsxManager[mgmtNSXSize]!
        let nsxNodes = d.isHA ? 3 : 1
        c.append(Component(name: "Management NSX Managers", nodes: nsxNodes, cpu: nsx.cpu * Double(nsxNodes), ram: nsx.ram * Double(nsxNodes),
                           disk: nsx.disk * Double(nsxNodes), note: mgmtNSXSize))
        if let edges, let e = A.nsxEdge[edges] {
            c.append(Component(name: "Management NSX Edges", nodes: 2, cpu: e.cpu * 2, ram: e.ram * 2, disk: e.disk * 2, note: edges))
        }
        c += servicesRuntime(d, logs: logs, logReplicas: logReplicas, rtm: rtm, services: ["fleet management", "identity broker", "software depot"])

        if vcfOps {
            let nodes = d == .haSmall ? 2 : (d.isHA ? 3 : 1)
            let o = A.operations[d.size]!
            c.append(Component(name: "VCF Operations", nodes: nodes, cpu: o.cpu * Double(nodes), ram: o.ram * Double(nodes), disk: o.disk * Double(nodes), note: d.size))
            let p = A.cloudProxy[d.isHA && d != .haSmall ? "Standard" : "Small"]!
            c.append(Component(name: "Cloud proxy", nodes: 1, cpu: p.cpu, ram: p.ram, disk: p.disk))
            c.append(Component(name: "License server", nodes: 1, cpu: A.licenseServer.cpu, ram: A.licenseServer.ram, disk: A.licenseServer.disk))
        }
        if vcfAuto {
            let nodes = d.isHA && d != .haSmall ? 3 : 1
            let a = A.automation[d.size]!
            c.append(Component(name: "VCF Automation", nodes: nodes, cpu: a.cpu * Double(nodes), ram: a.ram * Double(nodes), disk: a.disk * Double(nodes), note: d.size))
        }

        for wd in domains {
            if newVCenters, let v = A.vcenter[wd.vcSize] {
                c.append(Component(name: "\(wd.name) vCenter", nodes: 1, cpu: v.cpu, ram: v.ram, disk: A.vcenterDisk[wd.vcSize]!["Default"]!, note: wd.vcSize))
            }
            if wldNSXNodes > 0, let n = A.nsxManager[wd.nsxSize] {
                let k = Double(wldNSXNodes)
                c.append(Component(name: "\(wd.name) NSX Managers", nodes: wldNSXNodes, cpu: n.cpu * k, ram: n.ram * k, disk: n.disk * k, note: wd.nsxSize))
            }
        }
        if extra.cpu > 0 || extra.ram > 0 || extra.disk > 0 {
            c.append(Component(name: "Other management VMs", nodes: 0, cpu: extra.cpu, ram: extra.ram, disk: extra.disk))
        }
        return c
    }

    /// VCF services runtime control and worker nodes, following the workbook.
    static func servicesRuntime(_ d: VCFAppliances.Deployment, logs: String?, logReplicas: Int, rtm: Bool, services: [String]) -> [Component] {
        typealias A = VCFAppliances
        let ctl = A.runtimeControl[d.size]!
        let ctlNodes = d.isHA ? 3 : 1
        // Workers: enough nodes for the Day-0 services plus any Day-N services (with the workbook's 9% CPU and 20% RAM
        // allowances), plus one — except where the workbook's HA Medium profile already has the headroom.
        let w = A.runtimeWorker[d]!
        let day0 = A.runtimeServices[d]!
        var dayN = (cpu: 0.0, ram: 0.0, disk: 0.0)
        if let logs, let l = A.logs[logs] {
            dayN.cpu += l.cpu * Double(logReplicas); dayN.ram += l.ram * Double(logReplicas); dayN.disk += l.disk * Double(logReplicas)
        }
        if rtm, let r = A.realTimeMetrics[d] { dayN.cpu += r.cpu; dayN.ram += r.ram; dayN.disk += r.disk }
        let ramNeed = ((dayN.ram + day0.ram) * 1.2).rounded(.up)
        let cpuNeed = ((dayN.cpu + day0.cpu) * 1.09).rounded(.up)
        let nodesRAM = Int((ramNeed / w.ram).rounded(.up)) + (d == .haMedium ? 0 : 1)
        let nodesCPU = Int((cpuNeed / w.cpu).rounded(.up)) + ((logs != nil || rtm) && d == .haMedium ? 0 : 1)
        let workers = max(nodesRAM, nodesCPU)
        var services = services
        if logs != nil { services.append("log management") }
        if rtm { services.append("real-time metrics") }
        return [
            Component(name: "VCF services runtime — control nodes", nodes: ctlNodes, cpu: ctl.cpu * Double(ctlNodes), ram: ctl.ram * Double(ctlNodes),
                      disk: ctl.disk * Double(ctlNodes)),
            Component(name: "VCF services runtime — worker nodes", nodes: workers, cpu: w.cpu * Double(workers), ram: w.ram * Double(workers),
                      disk: w.disk + dayN.disk, note: services.joined(separator: ", ")),
        ]
    }

    /// vSphere Foundation components as the VCF Installer deploys them: no SDDC Manager, NSX, VCF Automation or workload
    /// domains. The services runtime uses the workbook's simple profile; its Day-0 figures include VCF-only services
    /// (identity broker, Salt), which only adds headroom.
    static func vvfComponents(newVCenter: Bool, services: Bool, proxy: Bool, logs: String?, logReplicas: Int, extra: VCFAppliances.Spec) -> [Component] {
        typealias A = VCFAppliances
        var c: [Component] = []
        if newVCenter {
            let vc = A.vcenter[A.vvfVCenterSize]!
            c.append(Component(name: "vCenter", nodes: 1, cpu: vc.cpu, ram: vc.ram, disk: A.vcenterDisk[A.vvfVCenterSize]!["Large"]!,
                               note: "\(A.vvfVCenterSize), Large storage"))
        }
        let o = A.operations[A.vvfOperationsSize]!
        c.append(Component(name: "VCF Operations", nodes: 1, cpu: o.cpu, ram: o.ram, disk: o.disk, note: "\(A.vvfOperationsSize), single node"))
        if proxy {
            let p = A.cloudProxy["Small"]!
            c.append(Component(name: "Cloud proxy", nodes: 1, cpu: p.cpu, ram: p.ram, disk: p.disk))
        }
        c.append(Component(name: "License server", nodes: 1, cpu: A.licenseServer.cpu, ram: A.licenseServer.ram, disk: A.licenseServer.disk))
        if services {
            c += servicesRuntime(.simple, logs: logs, logReplicas: logReplicas, rtm: false,
                                 services: ["fleet and SDDC lifecycle", "software depot", "telemetry"])
        }
        if extra.cpu > 0 || extra.ram > 0 || extra.disk > 0 {
            c.append(Component(name: "Other management VMs", nodes: 0, cpu: extra.cpu, ram: extra.ram, disk: extra.disk))
        }
        return c
    }

    // MARK: - Run

    public func run(vms: [VM], inventory inv: Inventory, params p: Params) -> SolutionResult {
        typealias A = VCFAppliances
        let vvf = p.choice("edition") == 1
        let edition = vvf ? "VVF" : "VCF"
        // "Recommended" (and anything unknown) follows the edition: dedicated for VCF, consolidated for VVF.
        let dedicated = p.choice("arch") == 0 || (p.choice("arch") > 1 && !vvf)
        let deploy: A.Deployment = vvf ? .simple : (A.Deployment(rawValue: p.choice("deploy")) ?? .haSmall)
        let mgmtTerm = vvf ? "management cluster" : "management domain"
        let mgmtArea = vvf ? "Management cluster" : "Management domain"
        let wldArea = vvf ? "Workload clusters" : "Workload domains"
        let coreMin = max(p.num("coreMin"), 1)
        let spare = Int(p.num("spare"))
        let maxLoad = max(p.num("maxLoad"), 1) / 100
        let mgmtRatio = max(p.num("mgmtRatio"), 0.1), wlRatio = max(p.num("wlRatio"), 0.1)
        let measured = p.choice("basis") == 0
        let reserve = p.num("reserve") / 100, growth = p.num("growth") / 100
        let wldNSX = p.choice("wldNSX")
        let newVCenters = !vvf && p.choice("wldVC") == 0
        let siteSpare = Int(p.num("siteSpare"))

        // Resolve a stored cluster (id, or a name from the CLI).
        func resolve(_ ref: String) -> Cluster? {
            inv.clusters.first { $0.id == ref } ?? inv.clusters.first { $0.name.lowercased() == ref.lowercased() && !$0.isStandalone }
        }

        let realHosts = inv.hosts.filter { !$0.isVirtual }
        var hostsByCluster = Dictionary(grouping: realHosts, by: \.clusterKey)
        var vmsByCluster = Dictionary(grouping: vms, by: \.clusterKey)
        var picked = p.names("mgmtCluster").first.flatMap(resolve)
        let scopeIDs = Set(vms.map(\.clusterKey)).union(picked.map { [$0.id] } ?? [])
        var clusters = inv.clusters.filter { scopeIDs.contains($0.id) && !$0.isStandalone && !(hostsByCluster[$0.id] ?? []).isEmpty }
            .sorted { ($0.vcenter.lowercased(), $0.name.lowercased()) < ($1.vcenter.lowercased(), $1.name.lowercased()) }

        var memberIDs: [String: [String]] = [:]
        /// One cluster everywhere from several: a management candidate (peeled or consolidated) and a workload cluster,
        /// with their hosts and workloads combined.
        func combine(_ parts: [Cluster], id: String, name: String) -> Cluster {
            var m = Cluster(id: id)
            m.name = name
            var vcs: [String] = []
            for c in parts where !vcs.contains(c.vcenter) { vcs.append(c.vcenter) }
            m.vcenter = vcs.joined(separator: " + ")
            m.vmCount = parts.reduce(0) { $0 + $1.vmCount }
            m.hostCount = parts.reduce(0) { $0 + $1.hostCount }
            hostsByCluster[m.id] = parts.flatMap { hostsByCluster[$0.id] ?? [] }
            vmsByCluster[m.id] = parts.flatMap { vmsByCluster[$0.id] ?? [] }
            memberIDs[m.id] = parts.map(\.id)
            let ids = Set(parts.map(\.id))
            clusters = clusters.filter { !ids.contains($0.id) } + [m]
            if let pk = picked, ids.contains(pk.id) { picked = m }
            return m
        }

        // HA cluster pairs: two clusters that are the sites of one stretched cluster, sized to survive losing a site.
        // A side needn't have selected VMs: the passive site still brings its hosts.
        let pairRefs = p.names("pairs")
        var pairs: [(cluster: Cluster, a: Cluster, b: Cluster, refs: [String])] = []
        var paired = Set<String>()
        var siteByCluster: [String: Int] = [:]
        for i in stride(from: 0, to: pairRefs.count - 1, by: 2) {
            guard let a = resolve(pairRefs[i]), let b = resolve(pairRefs[i + 1]), a.id != b.id, !paired.contains(a.id), !paired.contains(b.id),
                  ![a, b].contains(where: { $0.isStandalone || (hostsByCluster[$0.id] ?? []).isEmpty }) else { continue }
            paired.formUnion([a.id, b.id])
            siteByCluster[a.id] = 0
            siteByCluster[b.id] = 1
            let m = combine([a, b], id: "pair|\(a.id),\(b.id)", name: "\(a.name) ↔ \(b.name)")
            pairs.append((m, a, b, [pairRefs[i], pairRefs[i + 1]]))
        }
        func isPair(_ c: Cluster) -> Bool { pairs.contains { $0.cluster.id == c.id } }
        let stretchMgmt = !pairs.isEmpty && p.flag("stretchMgmt")
        /// What a load figure assumes is down.
        func downShort(_ hosts: [HostCap]) -> String {
            guard hosts.contains(where: { $0.site != nil }) else { return "\(spare) down" }
            return "a site" + (siteSpare > 0 ? " and \(siteSpare) more host(s)" : "") + " down"
        }

        // Clusters to merge are sized as one cluster.
        let mergeIDs = Set(p.names("merge").compactMap(resolve).map(\.id)).subtracting(paired)
        let mergeMembers = inv.clusters.filter { mergeIDs.contains($0.id) && !$0.isStandalone && !(hostsByCluster[$0.id] ?? []).isEmpty }
            .sorted { ($0.vcenter.lowercased(), $0.name.lowercased()) < ($1.vcenter.lowercased(), $1.name.lowercased()) }
        let mergedCluster = mergeMembers.count > 1
            ? combine(mergeMembers, id: "merged|" + mergeMembers.map(\.id).joined(separator: ","), name: mergeMembers.map(\.name).joined(separator: " + "))
            : nil
        func members(_ c: Cluster) -> [String] { memberIDs[c.id] ?? [c.id] }
        /// A reference for navigation; a merged cluster has no single object to open.
        func cref(_ c: Cluster, _ detail: String = "") -> AffectedObject {
            AffectedObject(kind: memberIDs[c.id] == nil ? .cluster : .other, id: c.id, name: c.name, detail: detail)
        }
        func onCluster(_ d: Datastore, _ c: Cluster) -> Bool { d.clusterKeys.contains(where: members(c).contains) }

        func caps(_ c: Cluster) -> [HostCap] {
            (hostsByCluster[c.id] ?? []).filter { !$0.inferred && $0.cores > 0 && $0.memoryMiB > 0 }
                .map { HostCap(id: $0.id, name: $0.name, cores: Double($0.cores), ramGiB: $0.memoryMiB / 1024, vendor: VCF9Sizing.vendor($0.cpuModel), cluster: $0.cluster,
                               licensed: $0.sockets > 0 ? Double($0.sockets) * max(coreMin, Double($0.coresPerSocket)) : max(coreMin, Double($0.cores)),
                               site: siteByCluster[$0.clusterKey]) }
        }
        var basisFallback: [String] = []
        func workload(_ c: Cluster) -> Demand {
            let configured: Demand = {
                let running = (vmsByCluster[c.id] ?? []).filter(\.isRunning)
                return Demand(cores: Double(running.reduce(0) { $0 + $1.cpus }) / wlRatio, ramGiB: running.reduce(0) { $0 + $1.memoryMiB } / 1024)
            }()
            guard measured else { return configured }
            let hs = (hostsByCluster[c.id] ?? []).filter { !$0.inferred }
            let d = Demand(cores: hs.reduce(0) { $0 + Double($1.cores) * $1.cpuUsagePct / 100 },
                           ramGiB: hs.reduce(0) { $0 + $1.memoryMiB / 1024 * $1.memUsagePct / 100 })
            if d.isEmpty && !configured.isEmpty { basisFallback.append(c.name); return configured }
            // Host usage covers every VM on the hosts; keep the selected VMs' share of it, from each VM's own measured
            // CPU and consumed memory (vCPU / vMemory tabs), or its configured size when those aren't in the export.
            let selected = (vmsByCluster[c.id] ?? []).filter(\.isRunning)
            let all = inv.vms.filter { $0.isVM && $0.isRunning && members(c).contains($0.clusterKey) }
            func share(_ value: (VM) -> Double) -> Double? {
                let total = all.reduce(0) { $0 + value($1) }
                return total > 0 ? min(1, selected.reduce(0) { $0 + value($1) } / total) : nil
            }
            let cpuShare = share(\.cpuUsageMHz) ?? share { Double($0.cpus) } ?? 1
            let memShare = share(\.memConsumedMiB) ?? share(\.memoryMiB) ?? 1
            return Demand(cores: d.cores * cpuShare, ramGiB: d.ramGiB * memShare)
        }

        // Storage type decides the minimum cluster sizes.
        func hasVSAN(_ c: Cluster) -> Bool { inv.datastores.contains { $0.type.lowercased() == "vsan" && onCluster($0, c) } }
        func storageKind(_ c: Cluster?) -> Int {   // 1 ESA, 2 OSA, 3 external
            let s = p.choice("storage")
            if s > 0 { return s }
            return c.map(hasVSAN) == true ? 1 : 3
        }
        func evenUp(_ n: Int) -> Int { n + n % 2 }
        // Stretched over vSAN, VCF 9.1's design guide wants 8 hosts for a Highly Available management domain and 6 for a workload cluster.
        func minMgmt(_ kind: Int, stretched: Bool = false) -> Int {
            let single = deploy.isHA ? 4 : (kind == 3 ? 2 : 3)
            return stretched ? (kind != 3 && deploy.isHA ? 8 : evenUp(single)) : single
        }
        // VVF clusters stay under their vCenter, so only vSAN sets a minimum there.
        func minWorkload(_ c: Cluster) -> Int {
            let single = hasVSAN(c) ? 3 : (vvf ? 1 : 2)
            return isPair(c) ? (hasVSAN(c) && !vvf ? 6 : evenUp(single)) : single
        }

        // Workload domains and their appliances (independent of which hosts the management domain takes).
        func domains(excluding mgmtCluster: Cluster?) -> [WorkloadDomain] {
            let rest = clusters.filter { $0.id != mgmtCluster?.id }
            var groups: [(String, [Cluster])] = []
            switch vvf ? 0 : p.choice("wldGroup") {
            case 1: groups += rest.map { ($0.name, [$0]) }
            case 2: if !rest.isEmpty { groups.append(("Workload domain", rest)) }
            default:
                var order: [String] = []
                let byVC = Dictionary(grouping: rest) { $0.vcenter.lowercased() }
                for c in rest where !order.contains(c.vcenter.lowercased()) { order.append(c.vcenter.lowercased()) }
                groups += order.map { vc in (byVC[vc]!.first!.vcenter, byVC[vc]!) }
            }
            return groups.enumerated().map { i, g in
                let hosts = g.1.reduce(0) { $0 + (hostsByCluster[$1.id]?.count ?? 0) }
                let count = g.1.reduce(0) { $0 + max($1.vmCount, vmsByCluster[$1.id]?.count ?? 0) }
                var d = WorkloadDomain(name: vvf ? g.0 : String(format: "w%02d", i + 1) + " · " + g.0, clusters: g.1, hosts: hosts, vms: count)
                d.vcSize = A.vcenterSize(hosts: hosts, vms: count)
                d.nsxSize = A.nsxSize(hosts: hosts, clusters: g.1.count)
                return d
            }
        }

        /// Appliances and workload domains; a consolidated management cluster isn't a workload domain.
        func components(consolidatedOn mgmtCluster: Cluster?, mgmtHosts: Int) -> ([Component], [WorkloadDomain]) {
            let wds = domains(excluding: mgmtCluster)
            var nsxSize = deploy == .haLarge ? "Large" : "Medium"
            if wldNSX == 2 {   // shared: the management NSX also carries every workload cluster
                nsxSize = A.larger(nsxSize, A.nsxSize(hosts: mgmtHosts + wds.reduce(0) { $0 + $1.hosts },
                                                      clusters: 1 + wds.reduce(0) { $0 + $1.clusters.count }))
            }
            let logs = ["", "Small", "Medium", "Large"][min(p.choice("logs"), 3)]
            if vvf {
                let services = p.flag("vvfServices")
                return (VCF9Sizing.vvfComponents(newVCenter: p.choice("vvfVC") == 1, services: services, proxy: p.flag("vvfProxy"),
                                                 logs: services && !logs.isEmpty ? logs : nil, logReplicas: max(Int(p.num("logReplicas")), 1),
                                                 extra: A.Spec(p.num("extraCPU"), p.num("extraRAM"), p.num("extraDisk"))), wds)
            }
            let edges = ["", "Small", "Medium", "Large", "XLarge"][min(p.choice("edges"), 4)]
            let comps = VCF9Sizing.managementComponents(
                deploy, vcfOps: p.flag("vcfOps"), vcfAuto: p.flag("vcfAuto"), logs: logs.isEmpty ? nil : logs,
                logReplicas: max(Int(p.num("logReplicas")), 1), rtm: p.flag("rtm"), edges: edges.isEmpty ? nil : edges, mgmtNSXSize: nsxSize,
                extra: A.Spec(p.num("extraCPU"), p.num("extraRAM"), p.num("extraDisk")),
                domains: wds, newVCenters: newVCenters, wldNSXNodes: [3, 1, 0][min(wldNSX, 2)])
            return (comps, wds)
        }

        func mgmtDemand(_ comps: [Component]) -> Demand {
            Demand(cores: comps.reduce(0) { $0 + $1.cpu } / mgmtRatio, ramGiB: comps.reduce(0) { $0 + $1.ram })
        }

        // Evaluate every candidate cluster both ways. The appliances don't depend on the candidate in dedicated mode;
        // in consolidated mode the candidate stops being a workload domain.
        struct Candidate {
            let cluster: Cluster
            let hosts: [HostCap]
            let workload: Demand
            let currentLoad: Double
            let peel: PeelPlan?
            let consolidated: Fit
            let comps: [Component]
            let domains: [WorkloadDomain]
        }
        let candidates: [Candidate] = clusters.compactMap { c in
            let hs = caps(c)
            guard let typical = VCF9Sizing.typical(hs) else { return nil }
            let wl = workload(c)
            let kind = storageKind(c)
            let ded = components(consolidatedOn: nil, mgmtHosts: minMgmt(kind, stretched: stretchMgmt))
            let plan = VCF9Sizing.peel(c, hosts: hs, workload: wl, hasVMs: !(vmsByCluster[c.id] ?? []).isEmpty, mgmt: mgmtDemand(ded.0),
                                       minMgmt: minMgmt(kind, stretched: stretchMgmt), minWorkload: minWorkload(c), spare: spare, siteSpare: siteSpare,
                                       stretchMgmt: stretchMgmt, maxLoad: maxLoad)
            let con = components(consolidatedOn: c, mgmtHosts: hs.count)
            let fit = VCF9Sizing.fit(hs, wl + mgmtDemand(con.0), typical: typical, minHosts: minMgmt(kind, stretched: isPair(c)), spare: spare, siteSpare: siteSpare, maxLoad: maxLoad)
            let (comps, wds) = dedicated ? ded : con
            return Candidate(cluster: c, hosts: hs, workload: wl, currentLoad: VCF9Sizing.load(hs, wl, spare: spare, siteSpare: siteSpare), peel: plan,
                             consolidated: fit, comps: comps, domains: wds)
        }

        let unknownHosts = clusters.flatMap { c in (hostsByCluster[c.id] ?? []).filter { $0.inferred || $0.cores == 0 || $0.memoryMiB == 0 } }
        guard !candidates.isEmpty else {
            return SolutionResult(headline: "No clusters with host capacity in scope", sections: [
                .notes("Nothing to size", [
                    clusters.isEmpty ? "Select VMs that run in a cluster on the Select VMs step." :
                        "The clusters behind the selected VMs have no host cores or memory in this export (vHost tab missing?).",
                ]),
            ])
        }

        func peelRank(_ c: Candidate) -> (Int, Double, Int) {
            guard let plan = c.peel else { return (Int.max, .infinity, 0) }
            return (plan.newHosts, plan.remainingLoad, -c.hosts.count)
        }
        func consRank(_ c: Candidate) -> (Int, Double, Int) {
            (c.consolidated.newHosts < 0 ? Int.max : c.consolidated.newHosts, c.consolidated.load, -c.hosts.count)
        }
        let bestPeel = candidates.min { peelRank($0) < peelRank($1) }!
        let bestCons = candidates.min { consRank($0) < consRank($1) }!
        let best = dedicated ? bestPeel : bestCons
        let chosen = picked.flatMap { pk in candidates.first { $0.cluster.id == pk.id } } ?? best
        let isAuto = picked == nil || chosen.cluster.id != picked?.id

        let comps = chosen.comps
        let wds = chosen.domains
        let mgmt = mgmtDemand(comps)
        let totCPU = comps.reduce(0) { $0 + $1.cpu }, totRAM = comps.reduce(0) { $0 + $1.ram }, totDisk = comps.reduce(0) { $0 + $1.disk }
        let kind = storageKind(chosen.cluster)
        let storageName = ["", "vSAN ESA", "vSAN OSA", "external (FC / NFS)"][kind]

        // Workbook storage: VM disk + swap, vSAN protection (FTT=1), rebuild / operations reserve, growth.
        let interim = totDisk + totRAM
        // Stretched over vSAN, each site holds a full copy.
        let mgmtStretched = dedicated ? stretchMgmt : isPair(chosen.cluster)
        // Rounded up at each step, as the workbook does.
        let protected = ((kind == 1 ? interim * 1.5 : (kind == 2 ? interim * 2 : interim)) * (mgmtStretched && kind != 3 ? 2 : 1)).rounded(.up)
        let reserved = kind == 3 ? protected : (protected * (1 + reserve)).rounded(.up)
        let storageGB = (reserved * (1 + growth)).rounded(.up)
        let storageMiB = storageGB * 1024   // the workbook's GB are treated as GiB, like the host memory it sizes against

        var b = CheckBuilder()
        var sections: [SolutionSection] = []
        var headline = ""
        var newHostsTotal = 0

        // One-click alternatives offered with the results.
        let dedicatedNew = chosen.peel?.newHosts ?? Int.max
        let toConsolidated: [SolutionAction] = bestCons.consolidated.newHosts >= 0 && bestCons.consolidated.newHosts < dedicatedNew ? [
            SolutionAction("Switch to consolidated on \(bestCons.cluster.name) — " + (bestCons.consolidated.newHosts == 0
                                ? "fits on its \(bestCons.consolidated.hosts.count) hosts" : "needs \(bestCons.consolidated.newHosts) new host(s)"),
                           help: "Sets Management domain to Consolidated and the management cluster to best fit.",
                           set: ["arch": .choice(1), "mgmtCluster": .names([])]),
        ] : []
        let toDedicated: [SolutionAction] = bestPeel.peel.map { plan in [
            SolutionAction("Switch to dedicated — " + (plan.newHosts == 0 ? "\(bestPeel.cluster.name) can spare \(plan.mgmt.count) hosts"
                                                                          : "needs \(plan.newHosts) new host(s)"),
                           help: "Sets Management domain to Dedicated and the management cluster to best fit.",
                           set: ["arch": .choice(0), "mgmtCluster": .names([])]),
        ] } ?? []
        // A dedicated management domain is the recommended design; a consolidated one is pushed towards it when hosts can be spared.
        let dedicatedFits = bestPeel.peel?.newHosts == 0
        let recommendation = vvf
            ? "A dedicated management cluster is still recommended for VVF where hosts can be spared: VCF Operations and the services runtime don't compete with workloads, and maintenance on the workload clusters doesn't touch them. VVF's footprint is small, so consolidated is a sound default."
            : "A dedicated management domain is the recommended VCF design: the management appliances don't compete with workloads for CPU and memory, and management and workload domains are upgraded, patched and scaled independently. Consolidate only when the hosts can't be spared."
        let greenTitle = vvf ? "Dedicated management cluster capacity" : "Greenfield management domain capacity"
        let greenBuild = vvf ? "a dedicated management cluster" : "a greenfield management domain build"
        let greenShort: CheckStatus = vvf ? .warning : .blocker

        // MARK: Management domain hosts
        let mgmtHostList: [HostCap]
        let mgmtLoad: Double
        let greenfieldOK = chosen.peel.map { $0.newHosts == 0 } ?? false
        if dedicated {
            if let plan = chosen.peel {
                mgmtHostList = plan.mgmt
                mgmtLoad = plan.mgmtLoad
                newHostsTotal += plan.newHosts
                let taken = plan.mgmt.filter { !$0.isNew }.count
                if plan.newHosts == 0 {
                    b.add("mgmt.greenfield", mgmtArea, greenTitle, .ready,
                          "\(taken) hosts from \(chosen.cluster.name) run the \(mgmtTerm) at \(Fmt.pct(plan.mgmtLoad * 100)) with \(downShort(plan.mgmt)); the other \(plan.remaining.count) carry its workloads at \(Fmt.pct(plan.remainingLoad * 100))" + (isPair(chosen.cluster) ? " with \(downShort(plan.remaining))" : ""))
                    headline = (vvf ? "Dedicated management cluster fits" : "Greenfield management domain fits") + ": \(taken) hosts from \(chosen.cluster.name), no new hosts"
                } else {
                    let forMgmt = plan.mgmt.filter(\.isNew).count
                    let split = [forMgmt > 0 ? "\(forMgmt) for the \(mgmtTerm)" : "", plan.newHosts - forMgmt > 0 ? "\(plan.newHosts - forMgmt) for \(chosen.cluster.name)" : ""]
                        .filter { !$0.isEmpty }.joined(separator: ", ")
                    // When the minimum host count, not the appliances, sets the size, say so: the hosts look mostly idle otherwise.
                    let minHosts = minMgmt(kind, stretched: stretchMgmt)
                    let capacityHosts = VCF9Sizing.fit([], mgmt, typical: VCF9Sizing.typical(chosen.hosts)!, minHosts: 1, spare: spare, maxLoad: maxLoad).newHosts
                    let byMinimum = forMgmt > 0 && plan.mgmt.count == minHosts && capacityHosts >= 0 && capacityHosts < minHosts
                    let minimumNote = byMinimum
                        ? "; the \(mgmtTerm) needs at least \(minHosts) hosts \(deploy.isHA ? "for the High availability deployment" : "on \(storageName)"), though its appliances alone would fit on \(capacityHosts)"
                        : ""
                    b.add("mgmt.greenfield", mgmtArea, greenTitle, greenShort,
                          "Not enough capacity for \(greenBuild): \(plan.newHosts) new host(s) needed (\(split)) — " + (taken == 0 ? "\(chosen.cluster.name) can't spare any of its \(chosen.hosts.count) hosts" : "\(chosen.cluster.name) can spare \(taken) of its \(chosen.hosts.count) hosts") + minimumNote,
                          remediation: "Free capacity on the other hosts (migrate or retire VMs), add hosts, or use a consolidated \(mgmtTerm)."
                              + (byMinimum && deploy.isHA ? " The Simple deployment model has a lower host minimum." : ""),
                          affected: [cref(chosen.cluster, "workloads need \(Fmt.pct(chosen.currentLoad * 100)) of today's hosts with \(downShort(chosen.hosts))")],
                          actions: toConsolidated)
                    headline = "Not enough capacity for \(greenBuild) — \(plan.newHosts) new host(s) needed (\(split))"
                }
            } else {
                mgmtHostList = []
                mgmtLoad = .infinity
                b.add("mgmt.greenfield", mgmtArea, greenTitle, greenShort,
                      "Not enough capacity for \(greenBuild) on \(chosen.cluster.name)", actions: toConsolidated)
                headline = "Not enough capacity for \(greenBuild)"
            }
        } else {
            let f = chosen.consolidated
            mgmtHostList = f.hosts
            mgmtLoad = f.load
            newHostsTotal += max(f.newHosts, 0)
            b.add("mgmt.consolidated", mgmtArea, "Consolidated \(mgmtTerm) capacity", f.newHosts == 0 ? .ready : .warning,
                  f.newHosts == 0
                    ? "\(chosen.cluster.name) runs the management appliances and its workloads at \(Fmt.pct(f.load * 100)) with \(isPair(chosen.cluster) ? downShort(f.hosts) : "\(spare) host(s) down")"
                    : "\(chosen.cluster.name) needs \(f.newHosts) more host(s) to run the management appliances alongside its workloads",
                  remediation: f.newHosts == 0 ? "" : "Add hosts, reduce the workloads, or choose a larger cluster.")
            // VVF: consolidated is the default; a dedicated cluster is only raised when the consolidated cluster runs tight.
            let tight = f.newHosts != 0 || f.load > maxLoad - 0.1
            if vvf, let plan = bestPeel.peel, tight {
                b.add("mgmt.recommend", mgmtArea, "Dedicated management cluster worth considering", .info,
                      plan.newHosts == 0
                        ? "\(chosen.cluster.name) runs tight with the management appliances; \(bestPeel.cluster.name) can give up \(plan.mgmt.count) hosts for a dedicated management cluster and still carry its workloads at \(Fmt.pct(plan.remainingLoad * 100)) with \(spare) down"
                        : "\(chosen.cluster.name) runs tight with the management appliances; a dedicated management cluster needs \(plan.newHosts) new host(s)",
                      remediation: recommendation, actions: toDedicated)
            } else if !vvf, let plan = bestPeel.peel {
                b.add("mgmt.recommend", mgmtArea, "Dedicated management domain recommended", dedicatedFits ? .warning : .info,
                      dedicatedFits
                        ? "\(bestPeel.cluster.name) can give up \(plan.mgmt.count) hosts for a dedicated management domain and still carry its workloads at \(Fmt.pct(plan.remainingLoad * 100)) with \(spare) down — no new hosts needed"
                        : "A dedicated management domain needs \(plan.newHosts) new host(s): \(bestPeel.cluster.name) can't spare enough hosts and still carry its workloads",
                      remediation: recommendation, actions: toDedicated)
            }
            headline = f.newHosts == 0
                ? "Consolidated: management and workloads on \(chosen.cluster.name) (\(f.hosts.count) hosts, \(Fmt.pct(f.load * 100)) with \(downShort(f.hosts)))"
                : "Consolidated on \(chosen.cluster.name) needs \(f.newHosts) more host(s)"
        }

        // Management storage against what the chosen hosts bring.
        if kind == 3 {
            let shared = inv.datastores.filter { onCluster($0, chosen.cluster) && $0.type.lowercased() != "vsan" && Set($0.hostKeys).count > 1 }
            let largest = shared.map(\.freeMiB).max() ?? 0
            b.add("mgmt.storage", mgmtArea, "\(mgmtArea) storage", largest >= storageMiB ? .info : .warning,
                  "\(Fmt.capacity(mib: storageMiB)) needed on the principal datastore; largest shared datastore on \(chosen.cluster.name) has \(Fmt.capacity(mib: largest)) free",
                  remediation: "A new \(mgmtTerm) on external storage needs its own principal datastore presented to the new hosts.")
        } else if case let vsan = inv.datastores.filter({ $0.type.lowercased() == "vsan" && onCluster($0, chosen.cluster) }), !vsan.isEmpty, chosen.hosts.count > 0 {
            let capacityMiB = vsan.reduce(0) { $0 + $1.capacityMiB }, freeMiB = vsan.reduce(0) { $0 + $1.freeMiB }
            let dsName = vsan.map(\.name).joined(separator: ", ")
            let perHost = capacityMiB / Double(chosen.hosts.count)
            let mgmtRaw = perHost * Double(mgmtHostList.count)
            b.add("mgmt.storage", mgmtArea, "\(mgmtArea) vSAN capacity", mgmtRaw >= storageMiB ? .ready : .warning,
                  "\(Fmt.capacity(mib: storageMiB)) needed; \(mgmtHostList.count) hosts bring about \(Fmt.capacity(mib: mgmtRaw)) of raw vSAN (from \(dsName))",
                  remediation: "Add capacity devices to the management hosts, or plan more hosts.")
            if dedicated, let plan = chosen.peel {
                let usedMiB = capacityMiB - freeMiB
                let left = perHost * Double(plan.remaining.count) * (1 - reserve)
                b.add("mgmt.donorvsan", mgmtArea, "vSAN left for \(chosen.cluster.name)", usedMiB <= left ? .ready : .warning,
                      "\(Fmt.capacity(mib: usedMiB)) used today; \(plan.remaining.count) remaining hosts give about \(Fmt.capacity(mib: left)) after the \(SFmt.num(reserve * 100))% reserve",
                      remediation: "Taking hosts out of a vSAN cluster takes their disks too: free space first or add capacity.")
            }
        } else {
            b.add("mgmt.storage", mgmtArea, "\(mgmtArea) vSAN capacity", .info,
                  "\(Fmt.capacity(mib: storageMiB)) of \(storageName) needed; \(chosen.cluster.name) has no vSAN datastore to compare against",
                  remediation: "The management hosts need local capacity devices on the vSAN ESA / OSA compatibility list.")
        }
        if kind != 3 {
            b.add("mgmt.esa", mgmtArea, "vSAN device eligibility", .info, "The export doesn't list host disks — confirm the management hosts' devices are certified for \(storageName)",
                  remediation: "vSAN ESA needs NVMe devices from the vSAN ESA ReadyNode / compatibility list.")
        }

        // MARK: Workload clusters
        // Merged clusters are sized as one cluster: one set of failover hosts instead of one per cluster.
        let candidateByID = Dictionary(candidates.map { ($0.cluster.id, $0) }, uniquingKeysWith: { a, _ in a })
        func liveHosts(_ c: Candidate) -> [HostCap] { dedicated && c.cluster.id == chosen.cluster.id ? (chosen.peel?.remaining ?? c.hosts) : c.hosts }
        /// Hosts the demand needs: drop the largest spare capacity while it still fits, or add hosts until it does.
        func hostsNeeded(_ hs: [HostCap], _ d: Demand, min: Int, typical: HostCap) -> (need: Int, fit: Fit) {
            let f = VCF9Sizing.fit(hs, d, typical: typical, minHosts: min, spare: spare, siteSpare: siteSpare, maxLoad: maxLoad)
            guard f.newHosts == 0 else { return (f.hosts.count, f) }
            var trimmed = hs.sorted { ($0.ramGiB, $0.cores) > ($1.ramGiB, $1.cores) }
            while case let next = VCF9Sizing.fewer(trimmed), next.count >= min, next.count < trimmed.count, VCF9Sizing.load(next, d, spare: spare, siteSpare: siteSpare) <= maxLoad { trimmed = next }
            return (trimmed.count, f)
        }

        struct Unit { let name: String, domain: String, ref: AffectedObject, hosts: [HostCap], demand: Demand, min: Int, typical: HostCap, note: String }
        var units: [Unit] = []
        for wd in wds {
            for c in wd.clusters {
                guard let cand = candidateByID[c.id] else { continue }
                units.append(Unit(name: c.name, domain: wd.name, ref: cref(c), hosts: liveHosts(cand), demand: cand.workload, min: minWorkload(c),
                                  typical: VCF9Sizing.typical(cand.hosts)!, note: dedicated && c.id == chosen.cluster.id ? " (after peel)" : ""))
            }
        }
        let siteDownText = downShort([HostCap(id: "", name: "", cores: 0, ramGiB: 0, vendor: "", site: 0)])
        let pairsDown = pairs.isEmpty ? "" : " (HA pairs: \(siteDownText))"
        var clusterRows: [[String]] = []
        var overloaded: [AffectedObject] = []
        var small: [AffectedObject] = []
        var planHosts = mgmtHostList   // every host in the plan, new ones included, for licensing
        for u in units {
            let (need, f) = hostsNeeded(u.hosts, u.demand, min: u.min, typical: u.typical)
            planHosts += f.hosts
            let l = VCF9Sizing.load(u.hosts, u.demand, spare: spare, siteSpare: siteSpare)
            let obj = u.ref
            if f.newHosts > 0 {
                newHostsTotal += f.newHosts
                overloaded.append(AffectedObject(kind: obj.kind, id: obj.id, name: obj.name, detail: "\(l.isFinite ? Fmt.pct(l * 100) : "no failover host") with \(downShort(u.hosts)) — add \(f.newHosts)"))
            }
            if u.hosts.count < u.min {
                small.append(AffectedObject(kind: obj.kind, id: obj.id, name: obj.name, detail: "\(u.hosts.count) hosts, \(u.min) minimum"))
            }
            let surplus = u.hosts.count - need
            let status = f.newHosts > 0 ? "Add \(f.newHosts) host(s)" : (surplus > 0 ? "\(surplus) host(s) spare" : "Fits")
            let added = u.hosts.filter(\.isNew).count
            clusterRows.append([u.name, u.domain, "\(u.hosts.count - added)" + (added > 0 ? " + \(added) new" : "") + u.note, SFmt.num(u.demand.cores.rounded()), SFmt.num(u.demand.ramGiB.rounded()),
                                l.isFinite ? Fmt.pct(l * 100) : "—", status])
        }
        let clusterRefs: [AffectedObject?] = units.map { $0.ref.kind == .cluster ? $0.ref : nil }
        b.list("wld.capacity", wldArea, "Workload cluster capacity", .warning, noun: "clusters are over \(SFmt.num(maxLoad * 100))% with \(spare) host(s) down" + pairsDown,
               affected: overloaded, ready: "Every workload cluster fits with \(spare) host(s) down" + pairsDown,
               remediation: "Add hosts, rebalance VMs between clusters, or merge clusters so they share failover capacity.")
        b.list("wld.size", wldArea, "Workload cluster minimum size", .warning, noun: "clusters below the \(edition) minimum", affected: small,
               ready: "Every workload cluster meets the minimum host count", remediation: vvf ? "vSAN clusters need at least 3 hosts, or 2 with a witness appliance; the export doesn't show witnesses, so confirm before adding a host." : "VCF needs 3 hosts per vSAN cluster and 2 with external storage." + (pairs.isEmpty ? "" : " HA pairs need an even host count; stretched over vSAN, VCF 9.1's design guide wants 6."))

        if !pairs.isEmpty {
            b.add("wld.pairs", wldArea, "HA cluster pairs set by hand", .warning,
                  "\(pairs.map(\.cluster.name).joined(separator: "; ")) \(pairs.count == 1 ? "is" : "are") sized to survive losing a site. RVTools can't see sites or stretching, so this comes from what you entered, not the export",
                  remediation: "Confirm each pair really is one stretched cluster, with half the capacity reserved for a site failure. Stretched vSAN also needs equal hosts per site, at least 10 Gbps and under 5 ms round trip between sites, and a witness at a third site.",
                  affected: pairs.map { cref($0.cluster, "\($0.a.name) and \($0.b.name)") })
            if !vvf && !mgmtStretched {
                b.add("wld.pairs.mgmt", wldArea, "Stretch the management domain first", .warning,
                      "VCF's stretched vSAN docs require the default management cluster to be stretched before a workload cluster is, but this plan's management domain isn't stretched",
                      remediation: "Stretch the management domain under Assumptions, or confirm the requirement doesn't apply, for example to a metro storage cluster on external storage.",
                      actions: dedicated ? [SolutionAction("Stretch the management domain", symbol: "arrow.left.and.right", set: ["stretchMgmt": .flag(true)])] : [])
            }
            let uneven = pairs.compactMap { pair -> AffectedObject? in
                let a = caps(pair.a), b = caps(pair.b)
                let cores = (a.reduce(0) { $0 + $1.cores }, b.reduce(0) { $0 + $1.cores }), ram = (a.reduce(0) { $0 + $1.ramGiB }, b.reduce(0) { $0 + $1.ramGiB })
                guard a.count != b.count || abs(cores.0 - cores.1) > 0.1 * max(cores.0, cores.1) || abs(ram.0 - ram.1) > 0.1 * max(ram.0, ram.1) else { return nil }
                return cref(pair.cluster, "\(a.count) hosts, \(SFmt.num(cores.0)) cores, \(SFmt.num(ram.0.rounded())) GiB and \(b.count) hosts, \(SFmt.num(cores.1)) cores, \(SFmt.num(ram.1.rounded())) GiB")
            }
            b.list("wld.pairs.balance", wldArea, "HA cluster pair balance", .warning, noun: "pair(s) have uneven sites, so the weaker site sets the load", affected: uneven,
                   ready: "Both sites of every pair are about the same size", remediation: "Stretched clusters need the same number of hosts in each site, so either can carry the load after a failure.")
            let mixed = pairs.compactMap { pair -> AffectedObject? in
                let vendors = Set((caps(pair.a) + caps(pair.b)).map(\.vendor).filter { !$0.isEmpty })
                return vendors.count > 1 ? cref(pair.cluster, vendors.sorted().joined(separator: ", ")) : nil
            }
            if !mixed.isEmpty {
                b.list("wld.pairs.cpu", wldArea, "HA cluster pair CPU vendors", .blocker, noun: "pair(s) mix CPU vendors", affected: mixed, ready: "",
                       remediation: "vMotion doesn't cross CPU vendors, so VMs couldn't move between the sites without a restart.")
            }
        }

        // vSAN entitlement: raw TiB per licensed core, pooled across the fleet, against the raw vSAN capacity in scope today.
        let tibPerCore = vvf ? A.vsanTiBPerCoreVVF : A.vsanTiBPerCoreVCF
        let licensedCores = planHosts.reduce(0) { $0 + $1.licensed }
        let entitledTiB = licensedCores * tibPerCore
        // Physical cores against licensed ones: CPUs below the per-CPU minimum are licensed for cores they don't have.
        let physicalCores = planHosts.reduce(0) { $0 + $1.cores }
        let overLicensed = max(0, licensedCores - physicalCores)
        let underMin = planHosts.filter { $0.licensed > $0.cores }
        if !planHosts.isEmpty {
            b.add("license.cores", "Licensing", "\(edition) subscription cores", .info,
                  "\(SFmt.num(licensedCores)) licensed cores for \(planHosts.count) hosts (\(SFmt.num(coreMin))-core minimum per CPU)"
                    + (overLicensed > 0 ? "; \(SFmt.num(physicalCores)) physical, so \(SFmt.num(overLicensed)) cores (\(Fmt.pct(overLicensed / licensedCores * 100))) are over-licensed on \(underMin.count) hosts with CPUs below the minimum" : ""),
                  remediation: "Licensed cores cover every host in the plan, new ones included. Confirm current Broadcom licensing terms, including any per-order minimums."
                    + (overLicensed > 0 ? " Hosts with CPUs below \(SFmt.num(coreMin)) cores pay for the minimum; denser CPUs in new or refreshed hosts recover those cores." : ""),
                  affected: underMin.map { h in
                      AffectedObject(kind: h.isNew ? .other : .host, id: h.id, name: h.name,
                                     detail: "\(SFmt.num(h.cores)) physical, \(SFmt.num(h.licensed)) licensed (+\(SFmt.num(h.licensed - h.cores)))")
                  })
        }
        var seenDS = Set<String>()
        let vsanStores = inv.datastores.filter { d in
            d.type.lowercased() == "vsan" && clusters.contains { onCluster(d, $0) } && seenDS.insert(d.id).inserted
        }
        let vsanRawTiB = vsanStores.reduce(0) { $0 + $1.capacityMiB } / 1024 / 1024
        let addOnTiB = max(0, (vsanRawTiB - entitledTiB).rounded(.up))
        if !planHosts.isEmpty {
            b.add("license.vsan", "Licensing", "vSAN capacity entitlement", vsanStores.isEmpty || addOnTiB == 0 ? .ready : .warning,
                  vsanStores.isEmpty
                    ? "\(SFmt.num(licensedCores)) licensed cores include \(SFmt.num(entitledTiB)) TiB of raw vSAN; no vSAN datastores in scope today"
                    : addOnTiB == 0
                        ? "\(SFmt.num(licensedCores)) licensed cores include \(SFmt.num(entitledTiB)) TiB of raw vSAN, covering the \(SFmt.num((vsanRawTiB * 10).rounded() / 10)) TiB in scope"
                        : "\(SFmt.num((vsanRawTiB * 10).rounded() / 10)) TiB of raw vSAN in scope, \(SFmt.num(entitledTiB)) TiB included with \(SFmt.num(licensedCores)) licensed cores: about \(SFmt.num(addOnTiB)) TiB of vSAN add-on capacity needed",
                  remediation: "\(edition) includes \(SFmt.num(tibPerCore)) TiB of raw vSAN per licensed core, pooled across clusters (compute-only clusters count too). Capacity beyond that is licensed as the vSAN add-on. Verify current Broadcom terms.")
        }

        var mergeRows: [[String]] = []
        if let merged = mergedCluster {
            let parts = mergeMembers.map { (c: $0, hosts: caps($0), demand: workload($0)) }.filter { !$0.hosts.isEmpty }
            let pool = parts.flatMap(\.hosts)
            let separate = parts.reduce(0) { $0 + hostsNeeded($1.hosts, $1.demand, min: minWorkload($1.c), typical: VCF9Sizing.typical($1.hosts)!).need }
            let together = hostsNeeded(pool, parts.reduce(Demand()) { $0 + $1.demand }, min: minWorkload(merged), typical: VCF9Sizing.typical(pool)!).need
            let role = merged.id == chosen.cluster.id ? (dedicated ? "gives up the management hosts" : "is the consolidated management cluster") : "is a workload cluster"
            mergeRows = [
                ["Clusters", parts.map(\.c.name).joined(separator: ", ")],
                ["Role in this plan", "The merged cluster " + role],
                ["Hosts today", "\(pool.count)"],
                ["Hosts their workloads need as separate clusters", "\(separate)"],
                ["Hosts their workloads need as one cluster", "\(together)"],
                [separate >= together ? "Hosts saved by merging" : "Extra hosts from merging", "\(abs(separate - together))"],
            ]
            let mergeCands = parts.map { (cluster: $0.c, hosts: $0.hosts) }
            let vendors = Set(pool.map(\.vendor).filter { !$0.isEmpty })
            if vendors.count > 1 {
                b.add("wld.merge.cpu", wldArea, "Merged cluster CPU vendors", .blocker, "The clusters to merge mix \(vendors.sorted().joined(separator: " and ")) CPUs",
                      remediation: "vMotion doesn't cross CPU vendors; keep Intel and AMD hosts in separate clusters.",
                      affected: mergeCands.map { AffectedObject(kind: .cluster, id: $0.cluster.id, name: $0.cluster.name, detail: Set($0.hosts.map(\.vendor)).sorted().joined(separator: ", ")) })
            } else {
                let evc = Set(mergeCands.flatMap { (hostsByCluster[$0.cluster.id] ?? []).map(\.evcCurrent) }.filter { !$0.isEmpty })
                if evc.count > 1 {
                    b.add("wld.merge.evc", wldArea, "Merged cluster EVC modes", .warning, "The clusters to merge run different EVC modes: \(evc.sorted().joined(separator: ", "))",
                          remediation: "Set the merged cluster's EVC mode to the lowest common generation, or move VMs cold.")
                }
            }
        }

        if !unknownHosts.isEmpty {
            b.list("hosts.unknown", "Data", "Hosts without capacity data", .info, noun: "hosts left out of the sizing",
                   affected: unknownHosts.map { $0.ref("no cores / memory in export") }, ready: "", remediation: "Ask for an export that includes the vHost tab.")
        }
        if !basisFallback.isEmpty {
            b.add("data.basis", "Data", "Measured usage missing", .info, "No host usage for \(basisFallback.joined(separator: ", ")); sized from configured VMs instead")
        }

        // MARK: Sections
        let checks = b.checks
        let wldAdds = comps.filter { c in wds.contains { c.name.hasPrefix($0.name + " ") } }
        sections.append(.metrics("Summary", [
            SolutionMetric(mgmtArea, "\(mgmtHostList.count) hosts",
                           dedicated ? [mgmtHostList.contains { !$0.isNew } ? "\(mgmtHostList.filter { !$0.isNew }.count) from \(chosen.cluster.name)" : "",
                                           mgmtHostList.contains(where: \.isNew) ? "\(mgmtHostList.filter(\.isNew).count) new" : ""].filter { !$0.isEmpty }.joined(separator: " + ")
                                     : "consolidated on \(chosen.cluster.name)" + (dedicatedFits && !vvf ? " · dedicated recommended" : ""),
                           symbol: "server.rack", status: dedicated ? (greenfieldOK ? .ready : greenShort)
                                                                    : (chosen.consolidated.newHosts == 0 && (vvf || !dedicatedFits) ? .ready : .warning)),
            SolutionMetric("Management appliances", "\(SFmt.num(totCPU)) vCPU", "\(Fmt.memory(mib: totRAM * 1024)) RAM · \(Fmt.capacity(mib: totDisk * 1024)) disk", symbol: "cpu"),
            SolutionMetric(mgmtHostList.contains { $0.site != nil } ? "Load with \(downShort(mgmtHostList))" : "Load with \(spare) host(s) down", mgmtLoad.isFinite ? Fmt.pct(mgmtLoad * 100) : "—", dedicated ? "management hosts" : "appliances + workloads", symbol: "gauge.with.dots.needle.50percent"),
            SolutionMetric("Management storage", Fmt.capacity(mib: storageMiB), "\(storageName) · \(SFmt.num(storageGB)) GB in workbook terms", symbol: "externaldrive"),
            vvf ? SolutionMetric("Workload clusters", Fmt.int(units.count), "under \(wds.count) vCenter(s)", symbol: "square.grid.2x2")
                : SolutionMetric("Workload domains", Fmt.int(wds.count), "\(wds.reduce(0) { $0 + $1.clusters.count }) clusters · adds \(SFmt.num(wldAdds.reduce(0) { $0 + $1.cpu })) vCPU to management", symbol: "square.grid.2x2"),
            SolutionMetric("Licensed cores", SFmt.num(licensedCores),
                           overLicensed > 0 ? "\(SFmt.num(physicalCores)) physical · \(SFmt.num(overLicensed)) over-licensed (\(SFmt.num(coreMin))-core min)"
                                            : "\(SFmt.num(coreMin))-core minimum per CPU", symbol: "key"),
            SolutionMetric("vSAN entitlement", "\(SFmt.num(entitledTiB)) TiB", vsanStores.isEmpty ? "\(SFmt.num(licensedCores)) licensed cores · no vSAN in scope"
                           : addOnTiB == 0 ? "covers \(SFmt.num((vsanRawTiB * 10).rounded() / 10)) TiB raw in scope" : "\(SFmt.num(addOnTiB)) TiB add-on needed",
                           symbol: "internaldrive", status: addOnTiB == 0 ? .ready : .warning),
            SolutionMetric("New hosts", Fmt.int(newHostsTotal), newHostsTotal == 0 ? "none needed" : "management and workload clusters", symbol: "plus.square.on.square",
                           status: newHostsTotal == 0 ? .ready : .warning),
        ]))
        sections.append(.checks("Assessment", checks))

        // Candidate clusters.
        let candRows = candidates.map { c -> [String] in
            let mark = c.cluster.id == chosen.cluster.id ? (isAuto ? "★ best fit" : "Selected") : (c.cluster.id == best.cluster.id ? "Best fit" : "")
            let green: String = {
                guard let plan = c.peel else { return "No" }
                return plan.newHosts == 0 ? "\(plan.mgmt.count) hosts, rest at \(Fmt.pct(plan.remainingLoad * 100))" : "Needs \(plan.newHosts) new"
            }()
            let cons = c.consolidated.newHosts < 0 ? "No" : (c.consolidated.newHosts == 0 ? "Fits at \(Fmt.pct(c.consolidated.load * 100))" : "Needs \(c.consolidated.newHosts) new")
            return [c.cluster.name, c.cluster.vcenter, "\(c.hosts.count)", SFmt.num(c.hosts.reduce(0) { $0 + $1.cores }),
                    SFmt.num(c.hosts.reduce(0) { $0 + $1.ramGiB }.rounded()), c.currentLoad.isFinite ? Fmt.pct(c.currentLoad * 100) : "—", green, cons, mark]
        }
        let merged = mergeMembers.map(\.id)
        let pending = mergedCluster == nil ? mergeMembers.first : nil   // one cluster ticked, waiting for a second
        let candActions: [[SolutionAction]] = candidates.map { c in
            var a: [SolutionAction] = []
            // Merge first so it lines up in one column; not every row offers "Use for management".
            if let pair = pairs.first(where: { $0.cluster.id == c.cluster.id }) {
                let rest = pairs.filter { $0.cluster.id != pair.cluster.id }.flatMap(\.refs)
                a.append(SolutionAction("Unpair", symbol: "arrow.triangle.branch", help: "Sizes these clusters separately again.", set: ["pairs": .names(rest)]))
            } else if candidates.count + mergeMembers.count > 1 {
                if mergedCluster?.id == c.cluster.id {
                    a.append(SolutionAction("Split", symbol: "arrow.triangle.branch", help: "Sizes these clusters separately again.", set: ["merge": .names([])]))
                } else if pending?.id == c.cluster.id {
                    a.append(SolutionAction("Cancel merge", symbol: "xmark", set: ["merge": .names([])]))
                } else {
                    let with = mergedCluster == nil ? pending?.name : mergedCluster?.name
                    a.append(SolutionAction(with.map { "Merge with \($0)" } ?? "Merge…", symbol: "arrow.triangle.merge",
                                            help: with == nil ? "Then choose another cluster to merge it with." : "Sizes these clusters as one cluster.",
                                            set: ["merge": .names(merged + [c.cluster.id])]))
                }
            }
            if c.cluster.id != chosen.cluster.id {
                a.append(SolutionAction("Use for management", symbol: "star", help: "Makes this the management cluster.",
                                        set: ["mgmtCluster": .names([memberIDs[c.cluster.id]?.first ?? c.cluster.id])]))
            } else if !isAuto {
                a.append(SolutionAction("Use best fit", symbol: "star.slash", set: ["mgmtCluster": .names([])]))
            }
            return a
        }
        sections.append(.table(SolutionTable(
            id: "candidates", title: "\(mgmtArea) candidates",
            subtitle: (pending.map { "\($0.name) is waiting to be merged — choose another cluster to merge it with. " } ?? "")
                + "Workload load is with \(spare) host(s) down\(pairsDown); \(vvf ? "dedicated" : "greenfield") peels the smallest hosts off the cluster.",
            columns: ["Cluster", "vCenter", "Hosts", "Cores", "RAM (GiB)", "Workload load", vvf ? "Dedicated" : "Greenfield", "Consolidated", ""],
            numeric: [2, 3, 4, 5], rows: candRows, rowRefs: candidates.map { memberIDs[$0.cluster.id] == nil ? cref($0.cluster) : nil }, rowActions: candActions)))

        // Appliances.
        var compRows = comps.map { [$0.name, $0.nodes > 0 ? "\($0.nodes)" : "—", SFmt.num($0.cpu), SFmt.num($0.ram), SFmt.num($0.disk), $0.note] }
        compRows.append(["Total", "\(comps.reduce(0) { $0 + $1.nodes })", SFmt.num(totCPU), SFmt.num(totRAM), SFmt.num(totDisk), ""])
        sections.append(.table(SolutionTable(
            id: "appliances", title: vvf ? "Management appliances" : "Management domain appliances",
            subtitle: vvf ? "vSphere Foundation · simple mode, as the VCF Installer deploys it · sizes from the \(A.source)" : "\(deploy.label) · sizes from the \(A.source)",
            columns: ["Component", "Nodes", "vCPU", "RAM (GB)", "Disk (GB)", "Notes"], numeric: [1, 2, 3, 4], rows: compRows, emphasized: [compRows.count - 1])))

        // Management hosts.
        if !mgmtHostList.isEmpty {
            let load = dedicated ? mgmt : mgmt + chosen.workload
            let sited = mgmtHostList.contains { $0.site != nil }
            let surviving = sited ? min(mgmtHostList.filter { $0.site == 0 }.count, mgmtHostList.filter { $0.site == 1 }.count) - siteSpare : mgmtHostList.count - spare
            let perCPU = surviving > 0 ? load.cores / Double(surviving) : .infinity
            let perRAM = surviving > 0 ? load.ramGiB / Double(surviving) : .infinity
            var rows = mgmtHostList.map { h in [h.name, h.isNew ? "New" : (h.cluster.isEmpty ? chosen.cluster.name : h.cluster), SFmt.num(h.cores), SFmt.num(h.ramGiB.rounded())] }
            rows.append([dedicated ? "Management load per host" : "Load per host (appliances + workloads)", sited ? downShort(mgmtHostList) : "\(spare) host(s) down", SFmt.num(perCPU.rounded(.up)), SFmt.num(perRAM.rounded(.up))])
            sections.append(.table(SolutionTable(
                id: "mgmt-hosts", title: dedicated ? "\(mgmtArea) hosts" : "Consolidated cluster hosts",
                subtitle: dedicated ? "Appliances at \(SFmt.num(mgmtRatio)):1 vCPU per core" : "Appliances at \(SFmt.num(mgmtRatio)):1 plus the cluster's workloads",
                columns: ["Host", "Source", "Cores", "RAM (GiB)"], numeric: [2, 3], rows: rows,
                rowRefs: mgmtHostList.map { $0.isNew ? nil : AffectedObject(kind: .host, id: $0.id, name: $0.name) } + [nil], emphasized: [rows.count - 1])))
        }

        // Storage.
        var storRows: [[String]] = [
            ["Appliance disk", SFmt.num(totDisk)],
            ["Swap (appliance memory)", SFmt.num(totRAM)],
        ]
        if kind != 3 {
            storRows.append(["vSAN protection (FTT=1, \(kind == 1 ? "×1.5 ESA" : "×2 OSA")\(mgmtStretched ? ", ×2 for the second site" : ""))", SFmt.num(protected.rounded(.up))])
            storRows.append(["Rebuild and operations reserve (\(SFmt.num(reserve * 100))%)", SFmt.num(reserved.rounded(.up))])
        }
        storRows.append(["With \(SFmt.num(growth * 100))% growth", SFmt.num(storageGB)])
        sections.append(.table(SolutionTable(id: "mgmt-storage", title: "\(vvf ? "Management" : "Management domain") storage (GB)", subtitle: storageName,
                                             columns: ["Step", "GB"], numeric: [1], rows: storRows, emphasized: [storRows.count - 1])))

        // Workload domains.
        if !wds.isEmpty {
            let rows = wds.map { wd -> [String] in
                let adds = comps.filter { $0.name.hasPrefix(wd.name + " ") }
                return [wd.name, wd.clusters.map(\.name).joined(separator: ", "), "\(wd.hosts)", Fmt.int(wd.vms),
                        newVCenters ? wd.vcSize : "Existing", wldNSX == 2 ? "Shared" : "\(wd.nsxSize) × \(wldNSX == 0 ? 3 : 1)",
                        "\(SFmt.num(adds.reduce(0) { $0 + $1.cpu })) vCPU · \(SFmt.num(adds.reduce(0) { $0 + $1.ram })) GB"]
            }
            if !vvf {
                sections.append(.table(SolutionTable(
                    id: "workload-domains", title: "Workload domains", subtitle: "What each converged domain adds to the management domain",
                    columns: ["Domain", "Clusters", "Hosts", "VMs", "vCenter", "NSX Managers", "Adds to management"], numeric: [2, 3], rows: rows)))
            }
            sections.append(.table(SolutionTable(
                id: "workload-clusters", title: "Workload clusters", subtitle: "Existing workloads with \(spare) host(s) down\(pairsDown), at most \(SFmt.num(maxLoad * 100))%",
                columns: ["Cluster", vvf ? "vCenter" : "Domain", "Hosts", "Demand (cores)", "Demand (GiB)", "Load", "Capacity"], numeric: [2, 3, 4, 5],
                rows: clusterRows, rowRefs: clusterRefs)))
        }
        if !pairs.isEmpty {
            // What the pair costs: the same hosts and workloads, against ordinary host failures.
            let rows = pairs.compactMap { pair -> [String]? in
                guard let cand = candidateByID[pair.cluster.id] else { return nil }
                let hs = liveHosts(cand)
                let siteDown = VCF9Sizing.load(hs, cand.workload, spare: spare, siteSpare: siteSpare)
                let hostsDown = VCF9Sizing.load(hs.map { h in var h = h; h.site = nil; return h }, cand.workload, spare: spare)
                func side(_ s: Int) -> String { "\(hs.filter { $0.site == s }.count) hosts" }
                return [pair.a.name, side(0), pair.b.name, side(1), siteDown.isFinite ? Fmt.pct(siteDown * 100) : "—", hostsDown.isFinite ? Fmt.pct(hostsDown * 100) : "—"]
            }
            sections.append(.table(SolutionTable(
                id: "ha-pairs", title: "HA cluster pairs", subtitle: "Set by hand under Assumptions: the export can't show that these are stretched",
                columns: ["Site A", "Hosts", "Site B", "Hosts", "Load with \(siteDownText)", "Load with \(spare) host(s) down"],
                numeric: [1, 3, 4, 5], rows: rows)))
        }
        if !mergeRows.isEmpty {
            sections.append(.table(SolutionTable(id: "merge", title: "Merged cluster", columns: ["", "Value"], numeric: [1], rows: mergeRows)))
        }

        // The alternative the user didn't pick, when it matters.
        if dedicated && !greenfieldOK {
            let f = bestCons.consolidated
            sections.append(.notes("Alternative: consolidated \(mgmtTerm)", [
                f.newHosts == 0
                    ? "\(bestCons.cluster.name) could run the management appliances alongside its workloads on its \(f.hosts.count) hosts (\(Fmt.pct(f.load * 100)) with \(spare) down)."
                    : "The best consolidated option, \(bestCons.cluster.name), needs \(max(f.newHosts, 0)) more host(s).",
                "Switch Management domain to Consolidated under Assumptions to size it in full.",
            ]))
        }

        var notes = [
            vvf ? "vSphere Foundation components follow the VCF 9.1 docs: the VCF Installer deploys VVF in simple mode with a Medium vCenter, Medium VCF Operations (one node), the license server and Small VCF management services; there is no SDDC Manager, NSX, VCF Automation or workload domain. Sizes and the storage steps come from the \(A.source)'s tables (its sizing tab has no VVF option). Its services runtime figures include VCF-only services such as the identity broker, so they carry some headroom. CPU and memory both keep \(spare) host(s) in reserve."
                : "Management appliance sizes, node counts and the storage steps follow the \(A.source) (Management Domain Sizing tab, first instance). Unlike the workbook, CPU and memory both keep \(spare) host(s) in reserve.",
            "Host fit uses each host's cores and memory from vHost. " + (measured
                ? "Existing workloads are sized from measured host CPU and memory usage, scaled to the selected VMs' share of each cluster's measured VM usage."
                : "Existing workloads are the selected powered-on VMs at \(SFmt.num(wlRatio)):1 vCPU per core and 1:1 memory."),
            "\(vvf ? "A dedicated cluster" : "Greenfield") assumes the other hosts in the cluster can take its VMs (vMotion / DRS) before hosts are removed for the \(mgmtTerm).",
            vvf ? "Not in this sizing: Supervisor, Avi, Live Recovery and Site Recovery Manager — add them as Other management VMs."
                : "Not in this sizing: Supervisor, Avi, Security Services Platform, VCF Operations for networks and Live Recovery — add them as Other management VMs.",
            "vSAN entitlement: \(SFmt.num(tibPerCore)) TiB of raw vSAN per licensed core (\(SFmt.num(coreMin))-core minimum per CPU), compared with the raw capacity of today's vSAN datastores in scope. Disks in new hosts aren't in the export.",
        ]
        if vvf && !dedicated, let plan = bestPeel.peel {
            notes.append("A dedicated management cluster is still recommended for VVF where hosts can be spared. " + (plan.newHosts == 0
                ? "\(bestPeel.cluster.name) could give up \(plan.mgmt.count) hosts for one and still carry its workloads at \(Fmt.pct(plan.remainingLoad * 100)) with \(spare) down."
                : "Here it would need \(plan.newHosts) new host(s)."))
        }
        if !pairs.isEmpty {
            notes.append("HA cluster pairs are sized so either site can carry both clusters' workloads alone, at most \(SFmt.num(maxLoad * 100))%, with \(siteSpare) more host(s) out on that site. Other clusters still keep \(spare) host(s) in reserve.")
        }
        if !isAuto { notes.insert("Management cluster chosen under Assumptions; best fit would be \(best.cluster.name).", at: 0) }
        sections.append(.notes("About this sizing", notes))

        if headline.isEmpty { headline = "\(clusters.count) clusters sized" }
        headline = (vvf ? "VVF · " : "") + headline
        headline += (vvf ? "" : " · \(wds.count) workload domain(s)") + (newHostsTotal > 0 ? " · \(newHostsTotal) new host(s) overall" : "")
        if addOnTiB > 0 { headline += " · \(SFmt.num(addOnTiB)) TiB vSAN add-on" }
        if !vvf && !dedicated && dedicatedFits { headline += " · a dedicated management domain fits without new hosts (recommended)" }
        return SolutionResult(headline: headline, sections: sections)
    }
}
