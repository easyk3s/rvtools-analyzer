import RVToolsCore
import SwiftUI

/// Shows how the tabs were joined, what each relationship reveals, and whether RVTools' own
/// counts agree with the counts derived from the other tabs.
struct CorrelationsView: View {
    @Environment(AppModel.self) private var model
    let report: Report

    private struct Relationship: Identifiable {
        var id: String { name }
        let name: String
        let links: String
        let insight: String
        let source: String
    }

    var body: some View {
        let inv = report.inventory
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if !inv.sourceTools.isEmpty { SourceToolCaution(tools: inv.sourceTools) }
                DataConfidenceCard(quality: report.dataQuality)
                ForEach(inv.sourceTools, id: \.name) { SourceToolGapsCard(tool: $0) }

                Card("Entity graph", subtitle: "Every tab is joined into this object model (counts for the current scope)") {
                    VStack(alignment: .leading, spacing: 14) {
                        chain([("vCenters", report.totals.vcenters), ("Datacenters", inv.datacenterCount), ("Clusters", report.totals.clusters),
                               ("Hosts", inv.hosts.count), ("VMs", inv.vms.count)])
                        HStack(alignment: .top, spacing: 24) {
                            satellites("Each VM joins", [("vCPU / vMemory / vTools", inv.vms.count), ("Disks", report.totals.disks),
                                                         ("Guest partitions", inv.vms.reduce(0) { $0 + $1.partitions.count }), ("NICs", report.totals.nics),
                                                         ("Snapshots", report.totals.snapshots), ("vHealth messages", inv.vms.reduce(0) { $0 + $1.health.count })])
                            satellites("Each host joins", [("Physical NICs", inv.pnics.count), ("HBAs", inv.hbas.count), ("VMkernel adapters", inv.vmkernels.count),
                                                           ("Standard vSwitches", inv.vSwitches.count), ("LUN path sets", inv.luns.count)])
                            satellites("Shared objects", [("Datastores", inv.datastores.count), ("Port groups", inv.portGroups.count),
                                                          ("Distributed switches", inv.dvSwitches.count), ("Resource pools", inv.resourcePools.count),
                                                          ("Licenses", inv.licenses.count)])
                        }
                    }
                }

                Card("Cross-tab relationships", subtitle: "What each correlation reveals") {
                    Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 18, verticalSpacing: 9) {
                        GridRow { Text("Relationship"); Text("Links"); Text("Insight"); Text("Joined from") }.font(.caption).foregroundStyle(.secondary)
                        Divider().gridCellUnsizedAxes(.horizontal)
                        ForEach(relationships(inv)) { r in
                            GridRow {
                                Text(r.name).font(.callout.weight(.medium))
                                Text(r.links).tabular()
                                Text(r.insight).font(.callout).fixedSize(horizontal: false, vertical: true)
                                Text(r.source).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }

                Card("Join coverage", subtitle: "Share of rows in each tab that matched their parent object (entire load, not scoped)") {
                    Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 16, verticalSpacing: 7) {
                        GridRow { Text("Tab"); Text("Joined to"); Text("Matched"); Text("Coverage"); Text("Key"); Text("Note") }.font(.caption).foregroundStyle(.secondary)
                        Divider().gridCellUnsizedAxes(.horizontal)
                        ForEach(inv.joins) { j in
                            GridRow {
                                Text(j.source).font(.callout.weight(.medium))
                                Text(j.target).font(.callout)
                                Text("\(Fmt.int(j.matched)) / \(Fmt.int(j.total))").tabular()
                                HStack(spacing: 6) {
                                    Meter(fraction: j.coverage, color: j.coverage >= 0.99 ? Palette.good : (j.coverage >= 0.8 ? Palette.warning : Palette.critical)).frame(width: 70)
                                    Text(Fmt.pct(j.coverage * 100)).tabular().font(.callout)
                                }
                                Text(j.keys).font(.caption).foregroundStyle(.secondary)
                                Text(j.note).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }

                Card("Consistency checks", subtitle: "Figures the export reports in one tab vs the same figure derived from other tabs") {
                    Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 16, verticalSpacing: 7) {
                        GridRow { Text(""); Text("Check"); Text("Reported"); Text("Derived"); Text("Note") }.font(.caption).foregroundStyle(.secondary)
                        Divider().gridCellUnsizedAxes(.horizontal)
                        ForEach(inv.checks) { c in
                            GridRow {
                                Image(systemName: c.ok ? "checkmark.circle.fill" : Severity.warning.symbol).foregroundStyle(c.ok ? Palette.good : Palette.warning)
                                Text(c.title).font(.callout)
                                Text(c.reported).tabular()
                                Text(c.derived).tabular()
                                Text(c.note).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                }
            }
            .padding(20)
        }
    }

    private func node(_ label: String, _ count: Int) -> some View {
        VStack(spacing: 2) {
            Text(Fmt.int(count)).font(.title2.weight(.semibold)).tabular()
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
        .frame(minWidth: 96)
        .padding(.vertical, 10).padding(.horizontal, 12)
        .background(RoundedRectangle(cornerRadius: 8).fill(Palette.track.opacity(0.7)))
    }

    private func chain(_ items: [(String, Int)]) -> some View {
        HStack(spacing: 8) {
            ForEach(Array(items.enumerated()), id: \.offset) { i, item in
                if i > 0 { Image(systemName: "arrow.right").foregroundStyle(.tertiary) }
                node(item.0, item.1)
            }
        }
    }

    private func satellites(_ title: String, _ items: [(String, Int)]) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.subheadline.weight(.semibold))
            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                HStack(spacing: 6) {
                    Image(systemName: "arrow.turn.down.right").font(.caption).foregroundStyle(.tertiary)
                    Text(item.0).font(.callout)
                    Spacer(minLength: 12)
                    Text(Fmt.int(item.1)).font(.callout.weight(.medium)).tabular()
                }
            }
        }
        .frame(maxWidth: 280)
    }

    private func relationships(_ inv: Inventory) -> [Relationship] {
        let hostNames = Dictionary(inv.hosts.map { ($0.id, $0.name) }, uniquingKeysWith: { a, _ in a })
        var perHost: [String: Int] = [:]
        for vm in inv.vms where vm.isVM { perHost[vm.hostKey, default: 0] += 1 }
        let busiest = perHost.max { $0.value < $1.value }
        let avgPerHost = inv.hosts.isEmpty ? 0 : Double(perHost.values.reduce(0, +)) / Double(inv.hosts.count)
        let multiDS = inv.vms.filter { $0.datastores.count > 1 }.count
        let multiNet = inv.vms.filter { $0.networks.count > 1 }.count
        let vlans = Set(inv.portGroups.flatMap(\.vlans)).count
        let hostMounts = inv.datastores.reduce(0) { $0 + $1.hostKeys.count }
        let sharedAcross = inv.datastores.filter { $0.clusterKeys.count > 1 }.count
        let local = inv.datastores.filter(\.isLocal).count
        let singleUplink = inv.hosts.filter { $0.pnicCount == 1 }.count
        let deadLUNs = inv.luns.filter { $0.deadPaths > 0 }.count
        let singlePath = inv.luns.filter { $0.paths == 1 }.count
        let disks = inv.vms.reduce(0) { $0 + $1.disks.count }
        let parts = inv.vms.reduce(0) { $0 + $1.partitions.count }
        let guestCap = inv.vms.reduce(0) { $0 + $1.guestCapacityMiB }
        let guestUsed = inv.vms.reduce(0) { $0 + $1.guestConsumedMiB }
        let provWithGuest = inv.vms.filter { !$0.partitions.isEmpty }.reduce(0) { $0 + $1.provisionedMiB }
        let snapVMs = inv.vms.filter { !$0.snapshots.isEmpty }
        let oldest = snapVMs.map(\.oldestSnapshotDays).max() ?? 0
        let healthMatched = inv.health.filter { !$0.objectID.isEmpty }.count
        let pgClusters = inv.portGroups.filter { pg in Set(pg.hostKeys.compactMap { model.lookup.hosts[$0]?.clusterKey }).count > 1 }.count
        let orphanPlacement = inv.vms.filter { model.lookup.hosts[$0.hostKey] == nil }.count
        return [
            Relationship(name: "VM → Host → Cluster", links: "\(Fmt.int(inv.vms.count)) placements",
                         insight: "Average \(Fmt.num(avgPerHost, 1)) VMs per host; busiest is \(busiest.flatMap { hostNames[$0.key] } ?? "—") with \(busiest?.value ?? 0)" + (orphanPlacement > 0 ? "; \(orphanPlacement) VMs on hosts missing from vHost" : ""),
                         source: "vInfo ⨝ vHost ⨝ vCluster"),
            Relationship(name: "VM → Datastore", links: "\(Fmt.int(inv.vms.reduce(0) { $0 + $1.datastores.count })) links",
                         insight: "\(Fmt.int(multiDS)) VMs span more than one datastore", source: "vDisk / vInfo paths ⨝ vDatastore"),
            Relationship(name: "VM → Port group → VLAN", links: "\(Fmt.int(inv.vms.reduce(0) { $0 + $1.networks.count })) links",
                         insight: "\(Fmt.int(multiNet)) VMs are multi-homed; \(vlans) VLAN IDs across \(inv.portGroups.count) port groups; \(pgClusters) port groups span clusters",
                         source: "vNetwork ⨝ vPort / dvPort"),
            Relationship(name: "Host → Datastore", links: "\(Fmt.int(hostMounts)) mounts",
                         insight: "\(sharedAcross) datastores are shared across clusters; \(local) are local to a single host", source: "vDatastore.Hosts ⨝ vHost"),
            Relationship(name: "Host → NIC / HBA / VMkernel", links: "\(inv.pnics.count) / \(inv.hbas.count) / \(inv.vmkernels.count)",
                         insight: "\(singleUplink) hosts have a single physical uplink", source: "vNIC, vHBA, vSC_VMK ⨝ vHost"),
            Relationship(name: "Host → LUN paths → Datastore", links: "\(inv.luns.count) LUN path sets",
                         insight: "\(deadLUNs) with dead paths, \(singlePath) with a single path", source: "vMultiPath ⨝ vHost, vDatastore"),
            Relationship(name: "VM → Disks → Guest partitions", links: "\(Fmt.int(disks)) disks · \(Fmt.int(parts)) partitions",
                         insight: "Guests use \(Fmt.capacity(mib: guestUsed)) of \(Fmt.capacity(mib: guestCap)) file-system capacity (\(Fmt.pct(provWithGuest > 0 ? guestUsed / provWithGuest * 100 : 0)) of provisioned)",
                         source: "vDisk, vPartition ⨝ vInfo"),
            Relationship(name: "VM → Snapshots", links: "\(inv.vms.reduce(0) { $0 + $1.snapshots.count }) snapshots",
                         insight: "\(snapVMs.count) VMs have snapshots; oldest is \(Fmt.num(oldest, 0)) days old at export time", source: "vSnapshot ⨝ vInfo"),
            Relationship(name: "Object → RVTools vHealth", links: "\(inv.health.count) messages",
                         insight: "\(healthMatched) matched to a VM, host or datastore", source: "vHealth.Name ⨝ vInfo / vHost / vDatastore"),
        ]
    }
}
