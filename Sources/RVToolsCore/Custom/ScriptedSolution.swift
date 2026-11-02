import Foundation
import JavaScriptCore

/// A solution defined by a pack: parameters from its manifest, results from its JavaScript `run` function.
///
/// Scripts run in a fresh JavaScriptCore context per run. The context has no file, network or process access —
/// only the inventory, the parameter values, the `rva` helpers and read-only prices declared in the manifest.
public struct ScriptedSolution: Solution {
    public let manifest: SolutionManifest
    public let packURL: URL
    public let scriptURL: URL
    public let script: String
    /// Rates of the loaded trend, passed to the script as `context.trend` (nil outside trend mode).
    public var trend: TrendRates? = nil
    /// The app's findings for the inventory in scope (acknowledged ones left out), passed as `context.findings`.
    /// nil = worked out from the inventory with the default thresholds.
    public var findings: [FindingGroup]? = nil
    /// Results of the solutions listed under `solutions` in the manifest, for `context.solutions`. The app sets this so they use
    /// its selections and assumptions; nil = each runs on its default selection and assumptions.
    public var companionResults: (@Sendable (String) -> SolutionResult?)? = nil
    /// Set when this solution runs for another one's `context.solutions`; its own `context.solutions` is then empty, so
    /// solutions that read each other can't loop.
    public var isCompanion = false
    /// Ids of the other solutions the script reads.
    public var companions: [String] { (manifest.solutions ?? []).filter { $0 != id } }

    public var id: String { manifest.id }
    public var title: String { manifest.title }
    public var symbol: String { manifest.symbol ?? "puzzlepiece.extension" }
    public var summary: String { manifest.summary ?? "" }
    public var version: String { manifest.version ?? "" }
    public var author: String { manifest.author ?? "" }
    /// Price providers the script may read.
    public var providers: [String] { manifest.pricing?.providers ?? [] }
    public var allowsDownload: Bool { manifest.pricing?.allowDownload ?? true }
    var timeout: Double { manifest.timeoutSeconds ?? 20 }

    public var parameters: [SolutionParameter] { (manifest.parameters ?? []).map(Self.parameter) }

    static func parameter(_ p: SolutionManifest.Parameter) -> SolutionParameter {
        let group = p.group ?? "Assumptions", help = p.help ?? ""
        switch p.type {
        case "number":
            let lo = p.min ?? 0, hi = p.max ?? 1_000_000_000
            var spec = SolutionParameter.number(p.id, group, p.label, p.default?.number ?? lo, min: lo, max: hi, step: p.step ?? 1, unit: p.unit ?? "", help: help)
            spec.observed = p.observed
            return spec
        case "choice":
            let options = p.options ?? []
            return .choice(p.id, group, p.label, options, selected: index(p.default, options) ?? 0, help: help)
        case "toggle":
            return .toggle(p.id, group, p.label, p.default?.bool ?? false, help: help)
        case "multi":
            let options = p.options ?? []
            return .multi(p.id, group, p.label, options, selected: (p.default?.array ?? []).compactMap { index($0, options) }, help: help)
        default:
            let regions = PriceLibrary.shared.knownRegions(p.provider ?? "")
            let chosen = (p.default?.array ?? []).compactMap { v -> Int? in
                if let code = v.string { return regions.firstIndex { $0.code == code } }
                return v.number.map(Int.init).flatMap { regions.indices.contains($0) ? $0 : nil }
            }
            return .multi(p.id, group, p.label, regions.map { "\($0.name) · \($0.code)" }, selected: chosen, help: help)
        }
    }

    static func index(_ v: JSONValue?, _ options: [String]) -> Int? {
        if let n = v?.number, options.indices.contains(Int(n)) { return Int(n) }
        if let s = v?.string { return options.firstIndex(of: s) }
        return nil
    }

