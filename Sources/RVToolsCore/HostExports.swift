import Foundation

/// RVTools pointed at an ESXi host instead of a vCenter writes the host's address as "VI SDK Server", so several such
/// exports read as that many vCenters with no clusters, and a shared datastore appears once per host. This regroups
/// them before merging: under the vCenter named by each host's certificate, into clusters by the storage they share.
/// All of that is inferred, and marked as such. Each row keeps its original server in `sourceColumn`.
struct HostExportPlan {
    static let sourceColumn = "Source host"

    private struct Member {
        let export: String
        let server: String
        let host: String
        var vcenter: String?
        let volumes: Set<String>
    }

    /// Where an export's rows go: only exports whose host was placed under a vCenter are listed.
    private var placement: [String: (server: String, vcenter: String, cluster: String)] = [:]
    /// What was inferred, for the export's notes.
    private(set) var notes: [String] = []

    /// `merges` moves everything inferred under one vCenter (or a host left on its own) to another, by name.
    init(exports: [(name: String, tables: [RawTable])], merges: [String: String] = [:]) {
        var members: [Member] = []
        for export in exports {
            func table(_ name: String) -> Table? {
                export.tables.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }.map(Table.init(raw:))
            }
            guard let source = table("vSource"), HostExportPlan.isHostExport(source), let first = source.rows.first else { continue }
            let hosts = table("vHost")
            let row = hosts?.rows.first { !$0.s(hosts?.col("Host")).isEmpty }
            let volumes = table("vDatastore").map { t in
                Set(t.rows.compactMap { r -> String? in
                    let id = r.s(t.col("URL")).isEmpty ? r.s(t.col("Address")) : r.s(t.col("URL"))
                    return id.isEmpty ? nil : id.lowercased()
                })
            } ?? []
            let server = first.s(source.col("VI SDK Server"))
            guard !server.isEmpty else { continue }
            members.append(Member(export: export.name, server: server, host: row?.s(hosts?.col("Host")) ?? server,
                                  vcenter: HostExportPlan.vCenterName(issuer: row?.s(hosts?.col("Certificate Issuer")) ?? ""), volumes: volumes))
        }
        guard !members.isEmpty else { return }

        var seenOn: [String: Int] = [:]
        for m in members { for v in m.volumes { seenOn[v, default: 0] += 1 } }
        func shared(_ m: Member) -> Set<String> { m.volumes.filter { seenOn[$0, default: 0] > 1 } }

        // A host whose certificate names no vCenter joins the one it shares the most storage with.
        var linked = 0
        let named = members
        for i in members.indices where members[i].vcenter == nil {
            let own = shared(members[i])
            var overlap: [String: Int] = [:]
            for other in named {
                guard let vc = other.vcenter, !own.isEmpty, HostExportPlan.overlaps(own, shared(other)) else { continue }
                overlap[vc, default: 0] += own.intersection(other.volumes).count
            }
            if let best = overlap.sorted(by: { ($0.value, $1.key) > ($1.value, $0.key) }).first {
                members[i].vcenter = best.key
                linked += 1
            }
        }

        // One name per vCenter whatever its case, then any merges chosen by hand.
        var display: [String: String] = [:]
        for m in members { if let v = m.vcenter, display[v.lowercased()] == nil { display[v.lowercased()] = v } }
        let lowered = Dictionary(merges.map { ($0.key.lowercased(), $0.value) }, uniquingKeysWith: { a, _ in a })
        func merged(_ name: String) -> String? {
            var current = name, hops = 0
            while let next = lowered[current.lowercased()], next.caseInsensitiveCompare(current) != .orderedSame, hops < 8 { current = next; hops += 1 }
            return hops == 0 ? nil : current
        }
        for i in members.indices {
            let m = members[i]
            let own = m.vcenter.map { display[$0.lowercased()] ?? $0 }
            members[i].vcenter = merged(own ?? m.server) ?? own
        }

        for (vcenter, group) in Dictionary(grouping: members.filter { $0.vcenter != nil }, by: { $0.vcenter!.lowercased() }).sorted(by: { $0.key < $1.key }) {
            let clusters = HostExportPlan.clusters(group.map { (id: $0.host, volumes: shared($0)) })
            let short = String(vcenter.split(separator: ".").first ?? "")
            for m in group {
                let at = clusters.firstIndex { $0.contains(m.host) }
                let cluster = at.map { "\(short) cluster\(clusters.count > 1 ? " \($0 + 1)" : "") (inferred)" } ?? ""
                placement[m.export] = (m.server, m.vcenter!, cluster)
            }
        }

