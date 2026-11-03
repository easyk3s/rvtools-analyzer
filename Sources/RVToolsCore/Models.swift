import Foundation

public enum PowerState: String, CaseIterable, Sendable {
    case on = "Powered on", off = "Powered off", suspended = "Suspended"

    init(raw: String) {
        let s = raw.lowercased()
        if s.contains("suspend") { self = .suspended }
        else if s.contains("off") { self = .off }
        else if s.contains("on") { self = .on }
        else { self = .off }
    }
}

public enum ObjectKind: String, CaseIterable, Sendable {
    case vm = "VM", host = "Host", cluster = "Cluster", datastore = "Datastore", network = "Network", vcenter = "vCenter", other = "Other"
}

@inline(__always) func key(_ server: String, _ name: String) -> String { server.lowercased() + "|" + name.lowercased() }

// MARK: - VM children

public struct VDisk: Hashable, Sendable {
    public var label = ""
    public var capacityMiB = 0.0
    public var thin: Bool?
    public var eagerScrub: Bool?
    public var mode = ""
    public var sharing = ""
    public var controller = ""
    public var raw = false
    public var sharedBus = ""
    public var path = ""
    public var datastore = ""
    public var provisioning: String {
        if raw { return "RDM" }
        if thin == true { return "Thin" }
        if eagerScrub == true { return "Thick eager-zeroed" }
        return "Thick lazy-zeroed"
    }
    public var isIndependent: Bool { mode.lowercased().contains("independent") }
}

public struct VPartition: Hashable, Sendable {
    public var disk = ""
    public var capacityMiB = 0.0
    public var consumedMiB = 0.0
    public var freeMiB = 0.0
    public var freePct = 0.0
}

public struct VNic: Hashable, Sendable {
    public var label = ""
    public var adapter = ""
    public var network = ""
    public var switchName = ""
    public var connected = false
    public var startsConnected = false
    public var mac = ""
    public var ipv4: [String] = []
    public var ipv6 = ""
}

public struct VSnapshot: Hashable, Sendable {
    public var name = ""
    public var description = ""
    public var date: Date?
    public var sizeMiB = 0.0
    public var quiesced = false
    public var ageDays: Double?
}

public struct VCDRom: Hashable, Sendable {
    public var node = ""
    public var connected = false
    public var deviceType = ""
}

/// A vCenter custom attribute, or a vSphere tag category, with its value on one VM.
public struct VCustomField: Hashable, Sendable {
    public var name = ""
    public var value = ""
}

public struct HealthItem: Identifiable, Hashable, Sendable {
    public var id: Int
    public var vcenter = ""
    public var name = ""
    public var message = ""
    public var type = ""
    public var kind: ObjectKind = .other
    public var objectID = ""
}

// MARK: - Core entities

public struct VM: Identifiable, Sendable {
    public let id: String
    public var name = ""
    public var vcenter = ""
    public var datacenter = ""
    public var cluster = ""
    public var clusterKey = ""
    public var host = ""
    public var hostKey = ""
    public var folder = ""
    public var resourcePool = ""
    public var vApp = ""
    public var powerState: PowerState = .off
    public var isTemplate = false
    public var isSRMPlaceholder = false
    public var configStatus = ""
    public var connectionState = ""
    public var guestState = ""
    public var heartbeat = ""
    public var consolidationNeeded = false
    public var osConfig = ""
    public var osTools = ""
    public var os = OSInfo.unknown
    public var cpus = 0
    public var sockets = 0
    public var coresPerSocket = 0
    public var memoryMiB = 0.0
    public var nicCount = 0
    public var diskCount = 0
    public var provisionedMiB = 0.0
    public var inUseMiB = 0.0
    public var unsharedMiB = 0.0
    public var cpusSource = FigureSource.reported
    public var memorySource = FigureSource.reported
    public var provisionedSource = FigureSource.reported
    public var inUseSource = FigureSource.reported
    public var hwVersion = 0
    public var firmware = ""
    public var secureBoot = false
    public var cbt: Bool?
    public var ftState = ""
    public var haRestartPriority = ""
    public var latencySensitivity = ""
    public var creationDate: Date?
    public var powerOnDate: Date?
    public var primaryIP = ""
    public var dnsName = ""
    public var annotation = ""
    /// Custom attributes and tag categories that have a value, in export order.
    public var customFields: [VCustomField] = []
    public var vmxPath = ""
    public var uuid = ""
    public var vmID = ""
    public var cpuReadinessPct: Double?

