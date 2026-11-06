import Foundation
import RVToolsCore

// Headless runner: rvtools-cli <export.xlsx | csv-folder> [more exports...] [--columns] [--export <dir>]
// Custom solutions: --list-solutions, --validate-solution <pack> [export], --solutions <dir>, --price-list <file>

var args = Array(CommandLine.arguments.dropFirst())
var exportDir: String?
if let i = args.firstIndex(of: "--export"), i + 1 < args.count {
    exportDir = args[i + 1]
    args.removeSubrange(i...(i + 1))
}
// --solution <id>: print that solution's report (Markdown) for its default VM selection.
var solutionID: String?
if let i = args.firstIndex(of: "--solution"), i + 1 < args.count {
    solutionID = args[i + 1]
    args.removeSubrange(i...(i + 1))
}
// --columns: for an export with non-standard column names, list how each column was matched.
let showColumns = args.contains("--columns")
args.removeAll { $0 == "--columns" }
// --pptx <file> [--template <file>]: with --solution, also write the results as a PowerPoint deck (optionally using a .pptx/.potx's theme and layouts).
var pptxPath: String?, templatePath: String?
for flag in ["--pptx", "--template"] {
    guard let i = args.firstIndex(of: flag), i + 1 < args.count else { continue }
    if flag == "--pptx" { pptxPath = args[i + 1] } else { templatePath = args[i + 1] }
    args.removeSubrange(i...(i + 1))
}
func writeDeck(_ result: SolutionResult, _ s: any Solution, subtitle: String, date: String) {
    guard let path = pptxPath else { return }
    let options = DeckOptions(title: s.title, subtitle: subtitle, date: date, template: templatePath.map { URL(fileURLWithPath: $0) })
    do {
        try result.pptx(options).write(to: URL(fileURLWithPath: path))
        FileHandle.standardError.write("Wrote \(path)\n".data(using: .utf8)!)
    } catch {
        FileHandle.standardError.write("Could not write \(path): \(error.localizedDescription)\n".data(using: .utf8)!)
        exit(1)
    }
}
// --decks <recipe.rvadecks> [--out <dir> | --zip <file>] [--customer <name>]: make every deck the recipe lists,
// with default selections and assumptions (see examples/decks.rvadecks). Default output: a "<export> Decks" folder beside the first export.
var decksRecipe: String?, decksOut: String?, decksZip: String?, decksCustomer: String?
for flag in ["--decks", "--out", "--zip", "--customer"] {
    guard let i = args.firstIndex(of: flag), i + 1 < args.count else { continue }
    switch flag { case "--decks": decksRecipe = args[i + 1]; case "--out": decksOut = args[i + 1]; case "--zip": decksZip = args[i + 1]; default: decksCustomer = args[i + 1] }
    args.removeSubrange(i...(i + 1))
}
// --map <kind>:<name>: print the relationship map of a vm, host, cluster, datastore or portgroup (with --export, also its CSV).
var mapSpec: String?
if let i = args.firstIndex(of: "--map"), i + 1 < args.count {
    mapSpec = args[i + 1]
    args.removeSubrange(i...(i + 1))
}
// --merge-vcenter <from>=<to>: regroup ESXi host exports inferred under one vCenter into another (repeatable).
var vcenterMerges: [String: String] = [:]
while let i = args.firstIndex(of: "--merge-vcenter"), i + 1 < args.count {
    let pair = args[i + 1].split(separator: "=", maxSplits: 1).map(String.init)
    if pair.count == 2 { vcenterMerges[pair[0]] = pair[1] }
    args.removeSubrange(i...(i + 1))
}
// --save-project <path>: save the loaded export (plus any --solution/--set assumptions) as a .rvaproj project.
var saveProjectPath: String?
if let i = args.firstIndex(of: "--save-project"), i + 1 < args.count {
    saveProjectPath = args[i + 1]
    args.removeSubrange(i...(i + 1))
}
/// Set when the input is a .rvaproj project: its thresholds, selections and assumptions are used.
var project: ProjectFile?

