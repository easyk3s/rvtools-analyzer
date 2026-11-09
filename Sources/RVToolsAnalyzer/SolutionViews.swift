import RVToolsCore
import SwiftUI
import UniformTypeIdentifiers

extension CheckStatus {
    var color: Color {
        switch self {
        case .blocker: return Palette.critical
        case .warning: return Palette.warning
        case .info: return Palette.severity(.info)
        case .ready: return Palette.good
        }
    }
}

extension ValueFormat {
    func format(_ v: Double) -> String {
        switch self {
        case .count: return Fmt.int(Int(v.rounded()))
        case .capacityMiB: return Fmt.capacity(mib: v)
        case .currency: return "$" + Fmt.int(Int(v.rounded()))
        case .number(let unit): return Fmt.num(v, 1) + (unit.isEmpty ? "" : " " + unit)
        }
    }
}

struct StatusBadge: View {
    let status: CheckStatus
    var showLabel = true

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: status.symbol).foregroundStyle(status.color)
            if showLabel { Text(status.label) }
        }
        .help(status.label)
    }
}

/// A solution page: 1 · select VMs, 2 · assumptions, 3 · results.
struct SolutionView: View {
    @Environment(AppModel.self) private var model
    let solution: any Solution
    let report: Report
    @State private var activeSelection = 0
    @State private var showDeckSheet = false

    private var active: SolutionSelection {
        let list = solution.selections
        return list[min(activeSelection, list.count - 1)]
    }

    private var selection: Binding<Set<String>> {
        let key = active.key(solution.id)
        return Binding(get: { model.solutionSelections[key] ?? [] }, set: { model.solutionSelections[key] = $0 })
    }

    private func count(_ sel: SolutionSelection) -> Int {
        let ids = model.solutionSelections[sel.key(solution.id)] ?? []
        return report.inventory.vms.filter { ids.contains($0.id) }.count
    }

    private var values: Binding<ParamValues> {
        Binding(get: { model.solutionParams[solution.id] ?? ParamValues() }, set: { model.solutionParams[solution.id] = $0 })
    }

    private var tab: Binding<Int> {
        Binding(get: { model.solutionTab[solution.id] ?? 0 }, set: { model.solutionTab[solution.id] = $0 })
    }

    var body: some View {
        let selected = model.solutionSelections[solution.id] ?? []
        let inScope = report.inventory.vms.filter { selected.contains($0.id) }.count
        VStack(spacing: 0) {
            HStack(alignment: .center, spacing: 12) {
                Image(systemName: solution.symbol).font(.system(size: 26)).foregroundStyle(Palette.primary)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(solution.title).font(.title3.weight(.semibold))
                        if let custom = solution as? ScriptedSolution { CustomBadge(solution: custom) }
                    }
                    Text(solution.summary).font(.callout).foregroundStyle(.secondary).lineLimit(2)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    if solution.selections.count > 1 {
                        Text(solution.selections.map { "\(Fmt.int(count($0))) \($0.label)" }.joined(separator: " · ")).font(.callout.weight(.medium))
                    } else {
                        Text("\(Fmt.int(inScope)) VMs selected").font(.callout.weight(.medium))
                    }
                    if selected.count > inScope {
                        Text("\(selected.count - inScope) outside the current scope").font(.caption).foregroundStyle(.secondary)
                    }
                }
                Menu {
                    Button("Report (Markdown and CSV)…") { model.exportSolution(solution) }
                    Button("PowerPoint Deck…") { showDeckSheet = true }
                } label: {
                    Label("Export…", systemImage: "square.and.arrow.up")
                } primaryAction: {
                    model.exportSolution(solution)
                }
                .menuStyle(.borderedButton).fixedSize()
                .help("Export the report as Markdown and CSV, or pick PowerPoint from the menu")
                .disabled(inScope == 0)
                .sheet(isPresented: $showDeckSheet) { DeckExportSheet(solution: solution, result: model.result(for: solution)).environment(model) }
                if let custom = solution as? ScriptedSolution { CustomSolutionMenu(solution: custom) }
            }
            .padding(.horizontal, 20).padding(.vertical, 12)
            if let priced = solution as? any PricedSolution {
                PriceBar(solution: priced)
            }
            if let custom = solution as? ScriptedSolution, !custom.providers.isEmpty {
                CustomPriceBar(solution: custom)
            }
            Picker("Step", selection: tab) {
                Text("1 · Select VMs").tag(0)
                Text("2 · Assumptions").tag(1)
                Text("3 · Results").tag(2)
            }
            .pickerStyle(.segmented).labelsHidden().frame(width: 420).padding(.bottom, 10)
            Divider()
            switch tab.wrappedValue {
            case 0:
                if solution.selections.count > 1 {
                    HStack(spacing: 12) {
                        Picker("Selection", selection: $activeSelection) {
                            ForEach(Array(solution.selections.enumerated()), id: \.offset) { i, sel in
                                Text("\(sel.label) (\(Fmt.int(count(sel))))").tag(i)
                            }
                        }
                        .pickerStyle(.segmented).labelsHidden().fixedSize()
                        Text(active.help.isEmpty ? "Choose which selection the checkboxes below edit." : active.help)
                            .font(.caption).foregroundStyle(.secondary).lineLimit(2)
                        Spacer()
                    }
                    .padding(.horizontal, 14).padding(.top, 10)
                }
                VMSelectionView(vms: report.inventory.vms, selection: selection,
                                badges: solution.selections.filter { $0 != active }.map { ($0.label, model.solutionSelections[$0.key(solution.id)] ?? []) })
            case 1:
                let showsSizingPreview = solution.id == "odin-azure-local"
                let _ = model.scriptRunVersion
                let sizingPreview = showsSizingPreview ? model.result(for: solution) : nil
                AssumptionsForm(solutionID: solution.id, parameters: solution.parameters, values: values,
                                showsSizingPreview: showsSizingPreview, sizingPreview: sizingPreview)
            default:
                let _ = model.priceVersion
                let _ = model.scriptRunVersion
                let _ = model.extensionsVersion
                if let result = model.result(for: solution) {
                    SolutionResultView(result: result)
                        .environment(\.applySolutionAction) { action in
                            var v = values.wrappedValue
                            for (id, value) in action.values { v.values[id] = value }
                            values.wrappedValue = v
                        }
                } else if let previous = model.latestScriptResults[solution.id] {
                    SolutionResultView(result: previous)
                        .opacity(0.5)
                        .overlay { ProgressView("Updating…").padding(16).background(RoundedRectangle(cornerRadius: 10).fill(.regularMaterial)) }
                } else if solution is ScriptedSolution {
                    ProgressView("Running \(solution.title)…").frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
    }
}

/// Price-list status and download control for solutions that need cloud prices.
private struct PriceBar: View {
    @Environment(AppModel.self) private var model
    let solution: any PricedSolution

