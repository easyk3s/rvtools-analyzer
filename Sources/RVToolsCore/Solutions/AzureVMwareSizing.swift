import Foundation

/// Sizes the selected VMs onto Azure VMware Solution host nodes and prices them under Broadcom BYOL licensing:
/// how many nodes of which host type, in which region, and what the Azure node charge plus the VCF subscription you
/// bring comes to per month. Node specs and limits come from `AVSNodes`; node rates from the Azure Retail Prices API.
///
/// Azure only publishes "VCF BYOL" node SKUs now, so the node price never includes Broadcom licensing — the VCF cost
/// per core is an assumption you enter, and the two are added for the total.
public struct AzureVMwareSizing: PricedSolution {
    public init() {}

    public var provider: CloudProvider { .azure }
    public var id: String { "avs" }
    public var title: String { "Azure VMware Solution Sizing" }
    public var symbol: String { "server.rack" }
    public var summary: String {
        "Sizes the selected VMs onto AVS nodes (AV36 … AV64) and totals the Azure node charge with the VCF licensing you "
            + "bring (BYOL), across regions and host types. A private cloud keeps the VMs as they are — no per-VM re-sizing onto instances."
    }

    /// vSAN storage policies: capacity multiplier and the hosts each needs. `label` is the dropdown, `short` reads in prose.
    static let policies: [(label: String, short: String, factor: Double, minHosts: Int)] = [
        ("RAID-1 (mirror), FTT=1 — AVS default", "RAID-1 (mirror), FTT=1", 2.0, 3),
        ("RAID-5 (erasure coding), FTT=1", "RAID-5, FTT=1", 1.25, 4),
        ("RAID-1 (mirror), FTT=2", "RAID-1 (mirror), FTT=2", 3.0, 5),
        ("RAID-6 (erasure coding), FTT=2", "RAID-6, FTT=2", 1.5, 6),
    ]

    var regionList: [CloudRegion] { CloudRegions.azure }

    public var parameters: [SolutionParameter] { [
        .multi("regions", "Target", "Regions", regionList.map { "\($0.name) · \($0.code)" }, selected: [0, 1, 10],
               help: "Prices are downloaded per region; the cheapest gets the detailed breakdown. Not every region offers every host type."),
        .multi("skus", "Target", "Host types to consider", AVSNodes.order.map { sku in
            let s = AVSNodes.specs[sku]!
            return "\(sku) · \(s.cores) cores, \(Fmt.int(Int(s.memoryGiB))) GiB, \(SFmt.num(s.capacityTB)) TB vSAN"
        }, selected: Array(AVSNodes.order.indices),
               help: "The cheapest host type that fits is chosen per region. AV36 and AV52 are older SKUs with limited availability and no 3-year term."),
        .choice("term", "Pricing", "Node term", AVSTerm.allCases.map(\.label), selected: 2,
                help: "AVS nodes are usually bought on a reserved term. A host type with no published rate for the chosen term is left out of the comparison and reported."),
        .number("discount", "Pricing", "Discount on node rates", 0, min: 0, max: 80, unit: "%",
                help: "Any negotiated or commitment discount (MACC, EA) off the Azure list rate for the nodes. It is not applied to the VCF licence cost below."),
        .number("hours", "Pricing", "Running hours per month", 730, min: 1, max: 744, unit: "hours",
                help: "A private cloud runs continuously; reserved terms are billed for the whole term regardless."),
        .number("vcfCost", "Licensing (BYOL)", "VCF subscription per core per year", 0, min: 0, max: 5000, step: 10, unit: "USD",
                help: "The Broadcom VCF subscription you bring for the AVS node cores, per core per year. Azure's BYOL node price excludes it. Enter your negotiated rate — 0 prices the Azure nodes alone."),
        .choice("licBasis", "Licensing (BYOL)", "Cores to license", [
            "Every physical core in every node",
            "Node cores less the AVS management reservation",
        ], help: "Broadcom licenses every physical core in the hosts. The second option is only for modelling a negotiated carve-out; it isn't standard terms."),
        .choice("basis", "Capacity", "vCPU sizing", ["As configured", "From CPU usage in the export (+ buffer)"],
                help: "The export is a point-in-time inventory — validate right-sizing against performance history before committing."),
        .choice("mem", "Capacity", "Memory sizing", ["As configured", "From consumed memory in the export (+ buffer)"]),
        .number("buffer", "Capacity", "Right-sizing buffer", 25, min: 0, max: 200, unit: "%"),
        .number("ratio", "Capacity", "vCPU per physical core", 4, min: 0.5, max: 20, step: 0.5, unit: ": 1",
                help: "CPU overcommitment on the nodes. AVS nodes are hyperthreaded (2 logical cores per physical core), so 4:1 is a common starting point for mixed server workloads."),
        .number("spare", "Capacity", "Host failures to tolerate", 1, min: 0, max: 3,
                help: "Nodes held back for failures and maintenance: CPU and memory must fit with these nodes out."),
        .number("maxLoad", "Capacity", "Max CPU / memory load with those nodes down", 80, min: 50, max: 100, unit: "%"),
        .toggle("mgmtPool", "Capacity", "Reserve the AVS management resource pool", true,
                help: "AVS reserves \(SFmt.num(AVSNodes.managementReservationGHz)) GHz of CPU and \(SFmt.num(AVSNodes.managementReservationGiB)) GiB of memory on the first cluster for vCenter, NSX and HCX. It can't be changed."),
        .choice("extMode", "External datastores", "Datastore strategy", [
            "vSAN only — add nodes until the capacity fits",
            "Supplement vSAN — size nodes for CPU and memory, put the rest on external storage",
            "External only — all VM data on external storage",
        ], help: "AVS can back datastores with Azure NetApp Files (NFS) or Elastic SAN (iSCSI), so capacity grows without buying nodes. "
            + "When storage is what drives the node count, this is usually far cheaper — and it cuts VCF cores too, since those follow the nodes. "
            + "The Storage strategy table in the results prices every option whichever one is chosen here."),
        .choice("extTier", "External datastores", "External storage", [
            "Azure NetApp Files — Standard", "Azure NetApp Files — Premium", "Azure NetApp Files — Ultra",
            "Azure Elastic SAN — Premium LRS", "Azure Elastic SAN — Premium ZRS",
        ], selected: 3, help: "Elastic SAN is the cheaper per TiB; ANF offers higher service levels and per-volume throughput. "
            + "Microsoft requires at least a 16 TiB Elastic SAN base size for an AVS datastore."),
        .number("extHeadroom", "External datastores", "Free space kept on external datastores", 20, min: 0, max: 100, unit: "%",
                help: "External datastores are thin but still need free space for snapshots, swap and growth. vSAN's own reserve is set by the policy and the 25% SLA slack."),
        .choice("diskBasis", "Storage", "Size disks from", ["Provisioned disk size", "Guest used space + headroom"]),
        .number("diskHead", "Storage", "Disk headroom (guest used basis)", 20, min: 0, max: 200, unit: "%"),
        .choice("policy", "Storage", "vSAN storage policy", Self.policies.map(\.label),
                help: "Sets the capacity multiplier and the minimum nodes per cluster."),
        .number("reduction", "Storage", "vSAN data reduction ratio", 1, min: 1, max: 5, step: 0.1, unit: ": 1",
                help: "Deduplication and compression. 1:1 assumes none, which is the safe starting point — measure before relying on a higher ratio."),
        .toggle("swap", "Storage", "Include VM swap files", true,
                help: "A powered-on VM without a full memory reservation writes a swap file the size of its configured memory to the datastore."),
        .number("growth", "Storage", "Estimated growth", 10, min: 0, max: 200, unit: "%"),
        .choice("off", "Scope", "Powered-off VMs", ["Storage only", "Size as running", "Exclude"]),
    ] }

    public func defaultSelection(_ inventory: Inventory) -> Set<String> {
        Set(inventory.workloadVMs.map(\.id))
    }

    public func regions(_ params: Params) -> [String] {
        params.multi("regions").compactMap { regionList.indices.contains($0) ? regionList[$0].code : nil }
    }

    // MARK: - Model

    /// GiB of VM data → decimal TB, the unit Microsoft states node capacity in.
    static func gibToTB(_ gib: Double) -> Double { gib * 1.073741824 / 1000 }

