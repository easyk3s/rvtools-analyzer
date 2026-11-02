import AppKit
import Charts
import RVToolsCore
import SwiftUI

struct Card<Content: View>: View {
    let title: String?
    let subtitle: String?
    let content: Content

    init(_ title: String? = nil, subtitle: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.subtitle = subtitle
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let title {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.headline)
                    if let subtitle { Text(subtitle).font(.caption).foregroundStyle(.secondary) }
                }
            }
            content
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Palette.card))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.primary.opacity(0.08)))
    }
}

struct KPITile: View {
    let title: String
    let value: String
    var detail: String?
    var symbol: String?
    var tint: Color?
    /// Colours the value itself, for a figure in a warning or critical state.
    var valueTint: Color?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                if let symbol { Image(systemName: symbol).foregroundStyle(tint ?? .secondary) }
                Text(title).font(.caption).foregroundStyle(.secondary).textCase(.uppercase)
            }
            Text(value).font(.system(size: 26, weight: .semibold)).foregroundStyle(valueTint ?? .primary).lineLimit(1).minimumScaleFactor(0.6)
            if let detail {
                Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(2).fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, minHeight: 92, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Palette.card))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.primary.opacity(0.08)))
    }
}

struct Meter: View {
    let fraction: Double
    var color: Color = Palette.primary
    var height: CGFloat = 6

    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Capsule().fill(Palette.track)
                Capsule().fill(color).frame(width: max(0, min(1, fraction.isFinite ? fraction : 1)) * g.size.width)
            }
        }
        .frame(height: height)
    }
}

struct UsageMeter: View {
    let pct: Double
    var warn = 80.0
    var crit = 90.0
    var width: CGFloat = 70

    var body: some View {
        HStack(spacing: 6) {
            Meter(fraction: pct / 100, color: Palette.usage(pct, warn: warn, crit: crit)).frame(width: width)
            Text(Fmt.pct(pct)).font(.callout).monospacedDigit().frame(minWidth: 38, alignment: .trailing)
        }
    }
}

/// Labeled meter row used in cards: "Memory used   ▓▓▓▓░░  81%".
struct LabeledMeter: View {
    let label: String
    let pct: Double
    var detail: String?
    var warn = 80.0
    var crit = 90.0

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(label).font(.callout)
                Spacer()
                if pct >= crit { Image(systemName: Severity.critical.symbol).foregroundStyle(Palette.critical).font(.caption) }
                else if pct >= warn { Image(systemName: Severity.warning.symbol).foregroundStyle(Palette.warning).font(.caption) }
                Text(pct.isFinite ? Fmt.pct(pct) : "—").font(.callout.weight(.medium)).monospacedDigit()
            }
            Meter(fraction: pct / 100, color: Palette.usage(pct, warn: warn, crit: crit))
            if let detail { Text(detail).font(.caption).foregroundStyle(.secondary) }
        }
    }
}

struct SeverityBadge: View {
    let severity: Severity
    var showLabel = true

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: severity.symbol).foregroundStyle(Palette.severity(severity))
            if showLabel { Text(severity.label) }
        }
        .help(severity.label)
    }
}

struct StateChip: View {
    let label: String
    let state: Bool?

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: state == true ? "checkmark.circle.fill" : (state == false ? "xmark.circle.fill" : "questionmark.circle"))
                .foregroundStyle(state == true ? Palette.good : (state == false ? Palette.critical : Palette.neutral))
            Text(label)
        }
        .font(.caption)
        .padding(.horizontal, 8).padding(.vertical, 3)
        .background(Capsule().fill(Palette.track))
    }
}

struct Tag: View {
    let text: String
    var body: some View {
        Text(text).font(.caption).padding(.horizontal, 7).padding(.vertical, 2).background(Capsule().fill(Palette.track))
    }
}

struct KeyValueGrid: View {
    let rows: [(String, String)]

    var body: some View {
        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 14, verticalSpacing: 5) {
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                GridRow {
                    Text(row.0).foregroundStyle(.secondary)
                    Text(row.1.isEmpty ? "—" : row.1).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .font(.callout)
    }
}

struct DetailSection<Content: View>: View {
    let title: String
    let count: Int?
    let content: Content