    var body: some View {
        let regions = solution.regions(Params(solution.parameters, model.solutionParams[solution.id] ?? ParamValues()))
        let _ = model.priceVersion
        let loaded = regions.compactMap { PriceStore.shared.prices(solution.provider, $0) }
        let oldest = loaded.map(\.fetched).min()
        HStack(spacing: 10) {
            Image(systemName: "dollarsign.circle").foregroundStyle(Palette.primary)
            if model.priceLoading {
                ProgressView().controlSize(.small)
                Text(model.priceStatus)
            } else {
                Text("\(solution.provider.name) list prices: \(loaded.count) of \(regions.count) regions" + (oldest.map { " · downloaded \(Fmt.dateTime($0))" } ?? ""))
                if let error = model.priceError {
                    Text(error).foregroundStyle(Palette.critical).lineLimit(1).help(error)
                }
            }
            Spacer()
            Text("Only public price lists are downloaded — no inventory data is sent.").font(.caption).foregroundStyle(.secondary)
            Button(loaded.count < regions.count ? "Download Prices" : "Refresh Prices") {
                model.downloadPrices(solution, force: loaded.count == regions.count)
            }
            .disabled(model.priceLoading || regions.isEmpty)
        }
        .font(.callout)
        .padding(.horizontal, 20).padding(.vertical, 7)
        .background(Palette.track.opacity(0.5))
        .onAppear { model.loadCachedPrices(solution) }
        .onChange(of: regions) { model.loadCachedPrices(solution) }
    }
}

/// Marks a solution that comes from a pack rather than the app.
private struct CustomBadge: View {
    let solution: ScriptedSolution

    var body: some View {
        Text("Custom")
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(Capsule().fill(Palette.primary.opacity(0.15)))
            .foregroundStyle(Palette.primary)
            .help("Custom solution\(solution.version.isEmpty ? "" : " " + solution.version)\(solution.author.isEmpty ? "" : " by " + solution.author) — \(solution.packURL.path)")
    }
}

private struct CustomSolutionMenu: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openSettings) private var openSettings
    let solution: ScriptedSolution

    var body: some View {
        Menu {
            Button("Reload Custom Solutions") { model.reloadExtensions() }
            Button("Open \(solution.scriptURL.lastPathComponent)") { model.openFile(solution.scriptURL) }
            Button("Show in Finder") { model.showInFinder(solution.packURL) }
            Divider()
            Button("Manage Solutions…") {
                AppDefaults.store.set("solutions", forKey: "settingsTab")
                openSettings()
            }
        } label: {
            Image(systemName: "puzzlepiece.extension")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Custom solution")
    }
}

/// Price status for custom solutions: the providers they read, and downloads for the built-in list prices they need.
private struct CustomPriceBar: View {
    @Environment(AppModel.self) private var model
    let solution: ScriptedSolution

    var body: some View {
        let _ = model.priceVersion
        let _ = model.extensionsVersion
        let params = Params(solution.parameters, model.solutionParams[solution.id] ?? ParamValues())
        let requests = downloads(params)
        let missing = requests.reduce(0) { total, r in
            let available = Set(PriceStore.shared.availableRegions(r.provider))
            return total + r.regions.filter { !available.contains($0) }.count
        }
        let text = summary(params)
        HStack(spacing: 10) {
            Image(systemName: "dollarsign.circle").foregroundStyle(Palette.primary)
            if model.priceLoading {
                ProgressView().controlSize(.small)
                Text(model.priceStatus)
            } else {
                Text(text).lineLimit(1).help(text)
                if let error = model.priceError {
                    Text(error).foregroundStyle(Palette.critical).lineLimit(1).help(error)
                }
            }
            Spacer()
            if solution.allowsDownload && !requests.isEmpty {
                Text("Only public price lists are downloaded — no inventory data is sent.").font(.caption).foregroundStyle(.secondary)
                Button(missing > 0 ? "Download Prices" : "Refresh Prices") {
                    model.downloadPrices(requests, force: missing == 0)
                }
                .disabled(model.priceLoading)
            } else {
                Text("Reads prices already on this Mac — nothing is downloaded.").font(.caption).foregroundStyle(.secondary)
            }
        }
        .font(.callout)
        .padding(.horizontal, 20).padding(.vertical, 7)
        .background(Palette.track.opacity(0.5))
    }

