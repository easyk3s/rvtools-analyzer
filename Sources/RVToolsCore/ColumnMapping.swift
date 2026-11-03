import Foundation

/// Chosen columns per tab: the file's header → the RVTools column it holds, or "" to keep the file's own name.
public typealias ColumnChoices = [String: [String: String]]

/// One column of a file whose headers aren't the ones RVTools normally writes.
public struct ColumnMatch: Identifiable, Sendable {
    /// How the column was matched: the same name once the tab prefix, case and spacing are ignored, a name known to
    /// mean that column, a guess from similar spelling, or nothing.
    public enum Kind: Sendable { case exact, known, suggested, unmatched }

    public let index: Int
    public let source: String
    public let samples: [String]
    public let kind: Kind
    public let automatic: String?
    public var target: String?

    public var id: Int { index }
    public var isEdited: Bool { target != automatic }
    /// Only guesses: a column with no match is usually one the app has no use for.
    public var needsChecking: Bool { !isEdited && kind == .suggested }
}

/// The proposed columns for one export, for the user to check or override (see `ColumnMatcher`).
public struct ColumnPlan: Sendable {
    public struct Tab: Identifiable, Sendable {
        public let name: String
        public let rowCount: Int
        /// The RVTools columns this tab can map to.
        public let options: [String]
        /// Columns the dashboards rely on; a file without them still opens, with those figures missing.
        public let keyColumns: [String]
        public var matches: [ColumnMatch]

        public var id: String { name }
        public var targets: [String] { matches.compactMap(\.target) }
        public var matchedCount: Int { matches.filter { $0.target != nil }.count }
        public var toCheckCount: Int { matches.filter(\.needsChecking).count }
        public var missingKeyColumns: [String] { keyColumns.filter { !targets.contains($0) } }
        public var duplicateTargets: [String] {
            Dictionary(grouping: targets, by: { $0 }).filter { $0.value.count > 1 }.keys.sorted()
        }
    }

    public let file: String
    public var tabs: [Tab]

    public var columnCount: Int { tabs.reduce(0) { $0 + $1.matches.count } }
    public var matchedCount: Int { tabs.reduce(0) { $0 + $1.matchedCount } }
    public var toCheckCount: Int { tabs.reduce(0) { $0 + $1.toCheckCount } }
    /// Without a VM column every VM is skipped, and one column can't stand in for two.
    public var hasVMColumn: Bool { tabs.first { $0.name.caseInsensitiveCompare("vInfo") == .orderedSame }?.targets.contains("VM") ?? true }
    public var canContinue: Bool { hasVMColumn && tabs.allSatisfy(\.duplicateTargets.isEmpty) }

    public var choices: ColumnChoices {
        var out: ColumnChoices = [:]
        for t in tabs { out[t.name] = Dictionary(t.matches.map { ($0.source, $0.target ?? "") }, uniquingKeysWith: { a, _ in a }) }
        return out
    }

    /// The plan with earlier choices restored, for columns they cover.
    public func applying(_ saved: ColumnChoices) -> ColumnPlan {
        var out = self
        for t in out.tabs.indices {
            guard let chosen = saved[out.tabs[t].name] else { continue }
            for m in out.tabs[t].matches.indices {
                if let c = chosen[out.tabs[t].matches[m].source] { out.tabs[t].matches[m].target = c.isEmpty ? nil : c }
            }
        }
        return out
    }

    /// The plan without guesses, for when nobody can check them (the command line, batches and trend loads).
    public var confidentOnly: ColumnPlan {
        var out = self
        for t in out.tabs.indices {
            for m in out.tabs[t].matches.indices where out.tabs[t].matches[m].kind == .suggested { out.tabs[t].matches[m].target = nil }
        }
        return out
    }

    /// Renames the headers; rows stay as they are, so a column kept unmatched is still there in Raw Data.
    func apply(to raws: [RawTable]) -> [RawTable] {
        let byName = Dictionary(tabs.map { ($0.name, $0) }, uniquingKeysWith: { a, _ in a })
        return raws.map { raw in
            guard let tab = byName[raw.name] else { return raw }
            var out = raw
            for m in tab.matches where m.index < out.headers.count {
                if let target = m.target { out.headers[m.index] = target }
            }
            return out
        }
    }
}