    // vCPU / vMemory
    /// vCPU "Overall": CPU in use at export time (MHz).
    public var cpuUsageMHz = 0.0
    public var cpuHotAdd = false
    public var memHotAdd = false
    public var cpuReservationMHz = 0.0
    public var cpuLimitMHz = -1.0
    public var memReservationMiB = 0.0
    public var memLimitMiB = -1.0
    public var memBalloonedMiB = 0.0
    public var memSwappedMiB = 0.0
    public var memConsumedMiB = 0.0
    public var memActiveMiB = 0.0

    // vTools
    public var toolsStatus = ""
    public var toolsVersion = ""
    public var toolsUpgradeable = ""
    public var toolsUpgradePolicy = ""

    // Correlated children
    public var disks: [VDisk] = []
    public var partitions: [VPartition] = []
    public var nics: [VNic] = []
    public var snapshots: [VSnapshot] = []
    public var cdroms: [VCDRom] = []
    public var usbConnected = 0
    public var health: [HealthItem] = []
    public var datastores: [String] = []
    public var networks: [String] = []

    // Set by the analyzer for the current scope
    public var issueCount = 0
    public var worstSeverity = 3

    // Derived
    public var isRunning: Bool { powerState == .on }
    public var isVM: Bool { !isTemplate && !isSRMPlaceholder }
    /// A vSphere Cluster Services agent VM ("vCLS-<uuid>"): vCenter creates and manages these, so they aren't
    /// workload. They still count as VMs everywhere, but are left out of solution selections by default and don't
    /// make a datastore look used.
    public var isClusterAgent: Bool {
        let n = name.lowercased()
        return n.hasPrefix("vcls-") || n == "vcls" || n.hasPrefix("vcls (")
    }
    public var diskCapacityMiB: Double { disks.reduce(0) { $0 + $1.capacityMiB } }
    public var guestCapacityMiB: Double { partitions.reduce(0) { $0 + $1.capacityMiB } }
    public var guestConsumedMiB: Double { partitions.reduce(0) { $0 + $1.consumedMiB } }
    public var snapshotCount: Int { snapshots.count }
    public var snapshotSizeMiB: Double { snapshots.reduce(0) { $0 + $1.sizeMiB } }
    public var oldestSnapshotDays: Double { snapshots.compactMap(\.ageDays).max() ?? 0 }
    public var ips: [String] {
        var out: [String] = []
        for n in nics { for ip in n.ipv4 where !out.contains(ip) { out.append(ip) } }
        if out.isEmpty, !primaryIP.isEmpty { out = [primaryIP] }
        return out
    }
    public var toolsDisplay: String { Lifecycle.toolsLabel(toolsStatus) }
    public var powerLabel: String { isTemplate ? "Template" : powerState.rawValue }
    public var creationSort: Double { creationDate?.timeIntervalSince1970 ?? 0 }
    public var osName: String { os.name }
    public var datastoreList: String { datastores.joined(separator: ", ") }
    public var networkList: String { networks.joined(separator: ", ") }
}

public struct Host: Identifiable, Sendable {
    public let id: String
    public var name = ""
    public var vcenter = ""
    public var datacenter = ""
    public var cluster = ""
    public var clusterKey = ""
    public var configStatus = ""
    public var maintenance = false
    public var quarantine = false
    public var cpuModel = ""
    public var speedMHz = 0.0
    public var sockets = 0
    public var coresPerSocket = 0
    public var cores = 0
    public var htAvailable = false
    public var htActive = false
    public var cpuUsagePct = 0.0
    public var memoryMiB = 0.0
    public var memUsagePct = 0.0
    public var nicCountReported = 0
    public var hbaCountReported = 0
    public var vmTotalReported: Int?
    public var vmOnReported: Int?
    public var vcpusReported: Int?
    public var vramReportedMiB = 0.0
    public var esxVersion = ""
    public var esxBuild = ""
    public var vendor = ""
    public var model = ""
    public var serial = ""
    public var biosVersion = ""
    public var bootTime: Date?
    public var ntpServers = ""
    public var ntpdRunning: Bool?
    /// False when the source has no NTP columns at all (Nutanix Collector, a trimmed export): unknown, not unconfigured.
    public var ntpReported = true
    public var dnsServers = ""
    public var timeZone = ""
    public var evcCurrent = ""
    public var evcMax = ""
    public var licenses = ""
    public var certExpiry: Date?
    public var powerPolicy = ""
    /// vSAN fault domain (two per cluster usually means a stretched cluster).
    public var vsanFaultDomain = ""