    /// Decimal TB of node capacity → GiB, to compare against VM sizes from the export.
    static func tbToGiB(_ tb: Double) -> Double { tb * 1000 / 1.073741824 }

    /// Node rates are a few dollars an hour, so whole dollars would hide the difference between host types.
    static func rate(_ v: Double) -> String { v.isFinite ? String(format: "$%.2f", v) : "—" }

    /// GiB → a TiB figure for display.
    static func tib(_ gib: Double) -> String { SFmt.num(gib / 1024) + " TiB" }

    /// What the selected VMs need, before any node overhead.
    struct Demand {
        var vcpu = 0.0
        var memGiB = 0.0
        /// VM disk (plus swap) before the storage policy, reduction and growth.
        var dataGiB = 0.0
        var vms = 0

        static func + (a: Demand, b: Demand) -> Demand {
            var o = Demand()
            o.vcpu = a.vcpu + b.vcpu
            o.memGiB = a.memGiB + b.memGiB
            o.dataGiB = a.dataGiB + b.dataGiB
            o.vms = a.vms + b.vms
            return o
        }
    }

    /// Where VM data lives: on the nodes' vSAN, or on an Azure storage service attached as a datastore.
    struct ExternalChoice {
        /// 0 = vSAN only, 1 = nodes sized for CPU and memory with the rest external, 2 = all data external.
        let mode: Int
        let offer: AVSDatastoreOffer?
        let headroomPct: Double

        static let vsanOnly = ExternalChoice(mode: 0, offer: nil, headroomPct: 0)
        /// True when external storage is actually in use (a mode that uses it, and a priced service).
        var active: Bool { mode > 0 && offer != nil }
    }

    /// A sized private cloud on one host type in one region.
    struct Plan {
        let region: String
        let sku: String
        let spec: AVSNodes.Spec
        let nodes: Int
        /// Clusters the nodes are split into: a cluster holds at most 16 hosts and keeps its own failure reserve.
        let clusters: Int
        /// Nodes each resource alone would need (storage is 0 when external storage carries the overflow).
        let cpuNodes: Int
        let memNodes: Int
        let storageNodes: Int
        let floorNodes: Int
        let hourly: Double
        let hours: Double
        let licensedCores: Double
        let vcfPerCoreYear: Double
        /// All VM data after reduction and growth, before any protection overhead, in GiB.
        let dataGiB: Double
        /// vSAN capacity consumed after the storage policy, in decimal TB.
        let storageTB: Double
        /// VM data held on external datastores, and the capacity billed for it (headroom and any minimum applied).
        let externalDataGiB: Double
        let externalBilledGiB: Double
        let external: ExternalChoice
        /// Load limits the CPU and memory fit was checked against, for the drivers table.
        let spare: Int
        let maxLoad: Double
        let policyFactor: Double

        var nodeMonthly: Double { Double(nodes) * hourly * hours }
        var vcfMonthly: Double { licensedCores * vcfPerCoreYear / 12 }
        var externalMonthly: Double { externalBilledGiB * (external.offer?.perGiBMonth ?? 0) }
        var total: Double { nodeMonthly + vcfMonthly + externalMonthly }
        /// Raw vSAN capacity the nodes bring, less the SLA slack.
        var usableTB: Double { Double(nodes) * spec.capacityTB * AVSNodes.vsanUsablePct / 100 }
        /// VM data that fits on the nodes' vSAN once the storage policy is applied.
        var vsanDataGiB: Double { AzureVMwareSizing.tbToGiB(usableTB) / max(policyFactor, 0.01) }

        /// Nodes held in reserve across the private cloud: every cluster keeps its own.
        var reservedNodes: Int { clusters * spare }
        /// Cores and memory available for VMs once each cluster's spare nodes are out and the load limit applied.
        var cpuCapacity: Double { Double(max(nodes - reservedNodes, 0)) * Double(spec.cores) * maxLoad }
        var memCapacity: Double { Double(max(nodes - reservedNodes, 0)) * spec.memoryGiB * maxLoad }

        /// Nodes per cluster, spread as evenly as the count allows — the split that makes workload placement
        /// and vSAN capacity easiest, since neither pools across clusters.
        var split: [Int] {
            guard clusters > 1 else { return [nodes] }
            let base = nodes / clusters
            let extra = nodes % clusters
            return (0..<clusters).map { base + ($0 < extra ? 1 : 0) }
        }
        var splitLabel: String {
            guard clusters > 1 else { return "one cluster" }
            return "\(clusters) clusters (\(split.map(String.init).joined(separator: " + ")))"
        }

        /// What set the node count, for the sizing-drivers table.
        var driver: String {
            var tied: [String] = []
            if cpuNodes == nodes { tied.append("CPU") }
            if memNodes == nodes { tied.append("memory") }
            if storageNodes == nodes && storageNodes > 0 { tied.append("storage") }
            if tied.isEmpty { return clusters > 1 ? "the cluster host limit" : "minimum cluster size" }
            return tied.joined(separator: " and ")
        }
    }

    func demandOptions(_ p: Params) -> CloudSizing.DemandOptions {
        var o = CloudSizing.DemandOptions()
        o.rightsizeCPU = p.choice("basis") == 1
        o.rightsizeMemory = p.choice("mem") == 1
        o.bufferPct = p.num("buffer")
        o.minVCPU = 1
        o.minMemoryGiB = 0.5
        o.diskFromGuestUsage = p.choice("diskBasis") == 1
        o.diskHeadroomPct = p.num("diskHead")
        return o
    }

    /// One VM's contribution. Powered-off VMs can count for storage only, as running, or not at all.
    func demand(_ vm: VM, _ p: Params, _ o: CloudSizing.DemandOptions, _ speed: [String: Double]) -> Demand {
        let s = CloudSizing.demand(vm, o, hostSpeedMHz: speed[vm.hostKey])
        let counts = vm.isRunning || p.choice("off") == 1
        var d = Demand()
        d.vms = 1
        if counts {
            d.vcpu = Double(s.vcpu)
            d.memGiB = s.memoryGiB
        }
        d.dataGiB = s.diskGiB.reduce(0, +)
        // Swap is only written for a powered-on VM, and only for memory it hasn't reserved.
        if p.flag("swap") && vm.isRunning { d.dataGiB += vm.swapMiB / 1024 }
        return d
    }

    /// Physical cores the demand needs at the chosen overcommit ratio, plus the AVS management reservation
    /// (converted at the host type's clock speed, since the reservation is in GHz).
    func coresNeeded(_ d: Demand, _ p: Params, _ spec: AVSNodes.Spec) -> Double {
        var cores = d.vcpu / max(p.num("ratio"), 0.1)
        if p.flag("mgmtPool") { cores += AVSNodes.managementReservationGHz / spec.clockGHz }
        return cores
    }

    /// Memory the demand needs, plus the AVS management reservation.
    func memNeeded(_ d: Demand, _ p: Params) -> Double {
        d.memGiB + (p.flag("mgmtPool") ? AVSNodes.managementReservationGiB : 0)
    }

    /// The datastore strategy the assumptions ask for, with the chosen service's rates from this region.
    func externalChoice(_ p: Params, region: String) -> ExternalChoice {
        let mode = min(max(p.choice("extMode"), 0), 2)
        guard mode > 0 else { return .vsanOnly }
        let offers = PriceStore.shared.prices(.azure, region)?.avsDatastores ?? []
        let wanted = Self.datastoreIDs[min(max(p.choice("extTier"), 0), Self.datastoreIDs.count - 1)]
        return ExternalChoice(mode: mode, offer: offers.first { $0.id == wanted }, headroomPct: p.num("extHeadroom"))
    }

    /// The `extTier` options, in the same order, as `AVSDatastoreOffer.id`.
    static let datastoreIDs = ["anf|Standard", "anf|Premium", "anf|Ultra", "esan|Premium LRS", "esan|Premium ZRS"]