    /// Built-in list prices the chosen regions need, including price lists based on Azure / AWS prices.
    private func downloads(_ params: Params) -> [(provider: CloudProvider, regions: [String])] {
        var byProvider: [CloudProvider: [String]] = [:]
        for sel in solution.regionSelections(params) {
            guard let base = CloudProvider(rawValue: sel.provider) ?? PriceLibrary.shared.entry(sel.provider)?.list.baseProvider else { continue }
            for region in sel.regions where !(byProvider[base]?.contains(region) ?? false) { byProvider[base, default: []].append(region) }
        }
        return CloudProvider.allCases.compactMap { p in byProvider[p].map { (p, $0) } }
    }

    private func summary(_ params: Params) -> String {
        let selections = solution.regionSelections(params)
        return solution.providers.map { id -> String in
            let info = PriceLibrary.shared.info(id)
            guard info.installed else { return "\(id): not installed" }
            let chosen = Array(Set(selections.filter { $0.provider == id }.flatMap(\.regions)))
            if chosen.isEmpty { return "\(info.name): \(info.regions.count) region\(info.regions.count == 1 ? "" : "s")" }
            return "\(info.name): \(chosen.filter(info.regions.contains).count) of \(chosen.count) regions"
        }.joined(separator: " · ")
    }
}

// MARK: - VM selection

struct VMSelectionView: View {
    let vms: [VM]
    @Binding var selection: Set<String>
    /// The solution's other selections, shown as badges next to the VMs they include.
    var badges: [(label: String, ids: Set<String>)] = []
    @State private var search = ""
    @State private var cluster = "All clusters"
    @State private var power = 0
    @State private var family = "All OS families"
    @State private var showTemplates = false
    @State private var includedOnly = false
    @State private var highlighted: Set<String> = []
    @State private var sortOrder = [KeyPathComparator(\VM.name)]

    private static func clusterLabel(_ vm: VM) -> String { vm.cluster.isEmpty ? "(no cluster)" : vm.cluster }

    private var shown: [VM] {
        let q = search.lowercased().trimmingCharacters(in: .whitespaces)
        var r = vms.filter { showTemplates || !$0.isTemplate }
        if cluster != "All clusters" { r = r.filter { VMSelectionView.clusterLabel($0) == cluster } }
        if power == 1 { r = r.filter(\.isRunning) } else if power == 2 { r = r.filter { !$0.isRunning } }
        if family != "All OS families" { r = r.filter { $0.os.family.rawValue == family } }
        if includedOnly { r = r.filter { selection.contains($0.id) } }
        if !q.isEmpty { r = r.filter { VMsView.searchText($0).contains(q) } }
        return r.sorted(using: sortOrder)
    }

    var body: some View {
        let rows = shown
        VStack(spacing: 0) {
            filterBar
            actionBar(rows)
            Divider()
            table(rows)
        }
    }

    private var filterBar: some View {
        HStack(spacing: 10) {
            TextField("Filter: name, host, OS, folder, network, IP, notes", text: $search)
                .textFieldStyle(.roundedBorder).frame(minWidth: 220, maxWidth: 320)
            Picker("Cluster", selection: $cluster) {
                Text("All clusters").tag("All clusters")
                ForEach(Array(Set(vms.map(VMSelectionView.clusterLabel))).sorted(), id: \.self) { Text($0).tag($0) }
            }
            .frame(width: 200)
            Picker("Power", selection: $power) {
                Text("All").tag(0)
                Text("On").tag(1)
                Text("Off").tag(2)
            }
            .pickerStyle(.segmented).labelsHidden().frame(width: 130).help("Power state")
            Picker("OS", selection: $family) {
                Text("All OS families").tag("All OS families")
                ForEach(OSFamily.allCases, id: \.self) { Text($0.rawValue).tag($0.rawValue) }
            }
            .frame(width: 210)
            Toggle("Templates", isOn: $showTemplates).toggleStyle(.checkbox)
            Toggle("Selected only", isOn: $includedOnly).toggleStyle(.checkbox)
            Spacer()
        }
        .padding(.horizontal, 14).padding(.top, 10).padding(.bottom, 6)
    }

    private func actionBar(_ rows: [VM]) -> some View {
        let ids = rows.map(\.id)
        let chosen = vms.filter { selection.contains($0.id) }
        return HStack(spacing: 8) {
            Button("Add Shown (\(Fmt.int(ids.count)))") { selection.formUnion(ids) }
            Button("Remove Shown") { selection.subtract(ids) }
            Button("Only Shown") { selection = Set(ids) }
            Divider().frame(height: 16)
            Button("Add Highlighted") { selection.formUnion(highlighted) }.disabled(highlighted.isEmpty)
            Button("Remove Highlighted") { selection.subtract(highlighted) }.disabled(highlighted.isEmpty)
            Divider().frame(height: 16)
            Button("All VMs") { selection = Set(vms.filter { !$0.isTemplate }.map(\.id)) }
            Button("None") { selection = [] }
            Spacer()
            Text("\(Fmt.int(chosen.count)) selected · \(Fmt.int(chosen.reduce(0) { $0 + $1.cpus })) vCPU · "
                + "\(Fmt.memory(mib: chosen.reduce(0) { $0 + $1.memoryMiB })) vRAM · \(Fmt.capacity(mib: chosen.reduce(0) { $0 + $1.inUseMiB })) in use")
                .font(.callout).foregroundStyle(.secondary).tabular()
        }
        .controlSize(.small)
        .padding(.horizontal, 14).padding(.bottom, 8)
    }