    init(_ title: String, count: Int? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.count = count
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(title).font(.headline)
                if let count { Text("\(count)").font(.subheadline).foregroundStyle(.secondary) }
            }
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 6)
    }
}

// MARK: - Bar lists
// Horizontal bars are drawn as rows (label column · bar · value) rather than with Swift Charts, so category
// labels always sit beside their bar and never collide with it.

/// Width for a right-aligned label column that fits the longest label (capped).
func barLabelWidth(_ labels: [String], max cap: CGFloat = 210) -> CGFloat {
    min(cap, max(56, CGFloat(labels.map(\.count).max() ?? 0) * 6.4 + 6))
}

struct LegendRow: View {
    let items: [(String, Color)]
    var body: some View {
        HStack(spacing: 14) {
            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                HStack(spacing: 5) {
                    RoundedRectangle(cornerRadius: 2).fill(item.1).frame(width: 10, height: 10)
                    Text(item.0).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }
}

/// Ranked horizontal bars (single series, so no legend) with direct value labels and hover highlight.
struct BarListChart: View {
    let items: [CountItem]
    var value: (CountItem) -> Double = { Double($0.count) }
    var label: (CountItem) -> String = { Fmt.int($0.count) }
    var color: Color = Palette.primary
    /// Horizontal room reserved after the longest bar for its value label.
    var valueRoom: CGFloat = 120
    @State private var hovered: String?

    var body: some View {
        let maxV = max(items.map(value).max() ?? 0, .leastNonzeroMagnitude)
        let lw = barLabelWidth(items.map(\.label))
        VStack(alignment: .leading, spacing: 5) {
            if items.isEmpty { Text("No data").font(.callout).foregroundStyle(.secondary) }
            ForEach(items) { item in
                let active = hovered == nil || hovered == item.label
                HStack(spacing: 8) {
                    Text(item.label).font(.caption).lineLimit(1).truncationMode(.middle)
                        .foregroundStyle(hovered == item.label ? Color.primary : Color.secondary)
                        .frame(width: lw, alignment: .trailing)
                    GeometryReader { g in
                        HStack(spacing: 6) {
                            RoundedRectangle(cornerRadius: 3)
                                .fill(color.opacity(active ? 1 : 0.4))
                                .frame(width: max(2, (g.size.width - valueRoom) * value(item) / maxV), height: 14)
                            Text(label(item)).font(.caption).foregroundStyle(.secondary).monospacedDigit().lineLimit(1).fixedSize()
                        }
                        .frame(maxHeight: .infinity)
                    }
                    .frame(height: 18)
                }
                .contentShape(Rectangle())
                .onHover { inside in hovered = inside ? item.label : (hovered == item.label ? nil : hovered) }
                .help("\(item.label): \(label(item))")
            }
        }
    }
}

struct StackSegment: Identifiable {
    let id = UUID()
    let category: String
    let series: String
    let value: Double
}

/// Horizontal stacked bars with a legend (for ≥ 2 series); a 1.5pt gap separates segments.
struct StackedBarChart: View {
    let segments: [StackSegment]
    let categories: [String]
    let series: [String]
    let colors: [Color]
    @State private var hovered: String?

    private struct Part: Identifiable {
        let id: Int
        let value: Double
    }

    var body: some View {
        let totals = Dictionary(grouping: segments, by: \.category).mapValues { $0.reduce(0) { $0 + $1.value } }
        let maxT = max(totals.values.max() ?? 0, .leastNonzeroMagnitude)
        let lw = barLabelWidth(categories)
        VStack(alignment: .leading, spacing: 5) {
            LegendRow(items: series.enumerated().map { ($0.element, colors[$0.offset % colors.count]) })
                .padding(.leading, lw + 8).padding(.bottom, 3)
            ForEach(categories, id: \.self) { cat in
                let parts = series.indices.compactMap { i -> Part? in
                    let v = segments.first { $0.category == cat && $0.series == series[i] }?.value ?? 0
                    return v > 0 ? Part(id: i, value: v) : nil
                }
                let total = totals[cat] ?? 0
                HStack(spacing: 8) {
                    Text(cat).font(.caption).lineLimit(1).truncationMode(.middle)
                        .foregroundStyle(hovered == cat ? Color.primary : Color.secondary)
                        .frame(width: lw, alignment: .trailing)
                    GeometryReader { g in
                        HStack(spacing: 6) {
                            HStack(spacing: 1.5) {
                                ForEach(parts) { p in
                                    RoundedRectangle(cornerRadius: 2)
                                        .fill(colors[p.id % colors.count])
                                        .frame(width: max(2, (g.size.width - 60) * p.value / maxT), height: 14)
                                }
                            }
                            .opacity(hovered == nil || hovered == cat ? 1 : 0.4)
                            Text(Fmt.int(Int(total.rounded()))).font(.caption).foregroundStyle(.secondary).monospacedDigit().fixedSize()
                        }
                        .frame(maxHeight: .infinity)
                    }
                    .frame(height: 18)
                }
                .contentShape(Rectangle())
                .onHover { inside in hovered = inside ? cat : (hovered == cat ? nil : hovered) }
                .help(cat + ": " + parts.map { "\(series[$0.id]) \(Fmt.int(Int($0.value.rounded())))" }.joined(separator: " · "))
            }
        }
    }
}

/// Vertical bars for ordinal / time buckets.
struct ColumnChart: View {
    let items: [CountItem]
    var color: Color = Palette.primary
    var height: CGFloat = 170
    var label: (CountItem) -> String = { Fmt.int($0.count) }
    @State private var hovered: String?

    var body: some View {
        // Swift Charts asserts when hover selection runs over an empty categorical domain (e.g. no creation dates).
        if items.isEmpty {
            Text("No data").font(.callout).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, minHeight: height, alignment: .center)
        } else {
            chartContent
        }
    }

    private var chart: some View {
        chartContent.contextMenu {
            Button("Copy Image", systemImage: "doc.on.doc") {
                if let image = ImageRenderer(content: chartContent).nsImage {
                    copyToClipboard(image)
                }
            }
        }
    }


    private var chartContent: some View {
        Chart(items) { item in
            BarMark(x: .value("Bucket", item.label), y: .value("Count", item.count), width: .ratio(0.7))
                .foregroundStyle(color.opacity(hovered == nil || hovered == item.label ? 1 : 0.4))
                .cornerRadius(3)
                .annotation(position: .top, spacing: 3) {
                    if item.count > 0 { Text(label(item)).font(.caption2).foregroundStyle(.secondary).monospacedDigit() }
                }
        }
        .chartXScale(domain: items.map(\.label))
        .chartYAxis { AxisMarks(position: .leading) { _ in AxisGridLine().foregroundStyle(Palette.grid); AxisValueLabel().font(.caption2) } }
        .chartXAxis { AxisMarks { _ in AxisValueLabel().font(.caption) } }
        .chartXSelection(value: $hovered)
        .frame(height: height)
    }
}

/// Part-to-whole as a single segmented bar with a labeled legend.
struct PartBar: View {
    struct Part: Identifiable {
        var id: String { label }
        let label: String
        let value: Double
        let color: Color
    }