    // Correlated
    public var vmCount = 0
    public var vmsOn = 0
    public var vcpuOn = 0
    public var vcpuTotal = 0
    public var vramOnMiB = 0.0
    public var pnicCount = 0
    public var hbaCount = 0
    public var vmkCount = 0
    public var lunCount = 0
    public var datastoreCount = 0
    public var uptimeDays: Double?
    public var issueCount = 0
    public var coresSource = FigureSource.reported
    public var memorySource = FigureSource.reported
    /// Known only by name from vInfo (the export has no vHost tab): no capacity, version or hardware.
    public var inferred = false

    /// A virtual ESXi host (vSAN witness appliance, nested lab host, cloud placeholder) — excluded from capacity roll-ups.
    public var isVirtual: Bool { cpuModel.lowercased().contains("vmware virtual") || model.lowercased().contains("vmware virtual") }
    public var threads: Int { htActive ? cores * 2 : cores }
    public var cpuCapacityMHz: Double { Double(cores) * speedMHz }
    public var cpuUsedMHz: Double { cpuCapacityMHz * cpuUsagePct / 100 }
    public var memUsedMiB: Double { memoryMiB * memUsagePct / 100 }
    public var vcpuPerCore: Double { cores > 0 ? Double(vcpuOn) / Double(cores) : 0 }
    public var esxShort: String { esxVersion.isEmpty ? "Unknown" : esxVersion }
}

public struct Cluster: Identifiable, Sendable {
    public let id: String
    public var name = ""
    public var vcenter = ""
    public var datacenter = ""
    public var isStandalone = false
    public var inClusterTab = false
    public var overallStatus = ""
    public var haEnabled: Bool?
    public var drsEnabled: Bool?
    public var admissionControl: Bool?
    public var failoverLevel = ""
    public var drsBehavior = ""
    public var numHostsReported: Int?
    public var totalCpuMHzReported = 0.0
    public var totalMemoryReported = 0.0
    public var numVMotions = 0

    // Correlated
    public var hostCount = 0
    public var hostsInMaintenance = 0
    public var sockets = 0
    public var cores = 0
    public var threads = 0
    public var memoryMiB = 0.0
    public var cpuMHz = 0.0
    public var cpuUsedMHz = 0.0
    public var memUsedMiB = 0.0
    public var largestHostMemMiB = 0.0
    public var largestHostCpuMHz = 0.0
    public var vmCount = 0
    public var vmsOn = 0
    public var templates = 0
    public var vcpuOn = 0
    public var vcpuTotal = 0
    public var vramOnMiB = 0.0
    public var vramTotalMiB = 0.0
    public var provisionedMiB = 0.0
    public var inUseMiB = 0.0
    public var datastoreCount = 0
    public var esxVersions: [String] = []
    public var cpuModels: [String] = []
    public var issueCount = 0

    public var displayName: String { name }
    /// Hosts are present but none reports cores or memory (e.g. hosts known only from vInfo).
    public var capacityUnknown: Bool { hostCount > 0 && cores == 0 && memoryMiB == 0 }
    public var vcpuPerCore: Double { cores > 0 ? Double(vcpuOn) / Double(cores) : 0 }
    public var vramPerPhysical: Double { memoryMiB > 0 ? vramOnMiB / memoryMiB : 0 }
    public var cpuUsagePct: Double { cpuMHz > 0 ? cpuUsedMHz / cpuMHz * 100 : 0 }
    public var memUsagePct: Double { memoryMiB > 0 ? memUsedMiB / memoryMiB * 100 : 0 }
    /// Memory utilisation of the surviving hosts if the largest host fails (N+1).
    public var memPctAfterHostLoss: Double {
        let remaining = memoryMiB - largestHostMemMiB
        return hostCount > 1 && remaining > 0 ? memUsedMiB / remaining * 100 : .infinity
    }
    public var cpuPctAfterHostLoss: Double {
        let remaining = cpuMHz - largestHostCpuMHz
        return hostCount > 1 && remaining > 0 ? cpuUsedMHz / remaining * 100 : .infinity
    }
}

public struct Datastore: Identifiable, Sendable {
    public let id: String
    public var name = ""
    public var vcenter = ""
    public var type = ""
    public var capacityMiB = 0.0
    public var provisionedMiB = 0.0
    /// False when the source has no provisioned figure (Nutanix Collector, Live Optics): unknown, not zero.
    public var provisionedReported = true
    public var inUseMiB = 0.0
    public var freeMiB = 0.0
    public var freePct = 0.0
    public var accessible = true
    public var configStatus = ""
    public var vmTotalReported: Int?
    public var hostNames: [String] = []
    public var datastoreCluster = ""
    public var siocEnabled = false
    public var majorVersion = 0
    public var url = ""
    public var address = ""

