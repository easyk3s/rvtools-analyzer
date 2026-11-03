import RVToolsCore
import SwiftUI

struct VMsView: View {
    @Environment(AppModel.self) private var model
    let report: Report
    @State private var search = ""
    @State private var power = PowerFilter.all
    @State private var family = "All"
    @State private var issuesOnly = false
    @State private var sortOrder = [KeyPathComparator(\VM.name)]

    enum PowerFilter: String, CaseIterable, Identifiable {
        case all = "All", on = "On", off = "Off", templates = "Templates"
        var id: String { rawValue }
    }

    private var rows: [VM] {
        var r = report.inventory.vms
        switch power {
        case .all: break
        case .on: r = r.filter { $0.isRunning && !$0.isTemplate }
        case .off: r = r.filter { !$0.isRunning && !$0.isTemplate }
        case .templates: r = r.filter(\.isTemplate)
        }
        if family != "All" { r = r.filter { $0.os.family.rawValue == family } }
        if issuesOnly { r = r.filter { $0.issueCount > 0 } }
        let q = search.lowercased().trimmingCharacters(in: .whitespaces)
        if !q.isEmpty {
            r = r.filter { (vm: VM) -> Bool in VMsView.searchText(vm).contains(q) }
        }
        return r.sorted(using: sortOrder)
    }

    static func searchText(_ vm: VM) -> String {
        var parts: [String] = [vm.name, vm.host, vm.cluster, vm.os.name, vm.osConfig, vm.folder, vm.annotation, vm.dnsName]
        parts.append(contentsOf: vm.ips)
        parts.append(contentsOf: vm.networks)
        parts.append(contentsOf: vm.datastores)
        parts.append(contentsOf: vm.customFields.map { "\($0.name) \($0.value)" })
        return parts.joined(separator: "\n").lowercased()
    }

    static func shortHost(_ vm: VM) -> String {
        vm.host.split(separator: ".").first.map(String.init) ?? vm.host
    }

    var body: some View {
        @Bindable var model = model
        let rows = rows
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Picker("Power", selection: $power) { ForEach(PowerFilter.allCases) { Text($0.rawValue).tag($0) } }
                    .pickerStyle(.segmented).frame(width: 280)
                Picker("OS family", selection: $family) {
                    Text("All OS families").tag("All")
                    ForEach(OSFamily.allCases, id: \.self) { Text($0.rawValue).tag($0.rawValue) }
                }
                .frame(width: 230)
                Toggle("With findings only", isOn: $issuesOnly).toggleStyle(.checkbox)
                Spacer()
                Text("\(Fmt.int(rows.count)) of \(Fmt.int(report.inventory.vms.count)) VMs").foregroundStyle(.secondary).font(.callout)
            }
            .padding(.horizontal, 14).padding(.vertical, 10)
            Divider()
            let supportDate = Lifecycle.supportReference(exportDate: report.inventory.reportDate)
            Table(rows, selection: $model.selectedVMID, sortOrder: $sortOrder) {
                Group {
                    TableColumn("Name", sortUsing: KeyPathComparator(\VM.name)) { (vm: VM) in VMNameCell(vm: vm) }.width(min: 160, ideal: 220)
                    TableColumn("Cluster", sortUsing: KeyPathComparator(\VM.cluster)) { (vm: VM) in Text(vm.cluster) }
                    TableColumn("Host", sortUsing: KeyPathComparator(\VM.host)) { (vm: VM) in Text(VMsView.shortHost(vm)) }
                    TableColumn("Guest OS", sortUsing: KeyPathComparator(\VM.osName)) { (vm: VM) in GuestOSCell(vm: vm, supportDate: supportDate) }.width(min: 120, ideal: 175)
                    TableColumn("vCPU", sortUsing: KeyPathComparator(\VM.cpus)) { (vm: VM) in Text("\(vm.cpus)").tabular() }.width(44)
                    TableColumn("Memory", sortUsing: KeyPathComparator(\VM.memoryMiB)) { (vm: VM) in Text(Fmt.memory(mib: vm.memoryMiB)).tabular() }.width(70)
                    TableColumn("Provisioned", sortUsing: KeyPathComparator(\VM.provisionedMiB)) { (vm: VM) in Text(Fmt.capacity(mib: vm.provisionedMiB)).tabular() }.width(80)
                    TableColumn("In use", sortUsing: KeyPathComparator(\VM.inUseMiB)) { (vm: VM) in Text(Fmt.capacity(mib: vm.inUseMiB)).tabular() }.width(70)
                }
                Group {
                    TableColumn("Datastores", sortUsing: KeyPathComparator(\VM.datastoreList)) { (vm: VM) in Text(vm.datastoreList) }
                    TableColumn("Networks", sortUsing: KeyPathComparator(\VM.networkList)) { (vm: VM) in Text(vm.networkList) }
                    TableColumn("IP", sortUsing: KeyPathComparator(\VM.primaryIP)) { (vm: VM) in Text(vm.ips.first ?? "") }
                    TableColumn("Tools", sortUsing: KeyPathComparator(\VM.toolsDisplay)) { (vm: VM) in Text(vm.toolsDisplay) }.width(80)
                    TableColumn("HW", sortUsing: KeyPathComparator(\VM.hwVersion)) { (vm: VM) in Text(vm.hwVersion > 0 ? "vmx-\(vm.hwVersion)" : "").tabular() }.width(55)
                    TableColumn("Snaps", sortUsing: KeyPathComparator(\VM.snapshotCount)) { (vm: VM) in Text(vm.snapshotCount > 0 ? "\(vm.snapshotCount)" : "").tabular() }.width(44)
                    TableColumn("Findings", sortUsing: KeyPathComparator(\VM.issueCount)) { (vm: VM) in FindingsCell(vm: vm) }.width(60)
                }
            }
        }
        .searchable(text: $search, placement: .toolbar, prompt: "Name, IP, host, OS, network, datastore, notes")
        .inspector(isPresented: Binding(get: { model.selectedVMID != nil }, set: { if !$0 { model.selectedVMID = nil } })) {
            if let id = model.selectedVMID, let vm = model.lookup.vms[id] {
                VMDetail(vm: vm, report: report)
            } else {
                ContentUnavailableView("Select a VM", systemImage: "desktopcomputer")
            }
        }
        .inspectorColumnWidth(min: 360, ideal: 440, max: 680)
    }
}