    /// Sizes one host type for a demand and prices it, under a given datastore strategy.
    func plan(region: String, sku: String, offer: AVSNodeOffer, demand d: Demand, _ p: Params, external: ExternalChoice) -> Plan? {
        guard let spec = AVSNodes.spec(sku), let rate = offer.hourly(AVSTerm(rawValue: p.choice("term")) ?? .payg) else { return nil }
        let hourly = rate * (1 - min(max(p.num("discount"), 0), 100) / 100)
        let spare = Int(p.num("spare"))
        let maxLoad = max(p.num("maxLoad"), 1) / 100
        let policy = Self.policies[min(max(p.choice("policy"), 0), Self.policies.count - 1)]

        // CPU and memory, with the management reservation and the failure reserve.
        var cores = d.vcpu / max(p.num("ratio"), 0.1)
        var memGiB = d.memGiB
        if p.flag("mgmtPool") {
            cores += AVSNodes.managementReservationGHz / spec.clockGHz
            memGiB += AVSNodes.managementReservationGiB
        }
        let perNodeCores = Double(spec.cores) * maxLoad
        let perNodeMem = spec.memoryGiB * maxLoad
        // Nodes that have to carry load, before any failure reserve.
        let cpuUsable = Int((cores / perNodeCores).rounded(.up))
        let memUsable = Int((memGiB / perNodeMem).rounded(.up))
        let floor = max(AVSNodes.minHostsPerCluster, policy.minHosts)

        // All the VM data that has to live somewhere, after data reduction and growth.
        let dataGiB = d.dataGiB / max(p.num("reduction"), 1) * (1 + p.num("growth") / 100)
        // One node's vSAN holds this much VM data: its usable raw capacity divided by the policy multiplier.
        let perNodeTB = spec.capacityTB * AVSNodes.vsanUsablePct / 100
        let perNodeDataGiB = Self.tbToGiB(perNodeTB) / policy.factor

        // vSAN-only sizing adds nodes until the data fits; the other modes leave the overflow to external storage,
        // which protects its own data, so no policy multiplier applies to it.
        // A cluster holds at most 16 hosts, so the node count and the cluster count are decided together: every
        // extra cluster keeps its own failure reserve (HA admission control is per cluster) and must itself meet
        // the minimum host count. Try each cluster count and keep the one needing the fewest nodes.
        let storageNodes = external.active || perNodeDataGiB <= 0
            ? 0 : Int((dataGiB / perNodeDataGiB).rounded(.up))
        var nodes = 0
        var clusterCount = 1
        for k in 1...AVSNodes.maxClustersPerPrivateCloud {
            // Load has to fit with `spare` nodes out of *each* cluster.
            let forLoad = max(cpuUsable, memUsable) + k * spare
            let candidate = max(max(forLoad, storageNodes), k * floor)
            guard candidate <= k * AVSNodes.maxHostsPerCluster else { continue }
            nodes = candidate
            clusterCount = k
            break
        }
        // Past the private cloud limit nothing fits; report the uncapped figure so the check can say so.
        if nodes == 0 {
            clusterCount = AVSNodes.maxClustersPerPrivateCloud
            nodes = max(max(cpuUsable, memUsable) + clusterCount * spare, max(storageNodes, clusterCount * floor))
        }

        var externalDataGiB = 0.0
        if external.active {
            let onVSAN = external.mode == 2 ? 0 : Double(nodes) * perNodeDataGiB
            externalDataGiB = max(0, dataGiB - onVSAN)
        }

        // What the external datastore is billed for: the data plus free-space headroom, and at least any minimum size.
        var billed = 0.0
        if externalDataGiB > 0 {
            billed = externalDataGiB * (1 + external.headroomPct / 100)
            if let minTiB = external.offer?.minTiB { billed = max(billed, minTiB * 1024) }
        }

        let totalCores = Double(nodes) * Double(spec.cores)
        var licensed = totalCores
        if p.choice("licBasis") == 1 {
            licensed = max(0, totalCores - AVSNodes.managementReservationGHz / spec.clockGHz)
        }
        // vSAN capacity actually consumed: everything not sent to external storage, at the policy multiplier.
        let onVSANData = max(0, dataGiB - externalDataGiB)
        return Plan(region: region, sku: sku, spec: spec, nodes: nodes, clusters: clusterCount,
                    cpuNodes: cpuUsable + clusterCount * spare, memNodes: memUsable + clusterCount * spare,
                    storageNodes: storageNodes, floorNodes: clusterCount * floor, hourly: hourly, hours: p.num("hours"),
                    licensedCores: licensed, vcfPerCoreYear: p.num("vcfCost"), dataGiB: dataGiB,
                    storageTB: Self.gibToTB(onVSANData * policy.factor), externalDataGiB: externalDataGiB,
                    externalBilledGiB: billed, external: external, spare: spare, maxLoad: maxLoad, policyFactor: policy.factor)
    }

    /// Every priced host type in a region, cheapest total first.
    func plans(region: String, allowed: Set<String>, demand d: Demand, _ p: Params, external: ExternalChoice) -> [Plan] {
        guard let prices = PriceStore.shared.prices(.azure, region) else { return [] }
        let nodes = prices.avsNodes ?? []
        let out = nodes.filter { allowed.contains($0.sku) }
            .compactMap { plan(region: region, sku: $0.sku, offer: $0, demand: d, p, external: external) }
        return out.sorted { ($0.total, $0.nodes, $0.sku) < ($1.total, $1.nodes, $1.sku) }
    }

    // MARK: - Run

