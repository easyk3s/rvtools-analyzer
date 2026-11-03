import Foundation

public enum Severity: Int, CaseIterable, Comparable, Identifiable, Sendable {
    case critical = 0, warning = 1, info = 2
    public var id: Int { rawValue }
    public static func < (a: Severity, b: Severity) -> Bool { a.rawValue < b.rawValue }
    public var label: String { ["Critical", "Warning", "Info"][rawValue] }
    public var symbol: String { ["xmark.octagon.fill", "exclamationmark.triangle.fill", "info.circle.fill"][rawValue] }
}

public enum FindingCategory: String, CaseIterable, Identifiable, Sendable {
    case availability = "Availability"
    case capacity = "Capacity"
    case performance = "Performance"
    case configuration = "Configuration"
    case lifecycle = "Lifecycle"
    case protection = "Data protection"
    case security = "Security"
    case hygiene = "Hygiene"
    case migration = "Migration readiness"
    public var id: String { rawValue }
}

public struct Finding: Identifiable, Sendable {
    public let id: Int
    public let rule: String
    public let title: String
    public let severity: Severity
    public let category: FindingCategory
    public let kind: ObjectKind
    public let objectID: String
    public let objectName: String
    public let location: String
    public let detail: String
    public var severityRank: Int { severity.rawValue }
    public var kindLabel: String { kind.rawValue }
    public var categoryLabel: String { category.rawValue }
}

public struct FindingGroup: Identifiable, Sendable {
    public var id: String { rule }
    public let rule: String
    public let title: String
    public let severity: Severity
    public let category: FindingCategory
    public let recommendation: String
    public let findings: [Finding]
    public var count: Int { findings.count }
}

/// User-tunable thresholds (exposed in Settings).
public struct Thresholds: Codable, Equatable, Sendable {
    public var snapshotAgeDays = 7.0
    public var snapshotSizeGiB = 50.0
    public var datastoreFreeWarnPct = 20.0
    public var datastoreFreeCritPct = 10.0
    public var datastoreOvercommitPct = 150.0
    public var hostCPUWarnPct = 80.0
    public var hostMemWarnPct = 85.0
    public var vcpuPerCoreWarn = 5.0
    public var guestFreeWarnPct = 10.0
    public var hostUptimeDays = 365.0
    public var certExpiryDays = 90.0
    /// Licenses expiring within this many days are flagged (measured from today; see `License.renewalReference`).
    public var licenseExpiryDays = 90.0
    /// Leave host-local datastores with no VM files (boot / scratch devices) out of every dashboard, finding and solution.
    public var ignoreUnusedLocalDatastores = true
    /// VMC on AWS: leave the management "vsanDatastore" out, since WorkloadDatastore reports the same capacity.
    public var ignoreVMCManagementDatastore = true

    public init() {}

    /// Settings and projects saved before a field existed keep their other values.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Thresholds()
        snapshotAgeDays = try c.decodeIfPresent(Double.self, forKey: .snapshotAgeDays) ?? d.snapshotAgeDays
        snapshotSizeGiB = try c.decodeIfPresent(Double.self, forKey: .snapshotSizeGiB) ?? d.snapshotSizeGiB
        datastoreFreeWarnPct = try c.decodeIfPresent(Double.self, forKey: .datastoreFreeWarnPct) ?? d.datastoreFreeWarnPct
        datastoreFreeCritPct = try c.decodeIfPresent(Double.self, forKey: .datastoreFreeCritPct) ?? d.datastoreFreeCritPct
        datastoreOvercommitPct = try c.decodeIfPresent(Double.self, forKey: .datastoreOvercommitPct) ?? d.datastoreOvercommitPct
        hostCPUWarnPct = try c.decodeIfPresent(Double.self, forKey: .hostCPUWarnPct) ?? d.hostCPUWarnPct
        hostMemWarnPct = try c.decodeIfPresent(Double.self, forKey: .hostMemWarnPct) ?? d.hostMemWarnPct
        vcpuPerCoreWarn = try c.decodeIfPresent(Double.self, forKey: .vcpuPerCoreWarn) ?? d.vcpuPerCoreWarn
        guestFreeWarnPct = try c.decodeIfPresent(Double.self, forKey: .guestFreeWarnPct) ?? d.guestFreeWarnPct
        hostUptimeDays = try c.decodeIfPresent(Double.self, forKey: .hostUptimeDays) ?? d.hostUptimeDays
        certExpiryDays = try c.decodeIfPresent(Double.self, forKey: .certExpiryDays) ?? d.certExpiryDays
        licenseExpiryDays = try c.decodeIfPresent(Double.self, forKey: .licenseExpiryDays) ?? d.licenseExpiryDays
        ignoreUnusedLocalDatastores = try c.decodeIfPresent(Bool.self, forKey: .ignoreUnusedLocalDatastores) ?? d.ignoreUnusedLocalDatastores
        ignoreVMCManagementDatastore = try c.decodeIfPresent(Bool.self, forKey: .ignoreVMCManagementDatastore) ?? d.ignoreVMCManagementDatastore
    }
}

struct RuleDef {
    let title: String
    let severity: Severity
    let category: FindingCategory
    let recommendation: String
}

