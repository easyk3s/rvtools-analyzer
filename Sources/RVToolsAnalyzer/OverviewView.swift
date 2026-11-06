import Charts
import RVToolsCore
import SwiftUI

struct OverviewView: View {
    @Environment(AppModel.self) private var model
    let report: Report
    private var t: Totals { report.totals }
    private var th: Thresholds { report.thresholds }
    private var q: DataQuality { report.dataQuality }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                SourceWarningsNotice()
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 190), spacing: 12)], spacing: 12) {
                    KPITile(title: "Virtual machines", value: Fmt.int(t.vms), detail: "\(Fmt.int(t.vmsOn)) on · \(Fmt.int(t.vmsOff)) off · \(Fmt.int(t.templates)) templates", symbol: "desktopcomputer")
                    KPITile(title: "Hosts", value: Fmt.int(t.hosts), detail: "\(t.clusters) clusters · \(t.datacenters) datacenters · \(report.inventory.vcenterSummary)", symbol: "server.rack")
                    // Without host data these read as zero; say so rather than show 0 cores or 0%.
                    let hosts = q.hostCapacityKnown, noHosts = q.absent("vHost")
                    KPITile(title: "Physical compute", value: hosts ? "\(Fmt.int(t.cores)) cores" : "—", detail: hosts ? "\(t.sockets) sockets · \(Fmt.memory(mib: t.physMemMiB)) RAM" : noHosts, symbol: "cpu")
                    KPITile(title: "vCPU : core", value: hosts ? Fmt.ratio(t.vcpuPerCore) : "—", detail: "\(Fmt.int(t.vcpuOn)) vCPU on running VMs", symbol: "square.stack.3d.up")
                    KPITile(title: "vRAM : RAM", value: hosts ? Fmt.pct(t.vramPerPhysical * 100) : "—", detail: "\(Fmt.memory(mib: t.vramOnMiB)) assigned to running VMs", symbol: "memorychip")
                    KPITile(title: "CPU usage", value: hosts ? Fmt.pct(t.cpuUsagePct) : "—", detail: hosts ? "\(Fmt.ghz(t.cpuUsedMHz)) of \(Fmt.ghz(t.cpuMHz))" : noHosts, symbol: "speedometer")
                    KPITile(title: "Memory usage", value: hosts ? Fmt.pct(t.memUsagePct) : "—", detail: hosts ? "\(Fmt.memory(mib: t.memUsedMiB)) of \(Fmt.memory(mib: t.physMemMiB))" : noHosts, symbol: "memorychip.fill")
                    KPITile(title: "Datastores", value: q.datastoreCapacityKnown ? Fmt.capacity(mib: t.dsCapacityMiB) : "—",
                            detail: (q.datastoreCapacityKnown ? "\(Fmt.pct(t.dsUsedPct)) used · \(Fmt.capacity(mib: t.dsFreeMiB)) free · " : "Capacity not in export · ") + "\(t.datastores) datastores"
                            + (report.thresholds.ignoreUnusedLocalDatastores && !report.unusedLocalDatastores.isEmpty ? " (\(report.unusedLocalDatastores.count) unused local left out)" : ""),
                            symbol: "externaldrive")
                    KPITile(title: "VM storage in use", value: Fmt.capacity(mib: t.vmInUseMiB), detail: "of \(Fmt.capacity(mib: t.vmProvisionedMiB)) provisioned", symbol: "internaldrive")
                    KPITile(title: "Snapshots", value: q.has("vSnapshot") ? Fmt.int(t.snapshots) : "—",
                            detail: q.has("vSnapshot") ? "\(Fmt.capacity(mib: t.snapshotMiB)) in delta files" : q.absent("vSnapshot"), symbol: "camera.on.rectangle")
                    KPITile(title: "Findings", value: Fmt.int(t.findings), detail: "\(t.critical) critical · \(t.warning) warning · \(t.info) info"
                                + (report.acknowledgedFindings.isEmpty ? "" : " · \(report.acknowledgedFindings.count) acknowledged"),
                            symbol: Severity.critical.symbol, tint: t.critical > 0 ? Palette.critical : .secondary)
                }

                HStack(alignment: .top, spacing: 16) {
                    Card("VM power state", subtitle: "\(Fmt.int(t.vms + t.templates)) objects in vInfo") {
                        PartBar(parts: zip(report.dist.powerState, Palette.series).map { PartBar.Part(label: $0.label, value: Double($0.count), color: $1) })
                        Divider()
                        footprint
                    }
                    healthCard
                }

                HStack(alignment: .top, spacing: 16) {
                    Card("VMs by cluster", subtitle: "Powered-on vs powered-off (templates excluded)") {
                        StackedBarChart(
                            segments: report.dist.vmsByCluster.flatMap {
                                [StackSegment(category: $0.label, series: "Powered on", value: Double($0.count)),
                                 StackSegment(category: $0.label, series: "Powered off", value: $0.value)]
                            },
                            categories: report.dist.vmsByCluster.map(\.label),
                            series: ["Powered on", "Powered off"],
                            colors: [Palette.series[0], Palette.series[1]])
                    }
                    Card("Guest OS family", subtitle: "VM count · vCPU in label") {
                        BarListChart(items: report.dist.osFamily, label: { "\(Fmt.int($0.count)) · \(Fmt.int(Int($0.value))) vCPU" })
                    }
                }

                clusterCapacity

                HStack(alignment: .top, spacing: 16) {
                    Card("Most-utilized datastores", subtitle: "Used capacity · tick marks the \(Fmt.num(100 - th.datastoreFreeWarnPct, 0))% warning threshold") {
                        DatastoreUsageChart(datastores: report.inventory.datastores, thresholds: th, limit: 12)
                    }
                    topIssues
                }
            }
            .padding(20)
        }
    }

    private var footprint: some View {
        let on = report.inventory.vms.filter { $0.isVM && $0.isRunning }
        let all = report.inventory.vms.filter(\.isVM)
        func row(_ name: String, _ vms: [VM]) -> some View {
            GridRow {
                Text(name).foregroundStyle(.secondary)
                Text(Fmt.int(vms.count)).tabular()
                Text(Fmt.int(vms.reduce(0) { $0 + $1.cpus })).tabular()
                Text(Fmt.memory(mib: vms.reduce(0) { $0 + $1.memoryMiB })).tabular()
                Text(Fmt.capacity(mib: vms.reduce(0) { $0 + $1.provisionedMiB })).tabular()
                Text(Fmt.capacity(mib: vms.reduce(0) { $0 + $1.inUseMiB })).tabular()
            }
        }
        return VStack(alignment: .leading, spacing: 6) {
            Text("Workload footprint").font(.subheadline.weight(.semibold))
            Grid(alignment: .trailing, horizontalSpacing: 16, verticalSpacing: 4) {
                GridRow {
                    Text("").gridColumnAlignment(.leading)
                    Text("VMs"); Text("vCPU"); Text("vRAM"); Text("Provisioned"); Text("In use")
                }
                .font(.caption).foregroundStyle(.secondary)
                row("Powered on", on)
                row("All VMs", all)
            }
            .font(.callout)
        }
    }

    private var healthCard: some View {
        Card("Health", subtitle: "\(Fmt.int(t.findings)) findings from \(report.groups.count) checks") {
            HStack(spacing: 10) {
                ForEach(Severity.allCases) { s in
                    Button { model.showIssues() } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            SeverityBadge(severity: s).font(.caption)
                            Text(Fmt.int(count(s))).font(.title2.weight(.semibold)).tabular()
                        }
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(RoundedRectangle(cornerRadius: 8).fill(Palette.track.opacity(0.6)))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            let cats = report.dist.findingsByCategory
            StackedBarChart(
                segments: cats.flatMap { c in Severity.allCases.compactMap { s in c.counts[s].map { StackSegment(category: c.category.rawValue, series: s.label, value: Double($0)) } } },
                categories: cats.map(\.category.rawValue),
                series: Severity.allCases.map(\.label),
                colors: Severity.allCases.map { Palette.severity($0) })
        }
    }

    private func count(_ s: Severity) -> Int {
        switch s { case .critical: return t.critical; case .warning: return t.warning; case .info: return t.info }
    }

    private var clusterCapacity: some View {
        Card("Cluster capacity & headroom", subtitle: "Utilization from host counters · N+1 = memory in use vs capacity left if the largest host fails") {
            Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 9) {
                GridRow {
                    Text("Cluster"); Text("Hosts"); Text("VMs on / total"); Text("vCPU : core"); Text("CPU used"); Text("Memory used")
                    Text("Memory after host loss"); Text("Protection")
                }
                .font(.caption).foregroundStyle(.secondary)
                Divider().gridCellUnsizedAxes(.horizontal)
                ForEach(report.inventory.clusters) { c in
                    GridRow {
                        Button(c.name) { model.computeTab = 0; model.sidebar = .compute }.buttonStyle(.link).lineLimit(1)
                        Text("\(c.hostCount)").tabular()
                        Text("\(Fmt.int(c.vmsOn)) / \(Fmt.int(c.vmCount))").tabular()
                        Text(c.capacityUnknown ? "—" : Fmt.ratio(c.vcpuPerCore)).tabular()
                        if c.capacityUnknown {
                            // CPU used, memory used, N+1: no host data behind any of them.
                            ForEach(0..<3, id: \.self) { _ in Text("no host data").font(.caption).foregroundStyle(.secondary) }
                        } else {
                            UsageMeter(pct: c.cpuUsagePct, warn: th.hostCPUWarnPct, crit: 95)
                            UsageMeter(pct: c.memUsagePct, warn: th.hostMemWarnPct, crit: 95)
                            if c.hostCount > 1 {
                                UsageMeter(pct: c.memPctAfterHostLoss, warn: 90, crit: 100)
                            } else {
                                Text("single host").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        if c.isStandalone {
                            Text("standalone").font(.caption).foregroundStyle(.secondary)
                        } else {
                            HStack(spacing: 4) {
                                StateChip(label: "HA", state: c.haEnabled)
                                StateChip(label: "DRS", state: c.drsEnabled)
                            }
                        }
                    }
                }
            }
        }
    }

    private var topIssues: some View {
        Card("Top issues", subtitle: "Critical and warning checks, most affected objects first") {
            let groups = report.groups.filter { $0.severity != .info }.prefix(10)
            if groups.isEmpty {
                Label("No critical or warning findings", systemImage: "checkmark.circle.fill").foregroundStyle(Palette.good)
            }
            VStack(spacing: 0) {
                ForEach(Array(groups)) { g in
                    Button { model.showIssues(rule: g.rule) } label: {
                        HStack(spacing: 8) {
                            SeverityBadge(severity: g.severity, showLabel: false)
                            Text(g.title).lineLimit(1)
                            Spacer()
                            Text(Fmt.int(g.count)).tabular().foregroundStyle(.secondary)
                            Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
                        }
                        .padding(.vertical, 6)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    Divider()
                }
            }
        }
    }
}

struct DatastoreUsageChart: View {
    let datastores: [Datastore]
    let thresholds: Thresholds
    var limit = 12

    var body: some View {
        let top = Array(datastores.filter { $0.capacityMiB > 0 }.sorted { $0.usedPct > $1.usedPct }.prefix(limit))
        let warn = 100 - thresholds.datastoreFreeWarnPct, crit = 100 - thresholds.datastoreFreeCritPct
        let lw = barLabelWidth(top.map(\.name))
        VStack(alignment: .leading, spacing: 5) {
            ForEach(top) { d in
                HStack(spacing: 8) {
                    Text(d.name).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                        .frame(width: lw, alignment: .trailing)
                    GeometryReader { g in
                        let w = max(g.size.width - 140, 20)
                        ZStack(alignment: .leading) {
                            Capsule().fill(Palette.track).frame(width: w, height: 10)
                            Capsule().fill(Palette.usage(d.usedPct, warn: warn, crit: crit)).frame(width: max(3, w * min(d.usedPct, 100) / 100), height: 10)
                            Rectangle().fill(Palette.neutral).frame(width: 1, height: 16).offset(x: w * warn / 100)
                            Text("\(Fmt.pct(d.usedPct)) · \(Fmt.capacity(mib: d.freeMiB)) free").font(.caption).foregroundStyle(.secondary)
                                .monospacedDigit().fixedSize().offset(x: w + 8)
                        }
                        .frame(maxHeight: .infinity)
                    }
                    .frame(height: 18)
                }
                .help("\(d.name): \(Fmt.pct(d.usedPct)) used · \(Fmt.capacity(mib: d.freeMiB)) free of \(Fmt.capacity(mib: d.capacityMiB))")
            }
            HStack(spacing: 14) {
                Label("\(Fmt.num(warn, 0))% line", systemImage: "line.diagonal").foregroundStyle(.secondary)
                Label("< \(Fmt.num(thresholds.datastoreFreeWarnPct, 0))% free", systemImage: Severity.warning.symbol).foregroundStyle(Palette.warning)
                Label("< \(Fmt.num(thresholds.datastoreFreeCritPct, 0))% free", systemImage: Severity.critical.symbol).foregroundStyle(Palette.critical)
            }
            .font(.caption)
        }
    }
}

/// Anything odd about the files themselves, e.g. rows that arrived twice because an export was opened more than once.
struct SourceWarningsNotice: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let warnings = model.dataset?.warnings ?? []
        if !warnings.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(warnings, id: \.self) { w in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Image(systemName: Severity.info.symbol).foregroundStyle(Palette.primary)
                        Text(w).font(.callout).fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 0)
                    }
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 8).fill(Palette.track.opacity(0.5)))
        }
    }
}
