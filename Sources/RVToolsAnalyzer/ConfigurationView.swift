import RVToolsCore
import SwiftUI

struct ConfigurationView: View {
    let report: Report

    var body: some View {
        let d = report.dist
        let vms = report.inventory.vms.filter(\.isVM)
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 16, alignment: .top), GridItem(.flexible(), spacing: 16, alignment: .top)], spacing: 16) {
                    Card("Guest OS family", subtitle: "VMs (templates excluded)") { BarListChart(items: d.osFamily) }
                    Card("Guest operating systems", subtitle: "Top 15 by VM count") { BarListChart(items: d.osName) }
                    Card("vCPU per VM") { ColumnChart(items: d.vcpuSize) }
                    Card("Memory per VM") { ColumnChart(items: d.memorySize) }
                    Card("Firmware & Secure Boot") { BarListChart(items: d.firmware) }
                    Card("Virtual disk controllers", subtitle: "Number of disks") { BarListChart(items: d.diskController) }
                    Card("Virtual NIC adapters") { BarListChart(items: d.nicAdapter) }
                    Card("Resource controls", subtitle: "Settings that change how vSphere schedules VMs") {
                        KeyValueGrid(rows: [
                            ("CPU hot-add enabled", count(vms) { $0.cpuHotAdd }),
                            ("Memory hot-add enabled", count(vms) { $0.memHotAdd }),
                            ("CPU limit set", count(vms) { $0.cpuLimitMHz >= 0 }),
                            ("Memory limit set", count(vms) { $0.memLimitMiB >= 0 }),
                            ("CPU reservation", count(vms) { $0.cpuReservationMHz > 0 }),
                            ("Memory reservation", count(vms) { $0.memReservationMiB > 0 }),
                            ("Changed Block Tracking on", count(vms) { $0.cbt == true }),
                            ("Latency sensitivity high", count(vms) { $0.latencySensitivity.lowercased() == "high" }),
                            ("Multi-socket vCPU layout", count(vms) { $0.sockets > 1 }),
                            ("Independent disks", count(vms) { $0.disks.contains(where: \.isIndependent) }),
                            ("RDM disks", count(vms) { $0.disks.contains(where: \.raw) }),
                            ("Connected CD/DVD", count(vms) { $0.cdroms.contains(where: \.connected) }),
                        ])
                    }
                    Card("Host CPU models") { BarListChart(items: d.cpuModel) }
                    Card("Host hardware") { BarListChart(items: d.hostModel) }
                    Card("Port group types") { BarListChart(items: d.portGroupKind) }
                    Card("Physical NIC link speed") { BarListChart(items: d.pnicSpeed) }
                }
            }
            .padding(20)
        }
    }

    private func count(_ vms: [VM], _ pred: (VM) -> Bool) -> String {
        let n = vms.filter(pred).count
        return "\(Fmt.int(n)) VMs (\(Fmt.pct(vms.isEmpty ? 0 : Double(n) / Double(vms.count) * 100)))"
    }
}

/// Licenses that have expired or expire within the renewal window (Settings › Findings), at the top of Lifecycle.
struct LicenseRenewalsCard: View {
    @Environment(AppModel.self) private var model
    let report: Report

    var body: some View {
        let exported = report.inventory.reportDate
        let now = License.renewalReference(exportDate: exported)
        let window = report.thresholds.licenseExpiryDays
        let due = report.inventory.licenses.filter { l in
            if let days = l.daysToExpiry(from: now) { return days <= window }
            return l.isEvaluation
        }
        .sorted { ($0.expiration ?? .distantFuture, $0.name) < ($1.expiration ?? .distantFuture, $1.name) }
        if !due.isEmpty {
            let expired = due.filter { ($0.daysToExpiry(from: now) ?? 1) <= 0 }.count
            Card("License renewals", subtitle: "Expired, or expiring within \(Fmt.num(window, 0)) days of today (\(Fmt.date(now)))"
                 + (Calendar.current.isDate(now, inSameDayAs: exported) ? "" : " · export taken \(Fmt.date(exported))") + " — change the window in Settings › Findings") {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 8) {
                        Image(systemName: expired > 0 ? Severity.critical.symbol : Severity.warning.symbol)
                            .foregroundStyle(expired > 0 ? Palette.critical : Palette.warning)
                        Text(headline(due.count, expired: expired, window: window)).font(.callout.weight(.medium))
                        Spacer()
                        Button("Show in Issues") { model.showIssues(rule: expired > 0 ? "lic.expired" : "lic.expiring") }.controlSize(.small)
                    }
                    Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
                        GridRow { Text("Status"); Text("Product"); Text("vCenter"); Text("Key"); Text("Used / total"); Text("Expires") }
                            .font(.caption).foregroundStyle(.secondary)
                        ForEach(due) { l in
                            GridRow {
                                LicenseStatus(license: l, now: now, window: window)
                                Text(l.name)
                                Text(l.vcenter).foregroundStyle(.secondary)
                                Text(l.keyMasked).tabular().foregroundStyle(.secondary)
                                Text(l.total > 0 ? "\(Fmt.num(l.used, 0)) / \(Fmt.num(l.total, 0)) \(l.costUnit)" : l.costUnit).tabular()
                                Text(l.expiration.map { Fmt.date($0) } ?? l.expirationRaw).tabular()
                            }
                        }
                    }
                    .font(.callout)
                }
            }
        }
    }

    private func headline(_ count: Int, expired: Int, window: Double) -> String {
        let s = count == 1 ? "" : "s"
        if expired == count { return "\(count) license\(s) expired" }
        if expired > 0 { return "\(expired) expired and \(count - expired) more expire within \(Fmt.num(window, 0)) days" }
        return "\(count) license\(s) expire\(count == 1 ? "s" : "") within \(Fmt.num(window, 0)) days"
    }
}

