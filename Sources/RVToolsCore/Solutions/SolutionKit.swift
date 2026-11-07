import Foundation

// A "solution" turns a selection of VMs plus a set of assumptions into a report (sizing, readiness, ...).
// The app renders its parameters, VM selection and results generically, and exports them to Markdown + CSV.
//
// Built-in solutions are Swift types listed in `SolutionCatalog.builtIn` (locked at v1.0; their ids are reserved).
// Everyone else adds solutions without rebuilding the app: a pack folder with a manifest and a JavaScript file,
// loaded by `SolutionLibrary` and run by `ScriptedSolution`. See docs/SOLUTIONS.md.

public protocol Solution: Sendable {
    var id: String { get }
    var title: String { get }
    var symbol: String { get }
    var summary: String { get }
    var parameters: [SolutionParameter] { get }
    /// The VM selections offered on the Select VMs step. The first is the primary selection, passed to `run` as `vms`.
    var selections: [SolutionSelection] { get }
    /// VMs included in the primary selection when an export is first opened.
    func defaultSelection(_ inventory: Inventory) -> Set<String>
    /// VMs included in a selection when an export is first opened.
    func defaultSelection(_ inventory: Inventory, for selection: SolutionSelection) -> Set<String>
    func run(vms: [VM], inventory: Inventory, params: Params) -> SolutionResult
    /// Runs with every selection (keyed by selection id); solutions with one selection only need `run(vms:inventory:params:)`.
    func run(vms: [VM], selections: [String: [VM]], inventory: Inventory, params: Params) -> SolutionResult
}

/// One named set of VMs a solution works on (e.g. "DR scope" and "Pilot light").
public struct SolutionSelection: Identifiable, Hashable, Sendable {
    public let id: String
    public let label: String
    public let help: String
    public let isPrimary: Bool

    public init(id: String, label: String, help: String = "", isPrimary: Bool) {
        self.id = id; self.label = label; self.help = help; self.isPrimary = isPrimary
    }

    public static let primary = SolutionSelection(id: "vms", label: "Selected VMs", isPrimary: true)

    /// Where the selection is stored (app state, projects): the solution id for the primary selection, so single-selection
    /// solutions and existing projects are unchanged, and "<solution>#<selection>" for the others.
    public func key(_ solutionID: String) -> String { isPrimary ? solutionID : solutionID + "#" + id }
}

public extension Solution {
    var selections: [SolutionSelection] { [.primary] }

    func defaultSelection(_ inventory: Inventory, for selection: SolutionSelection) -> Set<String> {
        defaultSelection(inventory)
    }

    /// The default selection, without VMs rebuilt from other tabs: someone removed those from vInfo, so they're only
    /// included when chosen.
    func initialSelection(_ inventory: Inventory, for selection: SolutionSelection) -> Set<String> {
        defaultSelection(inventory, for: selection).subtracting(inventory.vms.filter(\.notInVInfo).map(\.id))
    }

    func run(vms: [VM], selections: [String: [VM]], inventory: Inventory, params: Params) -> SolutionResult {
        run(vms: vms, inventory: inventory, params: params)
    }

    /// Runs the solution on its primary selection and records the assumptions that were used.
    func run(vms: [VM], inventory: Inventory, values: ParamValues) -> SolutionResult {
        run(vms: vms, selections: [:], inventory: inventory, values: values)
    }

    /// Runs the solution on all its selections and records the assumptions that were used.
    func run(vms: [VM], selections: [String: [VM]], inventory: Inventory, values: ParamValues) -> SolutionResult {
        var result = run(vms: vms, selections: selections, inventory: inventory, params: Params(parameters, values))
        result.vmCount = Set(vms.map(\.id) + selections.values.flatMap { $0.map(\.id) }).count
        result.assumptions = parameters.map { ($0.group + " · " + $0.label, $0.display(values.values[$0.id] ?? $0.defaultValue, inventory: inventory)) }
        // Every result and deck says so when the exports behind it didn't read cleanly, custom solutions included.
        if !inventory.sourceIssues.isEmpty {
            var b = CheckBuilder()
            for (i, issue) in inventory.sourceIssues.enumerated() {
                b.add("source-issue-\(i)", "Source data", issue.text, issue.level == .noVMsRead ? .blocker : .warning, issue.impact,
                      remediation: "Check the export, then open it again.")
            }
            result.sections.insert(.checks("Source data problems", b.checks), at: 0)
        }
        return result
    }
}