/// Proposes RVTools columns for exports with other headers, such as `vInfoVMName` for `VM`. Rows and tabs are the
/// usual ones in these files, so renaming the headers on load is enough for every view and solution to work.
public enum ColumnMatcher {
    /// nil for a file that already has RVTools' columns, including older versions and files with many custom columns.
    public static func plan(for raws: [RawTable], file: String) -> ColumnPlan? {
        let known = raws.filter { canonicalColumns(for: $0.name) != nil }
        guard known.contains(where: { needsMapping($0, canonicalColumns(for: $0.name)!) }) else { return nil }
        return ColumnPlan(file: file, tabs: known.map(tab))
    }

    static func canonicalColumns(for tab: String) -> [String]? {
        canonical.first { $0.key.caseInsensitiveCompare(tab) == .orderedSame }?.value
    }

    private static func needsMapping(_ raw: RawTable, _ columns: [String]) -> Bool {
        if raw.name.caseInsensitiveCompare("vInfo") == .orderedSame,
           !raw.headers.contains(where: { Table.normalize($0) == Table.normalize("VM") }) { return true }
        guard raw.headers.count >= 3 else { return false }
        let expected = Set(columns.map(Table.normalize))
        let found = Set(raw.headers.map(Table.normalize)).intersection(expected).count
        return Double(found) / Double(raw.headers.count) < 0.5 && Double(found) / Double(expected.count) < 0.5
    }

    private static func withoutPrefix(_ header: String, tab: String) -> String {
        let trimmed = header.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > tab.count, trimmed.lowercased().hasPrefix(tab.lowercased()) else { return trimmed }
        return String(trimmed.dropFirst(tab.count))
    }

    private static func tab(_ raw: RawTable) -> ColumnPlan.Tab {
        let key = canonical.keys.first { $0.caseInsensitiveCompare(raw.name) == .orderedSame } ?? raw.name
        let columns = canonical[key] ?? []
        let byName = Dictionary(columns.map { (Table.normalize($0), $0) }, uniquingKeysWith: { a, _ in a })
        let names = raw.headers.map { Table.normalize(withoutPrefix($0, tab: key)) }
        var result: [(target: String, kind: ColumnMatch.Kind)?] = Array(repeating: nil, count: raw.headers.count)
        var taken = Set<String>()
        func assign(_ i: Int, _ target: String?, _ kind: ColumnMatch.Kind) {
            guard result[i] == nil, let target, byName[Table.normalize(target)] != nil, taken.insert(target).inserted else { return }
            result[i] = (target, kind)
        }

        // Most certain first, so a name that is exact can't lose its column to one that merely means something similar.
        for i in raw.headers.indices { assign(i, byName[Table.normalize(raw.headers[i])], .exact) }
        let tabNames = tabAliases[key].map { Dictionary($0.map { (Table.normalize($0.key), $0.value) }, uniquingKeysWith: { a, _ in a }) } ?? [:]
        for i in raw.headers.indices { assign(i, tabNames[names[i]], .known) }
        for i in raw.headers.indices { assign(i, byName[names[i]], .exact) }
        for i in raw.headers.indices { assign(i, commonAliasesNormalized[names[i]], .known) }

        var guesses: [(score: Double, index: Int, target: String)] = []
        for i in raw.headers.indices where result[i] == nil && !names[i].isEmpty {
            for c in columns where !taken.contains(c) {
                let score = similarity(names[i], Table.normalize(c))
                if score >= 0.72 { guesses.append((score, i, c)) }
            }
        }
        for g in guesses.sorted(by: { ($0.score, $1.index) > ($1.score, $0.index) }) { assign(g.index, g.target, .suggested) }

        let matches = raw.headers.indices.map { i -> ColumnMatch in
            let target = result[i]?.target
            return ColumnMatch(index: i, source: raw.headers[i], samples: samples(raw, column: i), kind: result[i]?.kind ?? .unmatched,
                               automatic: target, target: target)
        }
        return ColumnPlan.Tab(name: raw.name, rowCount: raw.rows.count, options: columns, keyColumns: keyColumns[key] ?? [], matches: matches)
    }