enum Rules {
    static func catalog(_ t: Thresholds) -> [String: RuleDef] {
        func n(_ v: Double) -> String { Fmt.num(v, v.rounded() == v ? 0 : 1) }
        return [
            // VM
            "vm.snapshot.old": RuleDef(title: "Snapshots older than \(n(t.snapshotAgeDays)) days", severity: .warning, category: .protection,
                                       recommendation: "Snapshots are not backups. Validate and delete/consolidate them; long-lived delta chains grow without bound and degrade I/O."),
            "vm.snapshot.large": RuleDef(title: "Snapshots larger than \(n(t.snapshotSizeGiB)) GiB", severity: .warning, category: .capacity,
                                         recommendation: "Large deltas risk filling the datastore and make consolidation slow. Remove them in a maintenance window."),
            "vm.consolidation": RuleDef(title: "Disk consolidation needed", severity: .critical, category: .protection,
                                        recommendation: "Run Snapshots › Consolidate. Orphaned delta disks keep growing and break backups."),
            "vm.tools.missing": RuleDef(title: "VMware Tools not installed (powered-on VM)", severity: .warning, category: .configuration,
                                        recommendation: "Install VMware Tools / open-vm-tools for quiesced backups, graceful shutdown, heartbeats and paravirtual drivers."),
            "vm.tools.notrunning": RuleDef(title: "VMware Tools not running (powered-on VM)", severity: .warning, category: .configuration,
                                           recommendation: "Check the Tools service in the guest; without it HA VM monitoring and quiescing do not work."),
            "vm.tools.old": RuleDef(title: "VMware Tools out of date", severity: .info, category: .lifecycle,
                                    recommendation: "Upgrade Tools (or set 'Upgrade at power cycle') to pick up driver and security fixes."),
            "vm.heartbeat": RuleDef(title: "Guest heartbeat not healthy", severity: .warning, category: .availability,
                                    recommendation: "A red/yellow heartbeat on a running VM usually means a hung guest or broken Tools."),
            "vm.status": RuleDef(title: "VM configuration status not green", severity: .warning, category: .configuration,
                                 recommendation: "Open the VM's alarms/issues in vCenter to see what is flagged."),
            "vm.os.eol": RuleDef(title: "Guest OS past end of support", severity: .warning, category: .lifecycle,
                                 recommendation: "Plan upgrade or replacement; unsupported OSes get no security patches and often block cloud migration."),
            "vm.os.eolsoon": RuleDef(title: "Guest OS reaches end of support within 12 months", severity: .info, category: .lifecycle,
                                     recommendation: "Add to the upgrade roadmap before support ends."),
            "vm.os.mismatch": RuleDef(title: "Configured guest OS differs from running OS", severity: .info, category: .configuration,
                                      recommendation: "Set the VM's Guest OS to match the installed OS so vSphere applies the right defaults and support policy."),
            "vm.hw.old": RuleDef(title: "Virtual hardware older than vmx-11 (vSphere 6.0)", severity: .info, category: .lifecycle,
                                 recommendation: "Upgrade VM compatibility after upgrading Tools to unlock newer device and security features."),
            "vm.nic.legacy": RuleDef(title: "Legacy E1000/E1000e network adapter", severity: .info, category: .performance,
                                     recommendation: "Replace with VMXNET3 for lower CPU overhead and higher throughput."),
            "vm.scsi.legacy": RuleDef(title: "Legacy SCSI controller (BusLogic / LSI Logic Parallel)", severity: .info, category: .performance,
                                      recommendation: "Use LSI Logic SAS or VMware Paravirtual (PVSCSI) for supported OSes."),
            "vm.cdrom": RuleDef(title: "CD/DVD drive connected", severity: .info, category: .hygiene,
                                recommendation: "Disconnect ISO/host devices; they can block vMotion, DRS and maintenance mode."),
            "vm.usb": RuleDef(title: "USB device connected", severity: .info, category: .migration,
                              recommendation: "Passthrough USB devices tie a VM to a host and block vMotion / migration."),
            "vm.nic.disconnected": RuleDef(title: "Network adapter not connected on powered-on VM", severity: .info, category: .hygiene,
                                           recommendation: "Remove unused NICs or reconnect them."),
            "vm.limits": RuleDef(title: "CPU or memory limit configured", severity: .warning, category: .performance,
                                 recommendation: "Limits silently throttle VMs (memory limits force ballooning/swapping). Remove unless intentional."),
            "vm.memory.pressure": RuleDef(title: "Memory ballooning or swapping", severity: .warning, category: .performance,
                                          recommendation: "The host is reclaiming memory from this VM. Check host memory usage, limits and reservations."),
            "vm.cpu.readiness": RuleDef(title: "High CPU readiness (> 5%)", severity: .warning, category: .performance,
                                        recommendation: "The VM waits for physical CPU. Reduce vCPU count or cluster vCPU:core ratio."),
            "vm.vcpu.exceedsHost": RuleDef(title: "More vCPUs than host physical cores", severity: .critical, category: .performance,
                                           recommendation: "A VM should never have more vCPUs than its host has cores; right-size it."),
            "vm.vcpu.wide": RuleDef(title: "vCPUs exceed host cores per socket (NUMA-wide VM)", severity: .info, category: .performance,
                                    recommendation: "Wide VMs span NUMA nodes; confirm vNUMA topology (sockets × cores) matches the host."),
            "vm.hotadd.vnuma": RuleDef(title: "CPU hot-add enabled on VM with > 8 vCPUs", severity: .info, category: .performance,
                                       recommendation: "CPU hot-add disables vNUMA; disable it on large VMs."),
            "vm.partition.critical": RuleDef(title: "Guest partition less than 5% free", severity: .critical, category: .capacity,
                                             recommendation: "The guest file system is nearly full; extend the disk or clean up."),
            "vm.partition.low": RuleDef(title: "Guest partition less than \(n(t.guestFreeWarnPct))% free", severity: .warning, category: .capacity,
                                        recommendation: "Plan to extend the disk or clean up before it fills."),
            "vm.disk.independent": RuleDef(title: "Independent persistent disks (excluded from snapshots / backups)", severity: .warning, category: .protection,
                                           recommendation: "Snapshot-based backups skip independent disks. Confirm they are protected another way."),
            "vm.disk.rdm": RuleDef(title: "Raw device mapping (RDM) disks", severity: .info, category: .migration,
                                   recommendation: "RDMs need special handling for migration/backup; consider converting to VMDK."),
            "vm.disk.shared": RuleDef(title: "Shared / multi-writer disks or shared SCSI bus", severity: .info, category: .migration,
                                      recommendation: "Clustered disks (e.g. WSFC, Oracle RAC) constrain vMotion, snapshots and migration targets."),
            "vm.localds": RuleDef(title: "VM on a non-shared datastore in a multi-host cluster", severity: .warning, category: .availability,
                                  recommendation: "HA cannot restart and DRS cannot move VMs on local storage. Move to shared storage."),
            "vm.dup.ip": RuleDef(title: "Duplicate IPv4 address across powered-on VMs", severity: .warning, category: .configuration,
                                 recommendation: "Verify addressing; duplicates cause intermittent connectivity (ignore for intentional NAT/isolated networks)."),
            "vm.dup.mac": RuleDef(title: "Duplicate MAC address", severity: .critical, category: .configuration,
                                  recommendation: "Duplicate MACs break connectivity; regenerate the MAC on one VM."),
            "vm.dup.name": RuleDef(title: "Duplicate VM name", severity: .info, category: .hygiene,
                                   recommendation: "Duplicate names confuse operations, backup and migration tooling."),
            "vm.poweredoff": RuleDef(title: "Powered-off VM (reclaim candidate)", severity: .info, category: .hygiene,
                                     recommendation: "Confirm with owners; archive or delete to reclaim storage and licences."),
            "vm.cbt.off": RuleDef(title: "Changed Block Tracking disabled", severity: .info, category: .protection,
                                  recommendation: "Other VMs use CBT; enable it here too for efficient incremental backups."),
            "vm.ft": RuleDef(title: "Fault Tolerance enabled", severity: .info, category: .migration,
                             recommendation: "FT VMs have strict host/network requirements; plan them separately."),
            "vm.nonetwork": RuleDef(title: "Powered-on VM with no connected network", severity: .info, category: .configuration,
                                    recommendation: "Isolated VMs may be intentional; otherwise check the NIC."),
            "vhealth.zombie": RuleDef(title: "Possible zombie VMDK / orphaned files (RVTools)", severity: .warning, category: .hygiene,
                                      recommendation: "Files not attached to any registered VM. Verify and delete to reclaim space."),
            "vhealth.foldername": RuleDef(title: "VM name differs from its folder name (RVTools)", severity: .info, category: .hygiene,
                                          recommendation: "Usually a renamed VM; a Storage vMotion renames the folder and files."),
            // Host
            "host.maintenance": RuleDef(title: "Host in maintenance mode", severity: .info, category: .availability,
                                        recommendation: "Capacity is reduced while hosts are in maintenance; confirm it is intentional."),
            "host.status": RuleDef(title: "Host configuration status not green", severity: .warning, category: .configuration,
                                   recommendation: "Review host alarms/configuration issues in vCenter."),
            "host.cpu.high": RuleDef(title: "Host CPU usage above \(n(t.hostCPUWarnPct))%", severity: .warning, category: .performance,
                                     recommendation: "Rebalance with DRS or add capacity."),
            "host.mem.high": RuleDef(title: "Host memory usage above \(n(t.hostMemWarnPct))%", severity: .warning, category: .capacity,
                                     recommendation: "High memory use leads to ballooning/swapping; rebalance or add memory."),
            "host.vcpuratio": RuleDef(title: "Host vCPU : core ratio above \(n(t.vcpuPerCoreWarn)):1", severity: .warning, category: .performance,
                                      recommendation: "High consolidation raises CPU ready time; watch readiness or rebalance."),
            "host.esxi.eol": RuleDef(title: "ESXi version past end of general support", severity: .critical, category: .lifecycle,
                                     recommendation: "Upgrade ESXi; unsupported releases receive no security patches."),
            "host.esxi.eolsoon": RuleDef(title: "ESXi version reaches end of support within 12 months", severity: .warning, category: .lifecycle,
                                         recommendation: "Schedule the upgrade before support ends."),
            "host.ntp": RuleDef(title: "NTP not configured or not running", severity: .warning, category: .configuration,
                                recommendation: "Time drift breaks authentication, logs correlation and vSAN/HA. Configure NTP and start ntpd."),
            "host.cert.expired": RuleDef(title: "Host certificate expired", severity: .critical, category: .security,
                                         recommendation: "Renew the host certificate."),
            "host.cert.expiring": RuleDef(title: "Host certificate expires within \(n(t.certExpiryDays)) days", severity: .warning, category: .security,
                                          recommendation: "Renew before expiry to avoid vCenter connection failures."),
            "host.uptime": RuleDef(title: "Host up longer than \(n(t.hostUptimeDays)) days (likely unpatched)", severity: .info, category: .lifecycle,
                                   recommendation: "Long uptime implies missed patches; plan a rolling update."),
            "host.ht": RuleDef(title: "Hyperthreading available but not active", severity: .info, category: .performance,
                               recommendation: "Enable HT in BIOS/ESXi unless disabled intentionally for side-channel mitigation."),
            "host.nic.redundancy": RuleDef(title: "Fewer than 2 physical NICs", severity: .warning, category: .availability,
                                           recommendation: "A single uplink is a single point of failure."),
            "host.nic.down": RuleDef(title: "Physical NIC link down", severity: .info, category: .availability,
                                     recommendation: "An uplink assigned to a switch shows no link; check cabling/switch ports."),
            "host.lun.dead": RuleDef(title: "Dead storage paths", severity: .critical, category: .availability,
                                     recommendation: "Investigate fabric/array ports; the LUN is running with reduced redundancy."),
            "host.lun.singlepath": RuleDef(title: "LUN with a single storage path", severity: .warning, category: .availability,
                                           recommendation: "Configure multipathing so a single HBA/port failure doesn't drop the datastore."),
            // Datastore pathing
            "ds.path.dead": RuleDef(title: "Dead paths to a datastore", severity: .critical, category: .availability,
                                    recommendation: "The datastore runs with reduced redundancy. Check the fabric, array ports and HBA state."),
            "ds.path.single": RuleDef(title: "Datastore reached over a single path", severity: .critical, category: .availability,
                                      recommendation: "One HBA, cable, fabric or array port failure takes the datastore away from that host. Present the LUN over at least two paths."),
            "ds.path.adapter": RuleDef(title: "All paths to a datastore on one adapter", severity: .warning, category: .availability,
                                       recommendation: "Paths run over several array ports but a single HBA. Zone the LUN to a second HBA so the adapter isn't a single point of failure."),
            "ds.path.uneven": RuleDef(title: "Hosts see different numbers of paths", severity: .warning, category: .configuration,
                                      recommendation: "Uneven zoning or masking: a host with fewer paths loses redundancy first and performs differently. Align zoning across the cluster."),
            "ds.path.policy": RuleDef(title: "Path selection policy isn't Round Robin", severity: .info, category: .performance,
                                      recommendation: "Most active/active arrays expect VMW_PSP_RR. Confirm the vendor's supported policy (some arrays require Fixed or MRU)."),
            "ds.path.mixedpolicy": RuleDef(title: "Mixed path selection policies for one datastore", severity: .warning, category: .configuration,
                                           recommendation: "Hosts use different policies for the same LUN; performance and failover behaviour differ per host. Set one policy, usually by claim rule."),
            "ds.path.nodata": RuleDef(title: "No multipathing data for some hosts", severity: .info, category: .configuration,
                                      recommendation: "The vMultiPath tab has no rows for these hosts, so their redundancy can't be checked. Re-export with multipathing included."),
            "ds.nfs.novmk": RuleDef(title: "NFS datastore with no storage VMkernel adapter", severity: .warning, category: .availability,
                                    recommendation: "NFS traffic falls back to whichever adapter carries that subnet, usually management. Give each host a VMkernel adapter on the storage network."),
            "ds.nfs.singlevmk": RuleDef(title: "NFS datastore reached over one VMkernel adapter", severity: .info, category: .availability,
                                        recommendation: "NFS redundancy comes from the network: the adapter's port group should have two uplinks, or add a second VMkernel adapter with its own subnet for session trunking."),
            "ds.nfs.uplink": RuleDef(title: "NFS VMkernel adapter on a switch with one uplink", severity: .critical, category: .availability,
                                     recommendation: "A single NIC or cable failure takes the datastore away from that host. Add an uplink to the switch carrying the storage port group."),
            "ds.nfs.mtu": RuleDef(title: "Mixed MTU on the NFS storage network", severity: .warning, category: .configuration,
                                  recommendation: "Jumbo frames must match end to end (VMkernel, switches, array). Mismatched MTUs cause fragmentation or silent drops."),
            // Cluster
            "cluster.ha.off": RuleDef(title: "vSphere HA disabled", severity: .critical, category: .availability,
                                      recommendation: "Without HA, VMs are not restarted after a host failure."),
            "cluster.drs.off": RuleDef(title: "DRS disabled", severity: .warning, category: .performance,
                                       recommendation: "Enable DRS (at least partially automated) to balance load and simplify maintenance."),
            "cluster.ac.off": RuleDef(title: "HA admission control disabled", severity: .warning, category: .availability,
                                      recommendation: "Without admission control the cluster can be filled beyond what survives a host failure."),
            "cluster.n1.mem": RuleDef(title: "Cannot absorb loss of largest host (memory)", severity: .critical, category: .capacity,
                                      recommendation: "Current memory use exceeds what the remaining hosts provide; add capacity or reduce load."),
            "cluster.n1.cpu": RuleDef(title: "Cannot absorb loss of largest host (CPU)", severity: .warning, category: .capacity,
                                      recommendation: "Current CPU use exceeds what the remaining hosts provide."),
            "cluster.ratio": RuleDef(title: "Cluster vCPU : core ratio above \(n(t.vcpuPerCoreWarn)):1", severity: .warning, category: .performance,
                                     recommendation: "Review CPU ready times; consider right-sizing VMs or adding hosts."),
            "cluster.mixed.esxi": RuleDef(title: "Mixed ESXi builds in cluster", severity: .info, category: .lifecycle,
                                          recommendation: "Bring all hosts to the same build for consistent behaviour."),
            "cluster.mixed.cpu": RuleDef(title: "Mixed CPU models without EVC", severity: .warning, category: .configuration,
                                         recommendation: "Enable EVC so vMotion works across CPU generations."),
            "cluster.single": RuleDef(title: "Single-host cluster", severity: .info, category: .availability,
                                      recommendation: "No failover capacity; HA/DRS provide no protection."),
            // Datastore
            "ds.free.critical": RuleDef(title: "Datastore free space below \(n(t.datastoreFreeCritPct))%", severity: .critical, category: .capacity,
                                        recommendation: "Free space now: a full datastore stops VMs with thin disks or snapshots."),
            "ds.free.low": RuleDef(title: "Datastore free space below \(n(t.datastoreFreeWarnPct))%", severity: .warning, category: .capacity,
                                   recommendation: "Plan expansion or Storage vMotion VMs away."),
            "ds.overcommit": RuleDef(title: "Datastore provisioned above \(n(t.datastoreOvercommitPct))% of capacity", severity: .warning, category: .capacity,
                                     recommendation: "Thin-provisioned overcommit: if guests fill their disks the datastore runs out."),
            "ds.inaccessible": RuleDef(title: "Datastore not accessible", severity: .critical, category: .availability,
                                       recommendation: "Check storage connectivity."),
            "ds.empty": RuleDef(title: "Datastore with no VMs", severity: .info, category: .hygiene,
                                recommendation: "Unused capacity — confirm and reclaim, or use it."),
            "ds.vmfs.old": RuleDef(title: "VMFS version older than 6", severity: .info, category: .lifecycle,
                                   recommendation: "VMFS 5 lacks automatic UNMAP and 4Kn support; migrate to VMFS 6."),
            // Network
            "net.security": RuleDef(title: "Port group allows promiscuous mode, MAC changes or forged transmits", severity: .warning, category: .security,
                                    recommendation: "Set these to Reject unless required (e.g. nested ESXi, some appliances)."),
            "net.unused": RuleDef(title: "Port group with no VMs", severity: .info, category: .hygiene,
                                  recommendation: "Remove unused port groups to reduce clutter and misconfiguration risk."),
            // vCenter / licensing
            "vc.eol": RuleDef(title: "vCenter past end of general support", severity: .critical, category: .lifecycle,
                              recommendation: "Upgrade vCenter first — it must be at or above the ESXi version."),
            "vc.eolsoon": RuleDef(title: "vCenter reaches end of support within 12 months", severity: .warning, category: .lifecycle,
                                  recommendation: "Schedule the vCenter upgrade."),
            "lic.expired": RuleDef(title: "License expired", severity: .critical, category: .lifecycle,
                                   recommendation: "Renew or replace the license now: an expired license can stop hosts or features from working and ends the support entitlement."),
            "lic.expiring": RuleDef(title: "License expiring within \(n(t.licenseExpiryDays)) days", severity: .warning, category: .lifecycle,
                                    recommendation: "Renew or replace the license before it expires, confirming the quantity and term. Evaluation licenses need a permanent license."),
            "lic.overused": RuleDef(title: "License usage exceeds capacity", severity: .warning, category: .lifecycle,
                                    recommendation: "Assign additional licence capacity."),
        ]
    }