private struct VMNameCell: View {
    let vm: VM
    var body: some View {
        HStack(spacing: 6) {
            PowerIcon(vm: vm).frame(width: 12)
            Text(vm.name)
            if vm.notInVInfo {
                Text("Not in vInfo").font(.caption2).foregroundStyle(.secondary)
                    .help("Rebuilt from other tabs because its vInfo row is gone, so it has fewer details")
            }
        }
    }
}

private struct GuestOSCell: View {
    let vm: VM
    let supportDate: Date
    var body: some View {
        HStack(spacing: 4) {
            Text(vm.os.name)
            if let e = vm.os.endOfSupport, e <= supportDate {
                Image(systemName: Severity.warning.symbol).foregroundStyle(Palette.warning).help("Past end of support (\(Fmt.date(e)))")
            }
        }
    }
}

private struct FindingsCell: View {
    let vm: VM
    var body: some View {
        if vm.issueCount > 0, let s = Severity(rawValue: vm.worstSeverity) {
            HStack(spacing: 3) {
                Image(systemName: s.symbol).foregroundStyle(Palette.severity(s))
                Text("\(vm.issueCount)").tabular()
            }
            .help("\(vm.issueCount) findings, worst: \(s.label)")
        }
    }
}

struct VMDetail: View {
    @Environment(AppModel.self) private var model
    let vm: VM
    let report: Report