    // Correlated
    public var hostKeys: [String] = []
    public var vmIDs: [String] = []
    /// The subset of `vmIDs` that are cluster agent VMs (vCLS), and their disk capacity here.
    public var agentVMIDs: [String] = []
    public var agentDiskMiB = 0.0
    public var vmDiskMiB = 0.0
    public var clusters: [String] = []
    public var clusterKeys: [String] = []
    public var lunPaths = 0
    public var issueCount = 0
    public var capacitySource = FigureSource.reported
    /// VMC on AWS lists the cluster's vSAN capacity twice: as "vsanDatastore" (management) and as
    /// "WorkloadDatastore" (what the customer uses). Set on the management copy, whose capacity double-counts.
    public var isVMCManagementDatastore = false
    /// Known only from VM file paths (the export has no vDatastore tab): no capacity, type or host mounts.
    public var inferred = false

    public var vmCount: Int { vmIDs.count }
    public var hostCount: Int { hostNames.count }
    public var usedPct: Double { capacityMiB > 0 ? (capacityMiB - freeMiB) / capacityMiB * 100 : 0 }
    public var provisionedPct: Double { capacityMiB > 0 ? provisionedMiB / capacityMiB * 100 : 0 }
    public var isLocal: Bool { hostNames.count == 1 && !type.lowercased().contains("vsan") && !type.lowercased().contains("nfs") }
    public var clusterList: String { clusters.joined(separator: ", ") }
}

public extension Datastore {
    /// VMs here that aren't vCenter's own cluster agents.
    var workloadVMCount: Int { vmIDs.count - agentVMIDs.count }
    /// No workload on it: vCLS agents are placed automatically and don't make a datastore "used".
    var hasNoWorkload: Bool { workloadVMCount == 0 && (vmTotalReported ?? 0) <= agentVMIDs.count && vmDiskMiB - agentDiskMiB <= 0 }
    /// A host-local datastore with no VM, template or VM disk on it — typically an ESXi boot or scratch device.
    var isUnusedLocal: Bool { isLocal && hasNoWorkload }
}

public struct PortGroup: Identifiable, Sendable {
    public let id: String
    public var name = ""
    public var vcenter = ""
    public var kind = ""
    public var switchName = ""
    public var vlans: [String] = []
    public var hostKeys: [String] = []
    public var vmIDs: [String] = []
    public var nicCount = 0
    public var connectedNics = 0
    public var promiscuous = false
    public var macChanges = false
    public var forgedTransmits = false
    public var isVMkernel = false
    public var isUplink = false
    /// Networks in use, inferred from the guest IPv4 addresses of the VM NICs on this port group (see `Subnets`).
    public var observedSubnets: [ObservedSubnet] = []

    public var vlanList: String { vlans.isEmpty ? "—" : vlans.joined(separator: ", ") }
    public var subnetList: String { Subnets.list(observedSubnets) }
    public var vmCount: Int { vmIDs.count }
    public var hostCount: Int { hostKeys.count }
}

public struct VSwitchInfo: Identifiable, Sendable {
    public var id: String
    public var host = ""
    public var hostKey = ""
    public var name = ""
    public var ports = 0
    public var freePorts = 0
    public var mtu = 0
    public var promiscuous = false
    public var macChanges = false
    public var forgedTransmits = false
    public var policy = ""
}

public struct DVSwitchInfo: Identifiable, Sendable {
    public var id: String
    public var name = ""
    public var vcenter = ""
    public var datacenter = ""
    public var version = ""
    public var vendor = ""
    public var hostMembers = 0
    public var vmCount = 0
    public var ports = 0
    public var maxMTU = 0
    public var lacp = ""
    public var portGroupCount = 0
}

public struct VMKernel: Identifiable, Sendable {
    public var id: String
    public var host = ""
    public var hostKey = ""
    public var portGroup = ""
    public var device = ""
    public var ip = ""
    public var subnet = ""
    public var gateway = ""
    public var mtu = 0
    public var dhcp = false
}

public struct PhysicalNIC: Identifiable, Sendable {
    public var id: String
    public var host = ""
    public var hostKey = ""
    public var device = ""
    public var driver = ""
    public var speedMbps = 0
    public var duplex = ""
    public var switchName = ""
    public var mac = ""
}