    private func table(_ rows: [VM]) -> some View {
        Table(rows, selection: $highlighted, sortOrder: $sortOrder) {
            Group {
                TableColumn("✓", sortUsing: KeyPathComparator(\VM.name)) { (vm: VM) in IncludeToggle(id: vm.id, selection: $selection) }.width(26)
                TableColumn("Name", sortUsing: KeyPathComparator(\VM.name)) { (vm: VM) in
                    SelectionNameCell(vm: vm, badges: badges.filter { $0.ids.contains(vm.id) }.map(\.label) + (vm.notInVInfo ? ["Not in vInfo"] : []))
                }
                .width(min: 150, ideal: badges.isEmpty ? 220 : 300)
                TableColumn("Cluster", sortUsing: KeyPathComparator(\VM.cluster)) { (vm: VM) in Text(vm.cluster) }
                TableColumn("Host", sortUsing: KeyPathComparator(\VM.host)) { (vm: VM) in Text(VMsView.shortHost(vm)) }
                TableColumn("Guest OS", sortUsing: KeyPathComparator(\VM.osName)) { (vm: VM) in Text(vm.os.name) }.width(min: 110, ideal: 160)
            }
            Group {
                TableColumn("vCPU", sortUsing: KeyPathComparator(\VM.cpus)) { (vm: VM) in Text("\(vm.cpus)").tabular() }.width(44)
                TableColumn("Memory", sortUsing: KeyPathComparator(\VM.memoryMiB)) { (vm: VM) in Text(Fmt.memory(mib: vm.memoryMiB)).tabular() }.width(70)
                TableColumn("In use", sortUsing: KeyPathComparator(\VM.inUseMiB)) { (vm: VM) in Text(Fmt.capacity(mib: vm.inUseMiB)).tabular() }.width(75)
                TableColumn("Provisioned", sortUsing: KeyPathComparator(\VM.provisionedMiB)) { (vm: VM) in Text(Fmt.capacity(mib: vm.provisionedMiB)).tabular() }.width(85)
                TableColumn("Folder", sortUsing: KeyPathComparator(\VM.folder)) { (vm: VM) in Text(vm.folder) }
            }
        }
    }
}

private struct IncludeToggle: View {
    let id: String
    @Binding var selection: Set<String>

    var body: some View {
        Toggle("Include", isOn: Binding(get: { selection.contains(id) }, set: { on in
            if on { selection.insert(id) } else { selection.remove(id) }
        }))
        .labelsHidden()
        .toggleStyle(.checkbox)
    }
}

private struct SelectionNameCell: View {
    let vm: VM
    var badges: [String] = []

    var body: some View {
        HStack(spacing: 6) {
            PowerIcon(vm: vm).frame(width: 12)
            Text(vm.name)
            ForEach(badges, id: \.self) { label in
                Text(label)
                    .font(.caption2.weight(.semibold))
                    .padding(.horizontal, 5).padding(.vertical, 1)
                    .background(Capsule().fill(Palette.primary.opacity(0.15)))
                    .foregroundStyle(Palette.primary)
            }
        }
    }
}

// MARK: - Assumptions

struct AssumptionsForm: View {
    var solutionID = ""
    let parameters: [SolutionParameter]
    @Binding var values: ParamValues
    var showsSizingPreview = false
    var sizingPreview: SolutionResult?

    var body: some View {
        var seen = Set<String>()
        let groups = parameters.map(\.group).filter { seen.insert($0).inserted }
        return Form {
            ForEach(groups, id: \.self) { group in
                Section(group) {
                    ForEach(parameters.filter { $0.group == group }) { p in
                        ParameterRow(solutionID: solutionID, parameter: p, values: $values)
                    }
                }
                if showsSizingPreview && group == "Node hardware" {
                    sizingPreviewSection
                }
            }
            Section {
                HStack {
                    Text("Assumptions are saved and reused for every export you open.").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Restore Defaults") { values = ParamValues() }
                }
            }
        }
        .formStyle(.grouped)
    }

    @ViewBuilder
    private var sizingPreviewSection: some View {
        Section("Automatic hardware sizing") {
            if let sizingPreview, let sizingMetrics = automaticSizingMetrics(in: sizingPreview) {
                ForEach(Array(sizingMetrics.enumerated()), id: \.offset) { _, metric in
                    HStack(alignment: .top, spacing: 12) {
                        Label(metric.label, systemImage: metric.symbol ?? "cpu")
                            .foregroundStyle(.secondary)
                        Spacer(minLength: 8)
                        VStack(alignment: .trailing, spacing: 2) {
                            Text(metric.value).font(.headline)
                            if !metric.detail.isEmpty {
                                Text(metric.detail).font(.caption).foregroundStyle(.secondary)
                                    .multilineTextAlignment(.trailing)
                            }
                        }
                    }
                    .padding(.vertical, 3)
                }
                Text("Final server hardware specification is on the Results page.")
                    .font(.caption).foregroundStyle(.secondary)
            } else if let sizingPreview {
                Text(sizingPreview.vmCount == 0 ? "Select VMs on the first step to calculate hardware sizing." : "Automatic sizing is unavailable; see Results for details.")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                ProgressView("Calculating from the selected VMs and assumptions…")
            }
        }
    }

    private func automaticSizingMetrics(in result: SolutionResult) -> [SolutionMetric]? {
        for section in result.sections {
            if case .metrics("Automatic hardware sizing", let metrics) = section { return metrics }
        }
        return nil
    }
}

private struct ParameterRow: View {
    @Environment(AppModel.self) private var model
    let solutionID: String
    let parameter: SolutionParameter
    @Binding var values: ParamValues