/// Expired / days left / evaluation / active, for one license on `now` (see `License.renewalReference`).
struct LicenseStatus: View {
    let license: License
    let now: Date
    let window: Double

    var body: some View {
        if let days = license.daysToExpiry(from: now) {
            if days <= 0 {
                Label("Expired", systemImage: Severity.critical.symbol).foregroundStyle(Palette.critical)
            } else if days <= window {
                Label("\(Int(days.rounded(.up))) days", systemImage: Severity.warning.symbol).foregroundStyle(Palette.warning)
            } else {
                Label("Active", systemImage: "checkmark.circle.fill").foregroundStyle(Palette.good)
            }
        } else if license.isEvaluation {
            Label("Evaluation", systemImage: Severity.warning.symbol).foregroundStyle(Palette.warning)
        } else {
            Label("No expiry", systemImage: "checkmark.circle.fill").foregroundStyle(Palette.good)
        }
    }
}

struct LifecycleView: View {
    @Environment(AppModel.self) private var model
    let report: Report

    var body: some View {
        let inv = report.inventory
        let exported = inv.reportDate
        let now = Lifecycle.supportReference(exportDate: exported)
        let yearAhead = now.addingTimeInterval(365 * 86_400)
        let lifecycleColors: [String: Color] = ["Past end of support": Palette.critical, "Ends within 12 months": Palette.warning, "Supported": Palette.good, "Unknown": Palette.neutral]
        let osRows: [(name: String, count: Int, eos: Date)] = Dictionary(grouping: inv.vms.filter { $0.isVM && $0.os.endOfSupport != nil }, by: \.os.name)
            .map { ($0.key, $0.value.count, $0.value[0].os.endOfSupport!) }
            .sorted { ($0.eos, -$0.count) < ($1.eos, -$1.count) }
        let esxRows: [(version: String, hosts: Int, eos: Date?)] = Dictionary(grouping: inv.hosts, by: { $0.esxVersion + ($0.esxBuild.isEmpty ? "" : " build \($0.esxBuild)") })
            .map { ($0.key, $0.value.count, Lifecycle.vsphereEndOfSupport($0.value[0].esxVersion)) }
            .sorted { $0.version > $1.version }
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                LicenseRenewalsCard(report: report)
                Card("Guest OS support status", subtitle: "Based on built-in vendor end-of-support dates, as of today (\(Fmt.date(now)))"
                     + (Calendar.current.isDate(now, inSameDayAs: exported) ? "" : " · export taken \(Fmt.date(exported))")) {
                    PartBar(parts: report.dist.osLifecycle.map { PartBar.Part(label: $0.label, value: Double($0.count), color: lifecycleColors[$0.label] ?? Palette.neutral) })
                }
                HStack(alignment: .top, spacing: 16) {
                    Card("Operating systems with a support end date") {
                        Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
                            GridRow { Text("Operating system"); Text("VMs"); Text("Support ends"); Text("Status") }.font(.caption).foregroundStyle(.secondary)
                            ForEach(osRows, id: \.name) { row in
                                GridRow {
                                    Text(row.name)
                                    Text(Fmt.int(row.count)).tabular()
                                    Text(Fmt.date(row.eos)).tabular()
                                    status(row.eos, now: now, yearAhead: yearAhead)
                                }
                            }
                        }
                        .font(.callout)
                    }
                    VStack(spacing: 16) {
                        Card("ESXi versions") {
                            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
                                GridRow { Text("Version"); Text("Hosts"); Text("General support ends"); Text("Status") }.font(.caption).foregroundStyle(.secondary)
                                ForEach(esxRows, id: \.version) { row in
                                    GridRow {
                                        Text(row.version.isEmpty ? "Unknown" : row.version)
                                        Text("\(row.hosts)").tabular()
                                        Text(Fmt.date(row.eos)).tabular()
                                        if let e = row.eos { status(e, now: now, yearAhead: yearAhead) } else { Text("—") }
                                    }
                                }
                            }
                            .font(.callout)
                        }
                        Card(inv.vcenters.allSatisfy { $0.kind == .vCenter } ? "vCenter" : "vCenter (inferred)") {
                            if !model.vcenterMerges.isEmpty {
                                Button("Undo merged vCenters") { model.resetVCenterMerges() }
                                    .buttonStyle(.link)
                                    .font(.caption)
                            }
                            ForEach(inv.vcenters) { vc in
                                let v = Lifecycle.parseVMwareVersion(vc.version.isEmpty ? vc.fullName : vc.version).version
                                HStack {
                                    VStack(alignment: .leading, spacing: 1) {
                                        Text(vc.server).font(.callout.weight(.medium))
                                        switch vc.kind {
                                        case .vCenter:
                                            Text(vc.fullName.isEmpty ? "Version unknown (no vSource tab)" : vc.fullName).font(.caption).foregroundStyle(.secondary)
                                        case .inferred:
                                            Text("Inferred from the certificates of \(vc.sourceHosts.count) ESXi host(s) exported directly. Version unknown").font(.caption).foregroundStyle(.secondary)
                                        case .esxiHost:
                                            Text("ESXi host exported directly, with no sign of a vCenter · \(vc.fullName)").font(.caption).foregroundStyle(.secondary)
                                        }
                                    }
                                    Spacer()
                                    if vc.kind == .vCenter, let e = Lifecycle.vsphereEndOfSupport(v) { status(e, now: now, yearAhead: yearAhead) }
                                    let others = inv.vcenters.filter { $0.id != vc.id && $0.kind != .esxiHost }
                                    if vc.kind != .vCenter, !others.isEmpty, model.trend == nil {
                                        Menu("Merge into") {
                                            ForEach(others) { other in
                                                Button(other.server) { model.mergeVCenter(vc.server, into: other.server) }
                                            }
                                        }
                                        .menuStyle(.borderlessButton)
                                        .fixedSize()
                                    }
                                }
                            }
                        }
                    }
                }
                HStack(alignment: .top, spacing: 16) {
                    Card("Virtual hardware versions", subtitle: "Oldest ESXi release that supports each version") {
                        BarListChart(items: report.dist.hwVersion.map { CountItem(label: Lifecycle.hardwareLabel(Parse.firstInt($0.label) ?? 0), count: $0.count) })
                    }
                    Card("VMware Tools on running VMs") { BarListChart(items: report.dist.toolsStatus) }
                }
                HStack(alignment: .top, spacing: 16) {
                    Card("VMs created per year", subtitle: "From vInfo creation date") { ColumnChart(items: report.dist.creationYear) }
                    Card("Host uptime", subtitle: "Days since boot at export time — long uptime usually means missed patches") {
                        BarListChart(items: inv.hosts.compactMap { h in h.uptimeDays.map { CountItem(label: h.name.split(separator: ".").first.map(String.init) ?? h.name, count: Int($0)) } }
                            .sorted { $0.count > $1.count }.prefix(12).map { $0 }, label: { "\($0.count) days" })
                    }
                }
                if !inv.licenses.isEmpty {
                    Card("Licenses", subtitle: "From vLicense") {
                        Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
                            GridRow { Text("Status"); Text("Product"); Text("Key"); Text("Used / total"); Text("Expires") }.font(.caption).foregroundStyle(.secondary)
                            ForEach(inv.licenses) { l in
                                GridRow {
                                    LicenseStatus(license: l, now: License.renewalReference(exportDate: exported), window: report.thresholds.licenseExpiryDays)
                                    Text(l.name)
                                    Text(l.keyMasked).tabular().foregroundStyle(.secondary)
                                    HStack(spacing: 4) {
                                        Text("\(Fmt.num(l.used, 0)) / \(Fmt.num(l.total, 0)) \(l.costUnit)").tabular()
                                        if l.total > 0 && l.used > l.total { Image(systemName: Severity.warning.symbol).foregroundStyle(Palette.warning).help("Over-allocated") }
                                    }
                                    Text(l.expiration.map { Fmt.date($0) } ?? l.expirationRaw)
                                }
                            }
                        }
                        .font(.callout)
                    }
                }
            }
            .padding(20)
        }
    }

    @ViewBuilder
    private func status(_ eos: Date, now: Date, yearAhead: Date) -> some View {
        if eos <= now {
            Label("Ended", systemImage: Severity.critical.symbol).foregroundStyle(Palette.critical)
        } else if eos <= yearAhead {
            Label("< 12 months", systemImage: Severity.warning.symbol).foregroundStyle(Palette.warning)
        } else {
            Label("Supported", systemImage: "checkmark.circle.fill").foregroundStyle(Palette.good)
        }
    }
}