        let vcenters = Set(members.compactMap { $0.vcenter?.lowercased() }).count
        let alone = members.filter { $0.vcenter == nil }.count
        var note = "\(Fmt.int(members.count)) export(s) came from ESXi hosts directly, not from a vCenter."
        if vcenters > 0 {
            note += " Their hosts were grouped under \(Fmt.int(vcenters)) inferred vCenter(s), named by the hosts' certificates, and into clusters by the storage they share."
            note += " A certificate shows what issued it, which may not be what manages the host today, so check this with the customer."
        }
        if linked > 0 { note += " \(Fmt.int(linked)) host(s) with no vCenter on their certificate were placed by shared storage." }
        if alone > 0 { note += " \(Fmt.int(alone)) host(s) with no evidence of a vCenter stay on their own." }
        notes.append(note)
    }

    /// Hosts sharing a good part of their storage belong together: enough that one library LUN mounted across clusters
    /// doesn't join them, but a host missing a LUN or two still counts. A host sharing nothing stays out of any cluster.
    private static func overlaps(_ a: Set<String>, _ b: Set<String>) -> Bool {
        let smaller = min(a.count, b.count)
        return smaller > 0 && a.intersection(b).count * 2 >= smaller
    }

    private static func clusters(_ hosts: [(id: String, volumes: Set<String>)]) -> [Set<String>] {
        var groups: [Set<String>] = []
        for host in hosts.sorted(by: { $0.id.lowercased() < $1.id.lowercased() }) {
            let joined = hosts.filter { $0.id != host.id && overlaps($0.volumes, host.volumes) }.map(\.id)
            guard !joined.isEmpty else { continue }
            let touching = groups.indices.filter { !groups[$0].isDisjoint(with: joined + [host.id]) }
            var merged = Set(joined + [host.id])
            for i in touching { merged.formUnion(groups[i]) }
            for i in touching.reversed() { groups.remove(at: i) }
            groups.append(merged)
        }
        return groups.sorted { ($0.map { $0.lowercased() }.min() ?? "") < ($1.map { $0.lowercased() }.min() ?? "") }
    }

    static func isHostExport(_ source: Table) -> Bool {
        source.rows.contains { isHostRow($0, in: source) }
    }

    /// `API type` says so outright; older exports without it still name the product.
    static func isHostRow(_ row: [String], in source: Table) -> Bool {
        if let c = source.col("API type"), !row.s(c).isEmpty { return row.s(c).caseInsensitiveCompare("HostAgent") == .orderedSame }
        return (row.s(source.col("Name")) + " " + row.s(source.col("Fullname"))).lowercased().contains("esxi")
    }

    /// A certificate issued by a vCenter's own certificate authority carries the vCenter's name in `O=`. Self-signed
    /// and third-party certificates don't name one, and `O=VMware` is the default on older releases.
    static func vCenterName(issuer: String) -> String? {
        var organization = "", isVMCA = false
        for part in issuer.split(separator: ",") {
            let pair = part.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            guard pair.count == 2 else { continue }
            switch pair[0].uppercased() {
            case "O": organization = pair[1]
            case "OU": if pair[1].caseInsensitiveCompare("VMware Engineering") == .orderedSame { isVMCA = true }
            case "DC": if pair[1].caseInsensitiveCompare("vsphere") == .orderedSame { isVMCA = true }
            default: break
            }
        }
        guard isVMCA, !organization.isEmpty else { return nil }
        return organization.lowercased().hasPrefix("vmware") && !organization.contains(".") ? nil : organization
    }

    /// The tab with its rows moved to the inferred vCenter. VM IDs are only unique per host, so they gain the host's
    /// address; "VI SDK UUID" is the host's address here, not a vCenter's identity.
    func apply(_ raw: RawTable, export: String) -> RawTable {
        guard let place = placement[export] else { return raw }
        let names = raw.headers.map(Table.normalize)
        func column(_ name: String) -> Int? { names.firstIndex(of: Table.normalize(name)) }
        guard let cServer = column("VI SDK Server") else { return raw }
        let cUUID = column("VI SDK UUID"), cVMID = column("VM ID"), cCluster = column("Cluster")
        var rows = raw.rows
        for i in rows.indices {
            // RVTools' one-cell placeholder on tabs it didn't fill isn't data.
            guard rows[i].filter({ !$0.isEmpty }).count > 1 else { continue }
            if rows[i].count < raw.headers.count { rows[i] += Array(repeating: "", count: raw.headers.count - rows[i].count) }
            rows[i].append(rows[i][cServer].isEmpty ? place.server : rows[i][cServer])
            rows[i][cServer] = place.vcenter
            if let cUUID { rows[i][cUUID] = "" }
            if let cVMID, !rows[i][cVMID].isEmpty { rows[i][cVMID] = place.server + "/" + rows[i][cVMID] }
            if let cCluster, rows[i][cCluster].isEmpty { rows[i][cCluster] = place.cluster }
        }
        return RawTable(name: raw.name, headers: raw.headers + [HostExportPlan.sourceColumn], rows: rows)
    }
}