// --units binary|decimal, --rate bits|bytes: how storage capacities and network rates are shown (memory is always binary).
for (flag, apply) in [("--units", { (v: String) in StorageUnits(rawValue: v).map { Units.storage = $0 } != nil }),
                      ("--rate", { (v: String) in RateUnits(rawValue: v).map { Units.rate = $0 } != nil })] {
    guard let i = args.firstIndex(of: flag), i + 1 < args.count else { continue }
    if !apply(args[i + 1]) { FileHandle.standardError.write("\(flag): unknown value “\(args[i + 1])”\n".data(using: .utf8)!); exit(1) }
    args.removeSubrange(i...(i + 1))
}

// --trend: treat the inputs as snapshots of one environment over time and print the trend analysis.
var trendMode = false
if let i = args.firstIndex(of: "--trend") {
    trendMode = true
    args.remove(at: i)
}

func printTrend(_ t: TrendReport) {
    func cap(_ v: Double) -> String { Fmt.capacity(mib: v) }
    func fmt(_ v: Double, _ f: TrendFormat) -> String { f == .count ? Fmt.int(Int(v.rounded())) : (f == .percent ? Fmt.pct(v) : cap(v)) }
    func signed(_ v: Double, _ f: TrendFormat) -> String { (v >= 0 ? "+" : "−") + fmt(abs(v), f) }
    print("Snapshots (\(t.snapshots.count), \(Fmt.num(t.spanDays, 0)) days):")
    for s in t.snapshots {
        print("  \(s.id + 1). \(Fmt.dateTime(s.date))  VMs \(s.inventory.vms.filter(\.isVM).count) · hosts \(s.inventory.hosts.count) · \(s.vcenters.joined(separator: ", ")) · \(s.sources.map(\.lastPathComponent).first ?? "")\(s.sources.count > 1 ? " +\(s.sources.count - 1)" : "")")
    }
    print("\n== Metrics (first → last)")
    for s in t.series { print("  \(s.metric.rawValue.padding(toLength: 24, withPad: " ", startingAt: 0)) \(fmt(s.first, s.metric.format)) → \(fmt(s.last, s.metric.format))  (\(signed(s.last - s.first, s.metric.format)))") }
    print("\n== Observed growth")
    for g in t.growth {
        print("  \(g.label.padding(toLength: 40, withPad: " ", startingAt: 0)) \(signed(g.change, g.format)) · \(signed(g.perDay * 30.4, g.format))/month · \(g.annualPct.map { Fmt.num($0, 1) + "%/yr" } ?? "—")")
    }
    if let s = t.suggestedGrowthPct { print("  → suggested annual growth assumption: \(Fmt.num(s, 1))%") }
    if let d = t.netDailyGrowthPct { print("  → net daily growth \(Fmt.num(d, 3))% (lower bound for the daily change rate)") }
    print("\n== Changes per interval")
    for iv in t.intervals {
        let parts = ChangeKind.allCases.compactMap { k in iv.counts[k].map { "\(k.rawValue) \($0)" } }
        print("  \(Fmt.date(iv.from)) → \(Fmt.date(iv.to)) (\(Fmt.num(iv.days, 0))d): net VMs \(iv.netVMs >= 0 ? "+" : "")\(iv.netVMs), vCPU \(iv.netVCPU >= 0 ? "+" : "")\(iv.netVCPU), data \(signed(iv.dataGrowthMiB, .capacityMiB)) · " + parts.joined(separator: ", "))
    }
    print("\n== Top growing VMs")
    for g in t.vmGrowth.prefix(8) { print("  \(g.name.padding(toLength: 22, withPad: " ", startingAt: 0)) \(cap(g.firstDataMiB)) → \(cap(g.lastDataMiB)) (\(signed(g.perMonthMiB, .capacityMiB))/month)") }
    print("\n== Datastores by days to full")
    for d in t.datastores.prefix(6) { print("  \(d.name.padding(toLength: 20, withPad: " ", startingAt: 0)) \(Fmt.pct(d.usedPctLast)) used · \(signed(d.perMonthMiB, .capacityMiB))/month · full in \(d.daysToFull.map { Fmt.num($0, 0) + " days" } ?? "—")") }
    print("\n== Infrastructure changes")
    for c in t.infra { print("  \(Fmt.date(c.date)) \(c.kind.rawValue.padding(toLength: 9, withPad: " ", startingAt: 0)) \(c.name) — \(c.change) \(c.detail)") }
    print("\n== VM changes (\(t.changes.count); first 25 excluding host moves)")
    for c in t.changes.filter({ $0.kind != .hostMove }).prefix(25) { print("  \(Fmt.date(c.date)) \(c.kind.rawValue.padding(toLength: 16, withPad: " ", startingAt: 0)) \(c.name) — \(c.detail)") }
    if !t.warnings.isEmpty { print("\n== Warnings"); t.warnings.forEach { print("  ! \($0)") } }
}