    public func run(vms: [VM], inventory inv: Inventory, params p: Params) -> SolutionResult {
        let codes = regions(p)
        let allowed = Set(p.multi("skus").compactMap { AVSNodes.order.indices.contains($0) ? AVSNodes.order[$0] : nil })
        let term = AVSTerm(rawValue: p.choice("term")) ?? .payg
        let off = p.choice("off")
        let policy = Self.policies[min(max(p.choice("policy"), 0), Self.policies.count - 1)]
        let speed = Dictionary(inv.hosts.map { ($0.id, $0.speedMHz) }, uniquingKeysWith: { a, _ in a })
        let o = demandOptions(p)

        let inScope = vms.filter { !$0.isTemplate && (off != 2 || $0.isRunning) }
        let perVM = inScope.map { (vm: $0, d: demand($0, p, o, speed)) }
        let total = perVM.reduce(Demand()) { $0 + $1.d }

        // Price every region, then every host type in the cheapest, under the chosen datastore strategy.
        let byRegion = codes.map { code in
            (code: code, plans: plans(region: code, allowed: allowed, demand: total, p, external: externalChoice(p, region: code)))
        }
        let priced = byRegion.filter { !$0.plans.isEmpty }
        let name = { (code: String) in CloudRegions.name(.azure, code) }

        guard let best = priced.compactMap({ $0.plans.first }).min(by: { $0.total < $1.total }) else {
            var b = CheckBuilder()
            let haveAzure = codes.contains { PriceStore.shared.prices(.azure, $0) != nil }
            if codes.isEmpty {
                b.add("prices", "Pricing", "No regions selected", .blocker, "Choose at least one region under Assumptions.")
            } else if allowed.isEmpty {
                b.add("skus", "Target", "No host types selected", .blocker, "Choose at least one AVS host type under Assumptions.")
            } else if haveAzure {
                b.add("prices", "Pricing", "No AVS node prices in the downloaded price list", .blocker,
                      "Azure prices are cached for \(codes.count) region(s), but without AVS node rates — they were downloaded before AVS pricing was added.",
                      remediation: "Use Refresh Prices to download the AVS node rates. Only public price lists are fetched; no inventory data leaves this Mac.")
            } else {
                b.add("prices", "Pricing", "Azure prices not downloaded", .blocker,
                      "Use Download Prices to fetch list prices for \(codes.count) region(s).",
                      remediation: "Only public price lists are downloaded; no inventory data leaves this Mac.")
            }
            return SolutionResult(headline: "\(Fmt.int(inScope.count)) VMs selected — download Azure prices to size Azure VMware Solution",
                                  sections: [.checks("Pricing", b.checks)])
        }

        let bestRegion = name(best.region)
        let fetched = PriceStore.shared.prices(.azure, best.region)?.fetched ?? Date()
        let missing = byRegion.filter { $0.plans.isEmpty }.map(\.code)
        let allRegionPlans = priced.compactMap { $0.plans.first }.sorted { $0.total < $1.total }

        var sections: [SolutionSection] = []

        // Summary. "Constrained by" is the figure to act on: it says whether more nodes buy CPU, memory or capacity.
        let cpuUsed = best.cpuCapacity > 0 ? coresNeeded(total, p, best.spec) / best.cpuCapacity * 100 : 0
        let memUsed = best.memCapacity > 0 ? memNeeded(total, p) / best.memCapacity * 100 : 0
        let vsanUsed = best.vsanDataGiB > 0 ? max(0, best.dataGiB - best.externalDataGiB) / best.vsanDataGiB * 100 : 0
        var constraintDetail = "CPU \(Fmt.pct(cpuUsed)) · memory \(Fmt.pct(memUsed)) · vSAN \(Fmt.pct(vsanUsed)) used at \(best.nodes) nodes"
        if best.external.active && best.externalDataGiB > 0 {
            constraintDetail = "CPU \(Fmt.pct(cpuUsed)) · memory \(Fmt.pct(memUsed)) used; capacity is on external storage"
        }

        var metrics: [SolutionMetric] = [
            SolutionMetric("Nodes", "\(best.nodes) × \(best.sku)",
                           best.splitLabel, symbol: "server.rack",
                           status: best.nodes > AVSNodes.maxHostsPerPrivateCloud ? .blocker : nil),
            SolutionMetric("Constrained by", best.driver.prefix(1).uppercased() + best.driver.dropFirst(), constraintDetail,
                           symbol: "arrow.up.and.down.and.arrow.left.and.right"),
            SolutionMetric("Monthly estimate", SFmt.usd(best.total), "\(bestRegion) · \(term.label)", symbol: "dollarsign.circle"),
            SolutionMetric("Annual estimate", SFmt.usd(best.total * 12), "everything below, for 12 months", symbol: "calendar"),
        ]
        // The cost split: how much of the bill is Azure's and how much is Broadcom's.
        let nodePct = best.total > 0 ? best.nodeMonthly / best.total * 100 : 0
        let vcfPct = best.total > 0 ? best.vcfMonthly / best.total * 100 : 0
        let extPct = best.total > 0 ? best.externalMonthly / best.total * 100 : 0
        if best.vcfPerCoreYear > 0 {
            var split = "\(Fmt.pct(nodePct)) nodes · \(Fmt.pct(vcfPct)) VCF licensing"
            if best.externalMonthly > 0 { split += " · \(Fmt.pct(extPct)) storage" }
            metrics.append(SolutionMetric("Where the money goes", split,
                                          "nodes \(SFmt.usd(best.nodeMonthly)) · VCF \(SFmt.usd(best.vcfMonthly))"
                                            + (best.externalMonthly > 0 ? " · storage \(SFmt.usd(best.externalMonthly))" : "") + " per month",
                                          symbol: "chart.pie"))
        } else {
            metrics.append(SolutionMetric("Where the money goes", "Azure charges only",
                                          "\(SFmt.usd(best.nodeMonthly)) nodes"
                                            + (best.externalMonthly > 0 ? " · \(SFmt.usd(best.externalMonthly)) storage" : "")
                                            + " — set a VCF cost per core to include licensing", symbol: "chart.pie", status: .warning))
        }
        metrics.append(SolutionMetric("Licensed cores", SFmt.num(best.licensedCores),
                                      "\(best.nodes) × \(best.spec.cores) cores per node", symbol: "cpu"))
        if best.external.active && best.externalDataGiB > 0, let offer = best.external.offer {
            metrics.append(SolutionMetric("External datastore", Self.tib(best.externalBilledGiB),
                                          "\(offer.label) · \(SFmt.usd(best.externalMonthly))/month", symbol: "externaldrive.connected.to.line.below"))
        } else {
            metrics.append(SolutionMetric("vSAN capacity", "\(SFmt.num(best.storageTB)) TB",
                                          "of \(SFmt.num(best.usableTB)) TB usable (\(SFmt.num(AVSNodes.vsanUsablePct))% of raw)",
                                          symbol: "internaldrive", status: best.storageTB > best.usableTB ? .warning : nil))
        }
        sections.append(.metrics("Summary", metrics))

        // Region comparison
        let regionRows: [[String]] = byRegion.sorted { a, b in
            let x = a.plans.first?.total ?? .infinity
            let y = b.plans.first?.total ?? .infinity
            return (x, a.code) < (y, b.code)
        }.map { entry in
            guard let plan = entry.plans.first else {
                let known = PriceStore.shared.prices(.azure, entry.code) != nil
                return ["\(name(entry.code)) (\(entry.code))", "—", "—", "—", "—", "—", "—",
                        known ? "no selected host type on this term" : "prices not downloaded"]
            }
            let delta = plan.total - best.total
            return ["\(name(entry.code)) (\(entry.code))", "\(plan.nodes) × \(plan.sku)", SFmt.usd(plan.nodeMonthly),
                    SFmt.usd(plan.vcfMonthly), plan.externalMonthly > 0 ? SFmt.usd(plan.externalMonthly) : "—",
                    SFmt.usd(plan.total), SFmt.usd(plan.total * 12),
                    delta < 0.5 ? "cheapest" : "+\(SFmt.usd(delta)) (\(Fmt.pct(delta / max(best.total, 1) * 100)))"]
        }
        sections.append(.table(SolutionTable(
            id: "regions", title: "Region comparison", subtitle: "Cheapest selected host type per region · \(term.label), USD",
            columns: ["Region", "Nodes", "Nodes / month", "VCF / month", "Storage / month", "Total / month", "Total / year", "vs cheapest"],
            numeric: [2, 3, 4, 5, 6, 7], rows: regionRows, emphasized: [0])))
        sections.append(.bars("Monthly cost by region", "Nodes, VCF licensing and any external storage",
                              allRegionPlans.map { CountItem(label: name($0.region), count: $0.nodes, value: $0.total) }, .currency))

        // Host types in the cheapest region: every SKU Azure prices there, including the ones the chosen term rules out.
        let regionNodes = PriceStore.shared.prices(.azure, best.region)?.avsNodes ?? []
        var hostEntries: [(total: Double, sku: String, row: [String])] = []
        for offer in regionNodes {
            guard let spec = AVSNodes.spec(offer.sku) else { continue }
            let specCols = ["\(spec.cores) cores", "\(Fmt.int(Int(spec.memoryGiB))) GiB", "\(SFmt.num(spec.capacityTB)) TB"]
            let label = offer.sku + (allowed.contains(offer.sku) ? "" : " (not selected)")
            guard let sized = plan(region: best.region, sku: offer.sku, offer: offer, demand: total, p, external: best.external) else {
                hostEntries.append((.infinity, offer.sku, [label] + specCols + ["—", "no \(term.label) rate", "—", "—", "—", "—", "—"]))
                continue
            }
            let row = [label] + specCols + ["\(sized.nodes)", sized.driver, Self.rate(sized.hourly),
                                            SFmt.usd(sized.nodeMonthly), SFmt.usd(sized.vcfMonthly),
                                            sized.externalMonthly > 0 ? SFmt.usd(sized.externalMonthly) : "—", SFmt.usd(sized.total)]
            hostEntries.append((sized.total, offer.sku, row))
        }
        let hostRows = hostEntries.sorted { ($0.total, $0.sku) < ($1.total, $1.sku) }.map(\.row)
        sections.append(.table(SolutionTable(
            id: "hosttypes", title: "Host type comparison", subtitle: "\(bestRegion) · \(term.label)",
            columns: ["Host type", "Cores", "Memory", "vSAN raw", "Nodes", "Sized by", "$ / node / hour",
                      "Nodes / month", "VCF / month", "Storage / month", "Total / month"],
            numeric: [4, 6, 7, 8, 9, 10], rows: hostRows)))

        // Storage strategy: more nodes for capacity, or external datastores? Priced either way, whichever is chosen.
        if let strategy = storageStrategy(best: best, demand: total, p) { sections.append(.table(strategy)) }

        // Terms for the chosen host type
        var termRows: [[String]] = []
        let offer = (PriceStore.shared.prices(.azure, best.region)?.avsNodes ?? []).first { $0.sku == best.sku }
        for t in AVSTerm.allCases {
            guard let o2 = offer else { continue }
            let altParams = Params(parameters, termValues(p, t))
            guard let alt = plan(region: best.region, sku: best.sku, offer: o2, demand: total, altParams, external: best.external) else {
                termRows.append([t.label, "not offered", "—", "—", "—", "—"])
                continue
            }
            termRows.append([t.label, Self.rate(alt.hourly), SFmt.usd(alt.nodeMonthly), SFmt.usd(alt.vcfMonthly),
                             SFmt.usd(alt.total), SFmt.usd(alt.total - best.total)])
        }
        sections.append(.table(SolutionTable(
            id: "terms", title: "Node term options", subtitle: "\(best.nodes) × \(best.sku) in \(bestRegion); difference vs the current assumptions",
            columns: ["Term", "$ / node / hour", "Nodes / month", "VCF / month", "Total / month", "Difference / month"],
            numeric: [1, 2, 3, 4, 5], rows: termRows)))

        // What constrains the sizing: how full each resource is at the chosen node count, and what each alone would need.
        let maxLoad = best.maxLoad
        let spare = best.spare
        let needCores = coresNeeded(total, p, best.spec)
        let needMem = memNeeded(total, p)
        let onVSAN = max(0, best.dataGiB - best.externalDataGiB)
        var spareNote = ""
        if spare > 0 {
            spareNote = best.clusters > 1
                ? " with \(spare) out of each of \(best.clusters) clusters (\(best.reservedNodes) nodes)"
                : " with \(spare) node(s) out"
        }
        var driverRows: [[String]] = [
            ["CPU — physical cores at \(SFmt.num(p.num("ratio"))):1", "\(SFmt.num(needCores)) cores",
             "\(SFmt.num(best.cpuCapacity)) cores\(spareNote) at \(SFmt.num(maxLoad * 100))%", Fmt.pct(cpuUsed),
             "\(best.cpuNodes)"],
            ["Memory", "\(SFmt.num(needMem)) GiB", "\(SFmt.num(best.memCapacity)) GiB\(spareNote) at \(SFmt.num(maxLoad * 100))%",
             Fmt.pct(memUsed), "\(best.memNodes)"],
        ]
        if best.external.active, let dsOffer = best.external.offer {
            driverRows.append(["vSAN — data at \(policy.short) (×\(SFmt.num(policy.factor)))", Self.tib(onVSAN),
                               Self.tib(best.vsanDataGiB) + " on \(best.nodes) nodes", Fmt.pct(vsanUsed), "n/a — capacity is external"])
            driverRows.append(["\(dsOffer.shortLabel) datastore", Self.tib(best.externalDataGiB),
                               Self.tib(best.externalBilledGiB) + " provisioned", "—", "adds no nodes"])
        } else {
            driverRows.append(["vSAN — data at \(policy.short) (×\(SFmt.num(policy.factor)))", Self.tib(onVSAN),
                               Self.tib(best.vsanDataGiB) + " on \(best.nodes) nodes", Fmt.pct(vsanUsed), "\(best.storageNodes)"])
        }
        let floorPer = best.clusters > 0 ? best.floorNodes / best.clusters : best.floorNodes
        driverRows.append(["Minimum cluster size — \(floorPer) per cluster × \(best.clusters)",
                           "\(best.floorNodes) nodes", "—", "—", "\(best.floorNodes)"])
        driverRows.append(["Sized private cloud — constrained by \(best.driver)", "", "", "", "\(best.nodes)"])
        sections.append(.table(SolutionTable(
            id: "drivers", title: "What constrains the sizing",
            subtitle: "\(best.sku) in \(bestRegion) — the fullest resource sets the node count; the rest is headroom you've paid for",
            columns: ["Resource", "Needed", "Available", "Used", "Nodes if this alone"], numeric: [3, 4], rows: driverRows,
            emphasized: [driverRows.count - 1])))

        // Storage build-up
        let reduced = total.dataGiB / max(p.num("reduction"), 1)
        var storRows: [[String]] = [["VM disks\(p.flag("swap") ? " and swap files" : "")", SFmt.num(Self.gibToTB(total.dataGiB))]]
        if p.num("reduction") > 1 {
            storRows.append(["After \(SFmt.num(p.num("reduction"))):1 data reduction", SFmt.num(Self.gibToTB(reduced))])
        }
        storRows.append(["With \(SFmt.num(p.num("growth")))% growth — data to place", SFmt.num(Self.gibToTB(best.dataGiB))])
        if best.external.active, let dsOffer = best.external.offer {
            storRows.append(["On vSAN, with \(policy.short) (×\(SFmt.num(policy.factor)))", SFmt.num(best.storageTB)])
            storRows.append(["On \(dsOffer.shortLabel) — no vSAN policy multiplier", SFmt.num(Self.gibToTB(best.externalDataGiB))])
            storRows.append(["\(dsOffer.shortLabel) provisioned, with \(SFmt.num(best.external.headroomPct))% free space",
                             SFmt.num(Self.gibToTB(best.externalBilledGiB))])
        } else {
            storRows.append(["With \(policy.short) (×\(SFmt.num(policy.factor)))", SFmt.num(best.storageTB)])
        }
        storRows.append(["Usable vSAN on \(best.nodes) × \(best.sku)", SFmt.num(best.usableTB)])
        sections.append(.table(SolutionTable(
            id: "storage", title: "vSAN capacity", subtitle: "Decimal TB, as Microsoft states node capacity",
            columns: ["Step", "TB"], numeric: [1], rows: storRows, emphasized: [storRows.count - 1])))

        // Cost allocation by source cluster, on the share of whatever drives the size
        var byCluster: [String: (Demand, Int)] = [:]
        for e in perVM {
            let key = clusterName(inv, e.vm)
            var cur = byCluster[key] ?? (Demand(), 0)
            cur.0 = cur.0 + e.d
            cur.1 += 1
            byCluster[key] = cur
        }
        func weight(_ d: Demand) -> Double {
            if best.driver.contains("storage") { return d.dataGiB }
            if best.driver.contains("memory") { return d.memGiB }
            if best.driver.contains("CPU") { return d.vcpu }
            return d.vcpu + d.memGiB + d.dataGiB / 100
        }
        let totalWeight = byCluster.values.reduce(0.0) { $0 + weight($1.0) }
        let clusterItems = byCluster.map { entry -> CountItem in
            let share = totalWeight > 0 ? weight(entry.value.0) / totalWeight : 0
            return CountItem(label: entry.key, count: entry.value.1, value: best.total * share)
        }.sorted { $0.value > $1.value }
        sections.append(.bars("Monthly cost by source cluster", "Allocated on each cluster's share of \(best.driver)", clusterItems, .currency))
        sections.append(.table(SolutionTable(
            id: "clusters", title: "Demand by source cluster", subtitle: "What each cluster contributes to the sizing",
            columns: ["Cluster", "VMs", "vCPU", "Memory (GiB)", "Disk (TB)", "Allocated / month"], numeric: [1, 2, 3, 4, 5],
            rows: byCluster.sorted { weight($0.value.0) > weight($1.value.0) }.map { entry in
                let share = totalWeight > 0 ? weight(entry.value.0) / totalWeight : 0
                return [entry.key, Fmt.int(entry.value.1), SFmt.num(entry.value.0.vcpu), SFmt.num(entry.value.0.memGiB),
                        SFmt.num(Self.gibToTB(entry.value.0.dataGiB)), SFmt.usd(best.total * share)]
            })))

        sections.append(.checks("Sizing and licensing considerations",
                                checks(best: best, inScope: inScope, perVM: perVM, demandTotal: total, inv: inv, p: p, term: term,
                                       missing: missing, byRegion: byRegion, fetched: fetched, policy: policy).checks))

        sections.append(.notes("Sources, assumptions and exclusions", notes(best: best, p: p, term: term, fetched: fetched, policy: policy)))

        var headline = "\(Fmt.int(inScope.count)) VMs → \(best.nodes) × \(best.sku) in \(bestRegion), \(SFmt.usd(best.total))/month"
        headline += " (\(SFmt.usd(best.total * 12))/year)"
        headline += " · \(term.label)"
        if best.external.active, let dsOffer = best.external.offer, best.externalDataGiB > 0 {
            headline += " + \(Self.tib(best.externalBilledGiB)) \(dsOffer.shortLabel)"
        }
        if best.vcfPerCoreYear > 0 {
            headline += " incl. \(SFmt.num(best.licensedCores)) VCF cores"
        } else {
            headline += " — nodes only, add your VCF rate"
        }
        return SolutionResult(headline: headline, sections: sections)
    }