    @State private var confirmingPairs = false
    private var current: ParamValue { values.values[parameter.id] ?? parameter.defaultValue }

    private var currentNumber: Double? {
        if case .number(let x) = current { return x }
        return nil
    }

    /// In trend mode: what the snapshots actually measured for this assumption, with a one-click apply.
    @ViewBuilder private var observed: some View {
        if let rate = model.observedRate(solutionID, parameter.id) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: "chart.line.uptrend.xyaxis").foregroundStyle(Palette.primary)
                Text(rate.text).fixedSize(horizontal: false, vertical: true)
                if let value = rate.value {
                    if currentNumber == value {
                        Label("In use", systemImage: "checkmark.circle.fill").foregroundStyle(Palette.good)
                    } else {
                        Button("Use \(Fmt.num(value, 1))\(rate.unit)") { values.values[parameter.id] = .number(value) }
                            .controlSize(.small)
                    }
                }
                Button("Trend") { model.sidebar = .trendGrowth }.buttonStyle(.link)
                    .help("Open the Growth page of the trend")
                Spacer()
            }
            .font(.caption)
        }
    }

    /// Clusters of the open export (real clusters with hosts), plus any saved choice that isn't in this export.
    @ViewBuilder private func clusterPicker(multi: Bool, none: String) -> some View {
        let clusters = (model.report?.inventory.clusters ?? []).filter { !$0.isStandalone && $0.hostCount > 0 }
            .sorted { ($0.vcenter.lowercased(), $0.name.lowercased()) < ($1.vcenter.lowercased(), $1.name.lowercased()) }
        let chosen: [String] = { if case .names(let n) = current { return n }; return [] }()
        let known = Set(clusters.map(\.id))
        let missing = chosen.filter { !known.contains($0) }
        let label: (Cluster) -> String = { "\($0.name) (\($0.vcenter)) · \($0.hostCount) hosts" }
        if multi {
            Text(parameter.label)
            if clusters.isEmpty { Text("No clusters in this export.").font(.caption).foregroundStyle(.secondary) }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 280), alignment: .leading)], alignment: .leading, spacing: 4) {
                ForEach(clusters) { c in
                    Toggle(label(c), isOn: Binding<Bool>(
                        get: { chosen.contains(c.id) },
                        set: { on in values.values[parameter.id] = .names(on ? chosen + [c.id] : chosen.filter { $0 != c.id }) }))
                    .toggleStyle(.checkbox)
                }
            }
            if !missing.isEmpty {
                HStack {
                    Text("\(missing.count) saved cluster(s) not in this export").font(.caption).foregroundStyle(.secondary)
                    Button("Clear") { values.values[parameter.id] = .names(chosen.filter(known.contains)) }.controlSize(.small)
                }
            }
        } else {
            Picker(parameter.label, selection: Binding<String>(
                get: { chosen.first ?? "" },
                set: { values.values[parameter.id] = .names($0.isEmpty ? [] : [$0]) })) {
                Text(none).tag("")
                ForEach(clusters) { Text(label($0)).tag($0.id) }
                ForEach(missing, id: \.self) { Text("\(String($0.split(separator: "|").last ?? "")) — not in this export").tag($0) }
            }
        }
    }

    /// Rows of two clusters, each usable once. Starting needs a confirmation: the export can't back this up.
    @ViewBuilder private func clusterPairPicker() -> some View {
        let clusters = (model.report?.inventory.clusters ?? []).filter { !$0.isStandalone && $0.hostCount > 0 }
            .sorted { ($0.vcenter.lowercased(), $0.name.lowercased()) < ($1.vcenter.lowercased(), $1.name.lowercased()) }
        let chosen: [String] = { if case .names(let n) = current { return n }; return [] }()
        let known = Set(clusters.map(\.id))
        Text(parameter.label)
        ForEach(Array(stride(from: 0, to: chosen.count - 1, by: 2)), id: \.self) { row in
            HStack {
                ForEach([row, row + 1], id: \.self) { i in
                    Picker(i == row ? "Site A" : "Site B", selection: Binding<String>(
                        get: { chosen[i] },
                        set: { var n = chosen; n[i] = $0; values.values[parameter.id] = .names(n) })) {
                        Text("Choose…").tag("")
                        ForEach(clusters.filter { $0.id == chosen[i] || !chosen.contains($0.id) }) {
                            Text("\($0.name) (\($0.vcenter)) · \($0.hostCount) hosts").tag($0.id)
                        }
                        if !chosen[i].isEmpty && !known.contains(chosen[i]) {
                            Text("\(String(chosen[i].split(separator: "|").last ?? "")) — not in this export").tag(chosen[i])
                        }
                    }
                }
                Button {
                    var n = chosen
                    n.removeSubrange(row...(row + 1))
                    values.values[parameter.id] = .names(n)
                } label: { Image(systemName: "minus.circle") }
                .buttonStyle(.borderless)
                .help("Remove this pair")
            }
        }
        Button(chosen.isEmpty ? "Pair clusters…" : "Add pair") {
            if chosen.isEmpty { confirmingPairs = true } else { values.values[parameter.id] = .names(chosen + ["", ""]) }
        }
        .controlSize(.small)
        .disabled(clusters.count - chosen.filter { !$0.isEmpty }.count < 2)
        .alert("Size clusters as HA pairs?", isPresented: $confirmingPairs) {
            Button("Pair Clusters") { values.values[parameter.id] = .names(["", ""]) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This is an advanced option. RVTools can't see sites or stretched clusters, so make sure you know these clusters really are one stretched cluster across two sites. Each pair is sized to survive losing a whole site instead of a few hosts, which can change the host count and licensing a lot. The results will say this was set by hand.")
        }
    }

    /// One entry per host configuration in the open export, plus a saved choice that isn't in this export.
    @ViewBuilder private func hostPicker(none: String) -> some View {
        let inv = model.report?.inventory
        let configs = inv.map(HostSpecs.distinct) ?? []
        let chosen: String = { if case .names(let n) = current { return n.first ?? "" }; return "" }()
        // A saved host that shares a listed configuration shows as that entry.
        let tag: String = {
            guard !chosen.isEmpty, let inv, let h = HostSpecs.resolve(chosen, in: inv) else { return chosen }
            return configs.first { HostSpecs.key($0.host) == HostSpecs.key(h) }?.host.id ?? chosen
        }()
        let known = Set(configs.map(\.host.id))
        Picker(parameter.label, selection: Binding<String>(
            get: { tag },
            set: { values.values[parameter.id] = .names($0.isEmpty ? [] : [$0]) })) {
            Text(none).tag("")
            ForEach(configs, id: \.host.id) { c in
                Text(HostSpecs.label(c.host) + (c.count > 1 ? " (and \(c.count - 1) like it)" : "")).tag(c.host.id)
            }
            if !tag.isEmpty && !known.contains(tag) {
                Text("\(String(tag.split(separator: "|").last ?? "")) — not in this export").tag(tag)
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            switch parameter.kind {
            case .number(let lo, let hi, let step, let unit):
                let binding = Binding<Double>(
                    get: { if case .number(let x) = current { return x }; return lo },
                    set: { values.values[parameter.id] = .number(min(hi, max(lo, $0))) })
                LabeledContent(parameter.label) {
                    HStack(spacing: 6) {
                        TextField(parameter.label, value: binding, format: .number)
                            .labelsHidden().multilineTextAlignment(.trailing).frame(width: 80)
                        Stepper(parameter.label, value: binding, in: lo...hi, step: step).labelsHidden()
                        Text(unit).foregroundStyle(.secondary).frame(minWidth: 56, alignment: .leading)
                    }
                }
            case .choice(let options):
                Picker(parameter.label, selection: Binding<Int>(
                    get: { if case .choice(let i) = current { return i }; return 0 },
                    set: { values.values[parameter.id] = .choice($0) })) {
                    ForEach(options.indices, id: \.self) { Text(options[$0]).tag($0) }
                }
            case .toggle:
                Toggle(parameter.label, isOn: Binding<Bool>(
                    get: { if case .flag(let b) = current { return b }; return false },
                    set: { values.values[parameter.id] = .flag($0) }))
            case .multi(let options):
                let chosen: Set<Int> = { if case .selection(let s) = current { return Set(s) }; return [] }()
                Text(parameter.label)
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 240), alignment: .leading)], alignment: .leading, spacing: 4) {
                    ForEach(options.indices, id: \.self) { i in
                        Toggle(options[i], isOn: Binding<Bool>(
                            get: { chosen.contains(i) },
                            set: { on in
                                var s = chosen
                                if on { s.insert(i) } else { s.remove(i) }
                                values.values[parameter.id] = .selection(s.sorted())
                            }))
                        .toggleStyle(.checkbox)
                    }
                }
            case .clusters(let multi, let none):
                clusterPicker(multi: multi, none: none)
            case .clusterPairs:
                clusterPairPicker()
            case .host(let none):
                hostPicker(none: none)
            }
            if !parameter.help.isEmpty {
                Text(parameter.help).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            observed
        }
    }
}