public enum SolutionCatalog {
    /// The solutions that ship with the app.
    public static let builtIn: [any Solution] = [BackupSizing(), DisasterRecoverySizing(), VCF9Readiness(), VCF9Sizing(), CloudMigration(.azure), CloudMigration(.aws), AzureVMwareSizing(), AlternateHypervisors()]
    /// Enabled custom solutions, in title order.
    public static var custom: [ScriptedSolution] { SolutionLibrary.shared.enabled }
    /// Built-in solutions followed by enabled custom solutions.
    public static var all: [any Solution] { builtIn + custom.map { $0 as any Solution } }
    public static func solution(id: String) -> (any Solution)? { builtIn.first { $0.id == id } ?? custom.first { $0.id == id } }
    public static func isBuiltIn(_ id: String) -> Bool { builtIn.contains { $0.id == id } }

    /// Runs a solution for another solution's `context.solutions`: on the given selections (VM ids by selection id, the
    /// defaults when nil) and assumptions. A custom solution run this way gets no `context.solutions` of its own.
    public static func runCompanion(id: String, inventory: Inventory, selections: [String: Set<String>]? = nil,
                                    values: ParamValues = ParamValues()) -> SolutionResult? {
        guard var s = solution(id: id) else { return nil }
        if var scripted = s as? ScriptedSolution { scripted.isCompanion = true; s = scripted }
        var selected: [String: [VM]] = [:]
        for sel in s.selections {
            let ids = selections?[sel.id] ?? s.initialSelection(inventory, for: sel)
            selected[sel.id] = inventory.vms.filter { ids.contains($0.id) }
        }
        return s.run(vms: selected[s.selections[0].id] ?? [], selections: selected, inventory: inventory, values: values)
    }
    /// The solution a stored selection key belongs to (see `SolutionSelection.key`).
    public static func solutionID(fromSelectionKey key: String) -> String { String(key.prefix { $0 != "#" }) }
}

// MARK: - Parameters

public enum ParamValue: Codable, Hashable, Sendable {
    case number(Double)
    case choice(Int)
    case flag(Bool)
    case selection([Int])
    /// Inventory objects by id (e.g. cluster ids), so a choice survives across exports and projects.
    case names([String])
}

public struct SolutionParameter: Identifiable, Sendable {
    public enum Kind: Sendable {
        case number(min: Double, max: Double, step: Double, unit: String)
        case choice([String])
        case toggle
        case multi([String])
        /// Clusters from the open export, stored by cluster id. `none` labels the empty choice (e.g. "Best fit (automatic)").
        case clusters(multi: Bool, none: String)
        /// Pairs of clusters from the open export, stored as a flat list of cluster ids: A, B, A, B. A blank is a side not chosen yet.
        case clusterPairs
        /// One host from the open export, stored by host id; hosts with the same CPU and memory are offered once.
        /// `none` labels the empty choice (e.g. "Typical host").
        case host(none: String)
    }

    public let id: String
    public let group: String
    public let label: String
    public let help: String
    public let kind: Kind
    public let defaultValue: ParamValue
    /// A trend rate offered for this assumption (custom solutions: the manifest's `observed`).
    public var observed: String? = nil

    public static func number(_ id: String, _ group: String, _ label: String, _ value: Double, min: Double, max: Double,
                              step: Double = 1, unit: String = "", help: String = "") -> SolutionParameter {
        SolutionParameter(id: id, group: group, label: label, help: help, kind: .number(min: min, max: max, step: step, unit: unit), defaultValue: .number(value))
    }

    public static func choice(_ id: String, _ group: String, _ label: String, _ options: [String], selected: Int = 0, help: String = "") -> SolutionParameter {
        SolutionParameter(id: id, group: group, label: label, help: help, kind: .choice(options), defaultValue: .choice(selected))
    }