    private static func samples(_ raw: RawTable, column: Int) -> [String] {
        var out: [String] = []
        for r in raw.rows where column < r.count && !r[column].isEmpty && !out.contains(r[column]) {
            out.append(r[column])
            if out.count == 3 { break }
        }
        return out
    }

    /// Dice coefficient over letter pairs: 1 for the same text, about 0.7 for a few characters' difference.
    private static func similarity(_ a: String, _ b: String) -> Double {
        func pairs(_ s: String) -> [String: Int] {
            let c = Array(s)
            guard c.count > 1 else { return [:] }
            return Dictionary((0..<(c.count - 1)).map { (String(c[$0...($0 + 1)]), 1) }, uniquingKeysWith: +)
        }
        let x = pairs(a), y = pairs(b)
        let total = x.values.reduce(0, +) + y.values.reduce(0, +)
        guard total > 0 else { return 0 }
        return Double(x.reduce(0) { $0 + min($1.value, y[$1.key] ?? 0) } * 2) / Double(total)
    }

    private static let keyColumns: [String: [String]] = [
        "vInfo": ["VM", "Powerstate", "CPUs", "Memory", "Provisioned MiB", "In Use MiB", "Datacenter", "Cluster", "Host", "VI SDK Server"],
        "vHost": ["Host", "Cluster", "# Cores", "# Memory", "Speed", "VI SDK Server"],
        "vCluster": ["Name", "VI SDK Server"],
        "vDatastore": ["Name", "Capacity MiB", "Free MiB", "VI SDK Server"],
        "vDisk": ["VM", "Capacity MiB"],
    ]

    /// Names that mean the same column on every tab that has it.
    private static let commonAliases: [String: String] = [
        "VMName": "VM", "HostName": "Host", "Notes": "Annotation", "OS": "OS according to the configuration file",
        "OSTools": "OS according to the VMware Tools", "ObjectID": "VM ID", "UUID": "VM UUID", "InstanceUUID": "VI SDK UUID",
        "SDKServer": "VI SDK Server", "SDKUUID": "VI SDK UUID", "SortColumn": "Internal Sort Column",
    ]
    private static let commonAliasesNormalized = Dictionary(commonAliases.map { (Table.normalize($0.key), $0.value) }, uniquingKeysWith: { a, _ in a })