// MARK: - Results

private struct ApplySolutionActionKey: EnvironmentKey {
    static let defaultValue: ((SolutionAction) -> Void)? = nil
}

extension EnvironmentValues {
    /// Applies a result's suggested change to the solution's assumptions (nil where results can't be changed).
    var applySolutionAction: ((SolutionAction) -> Void)? {
        get { self[ApplySolutionActionKey.self] }
        set { self[ApplySolutionActionKey.self] = newValue }
    }
}

/// Buttons for a result's suggested changes; nothing when the results are read-only.
private struct ActionButtons: View {
    @Environment(\.applySolutionAction) private var apply
    let actions: [SolutionAction]

    var body: some View {
        if let apply, !actions.isEmpty {
            HStack(spacing: 6) {
                ForEach(actions, id: \.self) { a in
                    Button { apply(a) } label: { Label(a.label, systemImage: a.symbol) }
                        .help(a.help.isEmpty ? "Changes this solution's assumptions" : a.help)
                }
            }
            .controlSize(.small)
            .buttonStyle(.bordered)
        }
    }
}

struct SolutionResultView: View {
    let result: SolutionResult

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if result.vmCount == 0 {
                    ContentUnavailableView("No VMs selected", systemImage: "checklist", description: Text("Choose VMs on the Select VMs step."))
                        .frame(maxWidth: .infinity, minHeight: 300)
                } else {
                    Text(result.headline).font(.title3.weight(.medium)).textSelection(.enabled)
                    ForEach(Array(result.sections.enumerated()), id: \.offset) { _, section in
                        SectionView(section: section)
                    }
                                        if !result.exports.isEmpty { ExportsCard(exports: result.exports) }
                    Card("Assumptions used") { KeyValueGrid(rows: result.assumptions) }
                }
            }
            .padding(20)
        }
    }
}

private struct SectionView: View {
    let section: SolutionSection