// --set name=value (repeatable): override a solution assumption. Choices take an index; multi-selects take "0,2,5".
var overrides: [String: String] = [:]
while let i = args.firstIndex(of: "--set"), i + 1 < args.count {
    let kv = args[i + 1].split(separator: "=", maxSplits: 1).map(String.init)
    if kv.count == 2 { overrides[kv[0]] = kv[1] }
    args.removeSubrange(i...(i + 1))
}

// --solutions <dir> (repeatable): load custom solution packs from this folder too (or a single pack folder).
var solutionDirs: [URL] = []
while let i = args.firstIndex(of: "--solutions"), i + 1 < args.count {
    solutionDirs.append(URL(fileURLWithPath: args[i + 1]))
    args.removeSubrange(i...(i + 1))
}
// --price-list <file.rvaprices> (repeatable): use this price list without installing it.
var priceListFiles: [URL] = []
while let i = args.firstIndex(of: "--price-list"), i + 1 < args.count {
    priceListFiles.append(URL(fileURLWithPath: args[i + 1]))
    args.removeSubrange(i...(i + 1))
}
// --validate-solution <pack>: check a pack; with an export, also run it and print its console output.
var validatePack: URL?
if let i = args.firstIndex(of: "--validate-solution"), i + 1 < args.count {
    validatePack = URL(fileURLWithPath: args[i + 1])
    args.removeSubrange(i...(i + 1))
}
var listSolutions = false
if let i = args.firstIndex(of: "--list-solutions") {
    listSolutions = true
    args.remove(at: i)
}
SolutionLibrary.shared.extraDirectories = (validatePack.map { [$0] } ?? []) + solutionDirs
PriceLibrary.shared.extraFiles = priceListFiles
SolutionLibrary.shared.reload()

func stderr(_ s: String) { FileHandle.standardError.write((s + "\n").data(using: .utf8)!) }

if listSolutions {
    print("Built-in solutions:")
    for s in SolutionCatalog.builtIn { print("  \(s.id.padding(toLength: 22, withPad: " ", startingAt: 0)) \(s.title)") }
    print("\nCustom solutions (searched: \(SolutionLibrary.shared.searchDirectories.map(\.path).joined(separator: ", "))):")
    for s in SolutionLibrary.shared.solutions {
        print("  \(s.id.padding(toLength: 22, withPad: " ", startingAt: 0)) \(s.title) \(s.version) — \(s.packURL.path)")
    }
    for issue in SolutionLibrary.shared.issues { print("  ! \(issue.path): \(issue.message)") }
    print("\nPrice lists (\(PriceLibrary.directory.path)):")
    for p in CloudProvider.allCases { print("  \(p.rawValue.padding(toLength: 22, withPad: " ", startingAt: 0)) \(p.name) list prices — cached regions: \(PriceStore.shared.availableRegions(p).joined(separator: " "))") }
    for e in PriceLibrary.shared.all {
        print("  \(e.list.id.padding(toLength: 22, withPad: " ", startingAt: 0)) \(e.list.name) (\(e.list.currencyCode)\(e.list.basedOn.map { ", based on \($0)" } ?? "")) — \(e.origin.label)")
    }
    for issue in PriceLibrary.shared.issues { print("  ! \(issue.path): \(issue.message)") }
    exit(0)
}

/// The pack being validated (used instead of an installed solution with the same id).
var validated: ScriptedSolution?
if let pack = validatePack {
    do {
        let s = try SolutionLibrary.loadPack(pack)
        validated = s
        print("✓ \(s.title) (\(s.id)\(s.version.isEmpty ? "" : " " + s.version)) — apiVersion \(s.manifest.apiVersion), \(s.parameters.count) parameters")
        if SolutionCatalog.isBuiltIn(s.id) { print("  ! id “\(s.id)” belongs to a built-in solution — the app won't load this pack") }
        if let installed = SolutionLibrary.shared.solutions.first(where: { $0.id == s.id }), installed.packURL.standardizedFileURL != pack.standardizedFileURL {
            print("  · an installed pack uses the same id: \(installed.packURL.path)")
        }
        for provider in s.providers {
            let info = PriceLibrary.shared.info(provider)
            print("  · prices “\(provider)”: " + (info.installed ? "\(info.name) — \(info.regions.count) regions available now" : "not installed"))
        }
        for issue in PriceLibrary.shared.issues { print("  ! \(issue.path): \(issue.message)") }
        if args.isEmpty { exit(0) }
        solutionID = s.id
    } catch {
        print("✗ \(pack.path): \(error.localizedDescription)")
        exit(1)
    }
}