    public static func toggle(_ id: String, _ group: String, _ label: String, _ on: Bool, help: String = "") -> SolutionParameter {
        SolutionParameter(id: id, group: group, label: label, help: help, kind: .toggle, defaultValue: .flag(on))
    }

    public static func multi(_ id: String, _ group: String, _ label: String, _ options: [String], selected: [Int], help: String = "") -> SolutionParameter {
        SolutionParameter(id: id, group: group, label: label, help: help, kind: .multi(options), defaultValue: .selection(selected))
    }

    public static func clusters(_ id: String, _ group: String, _ label: String, multi: Bool, none: String, help: String = "") -> SolutionParameter {
        SolutionParameter(id: id, group: group, label: label, help: help, kind: .clusters(multi: multi, none: none), defaultValue: .names([]))
    }

    public static func clusterPairs(_ id: String, _ group: String, _ label: String, help: String = "") -> SolutionParameter {
        SolutionParameter(id: id, group: group, label: label, help: help, kind: .clusterPairs, defaultValue: .names([]))
    }

    public static func host(_ id: String, _ group: String, _ label: String, none: String, help: String = "") -> SolutionParameter {
        SolutionParameter(id: id, group: group, label: label, help: help, kind: .host(none: none), defaultValue: .names([]))
    }

    public func display(_ value: ParamValue, inventory: Inventory? = nil) -> String {
        switch (kind, value) {
        case (.host(let none), .names(let ids)):
            guard let id = ids.first else { return none }
            if let h = inventory.flatMap({ HostSpecs.resolve(id, in: $0) }) { return HostSpecs.label(h) }
            return String(id.split(separator: "|").last ?? Substring(id))
        case (.clusters(_, let none), .names(let ids)):
            let names = ids.map { id in
                inventory?.clusters.first { $0.id == id }.map { "\($0.name) (\($0.vcenter))" } ?? String(id.split(separator: "|").last ?? Substring(id))
            }
            return names.isEmpty ? none : names.joined(separator: "; ")
        case (.clusterPairs, .names(let ids)):
            func name(_ id: String) -> String {
                inventory?.clusters.first { $0.id == id }?.name ?? String(id.split(separator: "|").last ?? Substring(id))
            }
            let pairs = stride(from: 0, to: ids.count - 1, by: 2).filter { !ids[$0].isEmpty && !ids[$0 + 1].isEmpty }.map { "\(name(ids[$0])) ↔ \(name(ids[$0 + 1]))" }
            return pairs.isEmpty ? "None" : pairs.joined(separator: "; ")
        case (.multi(let options), .selection(let chosen)):
            let names = chosen.filter { options.indices.contains($0) }.map { options[$0] }
            return names.isEmpty ? "None" : names.joined(separator: "; ")
        case (.number(_, _, _, let unit), .number(let x)): return SFmt.num(x) + (unit.isEmpty ? "" : " " + unit)
        case (.choice(let options), .choice(let i)): return options.indices.contains(i) ? options[i] : "—"
        case (.toggle, .flag(let on)): return on ? "Yes" : "No"
        default: return "—"
        }
    }
}

/// User-edited values; anything missing falls back to the parameter's default.
public struct ParamValues: Codable, Hashable, Sendable {
    public var values: [String: ParamValue]
    public init(values: [String: ParamValue] = [:]) { self.values = values }
}

/// Typed access to parameter values with defaults filled in.
public struct Params {
    private let specs: [String: SolutionParameter]
    private let values: ParamValues