    /// Prices the same workload every way its capacity can be held: all on vSAN (buying nodes for it), or with the
    /// nodes sized for CPU and memory and the overflow on each external datastore service. This is the
    /// "more nodes or external storage?" decision, and it shows whichever strategy the assumptions pick.
    func storageStrategy(best: Plan, demand d: Demand, _ p: Params) -> SolutionTable? {
        let offers = PriceStore.shared.prices(.azure, best.region)?.avsDatastores ?? []
        let nodeOffer = (PriceStore.shared.prices(.azure, best.region)?.avsNodes ?? []).first { $0.sku == best.sku }
        guard let nodeOffer, !offers.isEmpty else { return nil }

        var options: [(label: String, plan: Plan)] = []
        if let vsanOnly = plan(region: best.region, sku: best.sku, offer: nodeOffer, demand: d, p, external: .vsanOnly) {
            options.append(("vSAN only — nodes carry all capacity", vsanOnly))
        }
        let headroom = p.num("extHeadroom")
        for offer in offers {
            let choice = ExternalChoice(mode: 1, offer: offer, headroomPct: headroom)
            guard let alt = plan(region: best.region, sku: best.sku, offer: nodeOffer, demand: d, p, external: choice) else { continue }
            options.append(("CPU/memory-sized nodes + \(offer.label)", alt))
        }
        guard options.count > 1 else { return nil }

        let cheapest = options.map(\.plan.total).min() ?? best.total
        let rows: [[String]] = options.map { option in
            let plan = option.plan
            let delta = plan.total - cheapest
            var current = ""
            if plan.external.mode == best.external.mode && plan.external.offer?.id == best.external.offer?.id { current = " (current)" }
            return [option.label + current, "\(plan.nodes)", SFmt.num(plan.licensedCores),
                    plan.externalDataGiB > 0 ? Self.tib(plan.externalBilledGiB) : "—",
                    SFmt.usd(plan.nodeMonthly), SFmt.usd(plan.vcfMonthly),
                    plan.externalMonthly > 0 ? SFmt.usd(plan.externalMonthly) : "—",
                    SFmt.usd(plan.total), delta < 0.5 ? "cheapest" : "+" + SFmt.usd(delta)]
        }
        let cheapestIndex = options.firstIndex { abs($0.plan.total - cheapest) < 0.5 } ?? 0
        return SolutionTable(
            id: "strategy", title: "Storage strategy — nodes or external datastores?",
            subtitle: "\(best.sku) in \(CloudRegions.name(.azure, best.region)) · \(AVSTerm(rawValue: p.choice("term"))?.label ?? ""). "
                + "External datastores hold their own protected copy, so they need no vSAN policy multiplier — and fewer nodes means fewer VCF cores.",
            columns: ["Strategy", "Nodes", "VCF cores", "External capacity", "Nodes / month", "VCF / month",
                      "Storage / month", "Total / month", "vs cheapest"],
            numeric: [1, 2, 4, 5, 6, 7, 8], rows: rows, emphasized: [cheapestIndex])
    }