    var body: some View {
        switch section {
        case .metrics(let title, let metrics):
            VStack(alignment: .leading, spacing: 8) {
                if !title.isEmpty && title != "Summary" { Text(title).font(.headline) }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 200), spacing: 12)], spacing: 12) {
                    ForEach(Array(metrics.enumerated()), id: \.offset) { _, m in
                        let alert = m.status == .blocker || m.status == .warning
                        KPITile(title: m.label, value: m.value, detail: m.detail.isEmpty ? nil : m.detail, symbol: m.symbol,
                                tint: m.status?.color, valueTint: alert ? m.status?.color : nil)
                    }
                }
            }
        case .checks(let title, let checks, let subtitle):
            ChecksCard(title: title, subtitle: subtitle, checks: checks)
        case .table(let table):
            TableCard(table: table)
        case .bars(let title, let subtitle, let items, let format):
            Card(title, subtitle: subtitle.isEmpty ? nil : subtitle) {
                BarListChart(items: items, value: { $0.value }, label: { format.format($0.value) })
            }

        case .notes(let title, let lines):
            Card(title) {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                        Text(linkifiedText("• " + line)).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                }
                .textSelection(.enabled)
            }
        }
    }
}

private struct ChecksCard: View {
    let title: String
    var subtitle = ""
    let checks: [SolutionCheck]

    var body: some View {
        var seen = Set<String>()
        let areas = checks.map(\.area).filter { seen.insert($0).inserted }
        let counts = Dictionary(grouping: checks, by: \.status).mapValues(\.count)
        return Card(title, subtitle: subtitle.isEmpty ? nil : subtitle) {
            HStack(spacing: 16) {
                ForEach(CheckStatus.allCases) { s in
                    if let n = counts[s] {
                        HStack(spacing: 4) { StatusBadge(status: s); Text("\(n)").foregroundStyle(.secondary).tabular() }
                    }
                }
            }
            .font(.callout)
            ForEach(areas, id: \.self) { area in
                VStack(alignment: .leading, spacing: 0) {
                    Text(area).font(.subheadline.weight(.semibold)).padding(.top, 8).padding(.bottom, 4)
                    ForEach(checks.filter { $0.area == area }) { c in
                        CheckRow(check: c)
                        Divider()
                    }
                }
            }
        }
    }
}

private struct CheckRow: View {
    @Environment(AppModel.self) private var model
    let check: SolutionCheck
    @State private var expanded = false

    var body: some View {
        if check.affected.isEmpty && (check.remediation.isEmpty || check.status == .ready) {
            header.padding(.vertical, 6).padding(.leading, 18)
        } else {
            DisclosureGroup(isExpanded: $expanded) {
                VStack(alignment: .leading, spacing: 4) {
                    if !check.remediation.isEmpty {
                        Label(check.remediation, systemImage: "lightbulb").font(.callout).foregroundStyle(.secondary).padding(.bottom, 4)
                    }
                    ForEach(Array(check.affected.prefix(300).enumerated()), id: \.offset) { _, a in
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Image(systemName: a.kind.symbol).foregroundStyle(.secondary).frame(width: 16)
                            if model.canReveal(a.kind, a.id) {
                                Button(a.name) { model.reveal(a.kind, a.id) }.buttonStyle(.link)
                            } else {
                                Text(a.name)
                            }
                            Text(a.detail).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
                            Spacer()
                        }
                    }
                    if check.affected.count > 300 {
                        Text("… and \(check.affected.count - 300) more (included in the export)").font(.caption).foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 4)
            } label: {
                header
            }
            .padding(.vertical, 4)
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            StatusBadge(status: check.status, showLabel: false)
            VStack(alignment: .leading, spacing: 1) {
                Text(check.title).font(.body.weight(.medium))
                Text(check.summary).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                ActionButtons(actions: check.actions).padding(.top, 4)
            }
            Spacer()
            if !check.affected.isEmpty { Text(Fmt.int(check.affected.count)).font(.callout.weight(.semibold)).tabular() }
        }
    }
}

private struct TableCard: View {
    @Environment(AppModel.self) private var model
    let table: SolutionTable