// --select <selection>=<vms> (repeatable): override a VM selection ("vms" is a single-selection solution's) with
// all, vms, poweredOn, none, or comma-separated VM names.
var selectOverrides: [String: String] = [:]
while let i = args.firstIndex(of: "--select"), i + 1 < args.count {
    let kv = args[i + 1].split(separator: "=", maxSplits: 1).map(String.init)
    if kv.count == 2 { selectOverrides[kv[0]] = kv[1] }
    args.removeSubrange(i...(i + 1))
}

/// VM ids for each selection of a solution: the project's saved selection or the default, then any --select override.
func resolveSelections(_ s: any Solution, _ inv: Inventory) -> [String: Set<String>] {
    var out: [String: Set<String>] = [:]
    for sel in s.selections {
        var ids = project?.solutionSelections[sel.key(s.id)].map { Set($0) } ?? s.initialSelection(inv, for: sel)
        if let raw = selectOverrides[sel.id] {
            switch raw {
            case "all": ids = Set(inv.vms.map(\.id))
            case "vms": ids = Set(inv.vms.filter(\.isVM).map(\.id))
            case "poweredOn": ids = Set(inv.vms.filter { $0.isVM && $0.isRunning }.map(\.id))
            case "none": ids = []
            default:
                let names = Set(raw.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces).lowercased() })
                ids = Set(inv.vms.filter { names.contains($0.name.lowercased()) }.map(\.id))
                if ids.count < names.count { stderr("--select \(sel.id): \(names.count - ids.count) VM name(s) not found") }
            }
        }
        out[sel.key(s.id)] = ids
    }
    return out
}

func paramValues(_ s: any Solution) -> ParamValues {
    ParamValues.parsing(overrides, for: s, base: project?.solutionParams[s.id] ?? ParamValues()) { stderr($0) }
}

// --prices azure|aws: download every region's public price list and report what was found.
if let i = args.firstIndex(of: "--prices"), i + 1 < args.count {
    guard let provider = CloudProvider(rawValue: args[i + 1]) else { print("usage: --prices azure|aws"); exit(1) }
    for region in CloudRegions.list(provider) {
        let errors = await PriceStore.shared.download(provider, regions: [region.code])
        if let e = errors[region.code] {
            print("  \(region.code.padding(toLength: 20, withPad: " ", startingAt: 0)) FAILED: \(e)")
        } else if let rp = PriceStore.shared.prices(provider, region.code) {
            let priced = rp.instances.filter { $0.linuxHourly != nil }
            print("  \(region.code.padding(toLength: 20, withPad: " ", startingAt: 0)) \(priced.count) instances · \(rp.instances.filter { $0.windowsHourly != nil }.count) Windows · "
                + "\(rp.instances.filter { $0.reserved1yHourly != nil }.count) reserved · storage \(rp.storage.keys.sorted().joined(separator: " "))")
        }
    }
    exit(0)
}

if let path = decksRecipe {
    guard !args.isEmpty else { stderr("--decks needs an export to read"); exit(1) }
    do {
        let recipe = try DeckRecipe.load(URL(fileURLWithPath: path))
        let problems = recipe.problems()
        guard problems.isEmpty else { problems.forEach { stderr("✗ " + $0) }; exit(1) }
        let inputs = args.map { URL(fileURLWithPath: $0) }
        let outputs = try DeckBatch.run(recipe, inputs: inputs, customer: decksCustomer)
        for o in outputs {
            o.notes.forEach { stderr("  · \(o.name): " + $0) }
            stderr(o.data != nil ? "✓ \(o.fileName)" : "✗ \(o.name): \(o.error ?? "failed")")
        }
        if let zip = decksZip {
            try DeckBatch.zip(outputs).write(to: URL(fileURLWithPath: zip))
            stderr("Wrote \(zip)")
        } else {
            let first = inputs[0].standardizedFileURL
            let dir = decksOut.map { URL(fileURLWithPath: $0) }
                ?? first.deletingLastPathComponent().appendingPathComponent(first.deletingPathExtension().lastPathComponent + " Decks")
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            for o in outputs { if let d = o.data { try d.write(to: dir.appendingPathComponent(o.fileName)) } }
            stderr("Wrote \(dir.path)")
        }
        exit(outputs.contains { $0.data == nil } ? 3 : 0)
    } catch {
        stderr("--decks: \(error.localizedDescription)")
        exit(1)
    }
}