    public init(_ specs: [SolutionParameter], _ values: ParamValues) {
        self.specs = Dictionary(specs.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        self.values = values
    }

    private func value(_ id: String) -> ParamValue? { values.values[id] ?? specs[id]?.defaultValue }
    public func num(_ id: String) -> Double { if case .number(let x)? = value(id) { return x }; return 0 }
    public func choice(_ id: String) -> Int { if case .choice(let i)? = value(id) { return i }; return 0 }
    public func flag(_ id: String) -> Bool { if case .flag(let b)? = value(id) { return b }; return false }
    public func multi(_ id: String) -> [Int] { if case .selection(let s)? = value(id) { return s }; return [] }
    public func names(_ id: String) -> [String] { if case .names(let n)? = value(id) { return n }; return [] }
}

/// Host configurations offered by `.host` parameters.
public enum HostSpecs {
    /// A stored host: its id, or a host name (from the CLI).
    public static func resolve(_ ref: String, in inv: Inventory) -> Host? {
        inv.hosts.first { $0.id == ref } ?? inv.hosts.first { $0.name.lowercased() == ref.lowercased() }
    }

    /// Physical hosts with known cores and memory, one per CPU and memory configuration (largest first), with the
    /// number of hosts that share it.
    public static func distinct(_ inv: Inventory) -> [(host: Host, count: Int)] {
        let real = inv.hosts.filter { !$0.inferred && !$0.isVirtual && $0.cores > 0 && $0.memoryMiB > 0 }
        let groups = Dictionary(grouping: real, by: key)
        return groups.values.map { g in (g.sorted { $0.name < $1.name }[0], g.count) }
            .sorted { ($1.host.memoryMiB, $1.host.cores, $0.host.name) < ($0.host.memoryMiB, $0.host.cores, $1.host.name) }
    }

    /// Hosts with the same key are the same configuration.
    public static func key(_ h: Host) -> String { "\(h.sockets)|\(h.cores)|\(Int(h.memoryMiB / 1024))|\(h.cpuModel)" }

    public static func label(_ h: Host) -> String {
        let cpu = h.cpuModel.isEmpty ? "" : " · \(h.cpuModel)"
        return "\(h.name) — \(h.sockets > 0 ? "\(h.sockets) × \(h.coresPerSocket)" : "\(h.cores)") cores, \(Fmt.memory(mib: h.memoryMiB))\(cpu)"
    }
}

// MARK: - Results

public enum CheckStatus: Int, CaseIterable, Comparable, Identifiable, Sendable {
    case blocker = 0, warning, info, ready
    public var id: Int { rawValue }
    public static func < (a: CheckStatus, b: CheckStatus) -> Bool { a.rawValue < b.rawValue }
    public var label: String { ["Blocker", "Warning", "Info", "Ready"][rawValue] }
    public var symbol: String { ["xmark.octagon.fill", "exclamationmark.triangle.fill", "info.circle.fill", "checkmark.circle.fill"][rawValue] }
}

public struct AffectedObject: Hashable, Sendable {
    public let kind: ObjectKind
    public let id: String
    public let name: String
    public let detail: String
    public init(kind: ObjectKind, id: String, name: String, detail: String = "") {
        self.kind = kind; self.id = id; self.name = name; self.detail = detail
    }
}

public struct SolutionCheck: Identifiable, Sendable {
    public let id: String
    public let area: String
    public let title: String
    public let status: CheckStatus
    public let summary: String
    public let remediation: String
    public let affected: [AffectedObject]
    /// One-click changes to the assumptions offered with this check (e.g. "Switch to consolidated").
    public var actions: [SolutionAction] = []
}

/// A change to a solution's assumptions offered next to a result, so the user can try it without going back to
/// Assumptions. The app applies `values` over the current assumptions and the result recalculates.
public struct SolutionAction: Hashable, Sendable {
    public let label: String
    public let symbol: String
    public let help: String
    public let values: [String: ParamValue]
    public init(_ label: String, symbol: String = "arrow.triangle.2.circlepath", help: String = "", set values: [String: ParamValue]) {
        self.label = label; self.symbol = symbol; self.help = help; self.values = values
    }
}

public struct SolutionMetric: Sendable {
    public let label: String
    public let value: String
    public let detail: String
    public let symbol: String?
    /// Optional state for the figure, e.g. `.blocker` for a total below a required minimum.
    public let status: CheckStatus?
    public init(_ label: String, _ value: String, _ detail: String = "", symbol: String? = nil, status: CheckStatus? = nil) {
        self.label = label; self.value = value; self.detail = detail; self.symbol = symbol; self.status = status
    }
}

public enum ValueFormat: Sendable {
    case count
    case capacityMiB
    case currency
    case number(String)
}

public struct SolutionTable: Sendable {
    public let id: String
    public let title: String
    public let subtitle: String
    public let columns: [String]
    public let numericColumns: Set<Int>
    public let rows: [[String]]
    /// Optional object per row (for navigation); empty or same length as `rows`.
    public let rowRefs: [AffectedObject?]
    /// Rows rendered in bold (totals).
    public let emphasized: Set<Int>
    /// Optional actions per row, shown as buttons after the last column; empty or same length as `rows`.
    public let rowActions: [[SolutionAction]]