    /// The current assumptions with the node term replaced, for the term comparison.
    private func termValues(_ p: Params, _ t: AVSTerm) -> ParamValues {
        var v = ParamValues()
        for spec in parameters {
            switch spec.kind {
            case .number: v.values[spec.id] = .number(p.num(spec.id))
            case .choice: v.values[spec.id] = .choice(p.choice(spec.id))
            case .toggle: v.values[spec.id] = .flag(p.flag(spec.id))
            case .multi: v.values[spec.id] = .selection(p.multi(spec.id))
            case .clusters, .clusterPairs, .host: v.values[spec.id] = .names(p.names(spec.id))
            }
        }
        v.values["term"] = .choice(t.rawValue)
        return v
    }

    // MARK: - Checks

    private func checks(best: Plan, inScope: [VM], perVM: [(vm: VM, d: Demand)], demandTotal: Demand, inv: Inventory, p: Params, term: AVSTerm,
                        missing: [String], byRegion: [(code: String, plans: [Plan])], fetched: Date,
                        policy: (label: String, short: String, factor: Double, minHosts: Int)) -> CheckBuilder {
        var b = CheckBuilder()
        let name = { (code: String) in CloudRegions.name(.azure, code) }

        if !missing.isEmpty {
            b.add("prices", "Pricing", "Regions without a priced host type", .warning, missing.map(name).joined(separator: ", "),
                  remediation: "Download prices for these regions, or check whether the selected host types are offered there on the \(term.label) term.")
        }
        let age = Date().timeIntervalSince(fetched)
        b.add("age", "Pricing", "Price list age", age > PriceStore.maxAge ? .warning : .ready,
              "Azure list prices downloaded \(Fmt.dateTime(fetched))",
              remediation: age > PriceStore.maxAge ? "Refresh prices for current rates." : "")

        // Host types left out because the term isn't published for them.
        let nodes = PriceStore.shared.prices(.azure, best.region)?.avsNodes ?? []
        let allowed = Set(p.multi("skus").compactMap { AVSNodes.order.indices.contains($0) ? AVSNodes.order[$0] : nil })
        let noTerm = nodes.filter { allowed.contains($0.sku) && $0.hourly(term) == nil }
        if !noTerm.isEmpty {
            b.add("term", "Pricing", "Host types not offered on this term", .info,
                  "\(noTerm.map(\.sku).joined(separator: ", ")) \(noTerm.count == 1 ? "has" : "have") no published \(term.label) rate in \(name(best.region))",
                  remediation: "They are left out of the comparison rather than priced at another term. Switch term under Assumptions to include them.",
                  actions: [SolutionAction("Compare on pay-as-you-go", help: "Sets the node term to pay-as-you-go.", set: ["term": .choice(0)])])
        }

        // Licensing
        if best.vcfPerCoreYear <= 0 {
            b.add("vcf", "Licensing", "VCF licensing not included", .warning,
                  "Azure's BYOL node rate excludes Broadcom licensing, and no cost per core is set — the totals are Azure charges only",
                  remediation: "Enter your VCF subscription cost per core per year under Assumptions. \(SFmt.num(best.licensedCores)) cores would be licensed for this plan.")
        } else {
            let pctLic = best.vcfMonthly / max(best.total, 1) * 100
            b.add("vcf", "Licensing", "VCF subscription (BYOL)", .ready,
                  "\(SFmt.num(best.licensedCores)) cores at \(SFmt.usd(best.vcfPerCoreYear))/core/year = \(SFmt.usd(best.vcfMonthly))/month, "
                    + "\(Fmt.pct(pctLic)) of the total",
                  remediation: "Confirm the rate and that your VCF subscription may be used on Azure VMware Solution under current Broadcom terms.")
        }
        if p.choice("licBasis") == 1 {
            b.add("licbasis", "Licensing", "Licensed cores reduced", .warning,
                  "Cores are counted less the AVS management reservation, which isn't standard Broadcom licensing",
                  remediation: "Broadcom licenses every physical core in the host. Use this only to model a negotiated carve-out.")
        }
        // VCF 9 includes raw vSAN capacity per licensed core; AVS nodes bring their own.
        let entitledTiB = best.licensedCores * VCFAppliances.vsanTiBPerCoreVCF
        // Microsoft states node capacity in decimal TB; the entitlement is in TiB (1 TB = 1 / 1.099511627776 TiB).
        let nodeRawTiB = Double(best.nodes) * best.spec.capacityTB / 1.099511627776
        b.add("vsanentitlement", "Licensing", "vSAN capacity entitlement", nodeRawTiB <= entitledTiB ? .ready : .warning,
              "\(SFmt.num(best.licensedCores)) licensed cores include \(SFmt.num(entitledTiB)) TiB of raw vSAN; the nodes bring "
                + "\(SFmt.num(nodeRawTiB)) TiB",
              remediation: nodeRawTiB <= entitledTiB
                  ? "VCF includes \(SFmt.num(VCFAppliances.vsanTiBPerCoreVCF)) TiB of raw vSAN per licensed core, which covers these nodes. Verify current Broadcom terms."
                  : "Capacity beyond the entitlement is licensed as the vSAN add-on. Verify current Broadcom terms.")

        // AVS limits
        if best.nodes > AVSNodes.maxHostsPerPrivateCloud {
            b.add("maxhosts", "Limits", "Over the private cloud limit", .blocker,
                  "\(best.nodes) nodes needed; a private cloud holds at most \(AVSNodes.maxHostsPerPrivateCloud)",
                  remediation: "Split the workloads across more than one private cloud, move storage-heavy VMs to external datastores, or raise the overcommitment ratio.")
        } else {
            b.add("maxhosts", "Limits", "Private cloud limits", .ready,
                  "\(best.nodes) nodes in \(best.clusters) cluster(s) — within \(AVSNodes.maxHostsPerPrivateCloud) hosts and "
                    + "\(AVSNodes.maxClustersPerPrivateCloud) clusters per private cloud")
        }
        if best.clusters > 1 {
            // The second cluster is not free: it brings its own failure reserve and its own minimum host count.
            let singleCluster = max(best.cpuNodes - (best.clusters - 1) * best.spare, best.storageNodes)
            let extra = best.nodes - singleCluster
            var summary = "\(singleCluster) nodes' worth of capacity exceeds the \(AVSNodes.maxHostsPerCluster)-host cluster limit, "
            summary += "so the private cloud is \(best.splitLabel)"
            if extra > 0 && best.spare > 0 {
                summary += extra == 1 ? " — 1 extra node for the second reserve" : " — \(extra) extra nodes for the extra reserves"
                summary += best.spare == 1 ? ", since each cluster tolerates its own failure" : ", since each cluster tolerates its own \(best.spare) failures"
            }
            b.add("clusters", "Limits", "More than one cluster", .warning, summary,
                  remediation: "Neither vSAN capacity nor HA failover pools across clusters, so each cluster needs its own reserve and its own "
                    + "storage headroom. An even split keeps that simplest, and workloads then have to be balanced to match it — a cluster can't "
                    + "lend capacity to another. Check too that no single VM's disks exceed one cluster's datastore.")
        }
        let smallest = best.split.min() ?? best.nodes
        if smallest < AVSNodes.recommendedHostsPerCluster {
            b.add("minhosts", "Limits", "Cluster below the recommended size", .warning,
                  best.clusters > 1
                    ? "The smallest cluster has \(smallest) hosts; Microsoft recommends at least \(AVSNodes.recommendedHostsPerCluster) per vSAN cluster"
                    : "Sized at \(best.nodes) hosts; Microsoft recommends at least \(AVSNodes.recommendedHostsPerCluster) per vSAN cluster",
                  remediation: "Three hosts is the hard minimum, but with three a single failure leaves no capacity to rebuild onto. "
                    + "Add a host to the smallest cluster before committing.")
        }
        if best.sku == "AV64" {
            b.add("av64", "Limits", "AV64 needs a base private cloud", .warning,
                  "AV64 can only extend a private cloud first deployed on \(AVSNodes.av64Prerequisites.joined(separator: ", "))",
                  remediation: "Plan at least a minimum base cluster on another host type, and note that AV64 isn't supported with stretched clusters.")
        }

        // Sizing sanity
        let maxLoad = max(p.num("maxLoad"), 1) / 100
        let nodeCores = Double(best.spec.cores) * max(p.num("ratio"), 0.1)
        let tooBig = perVM.filter { $0.d.vcpu > nodeCores || $0.d.memGiB > best.spec.memoryGiB * maxLoad }
        b.list("toobig", "Sizing", "VMs larger than one node", .warning, noun: "VMs exceed a single \(best.sku) node",
               affected: tooBig.map { $0.vm.ref("\(SFmt.num($0.d.vcpu)) vCPU / \(SFmt.num($0.d.memGiB)) GiB") },
               ready: "Every VM fits within one \(best.sku) node",
               remediation: "A VM can't span hosts: pick a larger host type, raise the overcommitment ratio, or split these workloads.")

        if best.storageTB > best.usableTB {
            b.add("capacity", "Storage", "vSAN capacity short", .blocker,
                  "\(SFmt.num(best.storageTB)) TB needed, \(SFmt.num(best.usableTB)) TB usable on \(best.nodes) nodes",
                  remediation: "Raise the node count, choose a host type with more capacity, or move cold data to an external datastore.")
        }
        if best.driver.contains("storage") {
            let forCompute = max(best.cpuNodes, max(best.memNodes, best.floorNodes))
            let extra = max(0, best.nodes - forCompute)
            // Price the best external option so the check carries the actual saving, not just the advice.
            var saving = ""
            var actions: [SolutionAction] = []
            let offers = PriceStore.shared.prices(.azure, best.region)?.avsDatastores ?? []
            let nodeOffer = (PriceStore.shared.prices(.azure, best.region)?.avsNodes ?? []).first { $0.sku == best.sku }
            if let nodeOffer {
                var alternatives: [(Int, Plan)] = []
                for (i, offer) in offers.enumerated() {
                    let choice = ExternalChoice(mode: 1, offer: offer, headroomPct: p.num("extHeadroom"))
                    if let alt = plan(region: best.region, sku: best.sku, offer: nodeOffer, demand: demandTotal, p, external: choice) {
                        alternatives.append((i, alt))
                    }
                }
                if let (index, cheapest) = alternatives.min(by: { $0.1.total < $1.1.total }), cheapest.total < best.total {
                    let tierIndex = Self.datastoreIDs.firstIndex(of: offers[index].id) ?? 3
                    saving = " — \(offers[index].label) instead would be \(SFmt.usd(best.total - cheapest.total))/month cheaper "
                        + "(\(cheapest.nodes) nodes, \(SFmt.num(cheapest.licensedCores)) VCF cores)"
                    actions.append(SolutionAction("Supplement with \(offers[index].shortLabel)",
                                                  help: "Sizes nodes for CPU and memory and puts the rest of the capacity on \(offers[index].label).",
                                                  set: ["extMode": .choice(1), "extTier": .choice(tierIndex)]))
                }
            }
            b.add("storagedriven", "Storage", "Storage drives the node count", .warning,
                  "Capacity needs \(best.storageNodes) nodes against \(forCompute) for CPU and memory, so about \(extra) node(s) "
                    + "are bought for storage alone\(saving)",
                  remediation: "Azure NetApp Files (NFS) and Elastic SAN (iSCSI) datastores add capacity without nodes, and carry their own "
                    + "redundancy, so they avoid the vSAN policy multiplier as well as the node and VCF cost. See the Storage strategy table.",
                  actions: actions)
        }

        // External datastore caveats, when one is in use.
        if best.external.active, let offer = best.external.offer, best.externalDataGiB > 0 {
            b.add("extstore", "Storage", "External datastore in the plan", .info,
                  "\(Self.tib(best.externalBilledGiB)) on \(offer.label) at \(SFmt.usd(best.externalMonthly))/month, "
                    + "keeping the nodes sized for CPU and memory",
                  remediation: "On AVS Gen 1 both services reach the private cloud over ExpressRoute: ANF needs an UltraPerformance or ErGw3Az "
                    + "gateway with FastPath, and Elastic SAN needs a gateway sized for the bandwidth plus a /24 storage address block. "
                    + "Gateway, FastPath and egress are not priced here. Put the volumes in the same region and availability zone as the private cloud.")
            if offer.kind == "esan" {
                let minGiB = (offer.minTiB ?? 0) * 1024
                let atMinimum = best.externalDataGiB * (1 + best.external.headroomPct / 100) < minGiB
                b.add("esanmin", "Storage", "Elastic SAN base size", atMinimum ? .warning : .ready,
                      atMinimum
                        ? "Only \(Self.tib(best.externalDataGiB)) needs placing, but Microsoft requires at least a \(SFmt.num(offer.minTiB ?? 0)) TiB base size, which is what's priced"
                        : "\(Self.tib(best.externalBilledGiB)) is above the \(SFmt.num(offer.minTiB ?? 0)) TiB minimum base size",
                      remediation: atMinimum
                        ? "At this little overflow, ANF or simply another node may cost less — compare in the Storage strategy table."
                        : "Priced at the base-unit rate throughout; real deployments mix in cheaper additional capacity units, which lowers it.")
            }
            if offer.kind == "anf" {
                b.add("anflimit", "Storage", "ANF datastore count", .info,
                      "Microsoft's default maximum is \(AVSNodes.maxANFDatastores) Azure NetApp Files datastores",
                      remediation: "\(Self.tib(best.externalBilledGiB)) spread over volumes within that limit is comfortable, but check the per-volume "
                        + "limits: regular datastores support files up to 64 TiB and VMDKs up to 62 TiB, and large volumes don't support large files.")
            }
            if best.sku == "AV48" {
                b.add("extsku", "Storage", "Host type and external storage", .ready,
                      "\(best.sku) supports ANF and Elastic SAN datastores on AVS Gen 1")
            }
        }

        let rdm = inScope.filter { vm in vm.disks.contains { $0.raw || $0.isSharedWriter } }
        b.list("rdm", "Migration", "RDM / shared disks", .warning, noun: "VMs need storage re-design",
               affected: rdm.map { $0.ref("RDM or shared disk") }, ready: "No RDM or shared disks",
               remediation: "AVS has no raw device mapping: move these to vSAN disks, an external datastore or iSCSI from Azure.")

        let eol = inScope.compactMap { vm -> AffectedObject? in
            guard let end = vm.os.endOfSupport, end <= Lifecycle.supportReference(exportDate: inv.reportDate) else { return nil }
            return vm.ref("\(vm.os.name) — ended \(Fmt.date(end))")
        }
        b.list("eol", "Migration", "Guest OS past end of support", .info, noun: "VMs", affected: eol,
               ready: "No end-of-support guests",
               remediation: "AVS runs the same ESXi as on-premises, so these VMs move as they are — but check vSphere 8 guest support and your own support position.")

        let offVMs = inScope.filter { !$0.isRunning }
        if !offVMs.isEmpty {
            let how = p.choice("off") == 1 ? "sized as running" : "counted for storage only"
            b.add("off", "Scope", "Powered-off VMs", .info, "\(offVMs.count) VMs \(how)", affected: offVMs.map(\.vmRef))
        }
        if p.flag("mgmtPool") {
            b.add("mgmtpool", "Capacity", "AVS management reservation", .ready,
                  "\(SFmt.num(AVSNodes.managementReservationGHz)) GHz and \(SFmt.num(AVSNodes.managementReservationGiB)) GiB held back for vCenter, NSX and HCX",
                  remediation: "AVS manages vCenter, NSX Manager and HCX itself; the reservation on the first cluster can't be changed.")
        }
        b.add("scope", "Scope", "Private cloud, not per-VM instances", .info,
              "VMs keep their configured size and run on ESXi in Azure — nothing is re-platformed",
              remediation: "Compare with the Azure Migration solution to see the same VMs right-sized onto Azure VM instances. "
                + "This estimate doesn't cover networking, egress, backup, DR, HCX add-ons or external datastores.")
        return b
    }