public struct HBA: Identifiable, Sendable {
    public var id: String
    public var host = ""
    public var hostKey = ""
    public var device = ""
    public var type = ""
    public var status = ""
    public var model = ""
    public var driver = ""
    public var wwn = ""
}

public struct MultiPathLUN: Identifiable, Sendable {
    public var id: String
    public var host = ""
    public var hostKey = ""
    public var datastore = ""
    public var disk = ""
    public var displayName = ""
    public var policy = ""
    public var operState = ""
    public var paths = 0
    public var activePaths = 0
    public var deadPaths = 0
    /// Path names as RVTools reports them ("vmhba1:C0:T0:L1"), so the adapters behind them can be counted.
    public var pathNames: [String] = []
    public var vendor = ""
    public var model = ""
}

public struct License: Identifiable, Sendable {
    public var id: String
    public var vcenter = ""
    public var name = ""
    public var keyMasked = ""
    public var total = 0.0
    public var used = 0.0
    public var costUnit = ""
    public var expiration: Date?
    public var expirationRaw = ""
}

public extension License {
    var isEvaluation: Bool { expirationRaw.lowercased().contains("eval") || name.lowercased().contains("evaluation") }

    /// The date license renewals are measured from: today, or the export date if that's later. Renewals are about what
    /// the customer must buy now, so an older export is still measured from today (as support end dates are).
    static func renewalReference(exportDate: Date) -> Date { Lifecycle.supportReference(exportDate: exportDate) }

    /// Days from `date` until the license expires (zero or negative once it has); nil when it doesn't expire.
    func daysToExpiry(from date: Date) -> Double? { expiration.map { $0.timeIntervalSince(date) / 86_400 } }
}

public struct ResourcePool: Identifiable, Sendable {
    public var id: String
    public var vcenter = ""
    public var name = ""
    public var path = ""
    public var vmCount = 0
    public var cpuLimit = -1.0
    public var cpuReservation = 0.0
    public var memLimit = -1.0
    public var memReservation = 0.0
}

public struct VCenter: Identifiable, Sendable {
    public let id: String
    public var server = ""
    public var fullName = ""
    public var version = ""
    public var build = ""
    public var apiVersion = ""
    public var osType = ""
    /// The vCenter's own instance UUID ("VI SDK UUID"). Stable identity across exports, unlike `server`, which is
    /// just the address RVTools connected to (an IP in one export, an FQDN in the next).
    public var instanceUUID = ""
    public var datacenters: [String] = []
}

/// How rows in one tab were joined to entities from another.
public struct JoinStat: Identifiable, Sendable {
    public var id: String { source + "→" + target }
    public var source: String
    public var target: String
    public var keys: String
    public var matched: Int
    public var total: Int
    public var note = ""
    public var coverage: Double { total > 0 ? Double(matched) / Double(total) : 1 }
}

/// A cross-tab consistency check: a figure RVTools reports in one tab vs the same figure derived from another.
public struct ConsistencyCheck: Identifiable, Sendable {
    public var id: String { title }
    public var title: String
    public var reported: String
    public var derived: String
    public var ok: Bool
    public var note = ""
}

/// A tool other than RVTools whose export was translated into RVTools tabs on load (see `NutanixCollector`,
/// `LiveOptics`), and how its data falls short of a full RVTools export.
public struct SourceTool: Sendable, Hashable {
    public var name: String
    public var version: String
    /// What RVTools would have and this tool doesn't gather at all.
    public var notCollected: [String]
    /// Figures it does gather, but measured or converted differently from RVTools.
    public var measuredDifferently: [String]
    public var label: String { version.isEmpty ? name : "\(name) \(version)" }
}

public struct Inventory: Sendable {
    public var reportDate = Date()
    public var vcenters: [VCenter] = []
    public var clusters: [Cluster] = []
    public var hosts: [Host] = []
    public var vms: [VM] = []
    public var datastores: [Datastore] = []
    public var portGroups: [PortGroup] = []
    public var vSwitches: [VSwitchInfo] = []
    public var dvSwitches: [DVSwitchInfo] = []
    public var vmkernels: [VMKernel] = []
    public var pnics: [PhysicalNIC] = []
    public var hbas: [HBA] = []
    public var luns: [MultiPathLUN] = []
    public var licenses: [License] = []
    public var resourcePools: [ResourcePool] = []
    public var health: [HealthItem] = []
    public var joins: [JoinStat] = []
    public var checks: [ConsistencyCheck] = []
    /// Lower-cased names of the tabs in the export (empty for inventories not built from a dataset).
    public var tabsPresent: Set<String> = []
    /// Problems found with the exports as they were read (see `SourceChecks`).
    public var sourceIssues: [SourceIssue] = []
    /// Non-RVTools tools the data was translated from; empty for plain RVTools exports.
    public var sourceTools: [SourceTool] = []