    var body: some View {
        Card(table.title, subtitle: table.subtitle.isEmpty ? nil : table.subtitle) {
            if table.rows.count <= 30 {
                ScrollView(.horizontal) {
                    Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 20, verticalSpacing: 6) {
                        GridRow {
                            ForEach(table.columns.indices, id: \.self) { j in
                                Text(table.columns[j]).font(.caption).foregroundStyle(.secondary)
                                    .gridColumnAlignment(table.numericColumns.contains(j) ? .trailing : .leading)
                            }
                            if !table.rowActions.isEmpty { Text("") }
                        }
                        Divider().gridCellUnsizedAxes(.horizontal)
                        ForEach(table.rows.indices, id: \.self) { i in
                            GridRow {
                                ForEach(table.columns.indices, id: \.self) { j in cell(i, j) }
                                if !table.rowActions.isEmpty { ActionButtons(actions: i < table.rowActions.count ? table.rowActions[i] : []) }
                            }
                            .fontWeight(table.emphasized.contains(i) ? .semibold : .regular)
                        }
                    }
                    .font(.callout)
                    .padding(.bottom, 2)
                }
            } else {
                DataGrid(headers: table.columns, rows: table.rows, identity: "\(table.id)|\(table.rows.hashValue)")
                    .frame(height: 380)
                Text("\(Fmt.int(table.rows.count)) rows — click a column header to sort; the full table is included in the export.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private func cell(_ i: Int, _ j: Int) -> some View {
        let text = j < table.rows[i].count ? table.rows[i][j] : ""
        if j == 0, i < table.rowRefs.count, let ref = table.rowRefs[i], model.canReveal(ref.kind, ref.id) {
            Button(text) { model.reveal(ref.kind, ref.id) }.buttonStyle(.link)
        } else {
            Text(text).tabular().textSelection(.enabled)
        }
    }
}

/// Options for exporting a solution's results as a PowerPoint deck.
struct DeckExportSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let solution: any Solution
    let result: SolutionResult?
    @State private var title = ""
    @State private var subtitle = ""
    @State private var date = ""
    @State private var selectedSectionIndices = Set<Int>()
    @State private var includeHeadline = true
    @State private var showSectionChoices = true
    @AppStorage("deckIssueDetails", store: AppDefaults.store) private var issueDetails = 5
    @AppStorage("deckReadyChecks", store: AppDefaults.store) private var readyChecks = false
    @AppStorage("deckAssumptions", store: AppDefaults.store) private var assumptions = true
    @AppStorage("deckTemplate", store: AppDefaults.store) private var templatePath = ""
    @AppStorage("deckKeepLayouts", store: AppDefaults.store) private var keepLayouts = false

    private var template: URL? {
        guard !templatePath.isEmpty, FileManager.default.fileExists(atPath: templatePath) else { return nil }
        return URL(fileURLWithPath: templatePath)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Export \(solution.title) as PowerPoint").font(.title3.weight(.semibold))
            Form {
                Section("Title slide") {
                    TextField("Title", text: $title)
                    TextField("Subtitle", text: $subtitle, prompt: Text("Customer or project"))
                    TextField("Date line", text: $date)
                }
                Section("Content") {
                    if let result, !result.headline.isEmpty {
                        Toggle("Include the headline", isOn: $includeHeadline)
                    }
                    if let result, !result.sections.isEmpty {
                        DisclosureGroup("Result sections (\(selectedSectionIndices.count)/\(result.sections.count))", isExpanded: $showSectionChoices) {
                            HStack {
                                Button("All") { selectedSectionIndices = Set(result.sections.indices) }
                                Button("None") { selectedSectionIndices.removeAll() }
                            }
                            ForEach(result.sections.indices, id: \.self) { index in
                                Toggle(sectionLabel(result.sections[index], index: index), isOn: sectionBinding(index))
                                    .font(.callout)
                            }
                        }
                    }
                    Stepper(value: $issueDetails, in: 0...25) {
                        Text(issueDetails == 0 ? "No slides for individual checks" : "A slide for each of the top \(issueDetails) checks")
                    }
                    .help("Blockers first, then warnings, then info: what was found, the recommendation and the affected objects")
                    Toggle("List passed checks in checks tables", isOn: $readyChecks)
                    Toggle("End with the assumptions", isOn: $assumptions)
                }
                Section("Design") {
                    LabeledContent("Template") {
                        HStack {
                            Text(template?.lastPathComponent ?? "Built-in").lineLimit(1).truncationMode(.middle)
                            Spacer()
                            if template != nil { Button("Use Built-in") { templatePath = "" } }
                            Button("Choose…") { chooseTemplate() }
                        }
                    }
                    Text("A .pptx or .potx whose theme, fonts and layouts the deck uses. Its own slides aren't copied. The deck uses its Title Slide and Title Only layouts.")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    if template != nil {
                        Toggle("Keep all of the template's layouts", isOn: $keepLayouts)
                            .help("Lets you add more slides in the template's style later, but layout photos can make the deck much larger")
                    }
                    if !templatePath.isEmpty && template == nil {
                        Label("The saved template is missing: \(templatePath)", systemImage: "exclamationmark.triangle")
                            .font(.caption).foregroundStyle(Palette.warning)
                    }
                }
            }
            .formStyle(.grouped)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Export…") {
                    let options = DeckOptions(title: title.isEmpty ? solution.title : title, subtitle: subtitle, date: date, issueDetails: issueDetails,
                                              includeReadyChecks: readyChecks, includeAssumptions: assumptions, template: template,
                                              keepTemplateLayouts: keepLayouts,
                                              includedSectionIndices: result == nil ? nil : selectedSectionIndices,
                                              includeHeadline: includeHeadline)
                    dismiss()
                    // Let the sheet close before the save panel opens.
                    DispatchQueue.main.async { model.exportDeck(solution, options) }
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 520)
        .onAppear {
            let defaults = model.deckDefaults(solution)
            title = solution.title; subtitle = defaults.subtitle; date = defaults.date
            if let result {
                selectedSectionIndices = Set(result.sections.indices)
                includeHeadline = !result.headline.isEmpty
            }
        }
    }

    private func sectionBinding(_ index: Int) -> Binding<Bool> {
        Binding(
            get: { selectedSectionIndices.contains(index) },
            set: { isSelected in
                if isSelected { selectedSectionIndices.insert(index) }
                else { selectedSectionIndices.remove(index) }
            }
        )
    }

    private func sectionLabel(_ section: SolutionSection, index: Int) -> String {
        let title: String
        switch section {
        case .metrics(let sectionTitle, _): title = sectionTitle.isEmpty ? "Summary" : sectionTitle
        case .checks(let sectionTitle, _, _): title = sectionTitle.isEmpty ? "Checks" : sectionTitle
        case .table(let table): title = table.title
        case .bars(let sectionTitle, _, _, _): title = sectionTitle
        case .notes(let sectionTitle, _): title = sectionTitle
        }
        return "\(index + 1). \(title)"
    }

    private func chooseTemplate() {
        let panel = NSOpenPanel()
        panel.title = "Choose a PowerPoint Template"
        panel.allowedContentTypes = ["pptx", "potx"].compactMap { UTType(filenameExtension: $0) }
        if let template { panel.directoryURL = template.deletingLastPathComponent() }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        templatePath = url.path
    }
}
