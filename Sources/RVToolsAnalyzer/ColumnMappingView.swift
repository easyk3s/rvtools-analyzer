import RVToolsCore
import SwiftUI

/// A file waiting for its columns to be checked; the load carries on once `finish` is called.
struct ColumnReview: Identifiable {
    let id = UUID()
    let plan: ColumnPlan
    let finish: (ColumnPlan?) -> Void
}

/// Shows how the columns of an export with non-standard headers were matched, with sample values to check them by,
/// and lets each one be changed before the export is read.
struct ColumnMappingSheet: View {
    let review: ColumnReview
    let done: (ColumnPlan?) -> Void

    @State private var plan: ColumnPlan
    @State private var selected: String
    @State private var onlyToCheck = false

    init(review: ColumnReview, done: @escaping (ColumnPlan?) -> Void) {
        self.review = review
        self.done = done
        _plan = State(initialValue: review.plan)
        _selected = State(initialValue: review.plan.tabs.first?.name ?? "")
    }

    private var tabIndex: Int? { plan.tabs.firstIndex { $0.name == selected } }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Check the columns in \(plan.file)").font(.title3.weight(.semibold))
                Text("This file doesn't use RVTools' usual column names. Each column has been matched where possible: check the sample values, and change any match that looks wrong.")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Text(summary).font(.callout.weight(.medium))
            }
            .padding(20)
            Divider()
            HStack(spacing: 0) {
                List(plan.tabs, selection: $selected) { tab in
                    HStack {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(tab.name)
                            Text("\(tab.matchedCount) of \(tab.matches.count) columns · \(Fmt.int(tab.rowCount)) rows")
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if needsAttention(tab) {
                            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Palette.warning).help("Has columns to check")
                        }
                    }
                    .tag(tab.name)
                }
                .frame(width: 210)
                Divider()
                if let t = tabIndex { columns(t) } else { Spacer() }
            }
            Divider()
            if let problem = problems.first {
                Label(problem, systemImage: plan.canContinue ? "exclamationmark.triangle" : "xmark.octagon")
                    .font(.callout)
                    .foregroundStyle(plan.canContinue ? Palette.warning : Palette.critical)
                    .padding(.horizontal, 20).padding(.top, 12)
            }
            HStack {
                Toggle("Only columns to check", isOn: $onlyToCheck).toggleStyle(.checkbox)
                Button("Reset Matches") { plan = review.plan }
                    .help("Go back to the automatic matches")
                Spacer()
                Button("Cancel", role: .cancel) { done(nil) }.keyboardShortcut(.cancelAction)
                Button("Use These Matches") { done(plan) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!plan.canContinue)
            }
            .padding(20)
        }
        .frame(width: 960, height: 660)
        .interactiveDismissDisabled()
    }

    private var summary: String {
        var parts = ["\(Fmt.int(plan.matchedCount)) of \(Fmt.int(plan.columnCount)) columns matched"]
        if plan.toCheckCount > 0 { parts.append("\(plan.toCheckCount) to check") }
        return parts.joined(separator: " · ")
    }

    private func needsAttention(_ tab: ColumnPlan.Tab) -> Bool {
        tab.toCheckCount > 0 || !tab.missingKeyColumns.isEmpty || !tab.duplicateTargets.isEmpty
    }

    /// Worst first: what stops the file opening, then what would leave figures out.
    private var problems: [String] {
        var out: [String] = []
        if !plan.hasVMColumn { out.append("Choose the vInfo column that holds the VM name. Without it, no VMs can be read.") }
        for t in plan.tabs {
            for d in t.duplicateTargets { out.append("\(t.name): more than one column is matched to \(d). Keep one of them.") }
        }
        for t in plan.tabs where !t.missingKeyColumns.isEmpty {
            out.append("\(t.name): nothing is matched to \(t.missingKeyColumns.joined(separator: ", ")), so figures that use them will be missing.")
        }
        return out
    }

    @ViewBuilder private func columns(_ t: Int) -> some View {
        let visible = plan.tabs[t].matches.indices.filter { !onlyToCheck || plan.tabs[t].matches[$0].needsChecking }
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Text("Column in the file").frame(width: 200, alignment: .leading)
                Text("Sample values").frame(maxWidth: .infinity, alignment: .leading)
                Text("RVTools column").frame(width: 230, alignment: .leading)
                Text("Match").frame(width: 72, alignment: .leading)
            }
            .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            .padding(.horizontal, 14).padding(.vertical, 8)
            Divider()
            if visible.isEmpty {
                Text("Nothing to check on this tab.").foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(visible, id: \.self) { m in
                            row(t, m)
                            Divider()
                        }
                    }
                }
                .id(selected)
            }
        }
    }

    private func row(_ t: Int, _ m: Int) -> some View {
        let match = plan.tabs[t].matches[m]
        return HStack(spacing: 12) {
            Text(match.source).font(.callout).lineLimit(1).truncationMode(.middle)
                .frame(width: 200, alignment: .leading).help(match.source)
            Text(match.samples.isEmpty ? "(empty)" : match.samples.joined(separator: " · "))
                .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading).help(match.samples.joined(separator: "\n"))
            Picker("RVTools column for \(match.source)", selection: $plan.tabs[t].matches[m].target) {
                Text("Don't use").tag(String?.none)
                Divider()
                ForEach(plan.tabs[t].options, id: \.self) { Text($0).tag(String?.some($0)) }
            }
            .labelsHidden()
            .frame(width: 230)
            badge(match).frame(width: 72, alignment: .leading)
        }
        .padding(.horizontal, 14).padding(.vertical, 5)
    }

    @ViewBuilder private func badge(_ m: ColumnMatch) -> some View {
        if m.isEdited {
            Label("Yours", systemImage: "pencil").foregroundStyle(Palette.primary).help("You changed this match")
        } else {
            switch m.kind {
            case .exact:
                Label("Same", systemImage: "checkmark.circle").foregroundStyle(Palette.good)
                    .help("The same name, ignoring the tab name, spacing and case")
            case .known:
                Label("Known", systemImage: "checkmark.circle").foregroundStyle(Palette.good)
                    .help("A name known to hold this column")
            case .suggested:
                Label("Check", systemImage: "questionmark.circle").foregroundStyle(Palette.warning)
                    .help("A guess from similar spelling: check the sample values")
            case .unmatched:
                Label("None", systemImage: "minus.circle").foregroundStyle(.secondary)
                    .help("No RVTools column matches. It stays available in Raw Data under its own name.")
            }
        }
    }
}