    /// VMs a solution works on by default: not templates, SRM placeholders or vCenter's own cluster agents.
    public var workloadVMs: [VM] { vms.filter { $0.isVM && !$0.isClusterAgent } }

    public var datacenterCount: Int { Set(hosts.map { key($0.vcenter, $0.datacenter) } + vms.map { key($0.vcenter, $0.datacenter) }).count }

    /// Host-local datastores that no workload VM uses (see `Datastore.isUnusedLocal`).
    public var unusedLocalDatastores: [Datastore] { datastores.filter(\.isUnusedLocal) }

    /// VMC management datastores whose capacity is the same vSAN capacity as WorkloadDatastore.
    public var vmcManagementDatastores: [Datastore] { datastores.filter(\.isVMCManagementDatastore) }

    /// The inventory without these datastores; host and cluster datastore counts and vHealth messages follow.
    public func removingDatastores(_ ids: Set<String>) -> Inventory {
        guard !ids.isEmpty else { return self }
        var s = self
        let hostIndex = Dictionary(hosts.enumerated().map { ($1.id, $0) }, uniquingKeysWith: { a, _ in a })
        let clusterIndex = Dictionary(clusters.enumerated().map { ($1.id, $0) }, uniquingKeysWith: { a, _ in a })
        for d in datastores where ids.contains(d.id) {
            for h in Set(d.hostKeys) { if let i = hostIndex[h] { s.hosts[i].datastoreCount = max(0, s.hosts[i].datastoreCount - 1) } }
            for c in Set(d.clusterKeys) { if let i = clusterIndex[c] { s.clusters[i].datastoreCount = max(0, s.clusters[i].datastoreCount - 1) } }
        }
        s.datastores = datastores.filter { !ids.contains($0.id) }
        s.health = health.filter { !ids.contains($0.objectID) }
        return s
    }
    /// Restricts the inventory to a set of clusters (by cluster id). Datastores, networks and host
    /// children follow the hosts/VMs that remain in scope.
    public func scoped(to clusterIDs: Set<String>) -> Inventory {
        var s = self
        s.clusters = clusters.filter { clusterIDs.contains($0.id) }
        s.hosts = hosts.filter { clusterIDs.contains($0.clusterKey) }
        s.vms = vms.filter { clusterIDs.contains($0.clusterKey) }
        let hostIDs = Set(s.hosts.map(\.id))
        let vmIDs = Set(s.vms.map(\.id))
        s.datastores = datastores.filter { ds in ds.hostKeys.contains(where: hostIDs.contains) || ds.vmIDs.contains(where: vmIDs.contains) }
        s.portGroups = portGroups.filter { pg in pg.hostKeys.contains(where: hostIDs.contains) || pg.vmIDs.contains(where: vmIDs.contains) }
        s.vSwitches = vSwitches.filter { hostIDs.contains($0.hostKey) }
        s.vmkernels = vmkernels.filter { hostIDs.contains($0.hostKey) }
        s.pnics = pnics.filter { hostIDs.contains($0.hostKey) }
        s.hbas = hbas.filter { hostIDs.contains($0.hostKey) }
        s.luns = luns.filter { hostIDs.contains($0.hostKey) }
        let servers = Set(s.hosts.map { $0.vcenter.lowercased() } + s.vms.map { $0.vcenter.lowercased() })
        s.vcenters = vcenters.filter { servers.contains($0.server.lowercased()) }
        let dvsNames = Set(s.portGroups.filter { $0.kind == "Distributed" }.map { key($0.vcenter, $0.switchName) })
        s.dvSwitches = dvSwitches.filter { dvsNames.contains(key($0.vcenter, $0.name)) }
        s.licenses = licenses.filter { servers.contains($0.vcenter.lowercased()) }
        s.resourcePools = resourcePools.filter { servers.contains($0.vcenter.lowercased()) }
        let objectIDs = vmIDs.union(hostIDs).union(s.datastores.map(\.id))
        s.health = health.filter { objectIDs.contains($0.objectID) || ($0.objectID.isEmpty && servers.contains($0.vcenter.lowercased())) }
        return s
    }
}