    /// Internal field names, which some RVTools exports carry as headers after the tab name, per tab.
    /// Checked against an export of the same version: same column order, and the same units as the usual headers.
    private static let tabAliases: [String: [String: String]] = [
        "vInfo": [
            "GuestHostName": "DNS Name", "BootTime": "PowerOn", "CreateDate": "Creation date", "NumVirtualDisks": "Disks",
            "Network1": "Network #1", "Network2": "Network #2", "Network3": "Network #3", "Network4": "Network #4",
            "Network5": "Network #5", "Network6": "Network #6", "Network7": "Network #7", "Network8": "Network #8",
            "NumDisplays": "Num Monitors", "FaultToleranceState": "FT State", "FTLatencyStatus": "FT Latency", "FTLogBandwidth": "FT Bandwidth",
            "FTSecondaryLatency": "FT Sec. Latency", "Provisioned": "Provisioned MiB", "InUse": "In Use MiB", "Unshared": "Unshared MiB",
            "VMmonitoring": "HA VM Monitoring", "ClusterRule": "Cluster rule(s)", "ClusterRuleName": "Cluster rule name(s)",
            "InstallBootRequired": "Boot Required", "BootBios": "Boot BIOS setup", "Version": "HW version", "VISDKAPI": "VI SDK API Version",
        ],
        "vCPU": [
            "CoresPerSocket": "Cores p/s", "MaxCpuUsage": "Max", "OverallCpuUsage": "Overall", "SharesLevel": "Level",
            "StaticCpuEntitlement": "Entitlement", "DistributedCpuEntitlement": "DRS Entitlement", "ReservationLimit": "Limit",
        ],
        "vMemory": [
            "ReservationLockedToMax": "Memory Reservation Locked To Max", "MaxUsage": "Max", "HostMemoryUsage": "Consumed",
            "consumedOverheadMemory": "Consumed Overhead", "privateMemory": "Private", "sharedMemory": "Shared", "swappedMemory": "Swapped",
            "balloonedMemory": "Ballooned", "GuestMemoryUsage": "Active", "staticMemoryEntitlement": "Entitlement",
            "distributedMemoryEntitlement": "DRS Entitlement", "SharesLevel": "Level", "ReservationLimit": "Limit",
        ],
        "vDisk": [
            "Key": "Disk Key", "Mode": "Disk Mode", "ThinProvisioned": "Thin", "ControllerLabel": "Label", "SCSICtlrUnitNumber": "SCSI Unit #",
            "Unit": "Unit #", "ControllerSharedBus": "Shared Bus", "RawLunId": "Raw LUN ID", "RawCompMode": "Raw Comp. Mode",
        ],
        "vPartition": ["FreePercentage": "Free %"],
        "vNetwork": [
            "Nic": "NIC label", "Name": "Network", "MacAddressType": "Type", "IP4Address": "IPv4 Address", "IP6Address": "IPv6 Address",
        ],
        "vCD": ["label": "Device Node", "Startup": "Starts Connected", "Summary": "Device Type"],
        "vUSB": ["Label": "Device Node", "Summary": "Device Type"],
        "vSnapshot": ["CreateTime": "Date / time", "SizeVmsn": "Size MiB (vmsn)", "SizeTotal": "Size MiB (total)"],
        "vTools": [
            "Version": "Tools Version", "AppState": "App status", "AppHeartbeatStatus": "Heartbeat status", "KernelCrashed": "Kernel Crash state",
            "OperationsReady": "Operation Ready", "StateChangeSupported": "State change support", "InteractiveOperationsReady": "Interactive Guest",
            "guestFullName": "OS according to the VMware Tools",
        ],
        "vRP": [
            "Name": "Resource Pool name", "Path": "Resource Pool path", "VMsTotal": "# VMs total", "VMs": "# VMs", "numberOfCPUs": "# vCPUs",
            "configuredMemoryMiB": "Mem Configured",
        ],
        "vCluster": [
            "Enabled": "HA enabled", "DpmEnabled": "DPM enabled", "DefaultDpmBehavior": "DPM default behavior", "HostPowerActionRate": "DPM Host Power Action Rate",
        ],
        "vHost": [
            "Name": "Host", "CpuMhz": "Speed", "NumCpuCores": "# Cores", "OverallCpuUsage": "CPU usage %", "MemorySize": "# Memory",
            "OverallMemoryUsage": "Memory usage %", "ServiceConsoleReserved": "Console", "VMsTotal": "# VMs total", "VMs": "# VMs", "vCPUs": "# vCPUs",
            "VMSwappedMemory": "VM Memory Swapped", "VMBalloonedMemory": "VM Memory Ballooned", "VmotionSupported": "VMotion support",
            "StorageVmotionSupported": "Storage VMotion support", "CurrentEVCModeKey": "Current EVC", "MaxEVCModeKey": "Max EVC",
            "AssignedLicenses": "Assigned License(s)", "CurrentPolicy": "Current CPU power man. policy", "HardwareSupport": "Supported CPU power man.",
            "HostPowerPolicyShortname": "Host Power Policy", "FullName": "ESX Version", "DomainName": "Domain", "SearchDomains": "Domain List",
            "NTPServers": "NTP Server(s)", "NTPD": "NTPD running", "TZDescription": "Time Zone", "TZName": "Time Zone Name", "TZOffset": "GMT Offset",
        ],
        "vHBA": ["WorldWideName": "WWN"],
        "vNIC": ["Device": "Network Device", "Mac": "MAC"],
        "vSwitch": [
            "Name": "Switch", "AllowPromiscuous": "Promiscuous Mode", "AverageBandwidth": "Width", "PeakBandwidth": "Peak", "BurstSize": "Burst",
            "NotifySwitches": "Notify Switch", "CsumOffload": "Offload", "TCPSegmentation": "TSO",
        ],
        "vPort": [
            "Name": "Port Group", "AllowPromiscuous": "Promiscuous Mode", "AverageBandwidth": "Width", "PeakBandwidth": "Peak", "BurstSize": "Burst",
            "NotifySwitches": "Notify Switch", "CsumOffload": "Offload", "TCPSegmentation": "TSO",
        ],
        "dvSwitch": [
            "Name": "Switch", "ProductInfoName": "Name", "ProductInfoVendor": "Vendor", "ProductInfoVersion": "Version", "CreateTime": "Created",
            "NumVms": "# VMs", "InTrafficEnabled": "In Traffic Shaping", "InTrafficAvg": "In Avg", "InTrafficPeak": "In Peak", "InTrafficBurst": "In Burst",
            "OutTrafficEnabled": "Out Traffic Shaping", "OutTrafficAvg": "Out Avg", "OutTrafficPeak": "Out Peak", "OutTrafficBurst": "Out Burst",
            "CDPProtocol": "CDP Type", "LacpLoadBalance": "LACP Load Balance Alg.", "ContactInfoContact": "Contact", "ContactInfoName": "Admin Name",
        ],
        "dvPort": ["Name": "Port"],
        "vSC_VMK": [
            "MAC": "Mac Address", "IP": "IP Address", "IP6": "IP 6 Address", "Mask": "Subnet mask", "Gateway6": "IP 6 Gateway",
        ],
        "vDatastore": [
            "Capacity": "Capacity MiB", "Provisioned": "Provisioned MiB", "InUse": "In Use MiB", "FreeSpace": "Free MiB", "FreePercentage": "Free %",
            "SIOCFlag": "SIOC enabled", "VMsTotal": "# VMs total", "VMs": "# VMs", "NumberofHosts": "# Hosts", "ClusterCapacity": "Cluster capacity MiB",
            "ClusterFreeSpace": "Cluster free space MiB", "BlockSizeMiB": "Block size", "Extents": "# Extents", "VMFSUpgradable": "VMFS Upgradeable",
            "MultipleHostAccess": "MHA",
        ],
        "vMultiPath": [
            "DatastoreName": "Datastore", "DiskName": "Disk", "OperationalState": "Oper. State", "VStorageSupport": "vStorage", "SCSILevel": "Level",
            "SerialNumber": "Serial #",
            "Path1": "Path 1", "Path2": "Path 2", "Path3": "Path 3", "Path4": "Path 4", "Path5": "Path 5", "Path6": "Path 6", "Path7": "Path 7", "Path8": "Path 8",
        ],
        "vFileInfo": ["FriendlyPath": "Friendly Path Name", "FileSize": "File Size in bytes"],
    ]