    /// Selected region codes of each `regions` parameter.
    public func regionSelections(_ params: Params) -> [(provider: String, parameter: String, regions: [String])] {
        (manifest.parameters ?? []).filter { $0.type == "regions" }.map { p in
            let known = PriceLibrary.shared.knownRegions(p.provider ?? "")
            return (p.provider ?? "", p.id, params.multi(p.id).compactMap { known.indices.contains($0) ? known[$0].code : nil })
        }
    }

    public var selections: [SolutionSelection] {
        guard let list = manifest.selections, !list.isEmpty else { return [.primary] }
        return list.enumerated().map { i, s in SolutionSelection(id: s.id, label: s.label, help: s.help ?? "", isPrimary: i == 0) }
    }

    public func defaultSelection(_ inv: Inventory) -> Set<String> {
        defaultSelection(inv, for: selections[0])
    }

    public func defaultSelection(_ inv: Inventory, for selection: SolutionSelection) -> Set<String> {
        let spec = manifest.selections?.first { $0.id == selection.id }
        switch spec?.default ?? (selection.isPrimary ? manifest.defaultSelection : nil) ?? (selection.isPrimary ? "vms" : "none") {
        case "poweredOn": return Set(inv.workloadVMs.filter(\.isRunning).map(\.id))
        case "all": return Set(inv.vms.map(\.id))
        case "none": return []
        default: return Set(inv.workloadVMs.map(\.id))
        }
    }

    public func run(vms: [VM], inventory: Inventory, params: Params) -> SolutionResult {
        run(vms: vms, selections: [:], inventory: inventory, params: params)
    }

    public func run(vms: [VM], selections: [String: [VM]], inventory: Inventory, params: Params) -> SolutionResult {
        ScriptRuntime(solution: self, inventory: inventory).run(selected: vms, selections: selections, params: params)
    }
}

// MARK: - Runtime