    public init(id: String, title: String, subtitle: String = "", columns: [String], numeric: Set<Int> = [], rows: [[String]],
                rowRefs: [AffectedObject?] = [], emphasized: Set<Int> = [], rowActions: [[SolutionAction]] = []) {
        self.id = id; self.title = title; self.subtitle = subtitle; self.columns = columns; self.numericColumns = numeric
        self.rows = rows; self.rowRefs = rowRefs; self.emphasized = emphasized; self.rowActions = rowActions
    }
}

public enum SolutionSection: Sendable {
    case metrics(String, [SolutionMetric])
    /// Title, checks and an optional caption (shown under the title and in exports).
    case checks(String, [SolutionCheck], subtitle: String = "")
    case table(SolutionTable)
    case bars(String, String, [CountItem], ValueFormat)
    case notes(String, [String])
}

public struct SolutionExport: Identifiable, Sendable {
    public var id: String { fileName }
    public let title: String
    public let fileName: String
    public let content: String
    public init(title: String, fileName: String, content: String) {
        self.title = title; self.fileName = fileName; self.content = content
    }
}

public struct SolutionResult {
    public var headline: String
    public var sections: [SolutionSection]
    public var assumptions: [(String, String)] = []
    public var vmCount = 0
    /// Custom solutions: console output, the price sheets read, and whether the script failed.
    public var log: [String] = []
    public var priceRefs: [PriceRef] = []
    public var failed = false
    public var exports: [SolutionExport] = []

    public init(headline: String, sections: [SolutionSection]) {
        self.headline = headline
        self.sections = sections
    }
}

// MARK: - Builders & helpers (internal)

struct CheckBuilder {
    var checks: [SolutionCheck] = []

    mutating func add(_ id: String, _ area: String, _ title: String, _ status: CheckStatus, _ summary: String,
                      remediation: String = "", affected: [AffectedObject] = [], actions: [SolutionAction] = []) {
        checks.append(SolutionCheck(id: id, area: area, title: title, status: status, summary: summary, remediation: remediation, affected: affected, actions: actions))
    }

    /// One check over many objects: status is the most severe non-ready item; only non-ready items are listed.
    mutating func aggregate(_ id: String, _ area: String, _ title: String, noun: String, items: [(CheckStatus, AffectedObject)],
                            ready: String, remediation: String, empty: String? = nil) {
        guard !items.isEmpty else {
            if let empty { add(id, area, title, .info, empty, remediation: remediation) }
            return
        }
        let bad = items.filter { $0.0 != .ready }.sorted { $0.0 < $1.0 }
        guard let worst = bad.first?.0 else {
            add(id, area, title, .ready, ready)
            return
        }
        let blockers = bad.filter { $0.0 == .blocker }.count
        var summary = "\(bad.count) of \(items.count) \(noun)"
        if blockers > 0 && blockers < bad.count { summary += " (\(blockers) blocking)" }
        add(id, area, title, worst, summary, remediation: remediation, affected: bad.map(\.1))
    }