    /// The columns RVTools writes on each tab, without custom attributes.
    private static let canonical: [String: [String]] = [
        "vInfo": ["VM", "Powerstate", "Template", "SRM Placeholder", "Config status", "DNS Name", "Connection state", "Guest state", "Heartbeat", "Consolidation Needed", "PowerOn", "Suspended To Memory", "Suspend time", "Suspend Interval", "Creation date", "Change Version", "CPUs", "Overall Cpu Readiness", "Memory", "Active Memory", "NICs", "Disks", "Total disk capacity MiB", "Fixed Passthru HotPlug", "min Required EVC Mode Key", "Latency Sensitivity", "Op Notification Timeout", "EnableUUID", "CBT", "Primary IP Address", "Network #1", "Network #2", "Network #3", "Network #4", "Network #5", "Network #6", "Network #7", "Network #8", "Num Monitors", "Video Ram KiB", "Resource pool", "Folder ID", "Folder", "vApp", "DAS protection", "FT State", "FT Role", "FT Latency", "FT Bandwidth", "FT Sec. Latency", "Vm Failover In Progress", "Provisioned MiB", "In Use MiB", "Unshared MiB", "HA Restart Priority", "HA Isolation Response", "HA VM Monitoring", "Cluster rule(s)", "Cluster rule name(s)", "Boot Required", "Boot delay", "Boot retry delay", "Boot retry enabled", "Boot BIOS setup", "Reboot PowerOff", "EFI Secure boot", "Firmware", "HW version", "HW upgrade status", "HW upgrade policy", "HW target", "Path", "Log directory", "Snapshot directory", "Suspend directory", "Annotation", "Datacenter", "Cluster", "Host", "OS according to the configuration file", "OS according to the VMware Tools", "Customization Info", "Guest Detailed Data", "VM ID", "SMBIOS UUID", "VM UUID", "VI SDK Server type", "VI SDK API Version", "VI SDK Server", "VI SDK UUID"],
        "vCPU": ["VM", "Powerstate", "Template", "SRM Placeholder", "CPUs", "Sockets", "Cores p/s", "Max", "Overall", "Level", "Shares", "Reservation", "Entitlement", "DRS Entitlement", "Limit", "Hot Add", "Hot Remove", "Numa Hotadd Exposed", "Annotation", "Datacenter", "Cluster", "Host", "Folder", "OS according to the configuration file", "OS according to the VMware Tools", "VM ID", "VM UUID", "VI SDK Server", "VI SDK UUID"],
        "vMemory": ["VM", "Powerstate", "Template", "SRM Placeholder", "Size MiB", "Memory Reservation Locked To Max", "Overhead", "Max", "Consumed", "Consumed Overhead", "Private", "Shared", "Swapped", "Ballooned", "Active", "Entitlement", "DRS Entitlement", "Level", "Shares", "Reservation", "Limit", "Hot Add", "Annotation", "Datacenter", "Cluster", "Host", "Folder", "OS according to the configuration file", "OS according to the VMware Tools", "VM ID", "VM UUID", "VI SDK Server", "VI SDK UUID"],
        "vDisk": ["VM", "Powerstate", "Template", "SRM Placeholder", "Disk", "Disk Key", "Disk UUID", "Disk Path", "Capacity MiB", "Raw", "Disk Mode", "Sharing mode", "Thin", "Eagerly Scrub", "Split", "Write Through", "Level", "Shares", "Reservation", "Limit", "Controller", "Label", "SCSI Unit #", "Unit #", "Shared Bus", "Path", "Raw LUN ID", "Raw Comp. Mode", "Internal Sort Column", "Annotation", "Datacenter", "Cluster", "Host", "Folder", "OS according to the configuration file", "OS according to the VMware Tools", "VM ID", "VM UUID", "VI SDK Server", "VI SDK UUID"],
        "vPartition": ["VM", "Powerstate", "Template", "SRM Placeholder", "Disk Key", "Disk", "Capacity MiB", "Consumed MiB", "Free MiB", "Free %", "Internal Sort Column", "Annotation", "Datacenter", "Cluster", "Host", "Folder", "OS according to the configuration file", "OS according to the VMware Tools", "VM ID", "VM UUID", "VI SDK Server", "VI SDK UUID"],
        "vNetwork": ["VM", "Powerstate", "Template", "SRM Placeholder", "NIC label", "Adapter", "Network", "Switch", "Connected", "Starts Connected", "Mac Address", "Type", "IPv4 Address", "IPv6 Address", "Direct Path IO", "Internal Sort Column", "Annotation", "Datacenter", "Cluster", "Host", "Folder", "OS according to the configuration file", "OS according to the VMware Tools", "VM ID", "VM UUID", "VI SDK Server", "VI SDK UUID"],
        "vCD": ["VM", "Powerstate", "Template", "SRM Placeholder", "Device Node", "Connected", "Starts Connected", "Device Type", "Annotation", "Datacenter", "Cluster", "Host", "Folder", "OS according to the configuration file", "OS according to the VMware Tools", "VMRef", "VM ID", "VM UUID", "VI SDK Server", "VI SDK UUID"],
        "vUSB": ["VM", "Powerstate", "Template", "SRM Placeholder", "Device Node", "Device Type", "Connected", "Family", "Speed", "EHCI enabled", "Auto connect", "Bus number", "Unit number", "Annotation", "Datacenter", "Cluster", "Host", "Folder", "OS according to the configuration file", "OS according to the VMware Tools", "VMRef", "VM ID", "VM UUID", "VI SDK Server", "VI SDK UUID"],
        "vSnapshot": ["VM", "Powerstate", "Name", "Description", "Date / time", "Filename", "Size MiB (vmsn)", "Size MiB (total)", "Quiesced", "State", "Annotation", "Datacenter", "Cluster", "Host", "Folder", "OS according to the configuration file", "OS according to the VMware Tools", "VM ID", "VM UUID", "VI SDK Server", "VI SDK UUID"],
        "vTools": ["VM", "Powerstate", "Template", "SRM Placeholder", "VM Version", "Tools", "Tools Version", "Required Version", "Upgradeable", "Upgrade Policy", "Sync time", "App status", "Heartbeat status", "Kernel Crash state", "Operation Ready", "State change support", "Interactive Guest", "Annotation", "Datacenter", "Cluster", "Host", "Folder", "OS according to the configuration file", "OS according to the VMware Tools", "VMRef", "VM ID", "VM UUID", "VI SDK Server", "VI SDK UUID"],
        "vSource": ["Name", "OS type", "API type", "API version", "Version", "Patch level", "Build", "Fullname", "Product name", "Product version", "Product line", "Vendor", "VI SDK Server", "VI SDK UUID"],
        "vRP": ["Resource Pool name", "Resource Pool path", "Status", "# VMs total", "# VMs", "# vCPUs", "CPU limit", "CPU overheadLimit", "CPU reservation", "CPU level", "CPU shares", "CPU expandableReservation", "CPU maxUsage", "CPU overallUsage", "Mem Configured", "Mem limit", "Mem reservation", "Mem level", "Mem shares", "Object ID", "VI SDK Server", "VI SDK UUID"],
        "vCluster": ["Name", "Config status", "OverallStatus", "NumHosts", "numEffectiveHosts", "TotalCpu", "NumCpuCores", "NumCpuThreads", "Effective Cpu", "TotalMemory", "Effective Memory", "Num VMotions", "HA enabled", "Failover Level", "AdmissionControlEnabled", "Host monitoring", "HB Datastore Candidate Policy", "Isolation Response", "Restart Priority", "Cluster Settings", "Max Failures", "Max Failure Window", "Failure Interval", "Min Up Time", "VM Monitoring", "DRS enabled", "DRS default VM behavior", "DRS vmotion rate", "DPM enabled", "DPM default behavior", "DPM Host Power Action Rate", "Object ID", "VI SDK Server", "VI SDK UUID"],
        "vHost": ["Host", "Datacenter", "Cluster", "Config status", "Compliance Check State", "in Maintenance Mode", "in Quarantine Mode", "vSAN Fault Domain Name", "CPU Model", "Speed", "HT Available", "HT Active", "# CPU", "Cores per CPU", "# Cores", "CPU usage %", "# Memory", "Memory Tiering Type", "Memory usage %", "Console", "# NICs", "# HBAs", "# VMs total", "# VMs", "VMs per Core", "# vCPUs", "vCPUs per Core", "vRAM", "VM Used memory", "VM Memory Swapped", "VM Memory Ballooned", "VMotion support", "Storage VMotion support", "Current EVC", "Max EVC", "Assigned License(s)", "ATS Heartbeat", "ATS Locking", "Current CPU power man. policy", "Supported CPU power man.", "Host Power Policy", "ESX Version", "Boot time", "DNS Servers", "DHCP", "Domain", "Domain List", "DNS Search Order", "NTP Server(s)", "NTPD running", "Time Zone", "Time Zone Name", "GMT Offset", "Vendor", "Model", "Serial number", "Service tag", "OEM specific string", "BIOS Vendor", "BIOS Version", "BIOS Date", "Certificate Issuer", "Certificate Start Date", "Certificate Expiry Date", "Certificate Status", "Certificate Subject", "Object ID", "AutoDeploy.MachineIdentity", "UUID", "VI SDK Server", "VI SDK UUID"],
        "vHBA": ["Host", "Datacenter", "Cluster", "Device", "Type", "Status", "Bus", "Pci", "Driver", "Model", "WWN", "VI SDK Server", "VI SDK UUID"],
        "vNIC": ["Host", "Datacenter", "Cluster", "Network Device", "Driver", "Speed", "Duplex", "MAC", "Switch", "Uplink port", "PCI", "WakeOn", "VI SDK Server", "VI SDK UUID"],
        "vSwitch": ["Host", "Datacenter", "Cluster", "Switch", "# Ports", "Free Ports", "Promiscuous Mode", "Mac Changes", "Forged Transmits", "Traffic Shaping", "Width", "Peak", "Burst", "Policy", "Reverse Policy", "Notify Switch", "Rolling Order", "Offload", "TSO", "Zero Copy Xmit", "MTU", "VI SDK Server", "VI SDK UUID"],
        "vPort": ["Host", "Datacenter", "Cluster", "Port Group", "Switch", "VLAN", "Promiscuous Mode", "Mac Changes", "Forged Transmits", "Traffic Shaping", "Width", "Peak", "Burst", "Policy", "Reverse Policy", "Notify Switch", "Rolling Order", "Offload", "TSO", "Zero Copy Xmit", "VI SDK Server", "VI SDK UUID"],
        "dvSwitch": ["Switch", "Datacenter", "Name", "Vendor", "Version", "Description", "Created", "Host members", "Max Ports", "# Ports", "# VMs", "In Traffic Shaping", "In Avg", "In Peak", "In Burst", "Out Traffic Shaping", "Out Avg", "Out Peak", "Out Burst", "CDP Type", "CDP Operation", "LACP Name", "LACP Mode", "LACP Load Balance Alg.", "Max MTU", "Contact", "Admin Name", "Object ID", "VI SDK Server", "VI SDK UUID"],
        "dvPort": ["Port", "Switch", "Type", "# Ports", "VLAN", "Speed", "Full Duplex", "Blocked", "Allow Promiscuous", "Mac Changes", "Active Uplink", "Standby Uplink", "Policy", "Forged Transmits", "In Traffic Shaping", "Out Traffic Shaping", "Reverse Policy", "Notify Switch", "Rolling Order", "Check Beacon", "Object ID", "VI SDK Server", "VI SDK UUID"],
        "vSC_VMK": ["Host", "Datacenter", "Cluster", "Port Group", "Device", "Mac Address", "DHCP", "IP Address", "IP 6 Address", "Subnet mask", "Gateway", "IP 6 Gateway", "MTU", "VI SDK Server", "VI SDK UUID"],
        "vDatastore": ["Name", "Config status", "Address", "Accessible", "Type", "# VMs total", "# VMs", "Capacity MiB", "Provisioned MiB", "In Use MiB", "Free MiB", "Free %", "SIOC enabled", "SIOC Threshold", "# Hosts", "Hosts", "Cluster name", "Cluster capacity MiB", "Cluster free space MiB", "Block size", "Max Blocks", "# Extents", "Major Version", "Version", "VMFS Upgradeable", "MHA", "URL", "Object ID", "VI SDK Server", "VI SDK UUID"],
        "vMultiPath": ["Host", "Cluster", "Datacenter", "Datastore", "Disk", "Display name", "Policy", "Oper. State", "Path 1", "Path 1 state", "Path 2", "Path 2 state", "Path 3", "Path 3 state", "Path 4", "Path 4 state", "Path 5", "Path 5 state", "Path 6", "Path 6 state", "Path 7", "Path 7 state", "Path 8", "Path 8 state", "vStorage", "Queue depth", "Vendor", "Model", "Revision", "Level", "Serial #", "UUID", "Object ID", "VI SDK Server", "VI SDK UUID"],
        "vLicense": ["Name", "Key", "Labels", "Cost Unit", "Total", "Used", "Expiration Date", "Features", "VI SDK Server", "VI SDK UUID"],
        "vFileInfo": ["Friendly Path Name", "File Name", "File Type", "File Size in bytes", "Path", "Internal Sort Column", "VI SDK Server", "VI SDK UUID"],
        "vHealth": ["Name", "Message", "Message type", "VI SDK Server", "VI SDK UUID"],
    ]
}