guard !args.isEmpty else {
    print("usage: rvtools-cli <RVTools export .xlsx | folder of RVTools_tab*.csv | project.rvaproj> [...] [--columns] [--export <dir>]")
    print("       [--merge-vcenter <from>=<to>] [--solution <id> [--pptx <file> [--template <file>]]] [--decks <recipe> [--out <dir> | --zip <file>] [--customer <name>]] [--set name=value ...] [--select selection=vms ...] [--save-project <path>] [--trend] [--map kind:name] [--units binary|decimal] [--rate bits|bytes]")
    print("       --list-solutions | --validate-solution <pack> [export] | --solutions <dir> | --price-list <file> | --prices azure|aws")
    exit(1)
}

func pad(_ s: String, _ n: Int) -> String { s.count >= n ? s : s + String(repeating: " ", count: n - s.count) }
func lpad(_ s: String, _ n: Int) -> String { s.count >= n ? s : String(repeating: " ", count: n - s.count) + s }
func ms(_ a: Date, _ b: Date) -> String { String(format: "%.0f ms", b.timeIntervalSince(a) * 1000) }

do {
    let t0 = Date()
    var inputs = args.map { URL(fileURLWithPath: $0) }
    if inputs.count == 1, ProjectFile.isProject(inputs[0]), let opened = try? ProjectFile.read(inputs[0]), opened.project.isTrend {
        printTrend(TrendAnalyzer.run(try TrendLoader.load(groups: opened.project.sourceGroups(in: inputs[0])),
                                     ignoreUnusedLocalDatastores: opened.project.thresholds.ignoreUnusedLocalDatastores))
        exit(0)
    }
    if trendMode {
        let snapshots = try TrendLoader.load(inputs)
        guard snapshots.count >= 2 else { print("Trend analysis needs at least two exports taken at different times (found \(snapshots.count))."); exit(1) }
        let t0 = Date()
        let trend = TrendAnalyzer.run(snapshots)
        // --trend with --solution: run the solution on the latest snapshot; custom solutions get the trend rates.
        if let sid = solutionID {
            guard let found = SolutionCatalog.solution(id: sid) else {
                print("unknown solution '\(sid)'; available: " + SolutionCatalog.all.map(\.id).joined(separator: ", "))
                exit(1)
            }
            var s = found
            let analyzed = Analyzer.run(trend.last.inventory, thresholds: Thresholds(), acknowledgements: [])
            if var scripted = found as? ScriptedSolution { scripted.trend = trend.rates; scripted.findings = analyzed.groups; s = scripted }
            let inv = analyzed.inventory
            let resolved = resolveSelections(s, inv)
            var selections: [String: [VM]] = [:]
            for sel in s.selections {
                let ids = resolved[sel.key(s.id)] ?? []
                selections[sel.id] = inv.vms.filter { ids.contains($0.id) }
            }
            let result = s.run(vms: selections[s.selections[0].id] ?? [], selections: selections, inventory: inv, values: paramValues(s))
            print(result.markdown(title: s.title, subtitle: "Trend of \(trend.snapshots.count) snapshots over \(Fmt.num(trend.spanDays, 0)) days · latest exported \(Fmt.dateTime(trend.last.date))"))
            writeDeck(result, s, subtitle: "Trend of \(trend.snapshots.count) snapshots", date: "Latest export \(Fmt.dateTime(trend.last.date))")
            result.log.forEach { stderr("  " + $0) }
            exit(result.failed ? 3 : 0)
        }
        printTrend(trend)
        print(String(format: "\n(analysed in %.0f ms)", Date().timeIntervalSince(t0) * 1000))
        if let out = saveProjectPath {
            let url = URL(fileURLWithPath: out)
            var p = ProjectFile(name: url.deletingPathExtension().lastPathComponent)
            p.mode = ProjectFile.trendMode
            _ = try ProjectFile.write(p, to: url, copyGroups: snapshots.map(\.sources), prices: [])
            print("Saved trend project \(url.path)")
        }
        exit(0)
    }
    if inputs.count == 1, ProjectFile.isProject(inputs[0]) {
        let opened = try ProjectFile.read(inputs[0])
        project = opened.project
        inputs = opened.sources
        PriceStore.shared.importSnapshots(opened.prices)
        PriceLibrary.shared.setProjectLists(opened.priceLists)
        print("Project:      \(opened.project.name) (saved \(Fmt.dateTime(opened.project.modified)))")
    }
    let ds = try Dataset.load(inputs, columnChoices: project?.columnMapping, vcenterMerges: vcenterMerges.isEmpty ? project?.vcenterMerges : vcenterMerges)
    let t1 = Date()
    let inv = InventoryBuilder.build(ds)
    let t2 = Date()
    let r = Analyzer.run(inv, thresholds: project?.thresholds ?? Thresholds(), acknowledgements: project?.acknowledgements ?? [])
    let t3 = Date()

    if let out = saveProjectPath {
        var url = URL(fileURLWithPath: out)
        if !ProjectFile.isProject(url) { url.appendPathExtension(ProjectFile.fileExtension) }
        var p = project ?? ProjectFile(name: url.deletingPathExtension().lastPathComponent)
        p.name = url.deletingPathExtension().lastPathComponent
        if !ds.columnPlans.isEmpty { p.columnMapping = ds.columnChoices }
        if !vcenterMerges.isEmpty { p.vcenterMerges = vcenterMerges }
        for s in SolutionCatalog.all {
            let chosen = s.id == solutionID || validated?.id == s.id
            for (key, ids) in resolveSelections(s, r.inventory) where p.solutionSelections[key] == nil || (chosen && !selectOverrides.isEmpty) {
                p.solutionSelections[key] = ids.sorted()
            }
        }
        if let sid = solutionID, let s = SolutionCatalog.solution(id: sid) { p.solutionParams[sid] = paramValues(s) }
        _ = try ProjectFile.write(p, to: url, copySources: ds.sources, prices: [])
        print("Saved project \(url.path)")
    }

    if let spec = mapSpec {
        guard let focus = RelationshipBuilder.focus(spec, in: r.inventory), let map = RelationshipBuilder.map(focus, in: r.inventory) else {
            stderr("--map: nothing matches “\(spec)” — use vm:, host:, cluster:, datastore: or portgroup: and a name")
            exit(1)
        }
        print(map.outline())
        if let dir = exportDir {
            let url = URL(fileURLWithPath: dir).appendingPathComponent(map.focus.name.replacingOccurrences(of: "/", with: "-") + "_relationships.csv")
            try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            try map.csv().write(to: url, atomically: true, encoding: .utf8)
            print("Wrote \(url.path)")
        }
        exit(0)
    }

    if let sid = solutionID {
        guard let s = validated ?? SolutionCatalog.solution(id: sid) else {
            print("unknown solution '\(sid)'; available: " + SolutionCatalog.all.map(\.id).joined(separator: ", "))
            exit(1)
        }
        if let priced = s as? any PricedSolution {
            let regions = priced.regions(Params(priced.parameters, paramValues(priced)))
            let missing = PriceStore.shared.loadFromDisk(priced.provider, regions: regions)
            if !missing.isEmpty {
                FileHandle.standardError.write("Downloading \(priced.provider.name) prices for \(missing.joined(separator: ", "))…\n".data(using: .utf8)!)
                for (region, error) in await PriceStore.shared.download(priced.provider, regions: missing) {
                    FileHandle.standardError.write("  \(region): \(error)\n".data(using: .utf8)!)
                }
            }
        }
        let resolved = resolveSelections(s, r.inventory)
        var selections: [String: [VM]] = [:]
        for sel in s.selections {
            let ids = resolved[sel.key(s.id)] ?? []
            selections[sel.id] = r.inventory.vms.filter { ids.contains($0.id) }
        }
        for key in selectOverrides.keys where !s.selections.contains(where: { $0.id == key }) {
            stderr("--select: \(s.title) has no selection “\(key)” — available: " + s.selections.map(\.id).joined(separator: ", "))
        }
        if let scripted = s as? ScriptedSolution {
            // Custom solutions never download: they read cached, project or price-list prices.
            for sel in scripted.regionSelections(Params(scripted.parameters, paramValues(scripted))) {
                guard let provider = CloudProvider(rawValue: sel.provider) else { continue }
                let missing = PriceStore.shared.loadFromDisk(provider, regions: sel.regions)
                if !missing.isEmpty { stderr("No cached \(provider.name) prices for \(missing.joined(separator: ", ")) — run `rvtools-cli --prices \(provider.rawValue)` or use Download Prices in the app.") }
            }
        }
        let started = Date()
        var runnable = s
        if var scripted = s as? ScriptedSolution { scripted.findings = r.groups; runnable = scripted }
        let result = runnable.run(vms: selections[s.selections[0].id] ?? [], selections: selections, inventory: r.inventory, values: paramValues(s))
        print(result.markdown(title: s.title, subtitle: "\(ds.sources.map(\.lastPathComponent).joined(separator: ", ")) · exported \(Fmt.dateTime(ds.reportDate))"))
        writeDeck(result, s, subtitle: ds.sources.map(\.lastPathComponent).joined(separator: ", "), date: "Exported \(Fmt.dateTime(ds.reportDate))")
        if s is ScriptedSolution {
            stderr("── \(s.title): \(String(format: "%.0f ms", Date().timeIntervalSince(started) * 1000)), \(result.log.count) console lines, prices read: "
                + (result.priceRefs.isEmpty ? "none" : result.priceRefs.map { "\($0.provider)/\($0.region)" }.joined(separator: " ")))
            result.log.forEach { stderr("  " + $0) }
        }
        exit(result.failed ? 3 : 0)
    }

    print("Sources:      \(ds.sources.map(\.lastPathComponent).joined(separator: ", "))")
    print("Export date:  \(Fmt.dateTime(ds.reportDate))   \(ds.toolLabel)")
    print("Timing:       load \(ms(t0, t1)), correlate \(ms(t1, t2)), analyze \(ms(t2, t3))")
    print("Tabs:         " + ds.tableNames.map { "\($0)=\(ds.table($0)?.rows.count ?? 0)" }.joined(separator: " "))
    for w in ds.warnings { print("Note:         \(w)") }
    if showColumns {
        for plan in ds.columnPlans {
            print("\n== Columns: \(plan.file)")
            for tab in plan.tabs {
                for m in tab.matches where m.target != m.source { print("  \(tab.name)\t\(m.source)\t\(m.target ?? "(no match)")\t\(m.kind)") }
            }
        }
    }

    let t = r.totals
    print("\n== Inventory")
    let kinds = r.inventory.vcenters.allSatisfy { $0.kind == .vCenter } ? "vCenters \(t.vcenters)" : r.inventory.vcenterSummary
    print("\(kinds) · datacenters \(t.datacenters) · clusters \(t.clusters) · hosts \(t.hosts) (\(t.hostsInMaintenance) in maintenance)")
    print("VMs \(t.vms): on \(t.vmsOn), off \(t.vmsOff), suspended \(t.vmsSuspended) · templates \(t.templates)")
    print("Compute: \(t.sockets) sockets, \(t.cores) cores, \(Fmt.memory(mib: t.physMemMiB)) RAM · vCPU on \(t.vcpuOn) (\(Fmt.ratio(t.vcpuPerCore))) · vRAM on \(Fmt.memory(mib: t.vramOnMiB))")
    print("Utilisation: CPU \(Fmt.pct(t.cpuUsagePct)) · memory \(Fmt.pct(t.memUsagePct))")
    if !r.vmcManagementDatastores.isEmpty {
        print("VMC management datastores, same vSAN capacity as WorkloadDatastore (\(r.thresholds.ignoreVMCManagementDatastore ? "left out of the figures below" : "included")): "
            + r.vmcManagementDatastores.map(\.name).sorted().joined(separator: ", "))
    }
    if !r.unusedLocalDatastores.isEmpty {
        print("Local datastores with no VM files (\(r.thresholds.ignoreUnusedLocalDatastores ? "left out of the figures below" : "included")): "
            + r.unusedLocalDatastores.map(\.name).sorted().joined(separator: ", "))
    }
    print("Storage: \(t.datastores) datastores, \(Fmt.capacity(mib: t.dsCapacityMiB)) capacity, \(Fmt.pct(t.dsUsedPct)) used · VM provisioned \(Fmt.capacity(mib: t.vmProvisionedMiB)), in use \(Fmt.capacity(mib: t.vmInUseMiB))")
    print("Snapshots \(t.snapshots) (\(Fmt.capacity(mib: t.snapshotMiB))) · port groups \(t.portGroups) · VLANs \(t.vlans)")

    print("\n== Clusters")
    for c in r.inventory.clusters {
        print("  \(pad(c.name, 34)) hosts \(lpad("\(c.hostCount)", 3))  VMs \(lpad("\(c.vmCount)", 4))  vCPU:core \(lpad(Fmt.ratio(c.vcpuPerCore), 6))  CPU \(lpad(Fmt.pct(c.cpuUsagePct), 4))  mem \(lpad(Fmt.pct(c.memUsagePct), 4))  N+1 mem \(Fmt.pct(c.memPctAfterHostLoss))")
    }

    print("\n== Correlations (tab joins)")
    for j in r.inventory.joins {
        print("  \(pad(j.source, 22)) → \(pad(j.target, 28)) \(lpad("\(j.matched)/\(j.total)", 11))  \(lpad(Fmt.pct(j.coverage * 100), 5))  via \(j.keys)")
    }
    print("\n== Consistency checks")
    for c in r.inventory.checks {
        print("  [\(c.ok ? "ok" : "!!")] \(pad(c.title, 50)) reported \(c.reported) · derived \(c.derived)")
    }

    let q = r.dataQuality
    print("\n== Data confidence: \(Fmt.num(q.score, 1))% of \(Fmt.int(q.total)) key figures available — \(Fmt.int(q.reported)) reported, \(Fmt.int(q.derived)) derived, \(Fmt.int(q.missing)) missing")
    for g in q.gaps {
        let tag = g.kind == .missing ? "missing" : (g.kind == .derived ? "derived" : "note")
        let count = g.total > 0 ? "\(g.affected)/\(g.total)" : ""
        print("  [\(pad(tag, 7))] \(pad(g.area + " · " + g.title, 34)) \(lpad(count, 11))  " + (g.fallback.isEmpty ? "" : "from \(g.fallback) — ") + g.impact)
    }

    print("\n== Findings: \(t.critical) critical, \(t.warning) warning, \(t.info) info"
        + (r.acknowledgedFindings.isEmpty ? "" : " (\(r.acknowledgedFindings.count) acknowledged findings not shown)"))
    for g in r.groups {
        print("  \(pad(g.severity.label, 8)) \(lpad("\(g.count)", 5))  \(pad(g.category.rawValue, 20)) \(g.title)")
    }

    print("\n== Distributions")
    func show(_ name: String, _ items: [CountItem]) {
        print("  \(name): " + items.prefix(8).map { "\($0.label) \($0.count)" }.joined(separator: " · "))
    }
    show("OS family", r.dist.osFamily)
    show("OS lifecycle", r.dist.osLifecycle)
    show("Tools (running)", r.dist.toolsStatus)
    show("HW version", r.dist.hwVersion)
    show("ESXi", r.dist.esxiVersion)
    show("Disk provisioning", r.dist.diskProvisioning)
    show("NIC adapters", r.dist.nicAdapter)
    show("Snapshot age", r.dist.snapshotAge)

    if let dir = exportDir {
        let base = URL(fileURLWithPath: dir)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let files: [(String, String)] = [
            ("findings.csv", CSVExport.findings(r)), ("vms.csv", CSVExport.vms(r)), ("hosts.csv", CSVExport.hosts(r)),
            ("clusters.csv", CSVExport.clusters(r)), ("datastores.csv", CSVExport.datastores(r)),
            ("vm-networks.csv", CSVExport.vmNetworks(r)), ("vm-datastores.csv", CSVExport.vmDatastores(r)),
            ("host-networks.csv", CSVExport.hostNetworks(r)), ("host-datastores.csv", CSVExport.hostDatastores(r)),
        ]
        for (name, content) in files { try content.write(to: base.appendingPathComponent(name), atomically: true, encoding: .utf8) }
        print("\nExported \(files.count) CSV files to \(base.path)")
    }
} catch {
    FileHandle.standardError.write("error: \(error.localizedDescription)\n".data(using: .utf8)!)
    exit(2)
}