    let parts: [Part]
    var format: (Double) -> String = { Fmt.int(Int($0)) }

    var body: some View {
        let total = max(parts.reduce(0) { $0 + $1.value }, 1)
        let visible = parts.filter { $0.value > 0 }
        VStack(alignment: .leading, spacing: 10) {
            GeometryReader { g in
                HStack(spacing: 2) {
                    ForEach(visible) { p in
                        RoundedRectangle(cornerRadius: 3)
                            .fill(p.color)
                            .frame(width: max(3, (g.size.width - CGFloat(max(visible.count - 1, 0)) * 2) * p.value / total))
                            .help("\(p.label): \(format(p.value)) (\(Fmt.pct(p.value / total * 100)))")
                    }
                }
            }
            .frame(height: 16)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 220), alignment: .leading)], alignment: .leading, spacing: 6) {
                ForEach(parts) { p in
                    HStack(spacing: 6) {
                        RoundedRectangle(cornerRadius: 2).fill(p.color).frame(width: 10, height: 10)
                        Text(p.label).font(.callout)
                        Text(format(p.value)).font(.callout.weight(.semibold)).monospacedDigit()
                        Text(Fmt.pct(p.value / total * 100)).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }
}

extension View {
    /// Tabular numbers for columns that must align.
    func tabular() -> some View { monospacedDigit() }
}
