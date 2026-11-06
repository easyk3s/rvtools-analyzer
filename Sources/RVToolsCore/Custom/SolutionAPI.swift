import Foundation

/// The data contract between the app and custom solutions: what a script receives as `inventory`.
///
/// Version 1. Fields may be added within a version; renaming or removing one requires a new `apiVersion`, so
/// published solutions keep working. Capacities are MiB, memory sizes in the VM/host objects are MiB, CPU is MHz,
/// dates are ISO 8601 strings, and unknown values are `null`. See docs/SOLUTIONS.md for the field reference.
public enum SolutionAPI {
    public static let version = 1

    private static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    static func date(_ d: Date?) -> Any { d.map { iso.string(from: $0) } ?? NSNull() }
    static func num(_ v: Double) -> Any { v.isFinite ? v : NSNull() }
    static func num(_ v: Double?) -> Any { v.map { num($0) } ?? NSNull() }
    static func int(_ v: Int?) -> Any { v.map { $0 as Any } ?? NSNull() }
    static func bool(_ v: Bool?) -> Any { v.map { $0 as Any } ?? NSNull() }
    /// RVTools uses -1 for "unlimited".
    static func limit(_ v: Double) -> Any { v < 0 ? NSNull() : num(v) }

    public static func familyKey(_ f: OSFamily) -> String { String(describing: f) }

    /// Object kinds as scripts name them (the `kind` of affected objects).
    static func kind(_ k: ObjectKind) -> String {
        switch k {
        case .vm: return "vm"
        case .host: return "host"
        case .cluster: return "cluster"
        case .datastore: return "datastore"
        case .network: return "network"
        case .vcenter: return "vcenter"
        case .other: return "other"
        }
    }

    static func status(_ s: CheckStatus) -> String { ["blocker", "warning", "info", "ready"][s.rawValue] }

    /// `context.findings`: the app's findings grouped by rule, worst first, then by how many objects each affects.
    static func findings(_ groups: [FindingGroup]) -> [[String: Any]] {
        groups.sorted { ($0.severity, -$0.count, $0.title) < ($1.severity, -$1.count, $1.title) }.map { g in
            [
                "rule": g.rule,
                "title": g.title,
                "severity": ["critical", "warning", "info"][g.severity.rawValue],
                "status": ["blocker", "warning", "info"][g.severity.rawValue],
                "category": g.category.rawValue,
                "recommendation": g.recommendation,
                "count": g.count,
                "kinds": Array(Set(g.findings.map { kind($0.kind) })).sorted(),
                "objects": g.findings.map { f in
                    ["kind": kind(f.kind), "id": f.objectID, "name": f.objectName, "location": f.location, "detail": f.detail] as [String: Any]
                },
            ] as [String: Any]
        }
    }

    /// Another solution's result for `context.solutions`, with sections in the same shape a script returns them.
    static func result(_ r: SolutionResult, id: String) -> [String: Any] {
        func ref(_ a: AffectedObject?) -> Any {
            a.map { ["kind": kind($0.kind), "id": $0.id, "name": $0.name, "detail": $0.detail] as [String: Any] } ?? NSNull()
        }
        let sections: [[String: Any]] = r.sections.map { section in
            switch section {
            case .metrics(let title, let items):
                return ["type": "metrics", "title": title, "items": items.map { m in
                    ["label": m.label, "value": m.value, "detail": m.detail, "symbol": m.symbol ?? NSNull(), "status": m.status.map(status) ?? NSNull()] as [String: Any]
                }]
            case .checks(let title, let checks, let subtitle):
                return ["type": "checks", "title": title, "subtitle": subtitle, "checks": checks.map { c in
                    ["id": c.id, "area": c.area, "title": c.title, "status": status(c.status), "summary": c.summary, "remediation": c.remediation,
                     "affected": c.affected.map { ref($0) }] as [String: Any]
                }]
            case .table(let t):
                var table: [String: Any] = ["type": "table", "id": t.id, "title": t.title, "subtitle": t.subtitle, "columns": t.columns,
                                            "numeric": t.numericColumns.sorted(), "rows": t.rows, "emphasized": t.emphasized.sorted()]
                if !t.rowRefs.isEmpty { table["rowRefs"] = t.rowRefs.map(ref) }
                return table
            case .bars(let title, let subtitle, let items, let format):
                var bars: [String: Any] = ["type": "bars", "title": title, "subtitle": subtitle,
                                           "items": items.map { ["label": $0.label, "value": num($0.value), "count": $0.count] as [String: Any] }]
                switch format {
                case .count: bars["format"] = "count"
                case .capacityMiB: bars["format"] = "capacityMiB"
                case .currency: bars["format"] = "currency"
                case .number(let unit): bars["format"] = "number"; bars["unit"] = unit
                }
                return bars
            case .notes(let title, let lines):
                return ["type": "notes", "title": title, "lines": lines]
            }
        }
        return [
            "id": id,
            "title": SolutionCatalog.solution(id: id)?.title ?? id,
            "headline": r.headline,
            "sections": sections,
            "assumptions": r.assumptions.map { ["label": $0.0, "value": $0.1] },
            "vmCount": r.vmCount,
            "failed": r.failed,
        ]
    }

