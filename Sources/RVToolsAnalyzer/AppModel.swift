import AppKit
import Observation
import RVToolsCore
import SwiftUI
import UniformTypeIdentifiers

extension UTType {
    /// Saved project package (`.rvaproj`); declared in the app's Info.plist.
    static let rvaProject = UTType(exportedAs: "local.rvtools-analyzer.project", conformingTo: .package)
}

/// A sidebar destination: one of the fixed pages, or a solution from `SolutionCatalog` (added dynamically).
struct SidebarItem: Hashable, Identifiable {
    let id: String
    let title: String
    let symbol: String

    var rawValue: String { title }
    var solutionID: String? { id.hasPrefix("solution:") ? String(id.dropFirst("solution:".count)) : nil }

    static let overview = SidebarItem(id: "overview", title: "Overview", symbol: "gauge.with.dots.needle.67percent")
    static let issues = SidebarItem(id: "issues", title: "Issues", symbol: "exclamationmark.triangle")
    static let compute = SidebarItem(id: "compute", title: "Compute", symbol: "cpu")
    static let vms = SidebarItem(id: "vms", title: "Virtual Machines", symbol: "desktopcomputer")
    static let storage = SidebarItem(id: "storage", title: "Storage", symbol: "externaldrive")
    static let network = SidebarItem(id: "network", title: "Network", symbol: "network")
    static let configuration = SidebarItem(id: "configuration", title: "Configuration", symbol: "slider.horizontal.3")
    static let lifecycle = SidebarItem(id: "lifecycle", title: "Lifecycle", symbol: "calendar.badge.clock")
    static let correlations = SidebarItem(id: "correlations", title: "Correlations", symbol: "point.3.connected.trianglepath.dotted")
    static let rawData = SidebarItem(id: "rawData", title: "Raw Tabs", symbol: "tablecells")

    /// Fixed pages, in sidebar order (used by the Go menu).
    static let allCases: [SidebarItem] = [overview, issues, compute, vms, storage, network, configuration, lifecycle, correlations, rawData]

    // Trend mode pages
    static let trendSummary = SidebarItem(id: "trend:summary", title: "Trend Summary", symbol: "chart.line.uptrend.xyaxis")
    static let trendChanges = SidebarItem(id: "trend:changes", title: "Changes", symbol: "arrow.triangle.2.circlepath")
    static let trendGrowth = SidebarItem(id: "trend:growth", title: "Growth", symbol: "chart.bar.xaxis")
    static let trendCapacity = SidebarItem(id: "trend:capacity", title: "Capacity Forecast", symbol: "calendar.badge.exclamationmark")
    static let trendPages: [SidebarItem] = [trendSummary, trendChanges, trendGrowth, trendCapacity]

    static func solution(_ s: any Solution) -> SidebarItem {
        SidebarItem(id: "solution:" + s.id, title: s.title, symbol: s.symbol)
    }

    /// A custom solution the open project uses that isn't installed or is turned off.
    static func missingSolution(_ id: String) -> SidebarItem {
        SidebarItem(id: "solution:" + id, title: id, symbol: "puzzlepiece.extension")
    }
}

struct ScopeOption: Identifiable, Hashable {
    let id: String
    let label: String
    /// nil = entire environment
    let clusterIDs: Set<String>?
    var isGroupStart = false
}

/// Fast id → entity lookups for the current report (used for cross-navigation in detail panes).
struct Lookup {
    var vms: [String: VM] = [:]
    var hosts: [String: RVToolsCore.Host] = [:]
    var clusters: [String: Cluster] = [:]
    var datastores: [String: Datastore] = [:]
    var portGroups: [String: PortGroup] = [:]

    init() {}