    /// Turns checks whose source tabs aren't in the export into unscored "not assessed" rows, so a partial export
    /// (e.g. vInfo only) doesn't read as ready. `requires` maps a check id to its tabs; "vPort|dvPort" means either.
    mutating func markUnassessed(_ requires: [String: [String]], present tabs: Set<String>) {
        guard !tabs.isEmpty else { return }
        checks = checks.map { c in
            let missing = (requires[c.id] ?? []).filter { alt in !alt.split(separator: "|").contains { tabs.contains($0.lowercased()) } }
            guard !missing.isEmpty else { return c }
            let names = missing.map { $0.replacingOccurrences(of: "|", with: " / ") }
            return SolutionCheck(id: c.id, area: c.area, title: c.title, status: .info,
                                 summary: "Not assessed: \(names.joined(separator: ", ")) not in export",
                                 remediation: "Ask for a full RVTools export (all tabs) to check this.", affected: [])
        }
    }

    /// A check that is "ready" when nothing is affected, otherwise `status`.
    mutating func list(_ id: String, _ area: String, _ title: String, _ status: CheckStatus, noun: String, affected: [AffectedObject],
                       ready: String, remediation: String, total: Int? = nil) {
        if affected.isEmpty {
            add(id, area, title, .ready, ready)
        } else {
            let of = total.map { " of \($0)" } ?? ""
            add(id, area, title, status, "\(affected.count)\(of) \(noun)", remediation: remediation, affected: affected)
        }
    }
}

enum SFmt {
    static func num(_ v: Double) -> String {
        guard v.isFinite else { return "—" }
        if v.rounded() == v && abs(v) < 1e12 { return Fmt.int(Int(v)) }
        return Fmt.num(v, abs(v) < 10 ? 2 : 1)
    }

    static func usd(_ v: Double) -> String {
        guard v.isFinite else { return "—" }
        if abs(v) >= 10_000_000 { return String(format: "$%.2fM", v / 1_000_000) }
        return (v < 0 ? "−$" : "$") + Fmt.int(Int(abs(v).rounded()))
    }

    static func duration(hours: Double) -> String {
        guard hours.isFinite else { return "—" }
        if hours < 1 { return String(format: "%.0f minutes", hours * 60) }
        if hours < 48 { return String(format: "%.1f hours", hours) }
        return String(format: "%.1f days", hours / 24)
    }
}

/// MiB → megabits
let mibToMegabits = 8.388608

func regexMatch(_ s: String, _ pattern: String) -> [String]? {
    guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
          let m = re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) else { return nil }
    return (0..<m.numberOfRanges).map { i in
        let r = m.range(at: i)
        guard r.location != NSNotFound, let rr = Range(r, in: s) else { return "" }
        return String(s[rr])
    }
}

extension VM {
    /// vInfo "In Use" includes the .vswp file of running VMs; it is not backed up or replicated.
    var swapMiB: Double { isRunning ? max(0, memoryMiB - memReservationMiB) : 0 }
    var inUseExcludingSwapMiB: Double { max(0, inUseMiB - swapMiB) }
    var vmRef: AffectedObject { AffectedObject(kind: .vm, id: id, name: name) }
    func ref(_ detail: String) -> AffectedObject { AffectedObject(kind: .vm, id: id, name: name, detail: detail) }
}

extension VDisk {
    var isSharedWriter: Bool {
        sharing.lowercased().contains("multi") || (!sharedBus.isEmpty && !["nosharing", "none"].contains(sharedBus.lowercased()))
    }
}

extension Host {
    func ref(_ detail: String) -> AffectedObject { AffectedObject(kind: .host, id: id, name: name, detail: detail) }
}

func clusterName(_ inv: Inventory, _ vm: VM) -> String {
    inv.clusters.first { $0.id == vm.clusterKey }?.name ?? (vm.cluster.isEmpty ? "(no cluster)" : vm.cluster)
}

// MARK: - Export