    /// The whole inventory as JSON text (parsed once inside the script runtime).
    public static func inventoryJSON(_ inv: Inventory) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: inventory(inv), options: [])
        return String(decoding: data, as: UTF8.self)
    }

    static func inventory(_ inv: Inventory) -> [String: Any] {
        let clusterNames = Dictionary(inv.clusters.map { ($0.id, $0.name) }, uniquingKeysWith: { a, _ in a })
        return [
            "apiVersion": version,
            "reportDate": date(inv.reportDate),
            "vcenters": inv.vcenters.map { ["id": $0.id, "server": $0.server, "kind": $0.kind.rawValue, "fullName": $0.fullName, "version": $0.version, "build": $0.build] as [String: Any] },
            "clusters": inv.clusters.map(cluster),
            "hosts": inv.hosts.map(host),
            "vms": inv.vms.map { vm($0, clusterName: clusterNames[$0.clusterKey]) },
            "datastores": inv.datastores.map(datastore),
            "portGroups": inv.portGroups.map(portGroup),
            "pnics": inv.pnics.map { ["hostId": $0.hostKey, "host": $0.host, "device": $0.device, "driver": $0.driver, "speedMbps": $0.speedMbps, "switch": $0.switchName] as [String: Any] },
            "vmkernels": inv.vmkernels.map { ["hostId": $0.hostKey, "host": $0.host, "device": $0.device, "portGroup": $0.portGroup, "ip": $0.ip, "subnet": $0.subnet, "mtu": $0.mtu] as [String: Any] },
            "licenses": inv.licenses.map { ["vcenter": $0.vcenter, "name": $0.name, "total": num($0.total), "used": num($0.used), "costUnit": $0.costUnit, "expiration": date($0.expiration)] as [String: Any] },
        ]
    }

    static func vm(_ v: VM, clusterName: String?) -> [String: Any] {
        [
            "id": v.id,
            "name": v.name,
            "vcenter": v.vcenter,
            "datacenter": v.datacenter,
            "cluster": v.cluster,
            "clusterId": v.clusterKey,
            "clusterName": clusterName ?? (v.cluster.isEmpty ? "(no cluster)" : v.cluster),
            "host": v.host,
            "hostId": v.hostKey,
            "folder": v.folder,
            "resourcePool": v.resourcePool,
            "vApp": v.vApp,
            "powerState": v.powerState == .on ? "on" : (v.powerState == .suspended ? "suspended" : "off"),
            "isRunning": v.isRunning,
            "isTemplate": v.isTemplate,
            "isSRMPlaceholder": v.isSRMPlaceholder,
            "notInVInfo": v.notInVInfo,
            "isClusterAgent": v.isClusterAgent,
            "consolidationNeeded": v.consolidationNeeded,
            "os": [
                "name": v.os.name,
                "family": familyKey(v.os.family),
                "familyLabel": v.os.family.rawValue,
                "configured": v.osConfig,
                "reportedByTools": v.osTools,
                "endOfSupport": date(v.os.endOfSupport),
            ] as [String: Any],
            "cpus": v.cpus,
            "sockets": v.sockets,
            "coresPerSocket": v.coresPerSocket,
            "memoryMiB": num(v.memoryMiB),
            "provisionedMiB": num(v.provisionedMiB),
            "inUseMiB": num(v.inUseMiB),
            "unsharedMiB": num(v.unsharedMiB),
            "swapMiB": num(v.swapMiB),
            "inUseExcludingSwapMiB": num(v.inUseExcludingSwapMiB),
            "diskCapacityMiB": num(v.diskCapacityMiB),
            "guestCapacityMiB": num(v.guestCapacityMiB),
            "guestConsumedMiB": num(v.guestConsumedMiB),
            "hwVersion": v.hwVersion,
            "firmware": v.firmware,
            "secureBoot": v.secureBoot,
            "cbt": bool(v.cbt),
            "ftState": v.ftState,
            "haRestartPriority": v.haRestartPriority,
            "latencySensitivity": v.latencySensitivity,
            "created": date(v.creationDate),
            "poweredOnAt": date(v.powerOnDate),
            "primaryIP": v.primaryIP,
            "ips": v.ips,
            "dnsName": v.dnsName,
            "annotation": v.annotation,
            "customFields": v.customFields.map { ["name": $0.name, "value": $0.value] },
            "uuid": v.uuid,
            "cpuUsageMHz": num(v.cpuUsageMHz),
            "cpuReadinessPct": num(v.cpuReadinessPct),
            "cpuReservationMHz": num(v.cpuReservationMHz),
            "cpuLimitMHz": limit(v.cpuLimitMHz),
            "cpuHotAdd": v.cpuHotAdd,
            "memHotAdd": v.memHotAdd,
            "memReservationMiB": num(v.memReservationMiB),
            "memLimitMiB": limit(v.memLimitMiB),
            "memConsumedMiB": num(v.memConsumedMiB),
            "memActiveMiB": num(v.memActiveMiB),
            "memBalloonedMiB": num(v.memBalloonedMiB),
            "memSwappedMiB": num(v.memSwappedMiB),
            "tools": ["status": v.toolsDisplay, "rawStatus": v.toolsStatus, "version": v.toolsVersion, "upgradeable": v.toolsUpgradeable] as [String: Any],
            "disks": v.disks.map { d in
                [
                    "label": d.label, "capacityMiB": num(d.capacityMiB), "provisioning": d.provisioning, "thin": bool(d.thin),
                    "mode": d.mode, "independent": d.isIndependent, "sharing": d.sharing, "sharedWriter": d.isSharedWriter,
                    "rdm": d.raw, "controller": d.controller, "datastore": d.datastore, "path": d.path,
                ] as [String: Any]
            },
            "partitions": v.partitions.map { ["disk": $0.disk, "capacityMiB": num($0.capacityMiB), "consumedMiB": num($0.consumedMiB), "freeMiB": num($0.freeMiB), "freePct": num($0.freePct)] as [String: Any] },
            "nics": v.nics.map { ["label": $0.label, "adapter": $0.adapter, "network": $0.network, "switch": $0.switchName, "connected": $0.connected, "mac": $0.mac, "ipv4": $0.ipv4] as [String: Any] },
            "snapshots": v.snapshots.map { ["name": $0.name, "created": date($0.date), "sizeMiB": num($0.sizeMiB), "quiesced": $0.quiesced, "ageDays": num($0.ageDays)] as [String: Any] },
            "snapshotSizeMiB": num(v.snapshotSizeMiB),
            "cdromsConnected": v.cdroms.filter(\.connected).count,
            "usbConnected": v.usbConnected,
            "datastores": v.datastores,
            "networks": v.networks,
            "issueCount": v.issueCount,
        ]
    }

    static func host(_ h: Host) -> [String: Any] {
        [
            "id": h.id, "name": h.name, "vcenter": h.vcenter, "datacenter": h.datacenter, "cluster": h.cluster, "clusterId": h.clusterKey,
            "maintenance": h.maintenance, "isVirtual": h.isVirtual, "cpuModel": h.cpuModel, "speedMHz": num(h.speedMHz),
            "sockets": h.sockets, "coresPerSocket": h.coresPerSocket, "cores": h.cores, "threads": h.threads, "htActive": h.htActive,
            "cpuCapacityMHz": num(h.cpuCapacityMHz), "cpuUsagePct": num(h.cpuUsagePct), "cpuUsedMHz": num(h.cpuUsedMHz),
            "memoryMiB": num(h.memoryMiB), "memUsagePct": num(h.memUsagePct), "memUsedMiB": num(h.memUsedMiB),
            "esxVersion": h.esxVersion, "esxBuild": h.esxBuild, "vendor": h.vendor, "model": h.model, "biosVersion": h.biosVersion,
            "evcCurrent": h.evcCurrent, "evcMax": h.evcMax, "bootTime": date(h.bootTime), "uptimeDays": num(h.uptimeDays),
            "vmCount": h.vmCount, "vmsOn": h.vmsOn, "vcpuOn": h.vcpuOn, "vcpuTotal": h.vcpuTotal, "vramOnMiB": num(h.vramOnMiB),
            "pnicCount": h.pnicCount, "hbaCount": h.hbaCount, "datastoreCount": h.datastoreCount, "certExpiry": date(h.certExpiry),
            "vsanFaultDomain": h.vsanFaultDomain,
        ]
    }

    static func cluster(_ c: Cluster) -> [String: Any] {
        [
            "id": c.id, "name": c.name, "vcenter": c.vcenter, "datacenter": c.datacenter, "isStandalone": c.isStandalone,
            "haEnabled": bool(c.haEnabled), "drsEnabled": bool(c.drsEnabled), "admissionControl": bool(c.admissionControl),
            "hostCount": c.hostCount, "hostsInMaintenance": c.hostsInMaintenance, "sockets": c.sockets, "cores": c.cores, "threads": c.threads,
            "memoryMiB": num(c.memoryMiB), "memUsedMiB": num(c.memUsedMiB), "cpuMHz": num(c.cpuMHz), "cpuUsedMHz": num(c.cpuUsedMHz),
            "largestHostMemMiB": num(c.largestHostMemMiB), "largestHostCpuMHz": num(c.largestHostCpuMHz),
            "vmCount": c.vmCount, "vmsOn": c.vmsOn, "templates": c.templates, "vcpuOn": c.vcpuOn, "vcpuTotal": c.vcpuTotal,
            "vramOnMiB": num(c.vramOnMiB), "vramTotalMiB": num(c.vramTotalMiB), "provisionedMiB": num(c.provisionedMiB), "inUseMiB": num(c.inUseMiB),
            "datastoreCount": c.datastoreCount, "esxVersions": c.esxVersions, "cpuModels": c.cpuModels,
        ]
    }

    static func datastore(_ d: Datastore) -> [String: Any] {
        [
            "id": d.id, "name": d.name, "vcenter": d.vcenter, "type": d.type, "capacityMiB": num(d.capacityMiB),
            "provisionedMiB": num(d.provisionedMiB), "inUseMiB": num(d.inUseMiB), "freeMiB": num(d.freeMiB), "freePct": num(d.freePct),
            "accessible": d.accessible, "isLocal": d.isLocal, "datastoreCluster": d.datastoreCluster, "majorVersion": d.majorVersion,
            "hostIds": d.hostKeys, "vmIds": d.vmIDs, "clusterIds": d.clusterKeys, "clusters": d.clusters, "vmDiskMiB": num(d.vmDiskMiB),
        ]
    }

    static func portGroup(_ p: PortGroup) -> [String: Any] {
        [
            "id": p.id, "name": p.name, "vcenter": p.vcenter, "kind": p.kind, "switch": p.switchName, "vlans": p.vlans,
            "hostIds": p.hostKeys, "vmIds": p.vmIDs, "isVMkernel": p.isVMkernel, "isUplink": p.isUplink,
        ]
    }
}