final class ScriptRuntime {
    let solution: ScriptedSolution
    let inventory: Inventory
    private var logs: [String] = []
    private var warnings = 0
    private var priceRefs: [PriceRef] = []
    private var sheets: [String: PriceSheet] = [:]
    private var sheetErrors: [String: String] = [:]
    private var offerCache: [String: [InstanceOffer]] = [:]
    private lazy var vmsByID = Dictionary(inventory.vms.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
    private lazy var hostSpeed = Dictionary(inventory.hosts.map { ($0.id, $0.speedMHz) }, uniquingKeysWith: { a, _ in a })

    init(solution: ScriptedSolution, inventory: Inventory) {
        self.solution = solution
        self.inventory = inventory
    }

    func run(selected: [VM], selections: [String: [VM]], params: Params) -> SolutionResult {
        guard let ctx = JSContext() else { return failure("JavaScript is unavailable", "Couldn't create a JavaScript context.") }
        ctx.name = solution.title
        let limited = JSWatchdog.limit(ctx, seconds: solution.timeout)
        install(ctx)

        ctx.evaluateScript("var __rvaUnits = { storage: \"\(Units.storage.rawValue)\", rate: \"\(Units.rate.rawValue)\" };")
        ctx.evaluateScript(ScriptPrelude.source, withSourceURL: URL(string: "rva:///prelude.js"))
        if let e = takeException(ctx) { return failure("The solution runtime failed to start", e) }
        ctx.evaluateScript(solution.script, withSourceURL: solution.scriptURL)
        if let e = takeException(ctx) { return failure("\(solution.scriptURL.lastPathComponent) couldn't be loaded", e) }

        let started = Date()
        let output: JSValue?
        do {
            let (values, labels) = paramsJSON(params)
            let context: [String: Any] = [
                "apiVersion": SolutionAPI.version,
                "solution": ["id": solution.id, "title": solution.title, "version": solution.version],
                "selectedCount": selected.count,
                "reportDate": SolutionAPI.date(inventory.reportDate),
                "supportDate": SolutionAPI.date(Lifecycle.supportReference(exportDate: inventory.reportDate)),
                "now": SolutionAPI.date(Date()),
                "trend": solution.trend.map { t -> Any in
                    let rate = { (v: Double?) -> Any in v ?? NSNull() }
                    return ["snapshots": t.snapshots, "from": SolutionAPI.date(t.from), "to": SolutionAPI.date(t.to), "spanDays": t.spanDays,
                            "annualGrowthPct": rate(t.annualGrowthPct), "organicGrowthPct": rate(t.organicGrowthPct),
                            "netDailyGrowthPct": rate(t.netDailyGrowthPct)] as [String: Any]
                } ?? NSNull(),
                "findings": SolutionAPI.findings(solution.findings ?? Analyzer.run(inventory).groups),
                "solutions": companionsJSON(),
            ]
            // Every declared selection, by id (the primary one is also `vms`).
            var selectionIDs: [String: [String]] = [:]
            for sel in solution.selections {
                selectionIDs[sel.id] = (selections[sel.id] ?? (sel.isPrimary ? selected : [])).map(\.id)
            }
            output = ctx.objectForKeyedSubscript("__main").call(withArguments: [
                try json(selected.map(\.id)), try SolutionAPI.inventoryJSON(inventory), try json(values), try json(labels), try json(context),
                try json(selectionIDs),
            ])
        } catch {
            return failure("The inventory couldn't be prepared for the script", error.localizedDescription)
        }
        if let e = takeException(ctx) {
            if limited && Date().timeIntervalSince(started) >= solution.timeout - 0.1 {
                return failure("run() was stopped after \(SFmt.num(solution.timeout)) seconds",
                               "The script took too long (possibly an endless loop). Raise timeoutSeconds in manifest.json if it genuinely needs longer.")
            }
            return failure("run() failed", e)
        }
        guard let text = output, text.isString, let resultJSON = text.toString() else {
            return failure("run() didn't return a result", "Return an object like { headline, sections: [...] }.")
        }
        do {
            var result = try ResultMapper.map(try JSONValue.parse(Data(resultJSON.utf8)), solution: solution)
            if (solution.manifest.debug ?? false || warnings > 0) && !logs.isEmpty {
                result.sections.append(.notes("Script console", Array(logs.suffix(200))))
            }
            result.log = logs
            result.priceRefs = priceRefs
            return result
        } catch {
            return failure("run() returned a result the app can't show", error.localizedDescription)
        }
    }

    /// `context.solutions`: each declared solution's result, or null when it's unknown or this run is itself a companion.
    private func companionsJSON() -> [String: Any] {
        var out: [String: Any] = [:]
        for id in solution.companions {
            guard !solution.isCompanion else { out[id] = NSNull(); continue }
            let result = solution.companionResults?(id) ?? SolutionCatalog.runCompanion(id: id, inventory: inventory)
            if result == nil && logs.count < 2000 {
                logs.append("warn: context.solutions: no solution with id “\(id)” is installed")
                warnings += 1
            }
            out[id] = result.map { SolutionAPI.result($0, id: id) } ?? NSNull()
        }
        return out
    }

    private func json(_ object: Any) throws -> String {
        String(decoding: try JSONSerialization.data(withJSONObject: object, options: [.fragmentsAllowed]), as: UTF8.self)
    }

    private func encode<T: Encodable>(_ value: T) -> String {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        return (try? e.encode(value)).map { String(decoding: $0, as: UTF8.self) } ?? "null"
    }

    /// Parameter values keyed by id (choices as indices, regions as codes) and their display labels.
    private func paramsJSON(_ params: Params) -> ([String: Any], [String: Any]) {
        var values: [String: Any] = [:], labels: [String: Any] = [:]
        let specs = Dictionary(solution.parameters.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        for p in solution.manifest.parameters ?? [] {
            let options: [String] = { if case .multi(let o)? = specs[p.id]?.kind { return o }; if case .choice(let o)? = specs[p.id]?.kind { return o }; return [] }()
            switch p.type {
            case "number":
                values[p.id] = SolutionAPI.num(params.num(p.id))
            case "choice":
                let i = params.choice(p.id)
                values[p.id] = i
                labels[p.id] = options.indices.contains(i) ? options[i] : NSNull()
            case "toggle":
                values[p.id] = params.flag(p.id)
            case "multi":
                let chosen = params.multi(p.id).filter(options.indices.contains)
                values[p.id] = chosen
                labels[p.id] = chosen.map { options[$0] }
            default:
                let known = PriceLibrary.shared.knownRegions(p.provider ?? "")
                let chosen = params.multi(p.id).filter(known.indices.contains)
                values[p.id] = chosen.map { known[$0].code }
                labels[p.id] = chosen.map { known[$0].name }
            }
        }
        return (values, labels)
    }

    private func takeException(_ ctx: JSContext) -> String? {
        guard let e = ctx.exception, !e.isUndefined, !e.isNull else { return nil }
        ctx.exception = nil
        var message = e.toString() ?? "Unknown error"
        if let line = e.objectForKeyedSubscript("line"), line.isNumber {
            let url = e.objectForKeyedSubscript("sourceURL")
            let file = (url?.isString ?? false) ? (url!.toString()! as NSString).lastPathComponent : ""
            message += " (\(file.isEmpty ? "" : file + ", ")line \(line.toInt32()))"
        }
        if let stack = e.objectForKeyedSubscript("stack"), stack.isString, let s = stack.toString(), !s.isEmpty {
            // Errors raised inside the helpers: point at the caller in the solution's own script.
            let script = solution.scriptURL.lastPathComponent
            if !message.contains(script), let frame = s.split(separator: "\n").first(where: { $0.contains(solution.scriptURL.absoluteString) }),
               let m = regexMatch(String(frame), #":(\d+):\d+$"#) {
                message += " — called from \(script), line \(m[1])"
            }
            logs.append("error: " + message)
            logs += s.split(separator: "\n").prefix(12).map { "    at " + $0 }
        }
        return message
    }

    private func failure(_ title: String, _ message: String) -> SolutionResult {
        var b = CheckBuilder()
        b.add("script", "Script", title, .blocker, message,
              remediation: "Fix the solution in \(solution.packURL.path), then use Reload. `rvtools-cli --validate-solution <pack> <export>` shows the full console output.")
        var sections: [SolutionSection] = [.checks("Custom solution error", b.checks)]
        if !logs.isEmpty { sections.append(.notes("Script console", Array(logs.suffix(200)))) }
        var r = SolutionResult(headline: "\(solution.title) couldn't run", sections: sections)
        r.log = logs
        r.failed = true
        return r
    }

    // MARK: Native bridge

    private func setBlock(_ ctx: JSContext, _ name: String, _ block: Any) {
        ctx.setObject(block as AnyObject, forKeyedSubscript: name as NSString)
    }

    /// Throws `message` as a JavaScript Error from inside a native function.
    private func jsThrow(_ message: String) -> String {
        if let c = JSContext.current() { c.exception = JSValue(newErrorFromMessage: message, in: c) }
        return "null"
    }

    private func sheet(_ provider: String, _ region: String) throws -> PriceSheet {
        let key = provider + "|" + region
        if let s = sheets[key] { return s }
        if let e = sheetErrors[key] { throw ExtensionError(e) }
        do {
            let s = try PriceLibrary.shared.sheet(provider, region)
            sheets[key] = s
            priceRefs.append(PriceRef(provider: provider, region: region))
            return s
        } catch {
            sheetErrors[key] = error.localizedDescription
            throw error
        }
    }

    private func declared(_ provider: String) -> String? {
        solution.providers.contains(provider) ? nil : "Add “\(provider)” to pricing.providers in manifest.json to read its prices."
    }

    private func install(_ ctx: JSContext) {
        let log: @convention(block) (String, String) -> Void = { [unowned self] level, text in
            if level != "log" { warnings += 1 }
            if logs.count < 2000 { logs.append(level == "log" ? text : "\(level): \(text)") }
        }
        setBlock(ctx, "__log", log)

        let providers: @convention(block) () -> String = { [unowned self] in
            encode(solution.providers.map { PriceLibrary.shared.info($0) })
        }
        setBlock(ctx, "__pricing_providers", providers)

        let regions: @convention(block) (String) -> String = { [unowned self] provider in
            if let problem = declared(provider) { return jsThrow(problem) }
            return encode(PriceLibrary.shared.regions(provider))
        }
        setBlock(ctx, "__pricing_regions", regions)

        let get: @convention(block) (String, String) -> String = { [unowned self] provider, region in
            if let problem = declared(provider) { return jsThrow(problem) }
            do { return "{\"sheet\":" + encode(try sheet(provider, region)) + "}" } catch {
                return encode(["error": error.localizedDescription])
            }
        }
        setBlock(ctx, "__pricing_get", get)

        let demand: @convention(block) (String, String) -> String = { [unowned self] vmID, optionsJSON in
            guard let vm = vmsByID[vmID] else { return jsThrow("rva.cloud.demand: no VM with id “\(vmID)”") }
            let o = (try? JSONValue.parse(Data(optionsJSON.utf8))) ?? .object([:])
            var d = CloudSizing.DemandOptions()
            d.rightsizeCPU = o["rightsizeCPU"]?.bool ?? false
            d.rightsizeMemory = o["rightsizeMemory"]?.bool ?? false
            d.bufferPct = o["bufferPct"]?.number ?? 25
            d.minVCPU = Int(o["minVCPU"]?.number ?? 1)
            d.minMemoryGiB = o["minMemoryGiB"]?.number ?? 1
            d.diskFromGuestUsage = o["diskBasis"]?.string == "guest"
            d.diskHeadroomPct = o["diskHeadroomPct"]?.number ?? 20
            let r = CloudSizing.demand(vm, d, hostSpeedMHz: hostSpeed[vm.hostKey])
            return (try? json(["vcpu": r.vcpu, "memoryGiB": r.memoryGiB, "windows": r.windows, "diskGiB": r.diskGiB, "rightsized": r.rightsized])) ?? "null"
        }
        setBlock(ctx, "__cloud_demand", demand)

        let bestFit: @convention(block) (String, String, String) -> String = { [unowned self] provider, region, optionsJSON in
            if let problem = declared(provider) { return jsThrow(problem) }
            let s: PriceSheet
            do { s = try sheet(provider, region) } catch { return jsThrow(error.localizedDescription) }
            let o = (try? JSONValue.parse(Data(optionsJSON.utf8))) ?? .object([:])
            let families = (o["families"]?.array ?? []).compactMap(\.string)
            let cacheKey = provider + "|" + region + "|" + families.joined(separator: ",")
            let offers = offerCache[cacheKey] ?? {
                let list = families.isEmpty ? s.instances : s.instances.filter { families.contains($0.family) }
                offerCache[cacheKey] = list
                return list
            }()
            guard let fit = CloudSizing.bestFit(vcpu: Int((o["vcpu"]?.number ?? 1).rounded(.up)), memoryGiB: o["memoryGiB"]?.number ?? 0,
                                                windows: o["windows"]?.bool ?? false, offers: offers,
                                                licenseIncluded: o["licenseIncluded"]?.bool ?? true,
                                                model: CloudSizing.PriceModel(o["model"]?.string ?? "payg"),
                                                discountPct: o["discountPct"]?.number ?? 0) else { return "null" }
            return "{\"hourly\":\(fit.hourly),\"instance\":" + encode(fit.offer) + "}"
        }
        setBlock(ctx, "__cloud_bestFit", bestFit)

        let disk: @convention(block) (String, String, String) -> String = { [unowned self] provider, region, optionsJSON in
            if let problem = declared(provider) { return jsThrow(problem) }
            let s: PriceSheet
            do { s = try sheet(provider, region) } catch { return jsThrow(error.localizedDescription) }
            let o = (try? JSONValue.parse(Data(optionsJSON.utf8))) ?? .object([:])
            let gib = o["gib"]?.number ?? 0
            let type = (o["type"]?.string ?? "").lowercased()
            let kind = CloudProvider(rawValue: provider) ?? PriceLibrary.shared.entry(provider)?.list.baseProvider
            let d: CloudSizing.Disk
            switch kind {
            case .azure:
                let prefix = ["p": "P", "premium": "P", "premium-ssd": "P", "e": "E", "standard-ssd": "E", "s": "S", "standard-hdd": "S", "hdd": "S"][type.isEmpty ? "p" : type]
                guard let prefix else { return jsThrow("rva.cloud.disk: Azure disk type must be premium-ssd, standard-ssd or standard-hdd") }
                d = CloudSizing.azureManagedDisk(gib: gib, prefix: prefix, storage: s.storage)
            case .aws:
                let t = type.isEmpty ? "gp3" : type
                guard ["gp3", "gp2", "st1"].contains(t) else { return jsThrow("rva.cloud.disk: AWS volume type must be gp3, gp2 or st1") }
                d = CloudSizing.awsVolume(gib: gib, type: t, storage: s.storage)
            case nil:
                return jsThrow("rva.cloud.disk works with Azure or AWS prices (or lists based on them); read sheet.storage directly for “\(provider)”")
            }
            return (try? json(["label": d.label, "gib": d.gib, "monthly": d.monthly, "oversize": d.oversize])) ?? "null"
        }
        setBlock(ctx, "__cloud_disk", disk)
    }
}

/// Stops runaway scripts. JavaScriptCore's execution time limit is not public API, so it's looked up at run
/// time; without it scripts simply run to completion.
enum JSWatchdog {
    private typealias SetLimit = @convention(c) (OpaquePointer?, Double, OpaquePointer?, UnsafeMutableRawPointer?) -> Void

    private static let setLimit: SetLimit? = {
        guard let handle = dlopen(nil, RTLD_NOW), let symbol = dlsym(handle, "JSContextGroupSetExecutionTimeLimit") else { return nil }
        return unsafeBitCast(symbol, to: SetLimit.self)
    }()

    static func limit(_ ctx: JSContext, seconds: Double) -> Bool {
        guard let f = setLimit, let group = JSContextGetGroup(ctx.jsGlobalContextRef) else { return false }
        f(group, seconds, nil, nil)
        return true
    }
}

// MARK: - Result mapping

enum ResultMapper {
    static func map(_ v: JSONValue, solution: ScriptedSolution) throws -> SolutionResult {
        guard case .object = v else { throw ExtensionError("run() must return an object like { headline, sections: [...] }") }
        let sections: [JSONValue]
        switch v["sections"] {
        case nil, .null?: sections = []
        case .array(let a)?: sections = a
        default: throw ExtensionError("sections must be a list")
        }
        var out: [SolutionSection] = []
        for (i, s) in sections.enumerated() {
            let type = s["type"]?.string ?? ""
            let at = "sections[\(i)]" + (type.isEmpty ? "" : " (\(type))")
            let title = s["title"]?.text ?? ""
            switch type {
            case "metrics":
                let items = try list(s["items"], "\(at).items")
                out.append(.metrics(title, try items.enumerated().map { j, m in
                    var metricStatus: CheckStatus?
                    if let text = m["status"]?.string, !text.isEmpty {
                        guard let st = status(text.lowercased()) else {
                            throw ExtensionError("\(at).items[\(j)]: status must be blocker, warning, info or ready (got “\(text)”)")
                        }
                        metricStatus = st
                    }
                    return SolutionMetric(m["label"]?.text ?? "", m["value"]?.text ?? "", m["detail"]?.text ?? "", symbol: m["symbol"]?.string, status: metricStatus)
                }))
            case "checks":
                let checks = try list(s["checks"], "\(at).checks").enumerated().map { j, c -> SolutionCheck in
                    let statusText = (c["status"]?.string ?? "info").lowercased()
                    guard let status = status(statusText) else {
                        throw ExtensionError("\(at).checks[\(j)]: status must be blocker, warning, info or ready (got “\(statusText)”)")
                    }
                    return SolutionCheck(id: c["id"]?.text ?? "check-\(j)", area: c["area"]?.text ?? "", title: c["title"]?.text ?? "",
                                         status: status, summary: c["summary"]?.text ?? "", remediation: c["remediation"]?.text ?? "",
                                         affected: (c["affected"]?.array ?? []).compactMap(ref))
                }
                out.append(.checks(title, checks, subtitle: s["subtitle"]?.text ?? ""))
            case "table":
                let columns = try list(s["columns"], "\(at).columns").map(\.text)
                let rows = try list(s["rows"], "\(at).rows").enumerated().map { j, r -> [String] in
                    guard let cells = r.array else { throw ExtensionError("\(at).rows[\(j)] must be a list of cells") }
                    return cells.map(\.text)
                }
                let numeric: Set<Int> = Set((s["numeric"]?.array ?? []).compactMap { n in n.number.map(Int.init) ?? n.string.flatMap { columns.firstIndex(of: $0) } })
                let refs = (s["rowRefs"]?.array ?? []).map(ref)
                let id = (s["id"]?.string ?? title).lowercased().replacingOccurrences(of: #"[^a-z0-9]+"#, with: "-", options: .regularExpression)
                out.append(.table(SolutionTable(id: id.isEmpty ? "table-\(i)" : id, title: title, subtitle: s["subtitle"]?.text ?? "", columns: columns,
                                                numeric: numeric, rows: rows, rowRefs: refs.count == rows.count ? refs : [],
                                                emphasized: Set((s["emphasized"]?.array ?? []).compactMap { $0.number.map(Int.init) }))))
            case "bars":
                let items = try list(s["items"], "\(at).items").map { b in
                    CountItem(label: b["label"]?.text ?? "", count: Int(b["count"]?.number ?? 0), value: b["value"]?.number ?? 0)
                }
                let format: ValueFormat
                switch s["format"]?.string ?? "number" {
                case "count": format = .count
                case "capacityMiB": format = .capacityMiB
                case "currency":
                    let code = (s["currency"]?.string ?? "USD").uppercased()
                    format = code == "USD" ? .currency : .number(code)
                default: format = .number(s["unit"]?.text ?? "")
                }
                out.append(.bars(title, s["subtitle"]?.text ?? "", items, format))
            case "notes":
                out.append(.notes(title, try list(s["lines"], "\(at).lines").map(\.text)))
            default:
                throw ExtensionError("\(at): type must be metrics, checks, table, bars or notes")
            }
        }
                var result = SolutionResult(headline: v["headline"]?.text ?? solution.title, sections: out)
        result.exports = try list(v["exports"], "exports").enumerated().map { j, e -> SolutionExport in
            guard let raw = e["fileName"]?.string, !raw.isEmpty else {
                throw ExtensionError("exports[\(j)]: fileName is required")
            }
            let name = raw.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
            return SolutionExport(title: e["title"]?.text ?? name, fileName: name, content: e["content"]?.string ?? "")
        }
        return result
    }

    private static func list(_ v: JSONValue?, _ path: String) throws -> [JSONValue] {
        switch v {
        case nil, .null?: return []
        case .array(let a)?: return a
        default: throw ExtensionError("\(path) must be a list")
        }
    }

    static func status(_ s: String) -> CheckStatus? {
        ["blocker": .blocker, "critical": .blocker, "warning": .warning, "info": .info, "ready": .ready, "ok": .ready][s]
    }

    static func ref(_ v: JSONValue) -> AffectedObject? {
        guard case .object = v else { return nil }
        let kinds: [String: ObjectKind] = ["vm": .vm, "host": .host, "cluster": .cluster, "datastore": .datastore, "network": .network, "portgroup": .network, "vcenter": .vcenter]
        return AffectedObject(kind: kinds[(v["kind"]?.string ?? "").lowercased()] ?? .other, id: v["id"]?.text ?? "",
                              name: v["name"]?.text ?? v["id"]?.text ?? "", detail: v["detail"]?.text ?? "")
    }
}
