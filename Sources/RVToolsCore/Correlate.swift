import Foundation

/// Joins every RVTools tab into one object graph:
/// vCenter → Datacenter → Cluster → Host → VM → (vCPU, vMemory, vTools, vDisk, vPartition, vNetwork, vSnapshot, vCD, vUSB, vHealth)
/// VM ↔ Datastore (disk & vmx paths), VM ↔ Port group (vNetwork ↔ vPort/dvPort), Host ↔ (vNIC, vHBA, vSC_VMK, vSwitch, vMultiPath),
/// Datastore ↔ Host (vDatastore.Hosts), Datastore ↔ LUN paths (vMultiPath), plus vLicense / vRP / vSource.
public enum InventoryBuilder {
    public static func build(_ ds: Dataset) -> Inventory { Builder(ds).run() }
}

private final class Builder {
    let ds: Dataset
    var inv = Inventory()

    var vmByID: [String: Int] = [:]
    var vmByUUID: [String: Int] = [:]
    var vmByName: [String: Int] = [:]
    var vmByBareName: [String: [Int]] = [:]
    var vmIDs: Set<String> = []
    var hostIndex: [String: Int] = [:]
    var hostByBareName: [String: [Int]] = [:]
    var clusterIndex: [String: Int] = [:]
    var dsIndex: [String: Int] = [:]
    var pgIndex: [String: Int] = [:]
    var vcIndex: [String: Int] = [:]
    /// Per-VM figures from other tabs, kept to fill blanks in vInfo (see `fillMissingFigures`).
    var vInfoDiskTotal: [Int: Double] = [:]
    var vcpuTabCPUs: [Int: Int] = [:]
    var vMemoryTabSize: [Int: Double] = [:]

    init(_ ds: Dataset) {
        self.ds = ds
        inv.reportDate = ds.reportDate
        inv.tabsPresent = Set(ds.tableNames.map { $0.lowercased() })
        inv.sourceTools = ds.sourceTools
        inv.sourceIssues = ds.sourceIssues.filter { $0.level != .note }
    }

    func run() -> Inventory {
        buildVCenters()
        buildHosts()
        buildClusters()
        buildVMs()
        restoreVMsMissingFromVInfo()
        inferHosts()
        attachVMChildren()
        buildDatastores()
        buildNetworking()
        buildHostChildren()
        buildLicensesAndPools()
        buildHealth()
        // Rows with no "VI SDK Server" (RVTools writes them for objects it couldn't attribute) aren't a vCenter.
        inv.vcenters.removeAll { $0.server.trimmingCharacters(in: .whitespaces).isEmpty }
        fillMissingFigures()
        rollUp()
        consistencyChecks()
        return inv
    }

    // MARK: - Helpers

    static func clusterID(_ server: String, _ datacenter: String, _ cluster: String) -> String {
        cluster.isEmpty ? key(server, "~standalone|" + datacenter) : key(server, cluster)
    }

    func days(since d: Date?) -> Double? {
        guard let d else { return nil }
        return inv.reportDate.timeIntervalSince(d) / 86_400
    }

    func matchHost(_ server: String, _ name: String) -> Int? {
        guard !name.isEmpty else { return nil }
        if let i = hostIndex[key(server, name)] { return i }
        if let list = hostByBareName[name.lowercased()], list.count == 1 { return list[0] }
        // FQDN vs short name
        let short = name.split(separator: ".").first.map(String.init)?.lowercased() ?? ""
        if let i = inv.hosts.firstIndex(where: { $0.vcenter.lowercased() == server.lowercased() && $0.name.split(separator: ".").first?.lowercased() == short }) { return i }
        return nil
    }

    /// Records the vCenter's instance UUID from any tab that carries "VI SDK UUID".
    func noteInstanceUUID(_ server: String, _ uuid: String) {
        guard !uuid.isEmpty, let i = vcIndex[server.lowercased()], inv.vcenters[i].instanceUUID.isEmpty else { return }
        inv.vcenters[i].instanceUUID = uuid
    }

    @discardableResult
    func ensureVCenter(_ server: String) -> Int {
        let id = server.lowercased()
        if let i = vcIndex[id] { return i }
        var vc = VCenter(id: id)
        vc.server = server
        inv.vcenters.append(vc)
        vcIndex[id] = inv.vcenters.count - 1
        return inv.vcenters.count - 1
    }

    @discardableResult
    func ensureCluster(server: String, datacenter: String, name: String) -> Int {
        let id = Builder.clusterID(server, datacenter, name)
        if let i = clusterIndex[id] {
            if inv.clusters[i].datacenter.isEmpty { inv.clusters[i].datacenter = datacenter }
            return i
        }
        var c = Cluster(id: id)
        c.vcenter = server
        c.datacenter = datacenter
        c.isStandalone = name.isEmpty
        c.name = name.isEmpty ? "Standalone hosts (\(datacenter.isEmpty ? "no datacenter" : datacenter))" : name
        inv.clusters.append(c)
        clusterIndex[id] = inv.clusters.count - 1
        return inv.clusters.count - 1
    }

    static func usageLabel(_ usage: [String: Int]) -> String {
        if usage.isEmpty { return "—" }
        return usage.sorted { $0.value > $1.value }.map { usage.count > 1 ? "\($0.key) (\($0.value))" : $0.key }.joined(separator: ", ")
    }

    // MARK: - vSource / vHost / vCluster