    init(_ inv: Inventory) {
        vms = Dictionary(inv.vms.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        hosts = Dictionary(inv.hosts.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        clusters = Dictionary(inv.clusters.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        datastores = Dictionary(inv.datastores.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        portGroups = Dictionary(inv.portGroups.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
    }

    static func id(_ server: String, _ name: String) -> String { server.lowercased() + "|" + name.lowercased() }
}

/// A rate measured in the loaded trend that an assumption can be replaced with (`value`), or that is only
/// context for it (`value` nil).
struct ObservedRate {
    let text: String
    let value: Double?
    let unit: String
}

enum ExportKind: String, CaseIterable, Identifiable {
    case findings = "Findings"
    case vms = "VM inventory"
    case hosts = "Hosts"
    case clusters = "Clusters"
    case datastores = "Datastores"
    case vmNetworks = "VM ↔ Networks"
    case vmDatastores = "VM ↔ Datastores"
    case hostNetworks = "Host ↔ Networks"
    case hostDatastores = "Host ↔ Datastores"
    var id: String { rawValue }
    /// One row per relationship, for planning in both directions.
    static let relationships: [ExportKind] = [.vmNetworks, .vmDatastores, .hostNetworks, .hostDatastores]
    var fileSuffix: String {
        switch self {
        case .findings: return "findings"
        case .vms: return "vms"
        case .hosts: return "hosts"
        case .clusters: return "clusters"
        case .datastores: return "datastores"
        case .vmNetworks: return "vm-networks"
        case .vmDatastores: return "vm-datastores"
        case .hostNetworks: return "host-networks"
        case .hostDatastores: return "host-datastores"
        }
    }

    func content(_ r: Report) -> String {
        switch self {
        case .findings: return CSVExport.findings(r)
        case .vms: return CSVExport.vms(r)
        case .hosts: return CSVExport.hosts(r)
        case .clusters: return CSVExport.clusters(r)
        case .datastores: return CSVExport.datastores(r)
        case .vmNetworks: return CSVExport.vmNetworks(r)
        case .vmDatastores: return CSVExport.vmDatastores(r)
        case .hostNetworks: return CSVExport.hostNetworks(r)
        case .hostDatastores: return CSVExport.hostDatastores(r)
        }
    }
}

@MainActor
@Observable
final class AppModel {
    static let shared = AppModel()

    var dataset: Dataset?
    var fullInventory: Inventory?
    var report: Report?
    var lookup = Lookup()
    var scopes: [ScopeOption] = []
    var scopeID = "all" { didSet { if oldValue != scopeID { recompute(); noteChange() } } }
    var sidebar: SidebarItem? = .overview
    var isLoading = false
    /// An export whose columns are waiting to be checked (see `ColumnMappingSheet`).
    var columnReview: ColumnReview?
    var loadingMessage = ""
    var errorMessage: String?
    var sources: [URL] = []

    // Trend mode: several exports of one environment over time. The snapshot dashboards (report, lookup, …)
    // show the export picked with `trendSnapshot` (the latest by default).
    var trend: TrendReport?
    var trendSnapshot = 0 { didSet { if oldValue != trendSnapshot { showSnapshot(trendSnapshot) } } }
    var trendVMKey: String?
    var trendInterval: Int?
    var trendChangesTab = 0

    // Cross-page navigation state
    var selectedVMID: String?
    var selectedHostID: String?
    var selectedDatastoreID: String?
    var selectedPortGroupID: String?
    var computeTab = 0
    var storageTab = 0
    var networkTab = 0
    var focusRule: String?
    /// Hides the data-confidence banner until another export is opened.
    var dataBannerDismissed = false

    // Solutions: per-solution VM selection (reset per export), assumptions (persisted) and active tab.
    var solutionSelections: [String: Set<String>] = [:] { didSet { noteChange() } }
    var solutionParams: [String: ParamValues] = AppModel.loadSolutionParams() {
        didSet {
            if let data = try? JSONEncoder().encode(solutionParams) { AppDefaults.store.set(data, forKey: "solutionParams") }
            noteChange()
        }
    }
    var solutionTab: [String: Int] = [:]
    private(set) var reportVersion = 0
    var priceVersion = 0
    var priceLoading = false
    var priceStatus = ""
    var priceError: String?
    @ObservationIgnored private var solutionCache: [String: SolutionResult] = [:]

    // Custom solutions (script packs) and price lists — see SolutionLibrary and PriceLibrary.
    private(set) var extensionsVersion = 0
    /// Bumped when a custom solution finishes running in the background.
    private(set) var scriptRunVersion = 0
    /// The last finished result of each custom solution, shown while a new run is in progress.
    private(set) var latestScriptResults: [String: SolutionResult] = [:]
    /// Custom solutions the open project has settings for.
    private(set) var projectSolutionIDs: Set<String> = []
    @ObservationIgnored private var runningScripts: Set<String> = []
    @ObservationIgnored private var lastPriceRefs: [String: [PriceRef]] = [:]
    @ObservationIgnored private var projectPriceRefs: Set<PriceRef> = []
    @ObservationIgnored private var projectListIDs: Set<String> = []
    @ObservationIgnored private var extensionWatcher: ExtensionWatcher?
    @ObservationIgnored private var reloadTask: Task<Void, Never>?

    // Projects: saved sessions (.rvaproj). Once saved, changes autosave.
    var projectURL: URL?
    var projectName = "" { didSet { if oldValue != projectName { noteChange() } } }
    var projectNotes = "" { didSet { if oldValue != projectNotes { noteChange() } } }
    var isDirty = false
    var lastSaved: Date?
    var showProjectInfo = false
    var recentProjects: [URL] = AppModel.loadRecents()
    @ObservationIgnored private var currentProject: ProjectFile?
    @ObservationIgnored private var restoring = false
    @ObservationIgnored private var autosaveTask: Task<Void, Never>?

    /// Findings and whole checks acknowledged on the Issues page; saved with the project.
    var acknowledgements: [Acknowledgement] = [] {
        didSet {
            guard acknowledgements != oldValue else { return }
            recompute()
            noteChange()
        }
    }

    /// Display units (a preference, not saved in projects). Changing them recalculates, so findings and results use them too.
    var storageUnits: StorageUnits = AppModel.loadPreference("storageUnits", StorageUnits.binary) {
        didSet {
            guard storageUnits != oldValue else { return }
            AppDefaults.store.set(storageUnits.rawValue, forKey: "storageUnits")
            Units.storage = storageUnits
            recompute()
            refreshTrend()
        }
    }
    var rateUnits: RateUnits = AppModel.loadPreference("rateUnits", RateUnits.bits) {
        didSet {
            guard rateUnits != oldValue else { return }
            AppDefaults.store.set(rateUnits.rawValue, forKey: "rateUnits")
            Units.rate = rateUnits
            recompute()
            refreshTrend()
        }
    }

    /// Re-runs the loaded trend (its change descriptions and figures depend on the settings).
    private func refreshTrend() {
        guard let t = trend else { return }
        let snapshots = t.snapshots, ignore = thresholds.ignoreUnusedLocalDatastores, ignoreVMC = thresholds.ignoreVMCManagementDatastore
        Task.detached(priority: .userInitiated) {
            let updated = TrendAnalyzer.run(snapshots, ignoreUnusedLocalDatastores: ignore, ignoreVMCManagementDatastore: ignoreVMC)
            await MainActor.run { if self.trend?.snapshots.count == snapshots.count { self.trend = updated } }
        }
    }

    private static func loadPreference<T: RawRepresentable>(_ key: String, _ fallback: T) -> T where T.RawValue == String {
        AppDefaults.store.string(forKey: key).flatMap(T.init(rawValue:)) ?? fallback
    }

    var thresholds: Thresholds = AppModel.loadThresholds() {
        didSet {
            guard thresholds != oldValue else { return }
            if let data = try? JSONEncoder().encode(thresholds) { AppDefaults.store.set(data, forKey: "thresholds") }
            recompute()
            if thresholds.ignoreUnusedLocalDatastores != oldValue.ignoreUnusedLocalDatastores
                || thresholds.ignoreVMCManagementDatastore != oldValue.ignoreVMCManagementDatastore { refreshTrend() }
            noteChange()
        }
    }

    private var generation = 0

    private init() {
        Units.storage = storageUnits
        Units.rate = rateUnits
        startExtensions()
    }

    private static func loadThresholds() -> Thresholds {
        guard let data = AppDefaults.store.data(forKey: "thresholds"), let t = try? JSONDecoder().decode(Thresholds.self, from: data) else { return Thresholds() }
        return t
    }

    var scopeLabel: String { scopes.first { $0.id == scopeID }?.label ?? "Entire environment" }

    var sourceSummary: String {
        if let t = trend { return "\(t.snapshots.count) snapshots · \(Fmt.date(t.first.date)) → \(Fmt.date(t.last.date))" }
        guard let first = sources.first else { return "" }
        if sources.count == 1 { return first.lastPathComponent }
        let folders = Set(sources.map { $0.deletingLastPathComponent().lastPathComponent })
        return sources.allSatisfy({ $0.pathExtension.lowercased() == "csv" }) && folders.count == 1 ? "\(folders.first!) (CSV)" : "\(sources.count) files"
    }

    // MARK: Loading

    func presentOpenPanel() {
        let panel = NSOpenPanel()
        panel.title = "Open"
        panel.message = "Choose a saved project, an RVTools .xlsx export, a folder of RVTools_tab*.csv files, a Nutanix Collector export (with its mapping file if anonymized), a Live Optics VMware export, or several exports to merge."
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.allowedContentTypes = [.rvaProject, UTType(filenameExtension: "xlsx"), UTType(filenameExtension: "xlsm"), .commaSeparatedText, .folder].compactMap { $0 }
        if panel.runModal() == .OK { open(panel.urls) }
    }

    var sampleURL: URL? { Bundle.main.url(forResource: "RVTools_sample", withExtension: "xlsx") }

    /// Opens exports or a saved project (.rvaproj), offering to save a customized session first.
    func open(_ urls: [URL]) {
        // Solution packs and price lists dropped on the app are installed, not opened.
        let extensions = urls.filter(AppModel.isExtensionFile)
        if !extensions.isEmpty && extensions.count == urls.count {
            installExtensions(extensions)
            return
        }
        guard !urls.isEmpty, confirmDiscardChanges() else { return }
        if let url = urls.first(where: ProjectFile.isProject) {
            do {
                let opened = try ProjectFile.read(url)
                if opened.project.isTrend {
                    loadTrend(groups: opened.project.sourceGroups(in: url), urls: nil, project: (opened.project, url, opened.prices, opened.priceLists))
                } else {
                    load(opened.sources, project: (opened.project, url, opened.prices, opened.priceLists))
                }
            } catch {
                errorMessage = error.localizedDescription
            }
            return
        }
        load(urls, project: nil)
    }

    private func load(_ urls: [URL], project: (file: ProjectFile, url: URL, prices: [RegionPrices], lists: [PriceList])?) {
        let scoped = urls.filter { $0.startAccessingSecurityScopedResource() }
        isLoading = true
        errorMessage = nil
        loadingMessage = project.map { "Opening \($0.file.name)…" } ?? "Reading \(urls.count == 1 ? urls[0].lastPathComponent : "\(urls.count) items")…"
        let t = project?.file.thresholds ?? thresholds
        let acks = project?.file.acknowledgements ?? []
        // Several exports opened together are merged as separate vCenters, unless they were taken at different times:
        // then they're most likely one environment over time, so offer trend mode instead.
        let checkTimes = project == nil && TrendLoader.expand(urls).count > 1
        Task.detached(priority: .userInitiated) {
            do {
                var loaded: (Dataset, Inventory)?
                if checkTimes {
                    let snapshots = try TrendLoader.load(urls)
                    if snapshots.count >= 2, snapshots[snapshots.count - 1].date.timeIntervalSince(snapshots[0].date) > TrendLoader.combineWindow {
                        switch await MainActor.run(body: { self.askToCompare(snapshots) }) {
                        case .compare:
                            let (trend, report) = AppModel.buildTrend(snapshots, thresholds: t, acknowledgements: acks)
                            await MainActor.run {
                                scoped.forEach { $0.stopAccessingSecurityScopedResource() }
                                self.apply(trend.last.dataset, trend.last.inventory, report, trend: trend)
                            }
                            return
                        case .merge:
                            break
                        case .cancel:
                            await MainActor.run {
                                scoped.forEach { $0.stopAccessingSecurityScopedResource() }
                                self.isLoading = false
                            }
                            return
                        }
                    } else if snapshots.count == 1, let only = snapshots.first, only.dataset.columnPlans.isEmpty {
                        // With unusual columns this falls through to the load below, so they're checked as with one file.
                        loaded = (only.dataset, only.inventory)
                    }
                }
                // A saved project keeps its column choices; anything else with unusual columns is shown for checking.
                let ds = try loaded?.0 ?? Dataset.load(urls, columnChoices: project?.file.columnMapping,
                                                       reviewColumns: project == nil ? { self.checkColumns($0) } : nil)
                await MainActor.run { self.loadingMessage = "Correlating \(ds.tableNames.count) tabs…" }
                let inv = loaded?.1 ?? InventoryBuilder.build(ds)
                let report = Analyzer.run(inv, thresholds: t, acknowledgements: acks)
                await MainActor.run {
                    scoped.forEach { $0.stopAccessingSecurityScopedResource() }
                    self.apply(ds, inv, report)
                    if let project { self.restore(project.file, url: project.url, prices: project.prices, lists: project.lists) }
                    DebugSnapshot.runIfRequested(self)
                }
            } catch {
                await MainActor.run {
                    scoped.forEach { $0.stopAccessingSecurityScopedResource() }
                    self.isLoading = false
                    if !(error is CancellationError) { self.errorMessage = error.localizedDescription }
                }
            }
        }
    }

    /// Called partway through a load, off the main thread: waits while the columns are checked in a sheet.
    private nonisolated func checkColumns(_ plan: ColumnPlan) -> ColumnPlan? {
        final class Answer: @unchecked Sendable { var plan: ColumnPlan? }
        let answer = Answer()
        let finished = DispatchSemaphore(value: 0)
        Task { @MainActor in
            self.columnReview = ColumnReview(plan: plan) {
                answer.plan = $0
                finished.signal()
            }
            DebugSnapshot.runIfRequested(columnReview: self)
        }
        finished.wait()
        return answer.plan
    }

    func finishColumnReview(_ plan: ColumnPlan?) {
        let review = columnReview
        columnReview = nil
        review?.finish(plan)
    }

    // MARK: Trend mode

    enum OpenChoice { case compare, merge, cancel }

    /// Asks what to do with exports that were opened together but taken at different times.
    private func askToCompare(_ snapshots: [TrendSnapshot]) -> OpenChoice {
        let alert = NSAlert()
        alert.messageText = "These exports were taken at different times"
        let dates = snapshots.map { Fmt.date($0.date) }
        alert.informativeText = "\(snapshots.count) exports from \(dates.first ?? "") to \(dates.last ?? ""). Compare them as snapshots of one environment "
            + "over time, or merge them into one view as if they were separate vCenters?"
        alert.addButton(withTitle: "Compare Snapshots")
        alert.addButton(withTitle: "Merge")
        alert.addButton(withTitle: "Cancel")
        switch alert.runModal() {
        case .alertFirstButtonReturn: return .compare
        case .alertSecondButtonReturn: return .merge
        default: return .cancel
        }
    }

    nonisolated static func buildTrend(_ snapshots: [TrendSnapshot], thresholds t: Thresholds, acknowledgements acks: [Acknowledgement]) -> (TrendReport, Report) {
        let trend = TrendAnalyzer.run(snapshots, ignoreUnusedLocalDatastores: t.ignoreUnusedLocalDatastores,
                                      ignoreVMCManagementDatastore: t.ignoreVMCManagementDatastore)
        return (trend, Analyzer.run(snapshots[snapshots.count - 1].inventory, thresholds: t, acknowledgements: acks))
    }

    var sampleSeriesURL: URL? { Bundle.main.url(forResource: "RVTools_sample_series", withExtension: nil) }

    func presentTrendPanel() {
        let panel = NSOpenPanel()
        panel.title = "Compare Snapshots"
        panel.message = "Choose two or more exports of the same environment taken at different times, or a folder that contains them."
        panel.prompt = "Compare"
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.allowedContentTypes = [UTType(filenameExtension: "xlsx"), UTType(filenameExtension: "xlsm"), .commaSeparatedText, .folder].compactMap { $0 }
        if panel.runModal() == .OK { openTrend(panel.urls) }
    }

    /// Opens exports as a time series of one environment (trend mode).
    func openTrend(_ urls: [URL]) {
        guard !urls.isEmpty, confirmDiscardChanges() else { return }
        if let url = urls.first(where: ProjectFile.isProject) { open([url]); return }
        loadTrend(groups: nil, urls: urls, project: nil)
    }

    private func loadTrend(groups: [[URL]]?, urls: [URL]?, project: (file: ProjectFile, url: URL, prices: [RegionPrices], lists: [PriceList])?) {
        let all = urls ?? groups?.flatMap { $0 } ?? []
        let scoped = all.filter { $0.startAccessingSecurityScopedResource() }
        isLoading = true
        errorMessage = nil
        loadingMessage = project.map { "Opening \($0.file.name)…" } ?? "Reading \(all.count == 1 ? all[0].lastPathComponent : "\(all.count) exports")…"
        let t = project?.file.thresholds ?? thresholds
        let acks = project?.file.acknowledgements ?? []
        Task.detached(priority: .userInitiated) {
            do {
                let snapshots = try groups.map { try TrendLoader.load(groups: $0) } ?? TrendLoader.load(all)
                guard snapshots.count >= 2 else {
                    throw RVToolsError.unreadable("Compare Snapshots needs exports of the same environment taken at different times, but these files form a single snapshot. To combine several vCenters into one view, use Open… instead.")
                }
                await MainActor.run { self.loadingMessage = "Comparing \(snapshots.count) snapshots…" }
                let (trend, report) = AppModel.buildTrend(snapshots, thresholds: t, acknowledgements: acks)
                await MainActor.run {
                    scoped.forEach { $0.stopAccessingSecurityScopedResource() }
                    self.apply(trend.last.dataset, trend.last.inventory, report, trend: trend)
                    if let project { self.restore(project.file, url: project.url, prices: project.prices, lists: project.lists) }
                    DebugSnapshot.runIfRequested(self)
                }
            } catch {
                await MainActor.run {
                    scoped.forEach { $0.stopAccessingSecurityScopedResource() }
                    self.isLoading = false
                    self.errorMessage = error.localizedDescription
                }
            }
        }
    }

    /// Points the snapshot dashboards at another export of the series.
    private func showSnapshot(_ index: Int) {
        guard let t = trend, t.snapshots.indices.contains(index) else { return }
        let snap = t.snapshots[index]
        let previous = fullInventory
        restoring = true
        dataset = snap.dataset
        fullInventory = snap.inventory
        resetMissingHostPicks()
        scopes = AppModel.buildScopes(snap.inventory)
        if !scopes.contains(where: { $0.id == scopeID }) { scopeID = "all" }
        // VM ids (vCenter + moref) are stable across exports: keep customized selections, re-default untouched ones.
        let valid = Set(snap.inventory.vms.map(\.id))
        for s in SolutionCatalog.all {
            for sel in s.selections {
                let key = sel.key(s.id)
                let current = solutionSelections[key] ?? []
                let untouched = previous.map { current == s.defaultSelection($0, for: sel) } ?? true
                solutionSelections[key] = untouched ? s.defaultSelection(snap.inventory, for: sel) : current.intersection(valid)
            }
        }
        selectedHostID = nil
        selectedDatastoreID = nil
        selectedPortGroupID = nil
        restoring = false
        recompute()
    }

    /// Opens a VM from the trend pages in the dashboards of the latest snapshot it appears in.
    func revealTrendVM(_ key: String) {
        guard let t = trend else { return }
        let history = t.history(key)
        guard let i = history.lastIndex(where: { $0.vm != nil }), let vm = history[i].vm else { return }
        trendSnapshot = i
        selectedVMID = vm.id
        sidebar = .vms
    }

    /// What the loaded trend measured for an assumption, shown beside it on the Assumptions step.
    func observedRate(_ solutionID: String, _ paramID: String) -> ObservedRate? {
        guard let t = trend, let kind = observedKind(solutionID, paramID) else { return nil }
        let period = "\(t.snapshots.count) snapshots over \(Fmt.int(Int(t.spanDays.rounded()))) days"
        switch kind {
        case "annualGrowth":
            guard let pct = t.suggestedGrowthPct else { return nil }
            let organic = t.organicGrowthPct.map { ", existing VMs only \(Fmt.num($0, 1))%" } ?? ""
            return ObservedRate(text: "Measured across \(period): \(Fmt.num(pct, 1))% a year\(organic).",
                                value: min(100, max(0, (pct * 2).rounded() / 2)), unit: "%")
        case "dailyChangeFloor":
            guard let daily = t.netDailyGrowthPct else { return nil }
            return ObservedRate(text: "Across \(period), existing VMs grew by a net \(Fmt.num(daily, 3))% a day. That's a floor for the change rate, not a measurement of it — rewritten blocks change without adding capacity.",
                                value: nil, unit: "%")
        default:
            return nil
        }
    }

    /// Which trend rate an assumption offers: Backup and DR growth / change, or a custom parameter's `observed`.
    private func observedKind(_ solutionID: String, _ paramID: String) -> String? {
        if solutionID == "backup" || solutionID == "dr" { return ["growth": "annualGrowth", "change": "dailyChangeFloor"][paramID] }
        return SolutionCatalog.custom.first { $0.id == solutionID }?.parameters.first { $0.id == paramID }?.observed
    }

    /// Sets every annual growth assumption that offers the observed rate (Backup, DR and custom solutions) to it.
    func applyObservedGrowth(_ pct: Double) {
        for s in SolutionCatalog.all {
            for p in s.parameters where observedKind(s.id, p.id) == "annualGrowth" {
                guard case .number(let lo, let hi, _, _) = p.kind else { continue }
                var v = solutionParams[s.id] ?? ParamValues()
                v.values[p.id] = .number(min(hi, max(lo, pct)))
                solutionParams[s.id] = v
            }
        }
    }

    func paramNumber(_ solution: String, _ id: String) -> Double? {
        let value = solutionParams[solution]?.values[id] ?? SolutionCatalog.solution(id: solution)?.parameters.first { $0.id == id }?.defaultValue
        if case .number(let v) = value { return v }
        return nil
    }

    func exportTrend() {
        guard let t = trend else { return }
        let panel = NSOpenPanel()
        panel.title = "Export Trend Report"
        panel.message = "Choose a folder for the trend CSV files (metrics, changes, growth, datastores)."
        panel.prompt = "Export Here"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let dir = panel.url else { return }
        let base = (t.last.sources.first?.deletingPathExtension().lastPathComponent ?? "RVTools") + "_trend"
        let files: [(String, String)] = [
            ("summary", TrendExport.summary(t)),
            ("vm-changes", TrendExport.changes(t)),
            ("infrastructure-changes", TrendExport.infrastructure(t)),
            ("vm-growth", TrendExport.vmGrowth(t)),
            ("datastores", TrendExport.datastores(t)),
        ]
        for (name, content) in files { write(content, to: dir.appendingPathComponent("\(base)_\(name).csv")) }
        NSWorkspace.shared.activateFileViewerSelecting([dir])
    }

    private func apply(_ ds: Dataset, _ inv: Inventory, _ r: Report, trend: TrendReport? = nil) {
        restoring = true
        self.trend = nil
        trendSnapshot = (trend?.snapshots.count ?? 1) - 1
        self.trend = trend
        trendVMKey = nil
        trendInterval = nil
        trendChangesTab = 0
        dataset = ds
        fullInventory = inv
        sources = trend.map { $0.snapshots.flatMap(\.sources) } ?? ds.sources
        scopes = AppModel.buildScopes(inv)
        generation += 1
        scopeID = "all"
        report = r
        lookup = Lookup(r.inventory)
        reportVersion += 1
        solutionSelections = AppModel.defaultSelections(SolutionCatalog.all, inv)
        latestScriptResults = [:]
        projectSolutionIDs = []
        acknowledgements = []
        projectPriceRefs = []
        projectListIDs = []
        PriceLibrary.shared.setProjectLists([])
        selectedVMID = nil
        selectedHostID = nil
        selectedDatastoreID = nil
        selectedPortGroupID = nil
        dataBannerDismissed = false
        sidebar = trend == nil ? .overview : .trendSummary
        isLoading = false
        // A freshly opened export is a new, unsaved session.
        projectURL = nil
        currentProject = nil
        projectName = ""
        projectNotes = ""
        lastSaved = nil
        resetMissingHostPicks()
        isDirty = false
        restoring = false
    }

    /// Puts host choices (such as Alternate Hypervisors' "Size new hosts like") back to their default when the chosen host
    /// isn't in the open export, so assumptions saved with another export don't point at a host that isn't there.
    private func resetMissingHostPicks() {
        guard let inv = fullInventory else { return }
        for s in SolutionCatalog.all {
            for p in s.parameters {
                guard case .host = p.kind, case .names(let ids)? = solutionParams[s.id]?.values[p.id],
                      let id = ids.first, HostSpecs.resolve(id, in: inv) == nil else { continue }
                solutionParams[s.id]?.values[p.id] = nil
            }
        }
    }

    /// Re-applies a saved project's settings on top of its freshly analysed export.
    private func restore(_ p: ProjectFile, url: URL, prices: [RegionPrices], lists: [PriceList]) {
        restoring = true
        defer {
            restoring = false
            isDirty = false
        }
        currentProject = p
        projectURL = url
        projectName = p.name
        projectNotes = p.notes
        lastSaved = p.modified
        if !prices.isEmpty {
            PriceStore.shared.importSnapshots(prices)
            priceVersion += 1
        }
        projectPriceRefs = Set(prices.map { PriceRef(provider: $0.provider.rawValue, region: $0.region) })
        projectListIDs = Set(lists.map(\.id))
        PriceLibrary.shared.setProjectLists(lists)
        projectSolutionIDs = Set(p.solutionSelections.keys.map(SolutionCatalog.solutionID(fromSelectionKey:))).union(p.solutionParams.keys)
            .filter { !SolutionCatalog.isBuiltIn($0) }
        thresholds = p.thresholds
        acknowledgements = p.acknowledgements ?? []
        let valid = Set(fullInventory?.vms.map(\.id) ?? [])
        for (id, ids) in p.solutionSelections { solutionSelections[id] = Set(ids).intersection(valid) }
        for (id, values) in p.solutionParams { solutionParams[id] = values }
        resetMissingHostPicks()
        solutionTab = p.solutionTabs
        if scopes.contains(where: { $0.id == p.scopeID }) { scopeID = p.scopeID }
        let pages = SidebarItem.allCases + SidebarItem.trendPages + SolutionCatalog.all.map { SidebarItem.solution($0) }
            + missingSolutionIDs.map(SidebarItem.missingSolution)
        if let page = p.page, let item = pages.first(where: { $0.id == page }) { sidebar = item }
        addRecent(url)
    }

    func close() {
        guard confirmDiscardChanges() else { return }
        dataset = nil
        fullInventory = nil
        report = nil
        lookup = Lookup()
        trend = nil
        trendVMKey = nil
        sources = []
        latestScriptResults = [:]
        projectSolutionIDs = []
        acknowledgements = []
        PriceLibrary.shared.setProjectLists([])
        scopes = []
        restoring = true
        projectURL = nil
        currentProject = nil
        projectName = ""
        projectNotes = ""
        isDirty = false
        restoring = false
    }

    // MARK: Projects

    var projectTitle: String { projectURL == nil ? "Unsaved session" : projectName }

    private var defaultProjectName: String {
        guard let first = trend?.last.sources.first ?? sources.first else { return "RVTools Project" }
        let base = first.pathExtension.lowercased() == "csv" ? first.deletingLastPathComponent().lastPathComponent : first.deletingPathExtension().lastPathComponent
        return trend == nil ? base : base + " trend"
    }

    /// Records a user customization; saved projects autosave shortly afterwards.
    private func noteChange() {
        guard !restoring, report != nil else { return }
        isDirty = true
        if projectURL != nil { scheduleAutosave() }
    }

    private func scheduleAutosave() {
        autosaveTask?.cancel()
        autosaveTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            guard !Task.isCancelled, let self, self.isDirty, self.projectURL != nil else { return }
            self.writeProject()
        }
    }

    private func snapshot() -> ProjectFile {
        var p = currentProject ?? ProjectFile(name: projectName.isEmpty ? defaultProjectName : projectName)
        if !projectName.isEmpty { p.name = projectName }
        p.notes = projectNotes
        p.scopeID = scopeID
        p.thresholds = thresholds
        p.acknowledgements = acknowledgements.isEmpty ? nil : acknowledgements
        p.solutionSelections = solutionSelections.mapValues { $0.sorted() }
        p.solutionParams = solutionParams
        p.solutionTabs = solutionTab
        p.page = sidebar?.id
        p.mode = trend == nil ? nil : ProjectFile.trendMode
        p.columnMapping = dataset?.columnPlans.isEmpty == false ? dataset?.columnChoices : nil
        return p
    }

    /// Price snapshots behind the cloud estimates, stored with the project so they can be reproduced: the built-in
    /// solutions' regions, what custom solutions read (or chose), and what the project already carried.
    private func projectPrices() -> [RegionPrices] {
        var seen = Set<String>()
        var out: [RegionPrices] = []
        func add(_ p: CloudProvider, _ region: String) {
            guard seen.insert(p.rawValue + "|" + region).inserted, let rp = PriceStore.shared.prices(p, region) else { return }
            out.append(rp)
        }
        for s in SolutionCatalog.builtIn.compactMap({ $0 as? any PricedSolution }) {
            for region in s.regions(Params(s.parameters, solutionParams[s.id] ?? ParamValues())) { add(s.provider, region) }
        }
        for s in SolutionCatalog.custom {
            var refs = lastPriceRefs[s.id] ?? []
            for sel in s.regionSelections(Params(s.parameters, solutionParams[s.id] ?? ParamValues())) {
                refs += sel.regions.map { PriceRef(provider: sel.provider, region: $0) }
            }
            for ref in refs {
                if let p = CloudProvider(rawValue: ref.provider) ?? PriceLibrary.shared.entry(ref.provider)?.list.baseProvider { add(p, ref.region) }
            }
        }
        for ref in projectPriceRefs {
            if let p = CloudProvider(rawValue: ref.provider) { add(p, ref.region) }
        }
        return out
    }

    /// Custom price lists the project's custom solutions can read, so the project opens with the same rates elsewhere.
    private func projectPriceLists() -> [PriceList] {
        var ids = projectListIDs
        for s in SolutionCatalog.custom { ids.formUnion(s.providers.filter { CloudProvider(rawValue: $0) == nil }) }
        return ids.sorted().compactMap { PriceLibrary.shared.entry($0)?.list }
    }

    func saveProject() {
        if projectURL == nil { saveProjectAs() } else { writeProject() }
    }

    func saveProjectAs() {
        guard let ds = dataset, report != nil else { return }
        let panel = NSSavePanel()
        panel.title = "Save Project"
        panel.message = "Saves a copy of the export with all your settings. Save to iCloud Drive or a OneDrive folder to use it on other Macs."
        panel.allowedContentTypes = [.rvaProject]
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = (projectName.isEmpty ? defaultProjectName : projectName) + "." + ProjectFile.fileExtension
        guard panel.runModal() == .OK, var url = panel.url else { return }
        if !ProjectFile.isProject(url) { url.appendPathExtension(ProjectFile.fileExtension) }
        var p = snapshot()
        p.name = url.deletingPathExtension().lastPathComponent
        do {
            let saved: ProjectFile
            if let t = trend {
                saved = try ProjectFile.write(p, to: url, copyGroups: t.snapshots.map(\.sources), prices: projectPrices(), priceLists: projectPriceLists())
            } else {
                saved = try ProjectFile.write(p, to: url, copySources: ds.sources, prices: projectPrices(), priceLists: projectPriceLists())
            }
            finishSave(saved, url)
            addRecent(url)
        } catch {
            errorMessage = "Couldn't save the project: \(error.localizedDescription)"
        }
    }

    /// Rewrites the settings of the open project (its sources are already inside the package).
    func writeProject() {
        guard let url = projectURL else { return }
        do {
            finishSave(try ProjectFile.write(snapshot(), to: url, copySources: nil, prices: projectPrices(), priceLists: projectPriceLists()), url)
        } catch {
            errorMessage = "Couldn't save the project: \(error.localizedDescription)"
        }
    }

    private func finishSave(_ saved: ProjectFile, _ url: URL) {
        restoring = true
        currentProject = saved
        projectURL = url
        projectName = saved.name
        restoring = false
        lastSaved = saved.modified
        isDirty = false
    }

    /// Before a customized session is replaced or the app quits: saved projects are written silently, unsaved
    /// sessions offer to save. Returns false if the user cancels.
    func confirmDiscardChanges() -> Bool {
        guard isDirty, report != nil else { return true }
        if projectURL != nil {
            writeProject()
            return true
        }
        let alert = NSAlert()
        alert.messageText = "Save this session as a project?"
        alert.informativeText = "You've changed VM selections, assumptions or settings. Save them as a project to come back to them later."
        alert.addButton(withTitle: "Save…")
        alert.addButton(withTitle: "Don't Save")
        alert.addButton(withTitle: "Cancel")
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            saveProjectAs()
            return !isDirty
        case .alertSecondButtonReturn:
            // Discarded: don't ask again when closing the window leads straight into quitting.
            isDirty = false
            return true
        default:
            return false
        }
    }

    private static func loadRecents() -> [URL] {
        let bookmarks = AppDefaults.store.array(forKey: "recentProjects") as? [Data] ?? []
        return bookmarks.compactMap { data in
            var stale = false
            return try? URL(resolvingBookmarkData: data, bookmarkDataIsStale: &stale)
        }
        .filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    private func addRecent(_ url: URL) {
        var list = recentProjects.filter { $0.standardizedFileURL.path != url.standardizedFileURL.path }
        list.insert(url, at: 0)
        recentProjects = Array(list.prefix(10))
        AppDefaults.store.set(recentProjects.compactMap { try? $0.bookmarkData() }, forKey: "recentProjects")
    }

    func clearRecentProjects() {
        recentProjects = []
        AppDefaults.store.removeObject(forKey: "recentProjects")
    }

    func recompute() {
        guard let full = fullInventory else { return }
        let scope = scopes.first { $0.id == scopeID }
        let inv = scope?.clusterIDs.map { full.scoped(to: $0) } ?? full
        let t = thresholds
        let acks = acknowledgements
        generation += 1
        let gen = generation
        Task.detached(priority: .userInitiated) {
            let r = Analyzer.run(inv, thresholds: t, acknowledgements: acks)
            await MainActor.run {
                guard gen == self.generation else { return }
                self.report = r
                self.lookup = Lookup(r.inventory)
                self.reportVersion += 1
            }
        }
    }

    static func buildScopes(_ inv: Inventory) -> [ScopeOption] {
        var out = [ScopeOption(id: "all", label: "Entire environment", clusterIDs: nil)]
        let byVC = Dictionary(grouping: inv.clusters, by: { $0.vcenter })
        if byVC.count > 1 {
            for (i, (vc, cs)) in byVC.sorted(by: { $0.key < $1.key }).enumerated() {
                out.append(ScopeOption(id: "vc:" + vc, label: "vCenter \(vc)", clusterIDs: Set(cs.map(\.id)), isGroupStart: i == 0))
            }
        }
        let byDC = Dictionary(grouping: inv.clusters, by: { $0.vcenter + " / " + $0.datacenter })
        if byDC.count > 1 {
            for (i, (dc, cs)) in byDC.sorted(by: { $0.key < $1.key }).enumerated() {
                let label = byVC.count > 1 ? "Datacenter \(dc)" : "Datacenter \(cs.first?.datacenter ?? dc)"
                out.append(ScopeOption(id: "dc:" + dc, label: label, clusterIDs: Set(cs.map(\.id)), isGroupStart: i == 0))
            }
        }
        for (i, c) in inv.clusters.enumerated() {
            out.append(ScopeOption(id: c.id, label: byVC.count > 1 ? "\(c.name) — \(c.vcenter)" : c.name, clusterIDs: [c.id], isGroupStart: i == 0))
        }
        return out
    }

    // MARK: Navigation

    func reveal(vm id: String) {
        selectedVMID = id
        sidebar = .vms
    }

    func reveal(host id: String) {
        selectedHostID = id
        computeTab = 1
        sidebar = .compute
    }

    func reveal(datastore id: String) {
        selectedDatastoreID = id
        storageTab = 1
        sidebar = .storage
    }

    func reveal(portGroup id: String) {
        selectedPortGroupID = id
        networkTab = 0
        sidebar = .network
    }

    func reveal(_ f: Finding) {
        switch f.kind {
        case .vm where lookup.vms[f.objectID] != nil: reveal(vm: f.objectID)
        case .host where lookup.hosts[f.objectID] != nil: reveal(host: f.objectID)
        case .datastore where lookup.datastores[f.objectID] != nil: reveal(datastore: f.objectID)
        case .network where lookup.portGroups[f.objectID] != nil: reveal(portGroup: f.objectID)
        case .cluster: computeTab = 0; sidebar = .compute
        default: break
        }
    }

    func showIssues(rule: String? = nil) {
        focusRule = rule
        sidebar = .issues
    }

    // MARK: Acknowledgements

    /// Acknowledges findings one by one (they reappear if the check finds a different object).
    func acknowledge(_ findings: [Finding], note: String) {
        var list = acknowledgements
        var keys = Set(list.map(\.key))
        for f in findings where keys.insert(f.acknowledgementKey).inserted { list.append(Acknowledgement(finding: f, note: note)) }
        acknowledgements = list
    }

    /// Acknowledges a whole check, including findings that appear later; replaces its individual acknowledgements.
    func acknowledgeCheck(_ rule: String, note: String) {
        acknowledgements = acknowledgements.filter { $0.rule != rule } + [Acknowledgement(rule: rule, note: note)]
    }

    /// Brings findings back, removing their own acknowledgements and, if `wholeCheck`, the check's.
    func restore(_ findings: [Finding], wholeCheck rule: String? = nil) {
        let keys = Set(findings.map(\.acknowledgementKey))
        acknowledgements = acknowledgements.filter { !keys.contains($0.key) && !(rule != nil && $0.rule == rule && $0.isWholeCheck) }
    }

    func restore(_ acknowledgement: Acknowledgement) {
        acknowledgements = acknowledgements.filter { $0.key != acknowledgement.key }
    }

    // MARK: Solutions

    private static func loadSolutionParams() -> [String: ParamValues] {
        guard let data = AppDefaults.store.data(forKey: "solutionParams"),
              let v = try? JSONDecoder().decode([String: ParamValues].self, from: data) else { return [:] }
        return v
    }

    /// Result for the current selection / assumptions / scope, cached until any of them change. Custom solutions run
    /// in the background: nil while running (see `latestScriptResults`), then `scriptRunVersion` changes.
    func result(for s: any Solution) -> SolutionResult? {
        guard let r = report else { return nil }
        let sets = s.selections.map { solutionSelections[$0.key(s.id)] ?? [] }
        let values = solutionParams[s.id] ?? ParamValues()
        let custom = s is ScriptedSolution
        let prices = custom ? "\(priceVersion).\(PriceLibrary.shared.version).\(extensionsVersion)" : "\(PriceStore.shared.version)"
        let rates = custom ? trend?.rates : nil
        // Solutions a custom one reads (context.solutions) run with their own selections and assumptions, so those are part of the key.
        let companions = (s as? ScriptedSolution)?.companions ?? []
        let companionState: [String: (selections: [String: Set<String>], values: ParamValues)] = Dictionary(uniqueKeysWithValues: companions.compactMap { id in
            SolutionCatalog.solution(id: id).map { c in
                (id, (Dictionary(uniqueKeysWithValues: c.selections.compactMap { sel in solutionSelections[sel.key(id)].map { (sel.id, $0) } }),
                      solutionParams[id] ?? ParamValues()))
            }
        })
        let companionKey = companions.map { id in
            let state = companionState[id]
            return "\(id):\(state?.values.hashValue ?? 0):\(state?.selections.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value.hashValue)" }.joined(separator: ";") ?? "")"
        }.joined(separator: ",") + (companions.isEmpty ? "" : "|\(PriceStore.shared.version)")
        let key = "\(s.id)|\(reportVersion)|\(prices)|\(sets.map { String($0.hashValue) }.joined(separator: ","))|\(values.hashValue)|\(rates?.hashValue ?? 0)|\(companionKey)"
        if let cached = solutionCache[key] { return cached }
        var selected: [String: [VM]] = [:]
        for (sel, ids) in zip(s.selections, sets) { selected[sel.id] = r.inventory.vms.filter { ids.contains($0.id) } }
        let vms = selected[s.selections[0].id] ?? []
        guard custom else {
            let result = s.run(vms: vms, selections: selected, inventory: r.inventory, values: values)
            if solutionCache.count > 16 { solutionCache.removeAll() }
            solutionCache[key] = result
            return result
        }
        if runningScripts.insert(key).inserted {
            let inventory = r.inventory
            let groups = r.groups
            let runnable: any Solution = {
                guard var scripted = s as? ScriptedSolution else { return s }
                scripted.trend = rates
                scripted.findings = groups
                scripted.companionResults = { id in
                    let state = companionState[id]
                    return SolutionCatalog.runCompanion(id: id, inventory: inventory, selections: state.map { $0.selections.isEmpty ? nil : $0.selections } ?? nil,
                                                        values: state?.values ?? ParamValues())
                }
                return scripted
            }()
            Task.detached(priority: .userInitiated) {
                let result = runnable.run(vms: vms, selections: selected, inventory: inventory, values: values)
                await MainActor.run {
                    self.runningScripts.remove(key)
                    if self.solutionCache.count > 16 { self.solutionCache.removeAll() }
                    self.solutionCache[key] = result
                    self.lastPriceRefs[s.id] = result.priceRefs
                    self.latestScriptResults[s.id] = result
                    self.scriptRunVersion += 1
                }
            }
        }
        return nil
    }

    /// Loads cached price files for the solution's regions (no network).
    func loadCachedPrices(_ s: any PricedSolution) {
        let regions = s.regions(Params(s.parameters, solutionParams[s.id] ?? ParamValues()))
        let before = PriceStore.shared.version
        PriceStore.shared.loadFromDisk(s.provider, regions: regions)
        if PriceStore.shared.version != before { priceVersion += 1 }
    }

    /// Downloads public list prices for the solution's regions (only when the user asks).
    func downloadPrices(_ s: any PricedSolution, force: Bool) {
        downloadPrices([(s.provider, s.regions(Params(s.parameters, solutionParams[s.id] ?? ParamValues())))], force: force)
    }

    /// Downloads public list prices for regions of one or more providers (only when the user asks).
    func downloadPrices(_ requests: [(provider: CloudProvider, regions: [String])], force: Bool) {
        let needed = requests.map { r in (r.provider, force ? r.regions : r.regions.filter { PriceStore.shared.cachedPrices(r.provider, $0) == nil }) }
            .filter { !$0.1.isEmpty }
        guard !needed.isEmpty else { return }
        let count = needed.reduce(0) { $0 + $1.1.count }
        priceLoading = true
        priceError = nil
        priceStatus = "Downloading \(needed.map(\.0.name).joined(separator: " and ")) prices for \(count) region\(count == 1 ? "" : "s")…"
        Task.detached {
            var errors: [String: String] = [:]
            for (provider, regions) in needed {
                for (region, error) in await PriceStore.shared.download(provider, regions: regions) {
                    errors[needed.count > 1 ? "\(provider.name) \(region)" : region] = error
                }
            }
            let failures = errors
            await MainActor.run {
                self.priceLoading = false
                self.priceVersion += 1
                self.noteChange()   // new price snapshots belong in the project
                self.priceError = failures.isEmpty ? nil
                    : "Failed: " + failures.sorted { $0.key < $1.key }.map { "\($0.key) (\($0.value))" }.joined(separator: ", ")
            }
        }
    }

    func exportSolution(_ s: any Solution) {
        guard let r = report, let result = result(for: s) else { return }
        let panel = NSOpenPanel()
        panel.title = "Export \(s.title)"
        panel.message = "Choose a folder for the report (Markdown) and its tables (CSV)."
        panel.prompt = "Export Here"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let dir = panel.url else { return }
        let base = "\(exportBaseName)_\(s.id)"
        let subtitle = "\(sourceSummary) · exported \(Fmt.dateTime(r.inventory.reportDate)) · scope: \(scopeLabel)"
        write(result.markdown(title: s.title, subtitle: subtitle), to: dir.appendingPathComponent(base + ".md"))
        for file in result.csvFiles() { write(file.content, to: dir.appendingPathComponent("\(base)_\(file.name).csv")) }
        for sel in s.selections {
            let ids = solutionSelections[sel.key(s.id)] ?? []
            let name = sel.isPrimary ? "selected-vms" : "selected-" + sel.id
            write(CSVExport.selection(r.inventory.vms.filter { ids.contains($0.id) }), to: dir.appendingPathComponent("\(base)_\(name).csv"))
        }
        NSWorkspace.shared.activateFileViewerSelecting([dir.appendingPathComponent(base + ".md")])
    }

    /// Title-slide lines suggested for a solution's deck.
    func deckDefaults(_ s: any Solution) -> (subtitle: String, date: String) {
        let date = report.map { "Exported \(Fmt.date($0.inventory.reportDate))" } ?? ""
        return (projectName.isEmpty ? sourceSummary : projectName, scopeID == "all" ? date : date + " · " + scopeLabel)
    }

    func exportDeck(_ s: any Solution, _ options: DeckOptions) {
        guard let result = result(for: s) else { return }
        let data: Data
        do { data = try result.pptx(options) } catch {
            errorMessage = "Could not build the deck: \(error.localizedDescription)"
            return
        }
        let panel = NSSavePanel()
        panel.title = "Export \(s.title) as PowerPoint"
        panel.allowedContentTypes = [UTType(filenameExtension: "pptx") ?? .data]
        panel.nameFieldStringValue = "\(exportBaseName)_\(s.id).pptx"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try data.write(to: url, options: .atomic) } catch {
            errorMessage = "Could not write \(url.lastPathComponent): \(error.localizedDescription)"
            return
        }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    func canReveal(_ kind: ObjectKind, _ id: String) -> Bool {
        switch kind {
        case .vm: return lookup.vms[id] != nil
        case .host: return lookup.hosts[id] != nil
        case .datastore: return lookup.datastores[id] != nil
        case .network: return lookup.portGroups[id] != nil
        case .cluster: return lookup.clusters[id] != nil
        default: return false
        }
    }

    func reveal(_ kind: ObjectKind, _ id: String) {
        switch kind {
        case .vm: reveal(vm: id)
        case .host: reveal(host: id)
        case .datastore: reveal(datastore: id)
        case .network: reveal(portGroup: id)
        case .cluster: computeTab = 0; sidebar = .compute
        default: break
        }
    }

    /// Default VM ids for every selection of the given solutions, keyed like `solutionSelections`.
    static func defaultSelections(_ solutions: [any Solution], _ inv: Inventory) -> [String: Set<String>] {
        var out: [String: Set<String>] = [:]
        for s in solutions {
            for sel in s.selections { out[sel.key(s.id)] = s.defaultSelection(inv, for: sel) }
        }
        return out
    }

    // MARK: Custom solutions and price lists

    static func isExtensionFile(_ url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        return ext == PriceList.fileExtension || ext == SolutionLibrary.packExtension
            || FileManager.default.fileExists(atPath: url.appendingPathComponent("manifest.json").path)
    }

    /// Custom solutions the open project has settings for that aren't installed or are turned off.
    var missingSolutionIDs: [String] {
        let _ = extensionsVersion
        return projectSolutionIDs.subtracting(SolutionCatalog.all.map(\.id)).sorted()
    }

    var bundledExamplesURL: URL? { Bundle.main.url(forResource: "Examples", withExtension: nil) }
    var authoringGuideURL: URL? { Bundle.main.url(forResource: "SOLUTIONS", withExtension: "md") }

    private func startExtensions() {
        SolutionLibrary.shared.disabled = Set(AppDefaults.store.stringArray(forKey: "disabledSolutions") ?? [])
        let fm = FileManager.default
        try? fm.createDirectory(at: SolutionLibrary.directory, withIntermediateDirectories: true)
        try? fm.createDirectory(at: PriceLibrary.directory, withIntermediateDirectories: true)
        SolutionLibrary.shared.reload()
        // Edits to packs and price lists (including a solution.js being written) reload automatically.
        // FSEvents doesn't follow symlinks, so watch where symlinked folders (e.g. on OneDrive) really are.
        let paths = (SolutionLibrary.shared.searchDirectories + [PriceLibrary.directory]).map { $0.resolvingSymlinksInPath().path }
        extensionWatcher = ExtensionWatcher(paths: paths) {
            Task { @MainActor in AppModel.shared.scheduleExtensionReload() }
        }
    }

    func scheduleExtensionReload() {
        reloadTask?.cancel()
        reloadTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard !Task.isCancelled else { return }
            self?.reloadExtensions()
        }
    }

    func reloadExtensions() {
        SolutionLibrary.shared.reload()
        extensionsChanged()
    }

    private func extensionsChanged() {
        solutionCache = solutionCache.filter { SolutionCatalog.isBuiltIn(String($0.key.prefix { $0 != "|" })) }
        if let inv = fullInventory {
            let wasRestoring = restoring
            restoring = true
            for (key, ids) in AppModel.defaultSelections(SolutionCatalog.custom, inv) where solutionSelections[key] == nil { solutionSelections[key] = ids }
            restoring = wasRestoring
        }
        extensionsVersion += 1
    }

    func isSolutionEnabled(_ id: String) -> Bool { !SolutionLibrary.shared.disabled.contains(id) }

    func setSolutionEnabled(_ id: String, _ enabled: Bool) {
        var disabled = SolutionLibrary.shared.disabled
        if enabled { disabled.remove(id) } else { disabled.insert(id) }
        SolutionLibrary.shared.disabled = disabled
        AppDefaults.store.set(disabled.sorted(), forKey: "disabledSolutions")
        extensionsChanged()
    }

    func presentInstallPanel() {
        let panel = NSOpenPanel()
        panel.title = "Install Solution or Price List"
        panel.message = "Choose custom solution folders (.rvasolution, with a manifest.json inside) or price lists (.rvaprices)."
        panel.prompt = "Install"
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.allowedContentTypes = [.folder, UTType(filenameExtension: PriceList.fileExtension)].compactMap { $0 }
        if panel.runModal() == .OK { installExtensions(panel.urls) }
    }

    /// Copies solution packs into the Solutions folder and price lists into the Price Lists folder.
    func installExtensions(_ urls: [URL]) {
        var installed: [String] = []
        var failed: [String] = []
        var newSolution: String?
        for url in urls {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            do {
                if url.pathExtension.lowercased() == PriceList.fileExtension {
                    installed.append("the price list “\(try PriceLibrary.shared.install(url).name)”")
                } else {
                    let s = try SolutionLibrary.shared.install(url)
                    installed.append("“\(s.title)”")
                    newSolution = s.id
                }
            } catch {
                failed.append("\(url.lastPathComponent): \(error.localizedDescription)")
            }
        }
        reloadExtensions()
        if let id = newSolution, !isSolutionEnabled(id) { newSolution = nil }
        let alert = NSAlert()
        if failed.isEmpty {
            alert.messageText = "Installed " + ListFormatter.localizedString(byJoining: installed)
            alert.informativeText = newSolution != nil && report != nil ? "Find it under Custom Solutions in the sidebar." : "Custom solutions appear in the sidebar once an export is open."
        } else {
            alert.alertStyle = .warning
            alert.messageText = installed.isEmpty ? "Nothing was installed" : "Installed " + ListFormatter.localizedString(byJoining: installed) + ", with problems"
            alert.informativeText = failed.joined(separator: "\n\n")
        }
        alert.runModal()
        if let id = newSolution, report != nil, let s = SolutionCatalog.solution(id: id) { sidebar = .solution(s) }
    }

    /// Copies the example solutions and price lists bundled with the app.
    func installExamples() {
        guard let root = bundledExamplesURL else { return }
        let fm = FileManager.default
        func items(_ folder: String, _ ext: String) -> [URL] {
            ((try? fm.contentsOfDirectory(at: root.appendingPathComponent(folder), includingPropertiesForKeys: nil)) ?? [])
                .filter { $0.pathExtension == ext }.sorted { $0.lastPathComponent < $1.lastPathComponent }
        }
        installExtensions(items("solutions", SolutionLibrary.packExtension) + items("price-lists", PriceList.fileExtension))
    }

    func removeSolution(_ s: ScriptedSolution) {
        guard confirmTrash("Move “\(s.title)” to the Trash?", "Projects keep its VM selection and assumptions, so reinstalling it brings the results back.") else { return }
        do { try SolutionLibrary.shared.remove(s.id) } catch { errorMessage = error.localizedDescription }
        reloadExtensions()
    }

    func removePriceList(_ entry: PriceLibrary.Entry) {
        guard confirmTrash("Move “\(entry.list.name)” to the Trash?", "Solutions that read it will report it as not installed.") else { return }
        do { try PriceLibrary.shared.remove(entry.id) } catch { errorMessage = error.localizedDescription }
        reloadExtensions()
    }

    private func confirmTrash(_ title: String, _ detail: String) -> Bool {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = detail
        alert.addButton(withTitle: "Move to Trash")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }

    func showInFinder(_ url: URL) { NSWorkspace.shared.activateFileViewerSelecting([url]) }
    func openFile(_ url: URL) { NSWorkspace.shared.open(url) }
    func openAuthoringGuide() { if let url = authoringGuideURL { NSWorkspace.shared.open(url) } }

    func openFolder(_ url: URL) {
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        NSWorkspace.shared.open(url)
    }

    // MARK: Export

    var exportBaseName: String {
        let base = sources.first?.deletingPathExtension().lastPathComponent ?? "RVTools"
        return scopeID == "all" ? base : base + "_" + scopeLabel.replacingOccurrences(of: " ", with: "_").replacingOccurrences(of: "/", with: "-")
    }

    func export(_ kind: ExportKind) {
        guard let r = report else { return }
        let panel = NSSavePanel()
        panel.title = "Export \(kind.rawValue)"
        panel.allowedContentTypes = [.commaSeparatedText]
        panel.nameFieldStringValue = "\(exportBaseName)_\(kind.fileSuffix).csv"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        write(kind.content(r), to: url)
    }

    func exportAll() {
        guard let r = report else { return }
        let panel = NSOpenPanel()
        panel.title = "Export all CSV files"
        panel.prompt = "Export Here"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let dir = panel.url else { return }
        for kind in ExportKind.allCases { write(kind.content(r), to: dir.appendingPathComponent("\(exportBaseName)_\(kind.fileSuffix).csv")) }
        NSWorkspace.shared.activateFileViewerSelecting([dir])
    }

    private func write(_ content: String, to url: URL) {
        do { try content.write(to: url, atomically: true, encoding: .utf8) } catch {
            errorMessage = "Could not write \(url.lastPathComponent): \(error.localizedDescription)"
        }
    }
}