    var body: some View {
        let supportDate = Lifecycle.supportReference(exportDate: report.inventory.reportDate)
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(vm.name).font(.title3.weight(.semibold)).textSelection(.enabled)
                    HStack(spacing: 6) {
                        PowerIcon(vm: vm)
                        Text("\(vm.powerLabel) · \(vm.os.name)").lineLimit(1)
                    }
                    .font(.callout)
                    if let e = vm.os.endOfSupport {
                        Tag(text: e <= supportDate ? "OS support ended \(Fmt.date(e))" : "OS support ends \(Fmt.date(e))")
                    }
                    RelationshipMapButton(focus: .vm(vm.id)).padding(.top, 2)
                }
                if let trend = model.trend {
                    DetailSection("History across snapshots") {
                        VMHistoryGrid(trend: trend, key: trend.key(vm))
                    }
                }
                DetailSection("Findings", count: report.findingsByObject[vm.id]?.count ?? 0) {
                    ObjectFindings(findings: report.findingsByObject[vm.id] ?? [])
                }
                DetailSection("Placement") {
                    Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 14, verticalSpacing: 5) {
                        GridRow { Text("vCenter").foregroundStyle(.secondary); Text(vm.vcenter) }
                        GridRow { Text("Datacenter").foregroundStyle(.secondary); Text(vm.datacenter) }
                        GridRow { Text("Cluster").foregroundStyle(.secondary); Text(vm.cluster.isEmpty ? "—" : vm.cluster) }
                        GridRow {
                            Text("Host").foregroundStyle(.secondary)
                            if model.lookup.hosts[vm.hostKey] != nil {
                                Button { model.reveal(host: vm.hostKey) } label: {
                                    Text(vm.host).lineLimit(1).truncationMode(.middle)
                                }
                                .buttonStyle(.link)
                            } else {
                                Text(vm.host)
                            }
                        }
                        GridRow {
                            Text("Datastores").foregroundStyle(.secondary)
                            HStack(spacing: 8) {
                                ForEach(vm.datastores, id: \.self) { name in
                                    let id = Lookup.id(vm.vcenter, name)
                                    if model.lookup.datastores[id] != nil {
                                        Button { model.reveal(datastore: id) } label: { Text(name).lineLimit(1) }.buttonStyle(.link)
                                    } else {
                                        Text(name)
                                    }
                                }
                            }
                        }
                        GridRow { Text("Folder").foregroundStyle(.secondary); Text(vm.folder.isEmpty ? "—" : vm.folder) }
                        GridRow { Text("Resource pool").foregroundStyle(.secondary); Text(vm.resourcePool.isEmpty ? "—" : vm.resourcePool).lineLimit(2) }
                    }
                    .font(.callout)
                }
                DetailSection("Compute") {
                    KeyValueGrid(rows: [
                        ("vCPU", "\(vm.cpus)" + (vm.sockets > 0 ? " (\(vm.sockets) socket × \(vm.coresPerSocket) cores)" : "") + sourceNote(vm.cpusSource)),
                        ("Memory", Fmt.memory(mib: vm.memoryMiB) + sourceNote(vm.memorySource)),
                        ("CPU reservation / limit", "\(Fmt.int(Int(vm.cpuReservationMHz))) MHz / " + (vm.cpuLimitMHz < 0 ? "unlimited" : "\(Fmt.int(Int(vm.cpuLimitMHz))) MHz")),
                        ("Memory reservation / limit", Fmt.memory(mib: vm.memReservationMiB) + " / " + (vm.memLimitMiB < 0 ? "unlimited" : Fmt.memory(mib: vm.memLimitMiB))),
                        ("Hot add", "CPU \(vm.cpuHotAdd ? "on" : "off") · memory \(vm.memHotAdd ? "on" : "off")"),
                        ("Consumed / active", "\(Fmt.memory(mib: vm.memConsumedMiB)) / \(Fmt.memory(mib: vm.memActiveMiB))"),
                        ("Ballooned / swapped", "\(Fmt.memory(mib: vm.memBalloonedMiB)) / \(Fmt.memory(mib: vm.memSwappedMiB))"),
                        ("CPU readiness", vm.cpuReadinessPct.map { Fmt.num($0, 1) + "%" } ?? "—"),
                    ])
                }
                DetailSection("Storage", count: vm.disks.count) {
                    KeyValueGrid(rows: [
                        ("Provisioned", Fmt.capacity(mib: vm.provisionedMiB) + sourceNote(vm.provisionedSource)),
                        ("In use", Fmt.capacity(mib: vm.inUseMiB) + sourceNote(vm.inUseSource)),
                        ("Guest file systems", vm.partitions.isEmpty ? "—" : "\(Fmt.capacity(mib: vm.guestConsumedMiB)) used of \(Fmt.capacity(mib: vm.guestCapacityMiB))"),
                    ])
                    ForEach(Array(vm.disks.enumerated()), id: \.offset) { _, d in
                        VStack(alignment: .leading, spacing: 1) {
                            HStack {
                                Text(d.label).font(.callout.weight(.medium))
                                Spacer()
                                Text(Fmt.capacity(mib: d.capacityMiB)).tabular()
                            }
                            Text("\(d.provisioning) · \(d.mode) · \(d.controller)").font(.caption).foregroundStyle(.secondary)
                            Text(d.path).font(.caption2).foregroundStyle(.tertiary).lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                        }
                        .padding(.vertical, 2)
                    }
                    if !vm.partitions.isEmpty {
                        Text("Guest partitions").font(.subheadline.weight(.semibold)).padding(.top, 4)
                        ForEach(Array(vm.partitions.enumerated()), id: \.offset) { _, p in
                            HStack(spacing: 8) {
                                Text(p.disk).font(.callout).frame(width: 70, alignment: .leading).lineLimit(1)
                                Meter(fraction: 1 - p.freePct / 100, color: Palette.usage(100 - p.freePct, warn: 100 - report.thresholds.guestFreeWarnPct, crit: 95))
                                Text("\(Fmt.num(p.freePct, 0))% free of \(Fmt.capacity(mib: p.capacityMiB))").font(.caption).foregroundStyle(.secondary).tabular()
                                    .frame(width: 140, alignment: .trailing)
                            }
                        }
                    }
                }
                DetailSection("Network", count: vm.nics.count) {
                    if vm.nics.isEmpty && !vm.networks.isEmpty { Text(vm.networkList).font(.callout) }
                    ForEach(Array(vm.nics.enumerated()), id: \.offset) { _, n in
                        let pgID = Lookup.id(vm.vcenter, n.network)
                        let pg = model.lookup.portGroups[pgID]
                        VStack(alignment: .leading, spacing: 1) {
                            HStack(spacing: 6) {
                                Image(systemName: n.connected ? "cable.connector" : "cable.connector.slash").foregroundStyle(n.connected ? Palette.good : .secondary)
                                Text(n.label).font(.callout.weight(.medium))
                                Text(n.adapter).font(.caption).foregroundStyle(.secondary)
                                Spacer()
                                if pg != nil { Button(n.network) { model.reveal(portGroup: pgID) }.buttonStyle(.link).font(.callout) } else { Text(n.network).font(.callout) }
                            }
                            Text(["VLAN \(pg?.vlanList ?? "—")", n.switchName, n.mac, n.ipv4.joined(separator: ", ")].filter { !$0.isEmpty }.joined(separator: " · "))
                                .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                        }
                        .padding(.vertical, 2)
                    }
                }
                if !vm.snapshots.isEmpty {
                    DetailSection("Snapshots", count: vm.snapshots.count) {
                        ForEach(Array(vm.snapshots.enumerated()), id: \.offset) { _, s in
                            HStack(alignment: .firstTextBaseline) {
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(s.name).font(.callout.weight(.medium))
                                    Text("\(Fmt.dateTime(s.date)) · \(Fmt.num(s.ageDays ?? 0, 0)) days old" + (s.quiesced ? " · quiesced" : "")).font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Text(Fmt.capacity(mib: s.sizeMiB)).tabular()
                            }
                        }
                    }
                }
                DetailSection("Configuration") {
                    KeyValueGrid(rows: [
                        ("Guest OS (configured)", vm.osConfig), ("Guest OS (Tools)", vm.osTools),
                        ("VMware Tools", "\(vm.toolsDisplay)" + (vm.toolsVersion.isEmpty ? "" : " · \(vm.toolsVersion)") + (vm.toolsUpgradePolicy.isEmpty ? "" : " · \(vm.toolsUpgradePolicy)")),
                        ("Hardware", Lifecycle.hardwareLabel(vm.hwVersion)),
                        ("Firmware", vm.firmware.uppercased() + (vm.secureBoot ? " · Secure Boot" : "")),
                        ("CBT", vm.cbt.map { $0 ? "Enabled" : "Disabled" } ?? "—"),
                        ("Heartbeat / status", "\(vm.heartbeat) / \(vm.configStatus)"),
                        ("CD/DVD", vm.cdroms.isEmpty ? "—" : vm.cdroms.map { "\($0.node): \($0.connected ? "connected" : "disconnected")" }.joined(separator: ", ")),
                        ("HA restart priority", vm.haRestartPriority), ("FT", vm.ftState),
                        ("Created", Fmt.dateTime(vm.creationDate)), ("Powered on", Fmt.dateTime(vm.powerOnDate)),
                        ("DNS name", vm.dnsName), ("VM ID", vm.vmID), ("UUID", vm.uuid),
                    ])
                }
                if !vm.health.isEmpty {
                    DetailSection("RVTools vHealth", count: vm.health.count) {
                        ForEach(vm.health) { h in
                            VStack(alignment: .leading, spacing: 1) {
                                Text(h.type).font(.caption.weight(.semibold))
                                Text(h.message).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                            }
                        }
                    }
                }
                if !vm.annotation.isEmpty {
                    DetailSection("Notes") { Text(vm.annotation).font(.callout).textSelection(.enabled) }
                }
                if !vm.customFields.isEmpty {
                    DetailSection("Custom attributes and tags", count: vm.customFields.count) {
                        KeyValueGrid(rows: vm.customFields.map { ($0.name, $0.value) })
                    }
                }
            }
            .padding(16)
        }
        // Kept off the top edge: a scroll view that runs under the toolbar gets its 52pt inset counted twice when macOS 27
        // hit-tests it, so clicks land on whatever is drawn that far below (the Relationship Map button hit the findings).
        .padding(.top, 1)
    }
}

/// Suffix for an inspector value that vInfo didn't report directly.
func sourceNote(_ source: FigureSource) -> String {
    switch source {
    case .reported: return ""
    case .missing: return " · not in export"
    default: return " · derived from \(source.rawValue)"
    }
}