    private func notes(best: Plan, p: Params, term: AVSTerm, fetched: Date,
                       policy: (label: String, short: String, factor: Double, minHosts: Int)) -> [String] {
        var out: [String] = []
        out.append("Scope: the selected VMs move into an Azure VMware Solution private cloud as they are — same ESXi, same vSphere, no re-platforming. "
            + "Nodes are sized for CPU, memory and vSAN capacity together, and the largest of the three sets the count.")
        out.append("Node rates: Azure Retail Prices API list prices (USD) for the \"VCF BYOL\" host SKUs, downloaded \(Fmt.dateTime(fetched)). "
            + "Reserved rates are the published 1- and 3-year reservation totals spread over the term. A host type with no rate for the chosen term "
            + "is left out rather than priced at another term."
            + (p.num("discount") > 0 ? " Node rates are shown less \(SFmt.num(p.num("discount")))%." : ""))
        out.append("Licensing: Azure withdrew the licence-included AVS SKUs, so every priced node is BYOL — the Azure charge covers the hardware and "
            + "service, and Broadcom licensing is yours to bring. "
            + (best.vcfPerCoreYear > 0
                ? "VCF here is \(SFmt.num(best.licensedCores)) cores × \(SFmt.usd(best.vcfPerCoreYear))/core/year, your figure, undiscounted and billed separately from Azure."
                : "No VCF cost per core is set, so the totals are Azure node charges only."))
        out.append("Node hardware and limits come from \(AVSNodes.source): \(best.sku) is \(best.spec.cpu), \(Fmt.int(Int(best.spec.memoryGiB))) GiB RAM, "
            + "\(SFmt.num(best.spec.capacityTB)) TB raw vSAN capacity (\(best.spec.vsan)). At most \(AVSNodes.maxHostsPerCluster) hosts per cluster, "
            + "\(AVSNodes.maxHostsPerPrivateCloud) per private cloud.")
        out.append("Capacity: vCPU at \(SFmt.num(p.num("ratio"))):1 per physical core and memory 1:1, both fitting with \(Int(p.num("spare"))) node(s) out "
            + "of every cluster at no more than \(SFmt.num(p.num("maxLoad")))% load. A cluster holds at most "
            + "\(AVSNodes.maxHostsPerCluster) hosts and at least \(AVSNodes.minHostsPerCluster), so the node count and the cluster count are "
            + "decided together: each cluster keeps its own failure reserve, because HA failover doesn't pool across clusters, which is why "
            + "crossing \(AVSNodes.maxHostsPerCluster) nodes costs more than one node. Nodes are split evenly, the easiest split to place "
            + "workloads and vSAN capacity against."
            + (p.flag("mgmtPool") ? " The AVS management resource pool (\(SFmt.num(AVSNodes.managementReservationGHz)) GHz, \(SFmt.num(AVSNodes.managementReservationGiB)) GiB) is reserved on top." : ""))
        // Built up in steps: as one expression this is too much for the type checker on older toolchains.
        let swapText: String = p.flag("swap") ? " plus swap files" : ""
        let reductionText: String = p.num("reduction") > 1
            ? ", after " + SFmt.num(p.num("reduction")) + ":1 data reduction"
            : ", with no data reduction assumed"
        var storageNote = "Storage: VM disks" + swapText + " × " + SFmt.num(policy.factor) + " for " + policy.short
        storageNote += reductionText
        storageNote += ", plus " + SFmt.num(p.num("growth")) + "% growth, against " + SFmt.num(AVSNodes.vsanUsablePct)
        storageNote += "% of raw node capacity — vSAN keeps the rest for the SLA. "
        storageNote += "Unlike CPU and memory, storage is sized against every node rather than holding nodes back: that reserve is what covers a rebuild. "
        storageNote += "Capacity is also pooled across the whole private cloud here, but a vSAN datastore belongs to one cluster, so size each cluster "
        storageNote += "separately before committing to a plan with more than one. "
        storageNote += "Microsoft states node capacity in decimal TB; VM sizes from the export are binary GiB and converted."
        out.append(storageNote)
        if best.external.active, let offer = best.external.offer {
            var ext = "External datastores: " + offer.label + " at " + String(format: "$%.4f", offer.perGiBMonth) + " per GiB per month"
            ext += offer.kind == "anf" ? " (the ANF capacity-pool rate, quoted hourly and taken over 730 hours). " : " (the Elastic SAN base-unit rate). "
            ext += "An NFS or iSCSI datastore is not vSAN, so vSAN storage policies and FTT don't apply to it — each service protects its own data, "
            ext += "and Microsoft's pages state no capacity multiplier for them. Capacity is therefore sized 1:1 with the data plus "
            ext += SFmt.num(best.external.headroomPct) + "% free space, where the same data on vSAN would be multiplied by "
            ext += SFmt.num(policy.factor) + ". Verify the protection each service gives you is what the workload needs. "
            if offer.kind == "esan" {
                ext += "Elastic SAN is priced at the base-unit rate for all capacity; a real deployment mixes in cheaper additional capacity units "
                ext += "(" + String(format: "$%.4f", offer.extraPerGiBMonth ?? 0) + " per GiB per month here), so this is the conservative figure. "
                ext += "Microsoft requires at least a " + SFmt.num(offer.minTiB ?? 0) + " TiB base size for an AVS datastore. "
            }
            ext += "Not priced: the ExpressRoute gateway and FastPath that Gen 1 needs for either service, egress, snapshots, backup and replication."
            out.append(ext)
        }
        out.append("Not included: networking and egress, ExpressRoute and its gateway, public IP, Pure Cloud Block Store datastores, "
            + "HCX add-ons, backup and DR, Azure services the VMs call, Windows or SQL Server licensing, support, taxes and negotiated discounts.")
        return out
    }
}