    struct Emitter {
        var catalog: [String: RuleDef]
        var findings: [Finding] = []

        mutating func define(_ rule: String, _ def: RuleDef) { if catalog[rule] == nil { catalog[rule] = def } }

        mutating func add(_ rule: String, _ kind: ObjectKind, _ id: String, _ name: String, _ location: String, _ detail: String) {
            guard let def = catalog[rule] else { assertionFailure("Unknown rule \(rule)"); return }
            findings.append(Finding(id: findings.count, rule: rule, title: def.title, severity: def.severity, category: def.category,
                                    kind: kind, objectID: id, objectName: name, location: location, detail: detail))
        }
    }

    static func evaluate(_ inv: Inventory, _ t: Thresholds) -> (findings: [Finding], catalog: [String: RuleDef]) {
        var e = Emitter(catalog: catalog(t))
        let now = inv.reportDate
        // Support end dates are judged from today (or the export date if later), not when the export was taken.
        let supportDate = Lifecycle.supportReference(exportDate: now)
        let yearAhead = supportDate.addingTimeInterval(365 * 86_400)
        let hosts = Dictionary(inv.hosts.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let clusters = Dictionary(inv.clusters.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let datastores = Dictionary(inv.datastores.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let cbtInUse = inv.vms.contains { $0.cbt == true }
        func loc(_ vm: VM) -> String { [clusters[vm.clusterKey]?.name ?? vm.cluster, vm.host].filter { !$0.isEmpty }.joined(separator: " › ") }

        // MARK: VMs
        var ipMap: [String: [Int]] = [:], macMap: [String: [Int]] = [:], nameMap: [String: [Int]] = [:]
        let ignoredIPs: Set<String> = ["0.0.0.0", "127.0.0.1", "192.168.122.1", "172.17.0.1"]
        for (i, vm) in inv.vms.enumerated() {
            let L = loc(vm)
            let f = { (rule: String, detail: String) in e.add(rule, .vm, vm.id, vm.name, L, detail) }
            if vm.isVM {
                nameMap[key(vm.vcenter, vm.name), default: []].append(i)
                for n in vm.nics where !n.mac.isEmpty { macMap[n.mac.lowercased(), default: []].append(i) }
            }

            if !vm.snapshots.isEmpty {
                let old = vm.snapshots.filter { ($0.ageDays ?? 0) > t.snapshotAgeDays }
                if let oldest = old.max(by: { ($0.ageDays ?? 0) < ($1.ageDays ?? 0) }) {
                    f("vm.snapshot.old", "\(old.count) snapshot(s); oldest \(Fmt.num(oldest.ageDays ?? 0, 0)) days: \"\(oldest.name)\"")
                }
                if vm.snapshotSizeMiB > t.snapshotSizeGiB * 1024 {
                    f("vm.snapshot.large", "\(vm.snapshots.count) snapshot(s) totalling \(Fmt.capacity(mib: vm.snapshotSizeMiB))")
                }
            }
            if vm.consolidationNeeded { f("vm.consolidation", "vCenter reports consolidation needed") }
            if vm.isTemplate { continue }

            if vm.isRunning {
                switch Lifecycle.toolsLabel(vm.toolsStatus) {
                case "Not installed": f("vm.tools.missing", vm.os.name)
                case "Not running": f("vm.tools.notrunning", vm.os.name)
                default: break
                }
                let hb = vm.heartbeat.lowercased()
                if hb == "red" || hb == "yellow" { f("vm.heartbeat", "Heartbeat: \(vm.heartbeat)") }
                for ip in vm.ips where !ignoredIPs.contains(ip) && !ip.hasPrefix("169.254.") && !ip.hasPrefix("127.") {
                    ipMap[ip, default: []].append(i)
                }
                if !vm.nics.isEmpty && !vm.nics.contains(where: \.connected) { f("vm.nonetwork", "\(vm.nics.count) NIC(s), none connected") }
                for n in vm.nics where !n.connected && !n.network.isEmpty { f("vm.nic.disconnected", "\(n.label) on \(n.network)") }
                if vm.memBalloonedMiB > 0 || vm.memSwappedMiB > 0 {
                    f("vm.memory.pressure", "Ballooned \(Fmt.memory(mib: vm.memBalloonedMiB)), swapped \(Fmt.memory(mib: vm.memSwappedMiB))")
                }
                if let rdy = vm.cpuReadinessPct, rdy > 5 { f("vm.cpu.readiness", "CPU ready \(Fmt.num(rdy, 1))%") }
                // Desktop VMs are usually VDI and not image-level backed up, so they are skipped.
                if vm.cbt == false && cbtInUse && vm.os.family != .windowsDesktop && vm.disks.contains(where: { !$0.isIndependent }) {
                    f("vm.cbt.off", "CBT disabled")
                }
                if vm.usbConnected > 0 { f("vm.usb", "\(vm.usbConnected) USB device(s)") }
            }
            if Lifecycle.toolsLabel(vm.toolsStatus) == "Out of date" { f("vm.tools.old", "Tools \(vm.toolsVersion)") }
            let cs = vm.configStatus.lowercased()
            if cs == "red" || cs == "yellow" { f("vm.status", "Config status: \(vm.configStatus)") }
            if let eol = vm.os.endOfSupport {
                if eol <= supportDate { f("vm.os.eol", "\(vm.os.name) — support ended \(Fmt.date(eol))") }
                else if eol <= yearAhead { f("vm.os.eolsoon", "\(vm.os.name) — support ends \(Fmt.date(eol))") }
            }
            if !vm.osConfig.isEmpty, !vm.osTools.isEmpty {
                let a = Lifecycle.classify(config: vm.osConfig, tools: ""), b = Lifecycle.classify(config: "", tools: vm.osTools)
                let specific = { (o: OSInfo) in o.name.rangeOfCharacter(from: .decimalDigits) != nil && !o.name.hasSuffix("+") }
                // vSphere has no separate "2012 R2" guest type, so R2 is not a mismatch.
                let base = { (o: OSInfo) in o.name.replacingOccurrences(of: " R2", with: "") }
                if a.family != .other, b.family != .other, a.family != b.family || (specific(a) && specific(b) && base(a) != base(b)) {
                    f("vm.os.mismatch", "Configured: \(vm.osConfig) · Running: \(vm.osTools)")
                }
            }
            if vm.hwVersion > 0 && vm.hwVersion < 11 { f("vm.hw.old", Lifecycle.hardwareLabel(vm.hwVersion)) }
            let legacyNICs = vm.nics.filter { $0.adapter.lowercased().hasPrefix("e1000") }
            if !legacyNICs.isEmpty { f("vm.nic.legacy", legacyNICs.map { "\($0.label): \($0.adapter)" }.joined(separator: ", ")) }
            let legacyCtrl = Set(vm.disks.map(\.controller).filter { let c = $0.lowercased(); return c.contains("buslogic") || c == "lsi logic" || c == "lsi logic parallel" })
            if !legacyCtrl.isEmpty { f("vm.scsi.legacy", legacyCtrl.sorted().joined(separator: ", ")) }
            let cds = vm.cdroms.filter(\.connected)
            if !cds.isEmpty { f("vm.cdrom", cds.map { "\($0.node) \($0.deviceType)" }.joined(separator: ", ")) }
            var limits: [String] = []
            if vm.cpuLimitMHz >= 0 { limits.append("CPU limit \(Fmt.int(Int(vm.cpuLimitMHz))) MHz") }
            if vm.memLimitMiB >= 0 { limits.append("memory limit \(Fmt.memory(mib: vm.memLimitMiB))") }
            if !limits.isEmpty { f("vm.limits", limits.joined(separator: ", ")) }
            if let h = hosts[vm.hostKey], h.cores > 0 {
                if vm.cpus > h.cores { f("vm.vcpu.exceedsHost", "\(vm.cpus) vCPU on a \(h.cores)-core host") }
                else if h.coresPerSocket > 0, vm.cpus > h.coresPerSocket, vm.isRunning {
                    f("vm.vcpu.wide", "\(vm.cpus) vCPU (\(vm.sockets)×\(vm.coresPerSocket)) vs \(h.coresPerSocket) cores/socket")
                }
            }
            if vm.cpuHotAdd && vm.cpus > 8 { f("vm.hotadd.vnuma", "\(vm.cpus) vCPU with CPU hot-add") }
            for p in vm.partitions where p.capacityMiB > 0 {
                if p.freePct < 5 { f("vm.partition.critical", "\(p.disk): \(Fmt.num(p.freePct, 1))% free of \(Fmt.capacity(mib: p.capacityMiB))") }
                else if p.freePct < t.guestFreeWarnPct { f("vm.partition.low", "\(p.disk): \(Fmt.num(p.freePct, 1))% free of \(Fmt.capacity(mib: p.capacityMiB))") }
            }
            // Non-persistent independent disks (e.g. Horizon disposable disks) discard changes by design; only persistent ones are a backup gap.
            let indep = vm.disks.filter { $0.isIndependent && !$0.mode.lowercased().contains("nonpersistent") }
            if !indep.isEmpty { f("vm.disk.independent", indep.map { "\($0.label) (\($0.mode))" }.joined(separator: ", ")) }
            let rdms = vm.disks.filter(\.raw)
            if !rdms.isEmpty { f("vm.disk.rdm", "\(rdms.count) RDM disk(s), \(Fmt.capacity(mib: rdms.reduce(0) { $0 + $1.capacityMiB }))") }
            let shared = vm.disks.filter { ($0.sharing.lowercased().contains("multi")) || (!$0.sharedBus.isEmpty && $0.sharedBus.lowercased() != "nosharing" && $0.sharedBus.lowercased() != "none") }
            if !shared.isEmpty { f("vm.disk.shared", shared.map { "\($0.label) \($0.sharing) \($0.sharedBus)".trimmingCharacters(in: .whitespaces) }.joined(separator: ", ")) }
            if let c = clusters[vm.clusterKey], c.hostCount > 1, !c.isStandalone {
                let local = vm.datastores.compactMap { datastores[key(vm.vcenter, $0)] }.filter(\.isLocal)
                if !local.isEmpty { f("vm.localds", local.map(\.name).joined(separator: ", ")) }
            }
            if vm.powerState == .off {
                f("vm.poweredoff", "\(Fmt.capacity(mib: vm.provisionedMiB)) provisioned, \(Fmt.capacity(mib: vm.inUseMiB)) in use")
            }
            let ft = vm.ftState.lowercased()
            if !ft.isEmpty && ft != "notconfigured" && ft != "not configured" { f("vm.ft", "FT state: \(vm.ftState)") }
        }
        for (ip, idxs) in ipMap where Set(idxs).count > 1 {
            for i in Set(idxs) {
                let others = Set(idxs).filter { $0 != i }.map { inv.vms[$0].name }.sorted()
                e.add("vm.dup.ip", .vm, inv.vms[i].id, inv.vms[i].name, loc(inv.vms[i]), "\(ip) also on \(others.joined(separator: ", "))")
            }
        }
        for (mac, idxs) in macMap where Set(idxs).count > 1 {
            for i in Set(idxs) {
                let others = Set(idxs).filter { $0 != i }.map { inv.vms[$0].name }.sorted()
                e.add("vm.dup.mac", .vm, inv.vms[i].id, inv.vms[i].name, loc(inv.vms[i]), "\(mac) also on \(others.joined(separator: ", "))")
            }
        }
        for (_, idxs) in nameMap where idxs.count > 1 {
            for i in idxs { e.add("vm.dup.name", .vm, inv.vms[i].id, inv.vms[i].name, loc(inv.vms[i]), "\(idxs.count) VMs share this name") }
        }

        // MARK: RVTools vHealth
        for h in inv.health {
            let type = h.type.trimmingCharacters(in: .whitespaces)
            let lt = type.lowercased()
            if lt == "vm tools" || lt == "snapshot" || lt == "cdrom" { continue } // covered by the richer rules above
            let rule: String
            if lt == "zombie" { rule = "vhealth.zombie" }
            else if lt == "foldername" { rule = "vhealth.foldername" }
            else {
                rule = "vhealth.type." + lt
                let sev: Severity = (lt.contains("storage") || lt.contains("host") || lt.contains("error")) ? .warning : .info
                e.define(rule, RuleDef(title: "RVTools vHealth: \(type.isEmpty ? "Other" : type)", severity: sev, category: lt.contains("perf") ? .performance : .configuration,
                                       recommendation: "Review the RVTools message text for each object."))
            }
            e.add(rule, h.kind, h.objectID, h.name, h.vcenter, h.message)
        }

        // MARK: Hosts
        // Hosts and datastores known only by name from vInfo have no configuration to check.
        for h in inv.hosts where !h.inferred {
            let L = clusters[h.clusterKey]?.name ?? h.cluster
            let f = { (rule: String, detail: String) in e.add(rule, .host, h.id, h.name, L, detail) }
            if h.maintenance { f("host.maintenance", "In maintenance mode") }
            let cs = h.configStatus.lowercased()
            if cs == "red" || cs == "yellow" { f("host.status", "Config status: \(h.configStatus)") }
            if h.cpuUsagePct > t.hostCPUWarnPct { f("host.cpu.high", "CPU \(Fmt.pct(h.cpuUsagePct))") }
            if h.memUsagePct > t.hostMemWarnPct { f("host.mem.high", "Memory \(Fmt.pct(h.memUsagePct)) of \(Fmt.memory(mib: h.memoryMiB))") }
            if h.vcpuPerCore > t.vcpuPerCoreWarn { f("host.vcpuratio", "\(h.vcpuOn) vCPU on \(h.cores) cores (\(Fmt.ratio(h.vcpuPerCore)))") }
            if let eol = Lifecycle.vsphereEndOfSupport(h.esxVersion) {
                if eol <= supportDate { f("host.esxi.eol", "ESXi \(h.esxVersion) — support ended \(Fmt.date(eol))") }
                else if eol <= yearAhead { f("host.esxi.eolsoon", "ESXi \(h.esxVersion) — support ends \(Fmt.date(eol))") }
            }
            if h.ntpReported, h.ntpServers.trimmingCharacters(in: .whitespaces).isEmpty || h.ntpdRunning == false {
                f("host.ntp", h.ntpServers.isEmpty ? "No NTP servers configured" : "ntpd not running (servers: \(h.ntpServers))")
            }
            if let exp = h.certExpiry {
                if exp <= now { f("host.cert.expired", "Expired \(Fmt.date(exp))") }
                else if exp <= now.addingTimeInterval(t.certExpiryDays * 86_400) { f("host.cert.expiring", "Expires \(Fmt.date(exp))") }
            }
            if let up = h.uptimeDays, up > t.hostUptimeDays { f("host.uptime", "Up \(Fmt.num(up, 0)) days (booted \(Fmt.date(h.bootTime)))") }
            if h.htAvailable && !h.htActive { f("host.ht", "HT available, not active") }
            if h.pnicCount > 0 && h.pnicCount < 2 { f("host.nic.redundancy", "\(h.pnicCount) physical NIC") }
        }
        for n in inv.pnics where n.speedMbps == 0 && !n.switchName.isEmpty {
            e.add("host.nic.down", .host, n.hostKey, n.host, n.switchName, "\(n.device) on \(n.switchName) has no link")
        }
        for l in inv.luns {
            let label = l.datastore.isEmpty ? (l.displayName.isEmpty ? l.disk : l.displayName) : l.datastore
            if l.deadPaths > 0 { e.add("host.lun.dead", .host, l.hostKey, l.host, label, "\(l.deadPaths) of \(l.paths) paths dead to \(label)") }
            else if l.paths == 1 { e.add("host.lun.singlepath", .host, l.hostKey, l.host, label, "Single path to \(label) (\(l.policy))") }
        }

        // MARK: Clusters
        let inferredClusters = Set(inv.hosts.filter(\.inferred).map(\.clusterKey))
        for c in inv.clusters where !c.isStandalone && !inferredClusters.contains(c.id) {
            let L = [c.vcenter, c.datacenter].filter { !$0.isEmpty }.joined(separator: " › ")
            let f = { (rule: String, detail: String) in e.add(rule, .cluster, c.id, c.name, L, detail) }
            if c.hostCount == 1 { f("cluster.single", "1 host") }
            if c.hostCount > 1 {
                if c.haEnabled == false { f("cluster.ha.off", "\(c.hostCount) hosts, HA disabled") }
                if c.drsEnabled == false { f("cluster.drs.off", "\(c.hostCount) hosts, DRS disabled") }
                if c.haEnabled == true && c.admissionControl == false { f("cluster.ac.off", "HA on, admission control off") }
                if c.memPctAfterHostLoss > 100 {
                    f("cluster.n1.mem", "Memory use \(Fmt.memory(mib: c.memUsedMiB)) vs \(Fmt.memory(mib: c.memoryMiB - c.largestHostMemMiB)) left after losing the largest host (\(Fmt.pct(c.memPctAfterHostLoss)))")
                }
                if c.cpuPctAfterHostLoss > 100 {
                    f("cluster.n1.cpu", "CPU use \(Fmt.ghz(c.cpuUsedMHz)) vs \(Fmt.ghz(c.cpuMHz - c.largestHostCpuMHz)) left after losing the largest host (\(Fmt.pct(c.cpuPctAfterHostLoss)))")
                }
                if Set(c.cpuModels).count > 1 {
                    let evc = inv.hosts.filter { $0.clusterKey == c.id }.map(\.evcCurrent)
                    if evc.allSatisfy({ $0.isEmpty || $0.lowercased() == "disabled" }) { f("cluster.mixed.cpu", c.cpuModels.joined(separator: " · ")) }
                }
                if c.esxVersions.count > 1 { f("cluster.mixed.esxi", c.esxVersions.joined(separator: " · ")) }
            }
            if c.vcpuPerCore > t.vcpuPerCoreWarn { f("cluster.ratio", "\(c.vcpuOn) vCPU on \(c.cores) cores (\(Fmt.ratio(c.vcpuPerCore)))") }
        }

        // MARK: Datastores
        let pathsByDatastore = StoragePaths.map(inv)
        for d in inv.datastores where !d.inferred {
            let L = d.clusterList.isEmpty ? d.type : d.clusterList
            let f = { (rule: String, detail: String) in e.add(rule, .datastore, d.id, d.name, L, detail) }
            if !d.accessible { f("ds.inaccessible", "Not accessible") }
            else if !d.inaccessibleFrom.isEmpty { f("ds.inaccessible", "Not accessible from \(d.inaccessibleFrom.joined(separator: ", "))") }
            if d.capacityMiB > 0 {
                let detail = "\(Fmt.num(d.freePct, 1))% free (\(Fmt.capacity(mib: d.freeMiB)) of \(Fmt.capacity(mib: d.capacityMiB)))"
                if d.freePct < t.datastoreFreeCritPct { f("ds.free.critical", detail) }
                else if d.freePct < t.datastoreFreeWarnPct { f("ds.free.low", detail) }
                if d.provisionedPct > t.datastoreOvercommitPct { f("ds.overcommit", "\(Fmt.pct(d.provisionedPct)) provisioned (\(Fmt.capacity(mib: d.provisionedMiB)))") }
            }
            if d.hasNoWorkload && d.capacityMiB > 0 {
                let agents = d.agentVMIDs.isEmpty ? "" : " · only \(d.agentVMIDs.count) vCLS agent VM\(d.agentVMIDs.count == 1 ? "" : "s")"
                f("ds.empty", "\(Fmt.capacity(mib: d.capacityMiB)) \(d.type)" + agents)
            }
            if d.type.lowercased() == "vmfs" && d.majorVersion > 0 && d.majorVersion < 6 { f("ds.vmfs.old", "VMFS \(d.majorVersion)") }

            // Pathing: multipathing for block storage, VMkernel adapters and uplinks for NFS.
            let p = pathsByDatastore[d.id] ?? DatastorePaths()
            let names = { (list: [HostStoragePaths]) in list.map(\.host).sorted().joined(separator: ", ") }
            if !p.deadPathHosts.isEmpty {
                f("ds.path.dead", "\(p.deadPaths) dead path\(p.deadPaths == 1 ? "" : "s") on \(names(p.deadPathHosts))")
            }
            if !p.singlePathHosts.isEmpty {
                f("ds.path.single", "1 path from \(names(p.singlePathHosts)) (\(p.transport.rawValue))")
            }
            if !p.singleAdapterHosts.isEmpty {
                let h = p.singleAdapterHosts[0]
                f("ds.path.adapter", "\(p.singleAdapterHosts.count) host\(p.singleAdapterHosts.count == 1 ? "" : "s") use only \(h.adapterList): \(names(p.singleAdapterHosts))")
            }
            if p.transport.isBlock, p.minPaths > 0, p.maxPaths > p.minPaths {
                f("ds.path.uneven", "\(p.minPaths)–\(p.maxPaths) paths across \(p.hosts.count) hosts")
            }
            if p.policies.count > 1 {
                f("ds.path.mixedpolicy", p.policies.map(StoragePaths.policyName).joined(separator: ", "))
            } else if let policy = p.policies.first, policy.uppercased() != "VMW_PSP_RR", p.maxPaths > 1 {
                f("ds.path.policy", "\(StoragePaths.policyName(policy)) with \(p.maxPaths) paths")
            }
            if !p.hostsWithoutData.isEmpty, p.transport != .local, !p.hosts.isEmpty, p.hostsWithoutData.count < p.hosts.count {
                f("ds.path.nodata", "\(p.hostsWithoutData.count) of \(p.hosts.count) hosts: \(p.hostsWithoutData.sorted().joined(separator: ", "))")
            }
            if !p.noVMKHosts.isEmpty {
                f("ds.nfs.novmk", "\(p.noVMKHosts.count) of \(p.hosts.count) hosts have no VMkernel adapter on the storage network\(p.server.isEmpty ? "" : " (\(p.server))")")
            }
            if !p.singleVMKHosts.isEmpty {
                f("ds.nfs.singlevmk", "1 VMkernel adapter on \(names(p.singleVMKHosts))")
            }
            if !p.singleUplinkHosts.isEmpty {
                f("ds.nfs.uplink", "1 uplink behind the storage VMkernel on \(names(p.singleUplinkHosts))")
            }
            if p.mtus.count > 1 {
                f("ds.nfs.mtu", "MTU " + p.mtus.map(String.init).joined(separator: " and ") + " on the VMkernel adapters reaching \(p.server.isEmpty ? "the server" : p.server)")
            }
        }

        // MARK: Networking
        for p in inv.portGroups where !p.isUplink {
            var flags: [String] = []
            if p.promiscuous { flags.append("promiscuous") }
            if p.macChanges { flags.append("MAC changes") }
            if p.forgedTransmits { flags.append("forged transmits") }
            if !flags.isEmpty { e.add("net.security", .network, p.id, p.name, p.switchName, "Allows " + flags.joined(separator: ", ")) }
            if p.vmCount == 0 && !p.isVMkernel && p.kind != "Unknown" && p.kind != "NSX / opaque" {
                e.add("net.unused", .network, p.id, p.name, p.switchName, "\(p.kind) · VLAN \(p.vlanList)")
            }
        }

        // MARK: vCenter & licensing
        for vc in inv.vcenters where vc.kind != .esxiHost {
            let v = Lifecycle.parseVMwareVersion(vc.version.isEmpty ? vc.fullName : vc.version).version
            if let eol = Lifecycle.vsphereEndOfSupport(v) {
                if eol <= supportDate { e.add("vc.eol", .vcenter, vc.id, vc.server, "", "vCenter \(v) — support ended \(Fmt.date(eol))") }
                else if eol <= yearAhead { e.add("vc.eolsoon", .vcenter, vc.id, vc.server, "", "vCenter \(v) — support ends \(Fmt.date(eol))") }
            }
        }
        let renewalDate = License.renewalReference(exportDate: now)
        for l in inv.licenses {
            let quantity = l.total > 0 ? "\(Fmt.num(l.total, 0)) \(l.costUnit)" : l.costUnit
            if let exp = l.expiration, let days = l.daysToExpiry(from: renewalDate), days <= 0 {
                e.add("lic.expired", .vcenter, l.vcenter.lowercased(), l.name, l.vcenter, "\(l.keyMasked) · \(quantity) · expired \(Fmt.date(exp))")
            } else if let exp = l.expiration, let days = l.daysToExpiry(from: renewalDate), days <= t.licenseExpiryDays {
                e.add("lic.expiring", .vcenter, l.vcenter.lowercased(), l.name, l.vcenter, "\(l.keyMasked) · \(quantity) · expires \(Fmt.date(exp)) (\(Int(days.rounded(.up))) days from \(Fmt.date(renewalDate)))")
            } else if l.isEvaluation {
                e.add("lic.expiring", .vcenter, l.vcenter.lowercased(), l.name, l.vcenter, "\(l.keyMasked) · evaluation license")
            }
            if l.total > 0 && l.used > l.total { e.add("lic.overused", .vcenter, l.vcenter.lowercased(), l.name, l.vcenter, "\(Fmt.num(l.used, 0)) used of \(Fmt.num(l.total, 0)) \(l.costUnit)") }
        }
        return (e.findings, e.catalog)
    }
}