public extension SolutionResult {
    func markdown(title: String, subtitle: String) -> String {
        func esc(_ s: String) -> String { s.replacingOccurrences(of: "|", with: "\\|").replacingOccurrences(of: "\n", with: " ") }
        func table(_ header: [String], _ rows: [[String]]) -> String {
            var t = "| " + header.map(esc).joined(separator: " | ") + " |\n|" + String(repeating: "---|", count: header.count) + "\n"
            for r in rows { t += "| " + r.map(esc).joined(separator: " | ") + " |\n" }
            return t
        }
        var md = "# \(title)\n\n_\(subtitle)_\n\n**\(headline)**\n\n"
        for section in sections {
            switch section {
            case .metrics(let t, let metrics):
                md += "## \(t.isEmpty ? "Summary" : t)\n\n" + table(["Metric", "Value", "Detail"], metrics.map { m in
                    [m.label, m.value + (m.status == .blocker || m.status == .warning ? " (\(m.status!.label))" : ""), m.detail]
                })
            case .checks(let t, let checks, let subtitle):
                md += "## \(t)\n\n" + (subtitle.isEmpty ? "" : "_\(subtitle)_\n\n") + table(["Status", "Area", "Check", "Result"], checks.map { [$0.status.label, $0.area, $0.title, $0.summary] })
                for c in checks where c.status != .ready && (!c.affected.isEmpty || !c.remediation.isEmpty) {
                    md += "\n### \(c.status.label): \(c.title)\n\n"
                    if !c.remediation.isEmpty { md += "\(c.remediation)\n\n" }
                    for a in c.affected.prefix(100) { md += "- \(a.name)\(a.detail.isEmpty ? "" : " — \(a.detail)")\n" }
                    if c.affected.count > 100 { md += "- … and \(c.affected.count - 100) more (see checks CSV)\n" }
                }
            case .table(let t):
                md += "## \(t.title)\n\n"
                if !t.subtitle.isEmpty { md += "_\(t.subtitle)_\n\n" }
                md += t.rows.count > 60 ? "_\(t.rows.count) rows — see the \(t.id) CSV._\n" : table(t.columns, t.rows)
            case .bars(let t, _, let items, let format):
                let f: (Double) -> String = {
                    switch format {
                    case .count: return Fmt.int(Int($0.rounded()))
                    case .capacityMiB: return Fmt.capacity(mib: $0)
                    case .currency: return SFmt.usd($0)
                    case .number(let unit): return SFmt.num($0) + " " + unit
                    }
                }
                md += "## \(t)\n\n" + table(["Item", "Value", "Count"], items.map { [$0.label, f($0.value), Fmt.int($0.count)] })
            case .notes(let t, let lines):
                md += "## \(t)\n\n" + lines.map { "- \($0)" }.joined(separator: "\n") + "\n"
            }
            md += "\n"
        }
        md += "## Assumptions\n\n" + table(["Assumption", "Value"], assumptions.map { [$0.0, $0.1] })
        md += "\n_\(AppVersion.generatedLine())_\n"
        return md
    }

    /// One CSV per table plus summary, checks and assumptions.
    func csvFiles() -> [(name: String, content: String)] {
        var files: [(String, String)] = []
        var summary: [[String]] = []
        var checkRows: [[String]] = []
        for section in sections {
            switch section {
            case .metrics(_, let metrics): summary += metrics.map { [$0.label, $0.value, $0.detail] }
            case .checks(_, let checks, _):
                for c in checks {
                    if c.affected.isEmpty {
                        checkRows.append([c.status.label, c.area, c.title, c.summary, c.remediation, "", "", ""])
                    } else {
                        for a in c.affected { checkRows.append([c.status.label, c.area, c.title, c.summary, c.remediation, a.kind.rawValue, a.name, a.detail]) }
                    }
                }
            case .table(let t): files.append((t.id, CSVExport.build(t.columns, t.rows)))
            case .bars(let t, _, let items, _):
                let id = t.lowercased().replacingOccurrences(of: " ", with: "-")
                files.append((id, CSVExport.build(["Item", "Value", "Count"], items.map { [$0.label, String(format: "%.2f", $0.value), "\($0.count)"] })))
            case .notes: break
            }
        }
        if !summary.isEmpty { files.insert(("summary", CSVExport.build(["Metric", "Value", "Detail"], summary)), at: 0) }
        if !checkRows.isEmpty {
            files.append(("checks", CSVExport.build(["Status", "Area", "Check", "Result", "Remediation", "Object type", "Object", "Detail"], checkRows)))
        }
        files.append(("assumptions", CSVExport.build(["Assumption", "Value"], assumptions.map { [$0.0, $0.1] })))
        return files
    }
}