    func buildVCenters() {
        guard let t = ds.table("vSource") else { return }
        let cServer = t.col("VI SDK Server"), cVersion = t.col("Version"), cBuild = t.col("Build"), cFull = t.col("Fullname")
        let cAPI = t.col("API version"), cOS = t.col("OS type"), cName = t.col("Name"), cUUID = t.col("VI SDK UUID")
        // Exports with non-standard columns can leave the server out of vSource, with Name just the product name.
        var serverByUUID: [String: String] = [:]
        if cServer == nil {
            for tab in ["vInfo", "vHost"] {
                guard let other = ds.table(tab), let s = other.col("VI SDK Server"), let u = other.col("VI SDK UUID") else { continue }
                for r in other.rows where !r.s(u).isEmpty && serverByUUID[r.s(u)] == nil { serverByUUID[r.s(u)] = r.s(s) }
            }
        }
        for r in t.rows {
            let server = r.s(cServer).isEmpty ? (serverByUUID[r.s(cUUID)] ?? r.s(cName)) : r.s(cServer)
            let i = ensureVCenter(server)
            inv.vcenters[i].fullName = r.s(cFull)
            inv.vcenters[i].version = cVersion == nil ? (r.s(cFull).range(of: #"\d+\.\d+(\.\d+)*"#, options: .regularExpression).map { String(r.s(cFull)[$0]) } ?? "") : r.s(cVersion)
            inv.vcenters[i].build = r.s(cBuild)
            inv.vcenters[i].apiVersion = r.s(cAPI)
            inv.vcenters[i].osType = r.s(cOS)
            if inv.vcenters[i].instanceUUID.isEmpty { inv.vcenters[i].instanceUUID = r.s(cUUID) }
        }
    }

    func buildHosts() {
        guard let t = ds.table("vHost") else { return }
        let cHost = t.col("Host"), cDC = t.col("Datacenter"), cCluster = t.col("Cluster"), cServer = t.col("VI SDK Server")
        let cStatus = t.col("Config status"), cMaint = t.col("in Maintenance Mode"), cQuar = t.col("in Quarantine Mode")
        let cModel = t.col("CPU Model"), cSpeed = t.col("Speed"), cHTA = t.col("HT Available"), cHT = t.col("HT Active")
        let cSockets = t.col("# CPU"), cCPS = t.col("Cores per CPU"), cCores = t.col("# Cores"), cCPU = t.col("CPU usage %")
        let cMem = t.col("# Memory"), cMemPct = t.col("Memory usage %"), cNICs = t.col("# NICs"), cHBAs = t.col("# HBAs")
        let cVMsTotal = t.col("# VMs total"), cVMs = t.col("# VMs"), cVCPUs = t.col("# vCPUs"), cVRAM = t.col("vRAM")
        let cEVC = t.col("Current EVC"), cMaxEVC = t.col("Max EVC"), cLic = t.col("Assigned License(s)")
        let cESX = t.col("ESX Version"), cBoot = t.col("Boot time"), cDNS = t.col("DNS Servers"), cNTP = t.col("NTP Server(s)")
        let cNTPD = t.col("NTPD running"), cTZ = t.col("Time Zone Name", "Time Zone"), cVendor = t.col("Vendor")
        let cHWModel = t.col("Model"), cSerial = t.col("Serial number"), cBIOS = t.col("BIOS Version")
        let cCert = t.col("Certificate Expiry Date"), cPower = t.col("Current CPU power man. policy"), cFaultDomain = t.col("vSAN Fault Domain Name")
        for r in t.rows {
            let server = r.s(cServer), name = r.s(cHost)
            guard !name.isEmpty else { continue }
            ensureVCenter(server)
            var h = Host(id: key(server, name))
            h.name = name
            h.vcenter = server
            h.datacenter = r.s(cDC)
            h.cluster = r.s(cCluster)
            h.clusterKey = Builder.clusterID(server, h.datacenter, h.cluster)
            h.configStatus = r.s(cStatus)
            h.maintenance = r.b(cMaint) ?? false
            h.quarantine = r.b(cQuar) ?? false
            h.cpuModel = r.s(cModel).replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            h.speedMHz = r.d0(cSpeed)
            h.htAvailable = r.b(cHTA) ?? false
            h.htActive = r.b(cHT) ?? false
            h.sockets = r.i0(cSockets)
            h.coresPerSocket = r.i0(cCPS)
            h.cores = r.i0(cCores) > 0 ? r.i0(cCores) : h.sockets * h.coresPerSocket
            h.cpuUsagePct = r.d0(cCPU)
            h.memoryMiB = r.d0(cMem)
            h.memUsagePct = r.d0(cMemPct)
            h.nicCountReported = r.i0(cNICs)
            h.hbaCountReported = r.i0(cHBAs)
            h.vmTotalReported = r.d(cVMsTotal).map { Int($0) }
            h.vmOnReported = r.d(cVMs).map { Int($0) }
            h.vcpusReported = r.d(cVCPUs).map { Int($0) }
            h.vramReportedMiB = r.d0(cVRAM)
            h.evcCurrent = r.s(cEVC)
            h.evcMax = r.s(cMaxEVC)
            h.licenses = r.s(cLic)
            let esx = Lifecycle.parseVMwareVersion(r.s(cESX))
            h.esxVersion = esx.version
            h.esxBuild = esx.build
            h.bootTime = r.date(cBoot)
            h.uptimeDays = days(since: h.bootTime)
            h.dnsServers = r.s(cDNS)
            h.ntpServers = r.s(cNTP)
            h.ntpdRunning = r.b(cNTPD)
            h.ntpReported = cNTP != nil || cNTPD != nil
            h.timeZone = r.s(cTZ)
            h.vendor = r.s(cVendor)
            h.model = r.s(cHWModel)
            h.serial = r.s(cSerial)
            h.biosVersion = r.s(cBIOS)
            h.certExpiry = r.date(cCert)
            h.vsanFaultDomain = r.s(cFaultDomain)
            h.powerPolicy = r.s(cPower)
            if hostIndex[h.id] != nil { continue }
            inv.hosts.append(h)
            hostIndex[h.id] = inv.hosts.count - 1
            hostByBareName[name.lowercased(), default: []].append(inv.hosts.count - 1)
        }
    }

    func buildClusters() {
        if let t = ds.table("vCluster") {
            let cName = t.col("Name"), cServer = t.col("VI SDK Server"), cStatus = t.col("OverallStatus")
            let cHosts = t.col("NumHosts"), cCpu = t.col("TotalCpu"), cMem = t.col("TotalMemory"), cVMot = t.col("Num VMotions")
            let cHA = t.col("HA enabled"), cAC = t.col("AdmissionControlEnabled"), cFail = t.col("Failover Level")
            let cDRS = t.col("DRS enabled"), cDRSB = t.col("DRS default VM behavior")
            var matched = 0
            for r in t.rows {
                let server = r.s(cServer), name = r.s(cName)
                guard !name.isEmpty else { continue }
                ensureVCenter(server)
                let dc = inv.hosts.first { $0.clusterKey == Builder.clusterID(server, "", name) }?.datacenter ?? ""
                let i = ensureCluster(server: server, datacenter: dc, name: name)
                if inv.hosts.contains(where: { $0.clusterKey == inv.clusters[i].id }) { matched += 1 }
                inv.clusters[i].inClusterTab = true
                inv.clusters[i].overallStatus = r.s(cStatus)
                inv.clusters[i].numHostsReported = r.d(cHosts).map { Int($0) }
                inv.clusters[i].totalCpuMHzReported = r.d0(cCpu)
                inv.clusters[i].totalMemoryReported = r.d0(cMem)
                inv.clusters[i].numVMotions = r.i0(cVMot)
                inv.clusters[i].haEnabled = r.b(cHA)
                inv.clusters[i].admissionControl = r.b(cAC)
                inv.clusters[i].failoverLevel = r.s(cFail)
                inv.clusters[i].drsEnabled = r.b(cDRS)
                inv.clusters[i].drsBehavior = r.s(cDRSB)
            }
            inv.joins.append(JoinStat(source: "vCluster", target: "Host (vHost)", keys: "VI SDK Server + cluster name",
                                      matched: matched, total: t.rows.count, note: "Clusters that have at least one host in vHost"))
        }
        for h in inv.hosts { ensureCluster(server: h.vcenter, datacenter: h.datacenter, name: h.cluster) }
        if let t = ds.table("vHost") {
            let clustered = inv.hosts.filter { !$0.cluster.isEmpty }
            let inTab = clustered.filter { h in inv.clusters.first { $0.id == h.clusterKey }?.inClusterTab ?? false }.count
            inv.joins.append(JoinStat(source: t.name, target: "Cluster (vCluster)", keys: "VI SDK Server + Cluster",
                                      matched: inTab, total: clustered.count, note: "\(inv.hosts.count - clustered.count) standalone host(s) not in a cluster"))
        }
    }

    // MARK: - vInfo

    func buildVMs() {
        guard let t = ds.table("vInfo") else { return }
        let cVM = t.col("VM"), cServer = t.col("VI SDK Server"), cPower = t.col("Powerstate"), cTemplate = t.col("Template")
        let cSRM = t.col("SRM Placeholder"), cStatus = t.col("Config status"), cDNS = t.col("DNS Name")
        let cConn = t.col("Connection state"), cGuest = t.col("Guest state"), cHB = t.col("Heartbeat")
        let cConsol = t.col("Consolidation Needed"), cPowerOn = t.col("PowerOn"), cCreated = t.col("Creation date")
        let cCPUs = t.col("CPUs"), cMem = t.col("Memory"), cNICs = t.col("NICs"), cDisks = t.col("Disks")
        let cIP = t.col("Primary IP Address"), cRP = t.col("Resource pool"), cFolder = t.col("Folder"), cVApp = t.col("vApp")
        let cFT = t.col("FT State"), cProv = t.col("Provisioned MiB"), cUsed = t.col("In Use MiB"), cUnshared = t.col("Unshared MiB")
        let cHA = t.col("HA Restart Priority"), cLat = t.col("Latency Sensitivity"), cFW = t.col("Firmware")
        let cHW = t.col("HW version"), cSB = t.col("EFI Secure boot"), cCBT = t.col("CBT"), cPath = t.col("Path")
        let cNote = t.col("Annotation"), cDC = t.col("Datacenter"), cCluster = t.col("Cluster"), cHost = t.col("Host")
        let cOSConf = t.col("OS according to the configuration file", "OS"), cOSTools = t.col("OS according to the VMware Tools")
        let cVMID = t.col("VM ID"), cUUID = t.col("VM UUID", "UUID"), cReady = t.col("Overall Cpu Readiness"), cDiskTotal = t.col("Total disk capacity MiB")
        let cSDKUUID = t.col("VI SDK UUID")
        let cNets = (1...8).map { t.col("Network #\($0)") }
        let cCustom = t.customColumns.sorted()

        for (ri, r) in t.rows.enumerated() {
            let server = r.s(cServer), name = r.s(cVM)
            guard !name.isEmpty else { continue }
            ensureVCenter(server)
            noteInstanceUUID(server, r.s(cSDKUUID))
            let vmid = r.s(cVMID), uuid = r.s(cUUID)
            var id = !vmid.isEmpty ? key(server, vmid) : (!uuid.isEmpty ? key(server, "uuid:" + uuid) : key(server, "name:\(name)"))
            if vmIDs.contains(id) { id += "#\(ri)" }
            var vm = VM(id: id)
            vm.name = name
            vm.vcenter = server
            vm.datacenter = r.s(cDC)
            vm.cluster = r.s(cCluster)
            vm.host = r.s(cHost)
            place(&vm)
            vm.folder = r.s(cFolder)
            vm.resourcePool = r.s(cRP)
            vm.vApp = r.s(cVApp)
            vm.powerState = PowerState(raw: r.s(cPower))
            vm.isTemplate = r.b(cTemplate) ?? false
            vm.isSRMPlaceholder = r.b(cSRM) ?? false
            vm.configStatus = r.s(cStatus)
            vm.connectionState = r.s(cConn)
            vm.guestState = r.s(cGuest)
            vm.heartbeat = r.s(cHB)
            vm.consolidationNeeded = r.b(cConsol) ?? false
            vm.powerOnDate = r.date(cPowerOn)
            vm.creationDate = r.date(cCreated)
            vm.cpus = r.i0(cCPUs)
            vm.memoryMiB = r.d0(cMem)
            vm.nicCount = r.i0(cNICs)
            vm.diskCount = r.i0(cDisks)
            vm.primaryIP = r.s(cIP)
            vm.dnsName = r.s(cDNS)
            vm.ftState = r.s(cFT)
            vm.provisionedMiB = r.d0(cProv)
            vm.inUseMiB = r.d0(cUsed)
            vm.unsharedMiB = r.d0(cUnshared)
            vm.haRestartPriority = r.s(cHA)
            vm.latencySensitivity = r.s(cLat)
            vm.firmware = r.s(cFW)
            vm.hwVersion = Parse.firstInt(r.s(cHW)) ?? 0
            vm.secureBoot = r.b(cSB) ?? false
            vm.cbt = cCBT == nil ? nil : (r.b(cCBT) ?? false)
            vm.vmxPath = r.s(cPath)
            vm.annotation = r.s(cNote)
            for c in cCustom {
                let value = r.s(c).trimmingCharacters(in: .whitespacesAndNewlines)
                if !value.isEmpty { vm.customFields.append(VCustomField(name: t.headers[c], value: value)) }
            }
            vm.osConfig = r.s(cOSConf)
            vm.osTools = r.s(cOSTools)
            vm.os = Lifecycle.classify(config: vm.osConfig, tools: vm.osTools)
            vm.vmID = vmid
            vm.uuid = uuid
            vm.cpuReadinessPct = r.d(cReady)
            for c in cNets { let n = r.s(c); if !n.isEmpty, !vm.networks.contains(n) { vm.networks.append(n) } }
            if let d = Parse.datastore(fromPath: vm.vmxPath) { vm.datastores.append(d) }

            vInfoDiskTotal[inv.vms.count] = r.d0(cDiskTotal)
            add(vm)
        }
        for vm in inv.vms { ensureCluster(server: vm.vcenter, datacenter: vm.datacenter, name: vm.cluster.isEmpty && vm.clusterKey.contains("~standalone") ? "" : vm.cluster) }

        let withHost = inv.vms.filter { !$0.host.isEmpty }
        let hostMatched = withHost.filter { hostIndex[$0.hostKey] != nil }.count
        inv.joins.append(JoinStat(source: t.name, target: "Host (vHost)", keys: "VI SDK Server + Host", matched: hostMatched, total: withHost.count))
    }

    /// Sets a VM's host and cluster keys from its vCenter, host, cluster and datacenter names.
    func place(_ vm: inout VM) {
        if let hi = matchHost(vm.vcenter, vm.host) {
            vm.hostKey = inv.hosts[hi].id
            vm.clusterKey = inv.hosts[hi].clusterKey
            if vm.datacenter.isEmpty { vm.datacenter = inv.hosts[hi].datacenter }
        } else {
            vm.hostKey = key(vm.vcenter, vm.host)
            vm.clusterKey = Builder.clusterID(vm.vcenter, vm.datacenter, vm.cluster)
        }
    }

    func add(_ vm: VM) {
        let idx = inv.vms.count
        inv.vms.append(vm)
        vmIDs.insert(vm.id)
        if !vm.vmID.isEmpty { vmByID[key(vm.vcenter, vm.vmID)] = idx }
        if !vm.uuid.isEmpty { vmByUUID[key(vm.vcenter, vm.uuid)] = idx }
        vmByName[key(vm.vcenter, vm.name)] = idx
        vmByBareName[vm.name.lowercased(), default: []].append(idx)
    }

    /// RVTools lists every VM on each VM tab, so a VM that's on the others but not in vInfo had its row removed. It's
    /// rebuilt from those tabs here, before they're joined, so their rows attach to it instead of to a VM with the same
    /// name in another vCenter. Its figures are filled in like any other blank (see `fillMissingFigures`).
    func restoreVMsMissingFromVInfo() {
        guard ds.sourceTools.isEmpty else { return }
        for tab in ["vCPU", "vMemory", "vDisk", "vTools"] {
            guard let t = ds.table(tab), let cVM = t.col("VM") else { continue }
            let cServer = t.col("VI SDK Server"), cVMID = t.col("VM ID"), cUUID = t.col("VM UUID")
            let cPower = t.col("Powerstate"), cTemplate = t.col("Template"), cSRM = t.col("SRM Placeholder")
            let cDC = t.col("Datacenter"), cCluster = t.col("Cluster"), cHost = t.col("Host"), cFolder = t.col("Folder")
            let cNote = t.col("Annotation"), cOSConf = t.col("OS according to the configuration file", "OS"), cOSTools = t.col("OS according to the VMware Tools")
            let cCustom = t.customColumns.sorted()
            for (ri, r) in t.rows.enumerated() {
                let server = r.s(cServer), name = r.s(cVM), vmid = r.s(cVMID), uuid = r.s(cUUID)
                guard !name.isEmpty, r.filter({ !$0.isEmpty }).count > 1 else { continue }
                if !vmid.isEmpty, vmByID[key(server, vmid)] != nil { continue }
                if !uuid.isEmpty, vmByUUID[key(server, uuid)] != nil { continue }
                // Two VMs can share a name, so a name only settles it when there's no VM ID to tell them apart.
                if let i = vmByName[key(server, name)], vmid.isEmpty || inv.vms[i].vmID.isEmpty { continue }
                ensureVCenter(server)
                var id = !vmid.isEmpty ? key(server, vmid) : (!uuid.isEmpty ? key(server, "uuid:" + uuid) : key(server, "name:\(name)"))
                if vmIDs.contains(id) { id += "#\(tab)\(ri)" }
                var vm = VM(id: id)
                vm.notInVInfo = true
                vm.name = name
                vm.vcenter = server
                vm.datacenter = r.s(cDC)
                vm.cluster = r.s(cCluster)
                vm.host = r.s(cHost)
                place(&vm)
                vm.folder = r.s(cFolder)
                vm.powerState = PowerState(raw: r.s(cPower))
                vm.isTemplate = r.b(cTemplate) ?? false
                vm.isSRMPlaceholder = r.b(cSRM) ?? false
                vm.annotation = r.s(cNote)
                for c in cCustom {
                    let value = r.s(c).trimmingCharacters(in: .whitespacesAndNewlines)
                    if !value.isEmpty { vm.customFields.append(VCustomField(name: t.headers[c], value: value)) }
                }
                vm.osConfig = r.s(cOSConf)
                vm.osTools = r.s(cOSTools)
                vm.os = Lifecycle.classify(config: vm.osConfig, tools: vm.osTools)
                vm.vmID = vmid
                vm.uuid = uuid
                add(vm)
                ensureCluster(server: vm.vcenter, datacenter: vm.datacenter, name: vm.cluster)
            }
        }
    }

    /// Without vHost, hosts are still named on every VM row: keep them as placeholders so placement, maps and
    /// per-host views work. Their capacity is marked missing rather than zero.
    func inferHosts() {
        guard ds.table("vHost") == nil else { return }
        for vm in inv.vms where !vm.host.isEmpty && hostIndex[vm.hostKey] == nil {
            var h = Host(id: vm.hostKey)
            h.name = vm.host
            h.vcenter = vm.vcenter
            h.datacenter = vm.datacenter
            h.cluster = vm.cluster
            h.clusterKey = vm.clusterKey
            h.inferred = true
            h.coresSource = .missing
            h.memorySource = .missing
            inv.hosts.append(h)
            hostIndex[h.id] = inv.hosts.count - 1
            hostByBareName[h.name.lowercased(), default: []].append(inv.hosts.count - 1)
        }
    }

    // MARK: - VM child tabs

    struct VMKeyCols { let server, id, uuid, name: Int? }

    func matchVM(_ r: [String], _ c: VMKeyCols, _ usage: inout [String: Int]) -> Int? {
        let server = r.s(c.server)
        let id = r.s(c.id)
        if !id.isEmpty, let i = vmByID[key(server, id)] { usage["VM ID", default: 0] += 1; return i }
        let uuid = r.s(c.uuid)
        if !uuid.isEmpty, let i = vmByUUID[key(server, uuid)] { usage["VM UUID", default: 0] += 1; return i }
        let name = r.s(c.name)
        guard !name.isEmpty else { return nil }
        if let i = vmByName[key(server, name)] { usage["VM name", default: 0] += 1; return i }
        if let list = vmByBareName[name.lowercased()], list.count == 1 { usage["VM name (any vCenter)", default: 0] += 1; return list[0] }
        return nil
    }

    /// Joins each row of a VM-level tab to its VM; `setup` resolves columns once and returns the per-row handler.
    func joinVMTab(_ tab: String, note: String = "", _ setup: (Table) -> (Int, [String]) -> Void) {
        guard let t = ds.table(tab) else { return }
        let cols = VMKeyCols(server: t.col("VI SDK Server"), id: t.col("VM ID"), uuid: t.col("VM UUID"), name: t.col("VM"))
        let handle = setup(t)
        var usage: [String: Int] = [:]
        var matched = 0
        for r in t.rows {
            if let i = matchVM(r, cols, &usage) { matched += 1; handle(i, r) }
        }
        inv.joins.append(JoinStat(source: t.name, target: "VM (vInfo)", keys: Builder.usageLabel(usage), matched: matched, total: t.rows.count, note: note))
    }

    func attachVMChildren() {
        joinVMTab("vCPU") { t in
            let cS = t.col("Sockets"), cC = t.col("Cores p/s"), cRes = t.col("Reservation"), cLim = t.col("Limit"), cHot = t.col("Hot Add")
            let cOverall = t.col("Overall"), cCPUs = t.col("CPUs")
            return { i, r in
                self.vcpuTabCPUs[i] = r.i0(cCPUs)
                self.inv.vms[i].cpuUsageMHz = r.d0(cOverall)
                self.inv.vms[i].sockets = r.i0(cS)
                self.inv.vms[i].coresPerSocket = r.i0(cC)
                self.inv.vms[i].cpuReservationMHz = r.d0(cRes)
                self.inv.vms[i].cpuLimitMHz = r.d(cLim) ?? -1
                self.inv.vms[i].cpuHotAdd = r.b(cHot) ?? false
            }
        }
        joinVMTab("vMemory") { t in
            let cRes = t.col("Reservation"), cLim = t.col("Limit"), cHot = t.col("Hot Add"), cBal = t.col("Ballooned")
            let cSwap = t.col("Swapped"), cCons = t.col("Consumed"), cAct = t.col("Active"), cSize = t.col("Size MiB")
            return { i, r in
                self.vMemoryTabSize[i] = r.d0(cSize)
                self.inv.vms[i].memReservationMiB = r.d0(cRes)
                self.inv.vms[i].memLimitMiB = r.d(cLim) ?? -1
                self.inv.vms[i].memHotAdd = r.b(cHot) ?? false
                self.inv.vms[i].memBalloonedMiB = r.d0(cBal)
                self.inv.vms[i].memSwappedMiB = r.d0(cSwap)
                self.inv.vms[i].memConsumedMiB = r.d0(cCons)
                self.inv.vms[i].memActiveMiB = r.d0(cAct)
            }
        }
        joinVMTab("vTools") { t in
            let cTools = t.col("Tools"), cVer = t.col("Tools Version"), cUp = t.col("Upgradeable"), cPol = t.col("Upgrade Policy")
            return { i, r in
                self.inv.vms[i].toolsStatus = r.s(cTools)
                self.inv.vms[i].toolsVersion = r.s(cVer)
                self.inv.vms[i].toolsUpgradeable = r.s(cUp)
                self.inv.vms[i].toolsUpgradePolicy = r.s(cPol)
            }
        }
        joinVMTab("vDisk") { t in
            let cLabel = t.col("Disk"), cCap = t.col("Capacity MiB"), cRaw = t.col("Raw"), cMode = t.col("Disk Mode")
            let cShare = t.col("Sharing mode"), cThin = t.col("Thin"), cEager = t.col("Eagerly Scrub"), cCtrl = t.col("Controller")
            let cBus = t.col("Shared Bus"), cPath = t.col("Path"), cDPath = t.col("Disk Path")
            return { i, r in
                var d = VDisk()
                d.label = r.s(cLabel)
                d.capacityMiB = r.d0(cCap)
                d.raw = r.b(cRaw) ?? false
                d.mode = r.s(cMode)
                d.sharing = r.s(cShare)
                d.thin = r.b(cThin)
                d.eagerScrub = r.b(cEager)
                d.controller = r.s(cCtrl)
                d.sharedBus = r.s(cBus)
                let p1 = r.s(cPath), p2 = r.s(cDPath)
                d.path = p1.hasPrefix("[") ? p1 : (p2.hasPrefix("[") ? p2 : p1)
                d.datastore = Parse.datastore(fromPath: d.path) ?? ""
                self.inv.vms[i].disks.append(d)
                if !d.datastore.isEmpty, !self.inv.vms[i].datastores.contains(d.datastore) { self.inv.vms[i].datastores.append(d.datastore) }
            }
        }
        joinVMTab("vPartition") { t in
            let cDisk = t.col("Disk"), cCap = t.col("Capacity MiB"), cCons = t.col("Consumed MiB"), cFree = t.col("Free MiB"), cPct = t.col("Free %")
            return { i, r in
                var p = VPartition()
                p.disk = r.s(cDisk)
                p.capacityMiB = r.d0(cCap)
                p.freeMiB = r.d0(cFree)
                p.consumedMiB = r.d(cCons) ?? max(0, p.capacityMiB - p.freeMiB)
                p.freePct = r.d(cPct) ?? (p.capacityMiB > 0 ? p.freeMiB / p.capacityMiB * 100 : 0)
                self.inv.vms[i].partitions.append(p)
            }
        }
        joinVMTab("vNetwork") { t in
            let cLabel = t.col("NIC label"), cAdapter = t.col("Adapter"), cNet = t.col("Network"), cSwitch = t.col("Switch")
            let cConn = t.col("Connected"), cStart = t.col("Starts Connected"), cMac = t.col("Mac Address")
            let cIP4 = t.col("IPv4 Address", "IP Address"), cIP6 = t.col("IPv6 Address")
            return { i, r in
                var n = VNic()
                n.label = r.s(cLabel)
                n.adapter = r.s(cAdapter)
                n.network = r.s(cNet)
                n.switchName = r.s(cSwitch)
                n.connected = r.b(cConn) ?? false
                n.startsConnected = r.b(cStart) ?? false
                n.mac = r.s(cMac)
                n.ipv4 = Parse.list(r.s(cIP4)).filter { $0.contains(".") }
                n.ipv6 = r.s(cIP6)
                self.inv.vms[i].nics.append(n)
                if !n.network.isEmpty, !self.inv.vms[i].networks.contains(n.network) { self.inv.vms[i].networks.append(n.network) }
            }
        }
        joinVMTab("vSnapshot") { t in
            let cName = t.col("Name"), cDesc = t.col("Description"), cDate = t.col("Date / time", "Date/time")
            let cSize = t.col("Size MiB (total)", "Size MiB (vmsn)"), cQ = t.col("Quiesced")
            return { i, r in
                var s = VSnapshot()
                s.name = r.s(cName)
                s.description = r.s(cDesc)
                s.date = r.date(cDate)
                s.ageDays = self.days(since: s.date)
                s.sizeMiB = r.d0(cSize)
                s.quiesced = r.b(cQ) ?? false
                self.inv.vms[i].snapshots.append(s)
            }
        }
        joinVMTab("vCD") { t in
            let cNode = t.col("Device Node"), cConn = t.col("Connected"), cType = t.col("Device Type")
            return { i, r in
                self.inv.vms[i].cdroms.append(VCDRom(node: r.s(cNode), connected: r.b(cConn) ?? false, deviceType: r.s(cType)))
            }
        }
        joinVMTab("vUSB") { t in
            let cConn = t.col("Connected")
            return { i, r in if r.b(cConn) ?? true { self.inv.vms[i].usbConnected += 1 } }
        }
    }

    // MARK: - Datastores

    func buildDatastores() {
        if let t = ds.table("vDatastore") {
            let cName = t.col("Name"), cServer = t.col("VI SDK Server"), cStatus = t.col("Config status"), cAddr = t.col("Address")
            let cAcc = t.col("Accessible"), cType = t.col("Type"), cVMsTotal = t.col("# VMs total"), cCap = t.col("Capacity MiB")
            let cProv = t.col("Provisioned MiB"), cUsed = t.col("In Use MiB"), cFree = t.col("Free MiB"), cPct = t.col("Free %")
            let cSIOC = t.col("SIOC enabled"), cHosts = t.col("Hosts"), cDSC = t.col("Cluster name"), cMajor = t.col("Major Version")
            let cURL = t.col("URL")
            var refs = 0, refMatched = 0
            for r in t.rows {
                let server = r.s(cServer), name = r.s(cName)
                guard !name.isEmpty else { continue }
                var d = Datastore(id: key(server, name))
                d.name = name
                d.vcenter = server
                d.type = r.s(cType)
                d.capacityMiB = r.d0(cCap)
                d.provisionedMiB = r.d0(cProv)
                d.provisionedReported = cProv != nil
                d.inUseMiB = r.d0(cUsed)
                d.freeMiB = r.d(cFree) ?? max(0, d.capacityMiB - d.inUseMiB)
                d.freePct = r.d(cPct) ?? (d.capacityMiB > 0 ? d.freeMiB / d.capacityMiB * 100 : 0)
                d.accessible = r.b(cAcc) ?? true
                d.configStatus = r.s(cStatus)
                d.vmTotalReported = r.d(cVMsTotal).map { Int($0) }
                d.hostNames = Parse.list(r.s(cHosts))
                d.datastoreCluster = r.s(cDSC)
                d.siocEnabled = r.b(cSIOC) ?? false
                d.majorVersion = Int(r.d0(cMajor))
                d.url = r.s(cURL)
                d.address = r.s(cAddr)
                for hn in d.hostNames {
                    refs += 1
                    if let hi = matchHost(server, hn) { refMatched += 1; d.hostKeys.append(inv.hosts[hi].id) }
                }
                if dsIndex[d.id] != nil { continue }
                inv.datastores.append(d)
                dsIndex[d.id] = inv.datastores.count - 1
            }
            inv.joins.append(JoinStat(source: "vDatastore.Hosts", target: "Host (vHost)", keys: "VI SDK Server + host name", matched: refMatched, total: refs, note: "Host mounts per datastore"))
        }

        // Without vDatastore, datastores are still named in every VM's .vmx and disk paths.
        if ds.table("vDatastore") == nil {
            for vm in inv.vms {
                for name in vm.datastores where dsIndex[key(vm.vcenter, name)] == nil {
                    var d = Datastore(id: key(vm.vcenter, name))
                    d.name = name
                    d.vcenter = vm.vcenter
                    d.inferred = true
                    d.capacitySource = .missing
                    inv.datastores.append(d)
                    dsIndex[d.id] = inv.datastores.count - 1
                }
            }
        }

        // VMC on AWS surfaces one vSAN datastore twice: "vsanDatastore" (management) and "WorkloadDatastore", both
        // reporting the whole cluster's capacity, so counting both doubles it.
        for i in inv.datastores.indices where inv.datastores[i].name.caseInsensitiveCompare("vsanDatastore") == .orderedSame {
            let d = inv.datastores[i]
            let workload = inv.datastores.first {
                $0.name.caseInsensitiveCompare("WorkloadDatastore") == .orderedSame && $0.vcenter.lowercased() == d.vcenter.lowercased()
                    && abs($0.capacityMiB - d.capacityMiB) < 1 && abs($0.freeMiB - d.freeMiB) < 1
            }
            if workload != nil { inv.datastores[i].isVMCManagementDatastore = true }
        }

        // VM ↔ Datastore via vDisk paths and the VM's .vmx path.
        var diskRefs = 0, diskMatched = 0
        for (vi, vm) in inv.vms.enumerated() {
            var perDS: [String: Double] = [:]
            for d in vm.disks where !d.datastore.isEmpty {
                diskRefs += 1
                if dsIndex[key(vm.vcenter, d.datastore)] != nil { diskMatched += 1 }
                perDS[d.datastore, default: 0] += d.capacityMiB
            }
            for name in vm.datastores {
                guard let di = dsIndex[key(vm.vcenter, name)] else { continue }
                inv.datastores[di].vmIDs.append(vm.id)
                inv.datastores[di].vmDiskMiB += perDS[name] ?? 0
                if vm.isClusterAgent {
                    inv.datastores[di].agentVMIDs.append(vm.id)
                    inv.datastores[di].agentDiskMiB += perDS[name] ?? 0
                }
                if !vm.hostKey.isEmpty, hostIndex[vm.hostKey] != nil, !inv.datastores[di].hostKeys.contains(vm.hostKey), inv.datastores[di].hostNames.isEmpty {
                    inv.datastores[di].hostKeys.append(vm.hostKey)
                }
            }
            _ = vi
        }
        if ds.table("vDisk") != nil {
            inv.joins.append(JoinStat(source: "vDisk.Path", target: "Datastore (vDatastore)", keys: "[datastore] prefix of VMDK path", matched: diskMatched, total: diskRefs))
        }
        for i in inv.datastores.indices {
            var names: [String] = [], keys: [String] = []
            for hk in inv.datastores[i].hostKeys {
                guard let hi = hostIndex[hk] else { continue }
                let ck = inv.hosts[hi].clusterKey
                if !keys.contains(ck) {
                    keys.append(ck)
                    names.append(inv.clusters.first { $0.id == ck }?.name ?? inv.hosts[hi].cluster)
                }
            }
            inv.datastores[i].clusterKeys = keys
            inv.datastores[i].clusters = names
        }
    }

    // MARK: - Networking

    @discardableResult
    func ensurePortGroup(server: String, name: String, kind: String, switchName: String) -> Int {
        let id = key(server, name)
        if let i = pgIndex[id] {
            if inv.portGroups[i].switchName.isEmpty { inv.portGroups[i].switchName = switchName }
            return i
        }
        var pg = PortGroup(id: id)
        pg.name = name
        pg.vcenter = server
        pg.kind = kind
        pg.switchName = switchName
        pg.isUplink = name.lowercased().contains("uplink")
        inv.portGroups.append(pg)
        pgIndex[id] = inv.portGroups.count - 1
        return inv.portGroups.count - 1
    }

    func addVLAN(_ i: Int, _ vlan: String) {
        let v = vlan.trimmingCharacters(in: .whitespaces)
        if !v.isEmpty, !inv.portGroups[i].vlans.contains(v) { inv.portGroups[i].vlans.append(v) }
    }

    func buildNetworking() {
        if let t = ds.table("vPort") {
            let cHost = t.col("Host"), cPG = t.col("Port Group"), cSwitch = t.col("Switch"), cVLAN = t.col("VLAN"), cServer = t.col("VI SDK Server")
            let cProm = t.col("Promiscuous Mode"), cMac = t.col("Mac Changes"), cForged = t.col("Forged Transmits")
            var matched = 0
            for r in t.rows {
                let server = r.s(cServer), name = r.s(cPG)
                guard !name.isEmpty else { continue }
                let i = ensurePortGroup(server: server, name: name, kind: "Standard", switchName: r.s(cSwitch))
                addVLAN(i, r.s(cVLAN))
                if let hi = matchHost(server, r.s(cHost)) {
                    matched += 1
                    if !inv.portGroups[i].hostKeys.contains(inv.hosts[hi].id) { inv.portGroups[i].hostKeys.append(inv.hosts[hi].id) }
                }
                inv.portGroups[i].promiscuous = inv.portGroups[i].promiscuous || (r.b(cProm) ?? false)
                inv.portGroups[i].macChanges = inv.portGroups[i].macChanges || (r.b(cMac) ?? false)
                inv.portGroups[i].forgedTransmits = inv.portGroups[i].forgedTransmits || (r.b(cForged) ?? false)
            }
            inv.joins.append(JoinStat(source: t.name, target: "Host (vHost)", keys: "VI SDK Server + Host", matched: matched, total: t.rows.count))
        }
        if let t = ds.table("dvPort") {
            let cPort = t.col("Port"), cSwitch = t.col("Switch"), cVLAN = t.col("VLAN"), cServer = t.col("VI SDK Server")
            let cProm = t.col("Allow Promiscuous", "Promiscuous Mode"), cMac = t.col("Mac Changes"), cForged = t.col("Forged Transmits")
            for r in t.rows {
                let server = r.s(cServer), name = r.s(cPort)
                guard !name.isEmpty else { continue }
                let i = ensurePortGroup(server: server, name: name, kind: "Distributed", switchName: r.s(cSwitch))
                inv.portGroups[i].kind = "Distributed"
                addVLAN(i, r.s(cVLAN))
                inv.portGroups[i].promiscuous = inv.portGroups[i].promiscuous || (r.b(cProm) ?? false)
                inv.portGroups[i].macChanges = inv.portGroups[i].macChanges || (r.b(cMac) ?? false)
                inv.portGroups[i].forgedTransmits = inv.portGroups[i].forgedTransmits || (r.b(cForged) ?? false)
            }
        }
        // VM NICs → port groups
        var nicRefs = 0, nicMatched = 0
        let knownPGs = Set(pgIndex.keys)
        for vm in inv.vms {
            let nicNets = vm.nics.isEmpty ? vm.networks.map { VNic(network: $0, connected: true) } : vm.nics
            for n in nicNets where !n.network.isEmpty {
                nicRefs += 1
                let id = key(vm.vcenter, n.network)
                if knownPGs.contains(id) { nicMatched += 1 }
                let i = ensurePortGroup(server: vm.vcenter, name: n.network, kind: n.switchName.isEmpty ? "Unknown" : "NSX / opaque", switchName: n.switchName)
                inv.portGroups[i].nicCount += 1
                if n.connected { inv.portGroups[i].connectedNics += 1 }
                if !inv.portGroups[i].vmIDs.contains(vm.id) { inv.portGroups[i].vmIDs.append(vm.id) }
                if !vm.hostKey.isEmpty, hostIndex[vm.hostKey] != nil, !inv.portGroups[i].hostKeys.contains(vm.hostKey), inv.portGroups[i].kind != "Standard" {
                    inv.portGroups[i].hostKeys.append(vm.hostKey)
                }
            }
        }
        // Observed subnets: RVTools has no netmasks for VM NICs, so networks are inferred from the guest IPs on each port group.
        var pgAddresses: [Int: [(ip: IPv4, owner: String)]] = [:]
        for vm in inv.vms {
            for n in vm.nics where !n.network.isEmpty {
                guard let i = pgIndex[key(vm.vcenter, n.network)] else { continue }
                for text in n.ipv4 { if let ip = IPv4(text) { pgAddresses[i, default: []].append((ip, vm.id)) } }
            }
        }
        for (i, addresses) in pgAddresses { inv.portGroups[i].observedSubnets = Subnets.observed(addresses) }

        if nicRefs > 0 {
            inv.joins.append(JoinStat(source: "vNetwork.Network", target: "Port group (vPort / dvPort)", keys: "VI SDK Server + network name",
                                      matched: nicMatched, total: nicRefs, note: "Unmatched networks are usually NSX segments / opaque networks"))
        }

        if let t = ds.table("vSwitch") {
            let cHost = t.col("Host"), cSwitch = t.col("Switch"), cPorts = t.col("# Ports"), cFree = t.col("Free Ports"), cServer = t.col("VI SDK Server")
            let cProm = t.col("Promiscuous Mode"), cMac = t.col("Mac Changes"), cForged = t.col("Forged Transmits"), cPol = t.col("Policy"), cMTU = t.col("MTU")
            for (ri, r) in t.rows.enumerated() {
                let server = r.s(cServer)
                var s = VSwitchInfo(id: "vs\(ri)")
                s.host = r.s(cHost)
                s.hostKey = matchHost(server, s.host).map { inv.hosts[$0].id } ?? key(server, s.host)
                s.name = r.s(cSwitch)
                s.ports = r.i0(cPorts)
                s.freePorts = r.i0(cFree)
                s.mtu = r.i0(cMTU)
                s.promiscuous = r.b(cProm) ?? false
                s.macChanges = r.b(cMac) ?? false
                s.forgedTransmits = r.b(cForged) ?? false
                s.policy = r.s(cPol)
                inv.vSwitches.append(s)
            }
        }
        if let t = ds.table("dvSwitch") {
            let cSwitch = t.col("Switch"), cName = t.col("Name"), cDC = t.col("Datacenter"), cVendor = t.col("Vendor"), cVer = t.col("Version")
            let cMembers = t.col("Host members"), cPorts = t.col("# Ports"), cVMs = t.col("# VMs"), cMTU = t.col("Max MTU")
            let cLACP = t.col("LACP Mode"), cServer = t.col("VI SDK Server")
            for (ri, r) in t.rows.enumerated() {
                let server = r.s(cServer)
                var s = DVSwitchInfo(id: "dvs\(ri)")
                s.name = r.s(cSwitch).isEmpty ? r.s(cName) : r.s(cSwitch)
                s.vcenter = server
                s.datacenter = r.s(cDC)
                s.vendor = r.s(cVendor)
                s.version = r.s(cVer)
                s.hostMembers = Parse.list(r.s(cMembers)).count
                s.ports = r.i0(cPorts)
                s.vmCount = r.i0(cVMs)
                s.maxMTU = r.i0(cMTU)
                s.lacp = r.s(cLACP)
                s.portGroupCount = inv.portGroups.filter { $0.kind == "Distributed" && $0.vcenter.lowercased() == server.lowercased() && $0.switchName == s.name }.count
                inv.dvSwitches.append(s)
            }
        }
        if let t = ds.table("vSC_VMK") {
            let cHost = t.col("Host"), cPG = t.col("Port Group"), cDev = t.col("Device"), cIP = t.col("IP Address"), cServer = t.col("VI SDK Server")
            let cMask = t.col("Subnet mask"), cGW = t.col("Gateway"), cMTU = t.col("MTU"), cDHCP = t.col("DHCP")
            var matched = 0
            for (ri, r) in t.rows.enumerated() {
                let server = r.s(cServer)
                var k = VMKernel(id: "vmk\(ri)")
                k.host = r.s(cHost)
                if let hi = matchHost(server, k.host) { matched += 1; k.hostKey = inv.hosts[hi].id } else { k.hostKey = key(server, k.host) }
                k.portGroup = r.s(cPG)
                k.device = r.s(cDev)
                k.ip = r.s(cIP)
                k.subnet = r.s(cMask)
                k.gateway = r.s(cGW)
                k.mtu = r.i0(cMTU)
                k.dhcp = r.b(cDHCP) ?? false
                inv.vmkernels.append(k)
                if let pi = pgIndex[key(server, k.portGroup)] { inv.portGroups[pi].isVMkernel = true }
            }
            inv.joins.append(JoinStat(source: t.name, target: "Host (vHost)", keys: "VI SDK Server + Host", matched: matched, total: t.rows.count))
        }
    }

    // MARK: - Host children

    func joinHostTab(_ tab: String, _ setup: (Table) -> (String, String, [String]) -> Void) {
        guard let t = ds.table(tab) else { return }
        let cHost = t.col("Host"), cServer = t.col("VI SDK Server")
        let handle = setup(t)
        var matched = 0
        for r in t.rows {
            let server = r.s(cServer), name = r.s(cHost)
            let hostKey: String
            if let hi = matchHost(server, name) { matched += 1; hostKey = inv.hosts[hi].id } else { hostKey = key(server, name) }
            handle(hostKey, name, r)
        }
        inv.joins.append(JoinStat(source: t.name, target: "Host (vHost)", keys: "VI SDK Server + Host", matched: matched, total: t.rows.count))
    }

    func buildHostChildren() {
        joinHostTab("vNIC") { t in
            let cDev = t.col("Network Device"), cDrv = t.col("Driver"), cSpeed = t.col("Speed"), cDup = t.col("Duplex"), cMAC = t.col("MAC"), cSw = t.col("Switch")
            return { hk, hn, r in
                var n = PhysicalNIC(id: "pnic\(self.inv.pnics.count)")
                n.host = hn; n.hostKey = hk
                n.device = r.s(cDev); n.driver = r.s(cDrv); n.speedMbps = r.i0(cSpeed); n.duplex = r.s(cDup)
                n.mac = r.s(cMAC); n.switchName = r.s(cSw)
                self.inv.pnics.append(n)
            }
        }
        joinHostTab("vHBA") { t in
            let cDev = t.col("Device"), cType = t.col("Type"), cStatus = t.col("Status"), cModel = t.col("Model"), cDrv = t.col("Driver"), cWWN = t.col("WWN")
            return { hk, hn, r in
                var h = HBA(id: "hba\(self.inv.hbas.count)")
                h.host = hn; h.hostKey = hk
                h.device = r.s(cDev); h.type = r.s(cType); h.status = r.s(cStatus); h.model = r.s(cModel); h.driver = r.s(cDrv); h.wwn = r.s(cWWN)
                self.inv.hbas.append(h)
            }
        }
        var lunDSRefs = 0, lunDSMatched = 0
        joinHostTab("vMultiPath") { t in
            let cDS = t.col("Datastore"), cDisk = t.col("Disk"), cDisp = t.col("Display name"), cPol = t.col("Policy"), cOper = t.col("Oper. State")
            let cVendor = t.col("Vendor"), cModel = t.col("Model"), cServer = t.col("VI SDK Server")
            let paths = (1...8).map { (t.col("Path \($0)"), t.col("Path \($0) state")) }
            return { hk, hn, r in
                var l = MultiPathLUN(id: "lun\(self.inv.luns.count)")
                l.host = hn; l.hostKey = hk
                l.datastore = r.s(cDS); l.disk = r.s(cDisk); l.displayName = r.s(cDisp); l.policy = r.s(cPol); l.operState = r.s(cOper)
                l.vendor = r.s(cVendor); l.model = r.s(cModel)
                for (p, s) in paths where !r.s(p).isEmpty {
                    l.paths += 1
                    l.pathNames.append(r.s(p))
                    let st = r.s(s).lowercased()
                    if st.contains("active") { l.activePaths += 1 }
                    if st.contains("dead") { l.deadPaths += 1 }
                }
                self.inv.luns.append(l)
                if !l.datastore.isEmpty {
                    lunDSRefs += 1
                    if let di = self.dsIndex[key(r.s(cServer), l.datastore)] { lunDSMatched += 1; self.inv.datastores[di].lunPaths += l.paths }
                }
            }
        }
        if lunDSRefs > 0 {
            inv.joins.append(JoinStat(source: "vMultiPath.Datastore", target: "Datastore (vDatastore)", keys: "VI SDK Server + datastore name", matched: lunDSMatched, total: lunDSRefs))
        }
    }

    // MARK: - vLicense / vRP

    func buildLicensesAndPools() {
        if let t = ds.table("vLicense") {
            let cName = t.col("Name"), cKey = t.col("Key"), cTotal = t.col("Total"), cUsed = t.col("Used"), cExp = t.col("Expiration Date")
            let cUnit = t.col("Cost Unit"), cServer = t.col("VI SDK Server")
            for (ri, r) in t.rows.enumerated() {
                var l = License(id: "lic\(ri)")
                l.vcenter = r.s(cServer)
                l.name = r.s(cName)
                let k = r.s(cKey)
                l.keyMasked = k.count > 5 ? "•••••-" + k.suffix(5) : k
                l.total = r.d0(cTotal)
                l.used = r.d0(cUsed)
                l.costUnit = r.s(cUnit)
                l.expirationRaw = r.s(cExp)
                l.expiration = r.date(cExp)
                inv.licenses.append(l)
            }
        }
        if let t = ds.table("vRP") {
            let cName = t.col("Resource Pool name"), cPath = t.col("Resource Pool path"), cVMs = t.col("# VMs total", "# VMs")
            let cCL = t.col("CPU limit"), cCR = t.col("CPU reservation"), cML = t.col("Mem limit"), cMR = t.col("Mem reservation"), cServer = t.col("VI SDK Server")
            for (ri, r) in t.rows.enumerated() {
                var p = ResourcePool(id: "rp\(ri)")
                p.vcenter = r.s(cServer)
                p.name = r.s(cName)
                p.path = r.s(cPath)
                p.vmCount = r.i0(cVMs)
                p.cpuLimit = r.d(cCL) ?? -1
                p.cpuReservation = r.d0(cCR)
                p.memLimit = r.d(cML) ?? -1
                p.memReservation = r.d0(cMR)
                inv.resourcePools.append(p)
            }
        }
    }

    // MARK: - vHealth

    func buildHealth() {
        guard let t = ds.table("vHealth") else { return }
        let cName = t.col("Name"), cMsg = t.col("Message"), cType = t.col("Message type"), cServer = t.col("VI SDK Server")
        var matched = 0
        for (ri, r) in t.rows.enumerated() {
            let server = r.s(cServer), name = r.s(cName)
            var h = HealthItem(id: ri)
            h.vcenter = server
            h.name = name
            h.message = r.s(cMsg)
            h.type = r.s(cType)
            if let vi = vmByName[key(server, name)] ?? (vmByBareName[name.lowercased()]?.count == 1 ? vmByBareName[name.lowercased()]![0] : nil) {
                h.kind = .vm; h.objectID = inv.vms[vi].id
                inv.vms[vi].health.append(h)
            } else if let hi = matchHost(server, name) {
                h.kind = .host; h.objectID = inv.hosts[hi].id
            } else if let di = dsIndex[key(server, name)] ?? Parse.datastore(fromPath: name).flatMap({ dsIndex[key(server, $0)] }) {
                h.kind = .datastore; h.objectID = inv.datastores[di].id
            }
            if !h.objectID.isEmpty { matched += 1 }
            inv.health.append(h)
        }
        inv.joins.append(JoinStat(source: t.name, target: "VM / Host / Datastore", keys: "Name (VM name, host name or [datastore] path)",
                                  matched: matched, total: t.rows.count, note: "Unmatched rows are vCenter-level messages"))
    }

    // MARK: - Blank or zeroed figures

    /// RVTools can leave a column blank or zero (a permissions gap, a vCenter that timed out, a trimmed export) while
    /// another tab still has the same fact. Fill those from the other tab, or mark them missing, before rolling up.
    func fillMissingFigures() {
        for i in inv.vms.indices where !inv.vms[i].isSRMPlaceholder {
            var vm = inv.vms[i]
            if vm.cpus <= 0 {
                let fromTab = vcpuTabCPUs[i] ?? 0, fromTopology = vm.sockets * vm.coresPerSocket
                if fromTab > 0 || fromTopology > 0 { vm.cpus = fromTab > 0 ? fromTab : fromTopology; vm.cpusSource = .vCPU } else { vm.cpusSource = .missing }
            }
            if vm.memoryMiB <= 0 {
                if let size = vMemoryTabSize[i], size > 0 { vm.memoryMiB = size; vm.memorySource = .vMemory } else { vm.memorySource = .missing }
            }
            // A VM that vInfo says has no disks, and none turned up in vDisk, genuinely has no storage.
            let hasDisks = !vm.disks.isEmpty || vm.diskCount > 0 || (vInfoDiskTotal[i] ?? 0) > 0
            if vm.provisionedMiB <= 0, hasDisks {
                if vm.diskCapacityMiB > 0 { vm.provisionedMiB = vm.diskCapacityMiB; vm.provisionedSource = .vDisk }
                else if let total = vInfoDiskTotal[i], total > 0 { vm.provisionedMiB = total; vm.provisionedSource = .vInfoDiskTotal }
                else if vm.guestCapacityMiB > 0 { vm.provisionedMiB = vm.guestCapacityMiB; vm.provisionedSource = .vPartitionCapacity }
                else { vm.provisionedSource = .missing }
            }
            if vm.inUseMiB <= 0, hasDisks {
                if vm.guestConsumedMiB > 0 { vm.inUseMiB = vm.guestConsumedMiB; vm.inUseSource = .vPartition }
                else if vm.provisionedMiB > 0 { vm.inUseMiB = vm.provisionedMiB; vm.inUseSource = .vDiskFull }
                else { vm.inUseSource = .missing }
            }
            inv.vms[i] = vm
        }
        for i in inv.hosts.indices where !inv.hosts[i].isVirtual {
            if inv.hosts[i].cores <= 0 { inv.hosts[i].coresSource = .missing }
            if inv.hosts[i].memoryMiB <= 0 { inv.hosts[i].memorySource = .missing }
        }
        for i in inv.datastores.indices where inv.datastores[i].accessible && inv.datastores[i].capacityMiB <= 0 {
            // Only with a real free figure: capacity rebuilt from in-use alone would read as 100% full.
            let rebuilt = inv.datastores[i].freeMiB + inv.datastores[i].inUseMiB
            if inv.datastores[i].freeMiB > 0 {
                inv.datastores[i].capacityMiB = rebuilt
                inv.datastores[i].freePct = inv.datastores[i].freeMiB / rebuilt * 100
                inv.datastores[i].capacitySource = .freePlusUsed
            } else {
                inv.datastores[i].capacitySource = .missing
            }
        }
    }

    // MARK: - Roll-ups

    func rollUp() {
        var hostAgg: [String: (vms: Int, on: Int, vcpuOn: Int, vcpu: Int, vramOn: Double)] = [:]
        var clusterAgg: [String: (vms: Int, on: Int, tpl: Int, vcpuOn: Int, vcpu: Int, vramOn: Double, vram: Double, prov: Double, used: Double)] = [:]
        for vm in inv.vms {
            if vm.isTemplate {
                clusterAgg[vm.clusterKey, default: (0, 0, 0, 0, 0, 0, 0, 0, 0)].tpl += 1
                clusterAgg[vm.clusterKey]!.prov += vm.provisionedMiB
                clusterAgg[vm.clusterKey]!.used += vm.inUseMiB
                continue
            }
            var h = hostAgg[vm.hostKey, default: (0, 0, 0, 0, 0)]
            h.vms += 1; h.vcpu += vm.cpus
            if vm.isRunning { h.on += 1; h.vcpuOn += vm.cpus; h.vramOn += vm.memoryMiB }
            hostAgg[vm.hostKey] = h
            var c = clusterAgg[vm.clusterKey, default: (0, 0, 0, 0, 0, 0, 0, 0, 0)]
            c.vms += 1; c.vcpu += vm.cpus; c.vram += vm.memoryMiB; c.prov += vm.provisionedMiB; c.used += vm.inUseMiB
            if vm.isRunning { c.on += 1; c.vcpuOn += vm.cpus; c.vramOn += vm.memoryMiB }
            clusterAgg[vm.clusterKey] = c
        }
        var pnics: [String: Int] = [:], hbas: [String: Int] = [:], vmks: [String: Int] = [:], luns: [String: Int] = [:], dss: [String: Int] = [:]
        for n in inv.pnics { pnics[n.hostKey, default: 0] += 1 }
        for h in inv.hbas { hbas[h.hostKey, default: 0] += 1 }
        for k in inv.vmkernels { vmks[k.hostKey, default: 0] += 1 }
        for l in inv.luns { luns[l.hostKey, default: 0] += 1 }
        for d in inv.datastores { for hk in d.hostKeys { dss[hk, default: 0] += 1 } }
        for i in inv.hosts.indices {
            let id = inv.hosts[i].id
            let a = hostAgg[id] ?? (0, 0, 0, 0, 0)
            inv.hosts[i].vmCount = a.vms
            inv.hosts[i].vmsOn = a.on
            inv.hosts[i].vcpuOn = a.vcpuOn
            inv.hosts[i].vcpuTotal = a.vcpu
            inv.hosts[i].vramOnMiB = a.vramOn
            inv.hosts[i].pnicCount = pnics[id] ?? inv.hosts[i].nicCountReported
            inv.hosts[i].hbaCount = hbas[id] ?? inv.hosts[i].hbaCountReported
            inv.hosts[i].vmkCount = vmks[id] ?? 0
            inv.hosts[i].lunCount = luns[id] ?? 0
            inv.hosts[i].datastoreCount = dss[id] ?? 0
        }
        var dsPerCluster: [String: Int] = [:]
        for d in inv.datastores { for ck in d.clusterKeys { dsPerCluster[ck, default: 0] += 1 } }
        for i in inv.clusters.indices {
            let id = inv.clusters[i].id
            let members = inv.hosts.filter { $0.clusterKey == id }
            // Virtual hosts (vSAN witness appliances, cloud placeholder hosts) add no workload capacity.
            let hosts = members.filter { !$0.isVirtual }
            inv.clusters[i].hostCount = members.count
            inv.clusters[i].hostsInMaintenance = members.filter(\.maintenance).count
            inv.clusters[i].sockets = hosts.reduce(0) { $0 + $1.sockets }
            inv.clusters[i].cores = hosts.reduce(0) { $0 + $1.cores }
            inv.clusters[i].threads = hosts.reduce(0) { $0 + $1.threads }
            inv.clusters[i].memoryMiB = hosts.reduce(0) { $0 + $1.memoryMiB }
            inv.clusters[i].cpuMHz = hosts.reduce(0) { $0 + $1.cpuCapacityMHz }
            inv.clusters[i].cpuUsedMHz = hosts.reduce(0) { $0 + $1.cpuUsedMHz }
            inv.clusters[i].memUsedMiB = hosts.reduce(0) { $0 + $1.memUsedMiB }
            inv.clusters[i].largestHostMemMiB = hosts.map(\.memoryMiB).max() ?? 0
            inv.clusters[i].largestHostCpuMHz = hosts.map(\.cpuCapacityMHz).max() ?? 0
            inv.clusters[i].esxVersions = Array(Set(hosts.map { $0.esxVersion + ($0.esxBuild.isEmpty ? "" : " (\($0.esxBuild))") })).sorted()
            inv.clusters[i].cpuModels = Array(Set(hosts.map(\.cpuModel))).sorted()
            if inv.clusters[i].datacenter.isEmpty { inv.clusters[i].datacenter = hosts.first?.datacenter ?? "" }
            let a = clusterAgg[id] ?? (0, 0, 0, 0, 0, 0, 0, 0, 0)
            inv.clusters[i].vmCount = a.vms
            inv.clusters[i].vmsOn = a.on
            inv.clusters[i].templates = a.tpl
            inv.clusters[i].vcpuOn = a.vcpuOn
            inv.clusters[i].vcpuTotal = a.vcpu
            inv.clusters[i].vramOnMiB = a.vramOn
            inv.clusters[i].vramTotalMiB = a.vram
            inv.clusters[i].provisionedMiB = a.prov
            inv.clusters[i].inUseMiB = a.used
            inv.clusters[i].datastoreCount = dsPerCluster[id] ?? 0
        }
        inv.clusters.sort { ($0.isStandalone ? 1 : 0, $0.vcenter, $0.name) < ($1.isStandalone ? 1 : 0, $1.vcenter, $1.name) }

        for i in inv.vcenters.indices {
            let server = inv.vcenters[i].server.lowercased()
            let dcs = Set(inv.hosts.filter { $0.vcenter.lowercased() == server }.map(\.datacenter) + inv.vms.filter { $0.vcenter.lowercased() == server }.map(\.datacenter))
            inv.vcenters[i].datacenters = dcs.filter { !$0.isEmpty }.sorted()
        }
    }

    // MARK: - Cross-tab consistency

    func consistencyChecks() {
        func add(_ title: String, _ reported: Int, _ derived: Int, note: String = "") {
            inv.checks.append(ConsistencyCheck(title: title, reported: Fmt.int(reported), derived: Fmt.int(derived), ok: reported == derived, note: note))
        }
        func addRatio(_ title: String, matching: Int, of total: Int, note: String) {
            guard total > 0 else { return }
            inv.checks.append(ConsistencyCheck(title: title, reported: "\(Fmt.int(total)) objects", derived: "\(Fmt.int(matching)) match", ok: matching == total, note: note))
        }
        if ds.table("vDisk") != nil {
            add("Σ vInfo.Disks vs vDisk rows", inv.vms.reduce(0) { $0 + $1.diskCount }, inv.vms.reduce(0) { $0 + $1.disks.count })
        }
        if ds.table("vNetwork") != nil {
            add("Σ vInfo.NICs vs vNetwork rows", inv.vms.reduce(0) { $0 + $1.nicCount }, inv.vms.reduce(0) { $0 + $1.nics.count })
        }
        for tab in ["vCPU", "vMemory", "vTools"] {
            if let j = inv.joins.first(where: { $0.source == tab }) { add("vInfo VMs vs \(tab) rows", inv.vms.count, j.matched) }
        }
        let tabClusters = inv.clusters.filter { $0.numHostsReported != nil }
        addRatio("vCluster.NumHosts vs hosts in vHost", matching: tabClusters.filter { $0.numHostsReported == $0.hostCount }.count, of: tabClusters.count,
                 note: "Per cluster: host count reported by vCluster equals hosts found in vHost")
        // RVTools' "# VMs total" excludes templates; "# VMs" counts powered-on VMs.
        let hostsWithReport = inv.hosts.filter { $0.vmTotalReported != nil }
        addRatio("vHost.# VMs total vs VMs in vInfo", matching: hostsWithReport.filter { $0.vmTotalReported == $0.vmCount }.count, of: hostsWithReport.count,
                 note: "Per host: non-template VMs reported by vHost equals VMs placed on it in vInfo")
        let hostsWithOn = inv.hosts.filter { $0.vmOnReported != nil }
        addRatio("vHost.# VMs vs powered-on VMs in vInfo", matching: hostsWithOn.filter { $0.vmOnReported == $0.vmsOn }.count, of: hostsWithOn.count,
                 note: "Per host: powered-on VM count")
        let templates = Set(inv.vms.filter(\.isTemplate).map(\.id))
        let dsWithReport = inv.datastores.filter { $0.vmTotalReported != nil }
        addRatio("vDatastore.# VMs total vs VMs with files there",
                 matching: dsWithReport.filter { ds in ds.vmTotalReported == ds.vmIDs.filter { !templates.contains($0) }.count }.count, of: dsWithReport.count,
                 note: "Per datastore (templates excluded): derived from VMDK and .vmx paths; VMs with only ISO/swap files there can differ")
        if ds.table("vDisk") != nil, ds.table("vInfo")?.col("Total disk capacity MiB") != nil, let t = ds.table("vInfo") {
            let c = t.col("Total disk capacity MiB"), cVM = t.col("VM"), cServer = t.col("VI SDK Server")
            var reported: [String: Double] = [:]
            for r in t.rows { reported[key(r.s(cServer), r.s(cVM))] = r.d0(c) }
            let comparable = inv.vms.filter { reported[key($0.vcenter, $0.name)] != nil && !$0.disks.isEmpty }
            let ok = comparable.filter { abs((reported[key($0.vcenter, $0.name)] ?? 0) - $0.diskCapacityMiB) < 2 }.count
            addRatio("vInfo.Total disk capacity vs Σ vDisk capacity", matching: ok, of: comparable.count, note: "Per VM, within 2 MiB")
        }
    }
}
