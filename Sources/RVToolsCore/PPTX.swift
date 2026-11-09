import Foundation

/// How a solution's results become a PowerPoint deck.
public struct DeckOptions: Sendable {
    public var title: String
    /// Second line of the title slide, e.g. the customer or the export.
    public var subtitle: String
    /// Third line of the title slide, e.g. the export date and scope.
    public var date: String
    /// A slide per issue for the first N blocker/warning/info checks (0 = none).
    public var issueDetails: Int
    /// List passed checks in the checks tables too.
    public var includeReadyChecks: Bool
    public var includeAssumptions: Bool
    /// A .pptx or .potx whose theme, masters and layouts the deck uses; its own slides are dropped. nil = built-in look.
    public var template: URL?
    /// Keep every master and layout of the template, so more slides can be added in its style. Otherwise the deck keeps only
    /// the two layouts it uses, which can make it much smaller when layouts carry photos.
    public var keepTemplateLayouts: Bool
    /// Section indexes to include, or nil to include every section.
    public var includedSectionIndices: Set<Int>?
    public var includeHeadline: Bool

    public init(title: String, subtitle: String = "", date: String = "", issueDetails: Int = 5,
                includeReadyChecks: Bool = false, includeAssumptions: Bool = true, template: URL? = nil, keepTemplateLayouts: Bool = false,
                includedSectionIndices: Set<Int>? = nil, includeHeadline: Bool = true) {
        self.title = title; self.subtitle = subtitle; self.date = date; self.issueDetails = issueDetails
        self.includeReadyChecks = includeReadyChecks; self.includeAssumptions = includeAssumptions; self.template = template
        self.keepTemplateLayouts = keepTemplateLayouts
        self.includedSectionIndices = includedSectionIndices; self.includeHeadline = includeHeadline
    }
}

public extension SolutionResult {
    /// The results as a .pptx file.
    func pptx(_ options: DeckOptions) throws -> Data {
        var pkg = try options.template.map { try DeckPackage(template: $0) } ?? DeckPackage.builtIn()
        let slides = DeckRenderer(pkg).render(DeckBlocks.from(self, options))
        if !options.keepTemplateLayouts { pkg.trimLayouts() }
        return try pkg.write(slides, title: options.title)
    }
}

// MARK: - Logical content

struct DeckCell {
    var text: String
    var bold = false
    var fill: DeckColor?
    var color: DeckColor?
    /// Columns this cell spans; the cells it covers are still in the row and are written as merged.
    var span = 1
}

struct DeckTable {
    var title: String
    var subtitle = ""
    var columns: [String]
    var rows: [[DeckCell]]
    var numeric: Set<Int> = []
    /// Fixed column widths in inches by index; the rest share what's left.
    var fixed: [Int: Double] = [:]
    var footnote = ""
}

enum DeckBlock {
    case title(String, String, String)
    case headline(String)
    case metrics(String, String?, [SolutionMetric])
    case table(DeckTable)
    case bars(String, String, [(label: String, value: String, fraction: Double)], more: Int)
    case bullets(String, [String])
    case issue(SolutionCheck)
}

enum DeckBlocks {
    static let maxTableRows = 40
    static let maxBars = 12

    static func from(_ r: SolutionResult, _ o: DeckOptions) -> [DeckBlock] {
        var out: [DeckBlock] = [.title(o.title, o.subtitle, o.date)]
        let sections = r.sections.enumerated().filter { o.includedSectionIndices?.contains($0.offset) ?? true }.map(\.element)
        var headline: String? = o.includeHeadline && !r.headline.isEmpty ? r.headline : nil
        if let h = headline, !sections.contains(where: { if case .metrics = $0 { return true }; return false }) {
            out.append(.headline(h)); headline = nil
        }
        for section in sections {
            switch section {
            case .metrics(let t, let metrics):
                out.append(.metrics(t.isEmpty ? "Summary" : t, headline, metrics)); headline = nil
            case .checks(let t, let checks, let subtitle):
                out += checkBlocks(t.isEmpty ? "Checks" : t, checks, o, subtitle: subtitle)
            case .table(let t):
                if t.rows.isEmpty { continue }
                let rows = t.rows.prefix(maxTableRows).enumerated().map { i, row in
                    row.map { DeckCell(text: $0, bold: t.emphasized.contains(i)) }
                }
                out.append(.table(DeckTable(title: t.title, subtitle: t.subtitle, columns: t.columns, rows: Array(rows), numeric: t.numericColumns,
                                            footnote: t.rows.count > maxTableRows ? "Showing \(maxTableRows) of \(Fmt.int(t.rows.count)) rows. The CSV export has them all." : "")))
            case .bars(let t, let subtitle, let items, let format):
                if items.isEmpty { continue }
                let top = items.prefix(maxBars)
                let peak = top.map(\.value).max() ?? 0
                let rows = top.map { item -> (String, String, Double) in
                    var value = formatted(item.value, format)
                    if case .count = format {} else if item.count > 0 { value += " (\(Fmt.int(item.count)))" }
                    return (item.label, value, peak > 0 ? max(0, item.value / peak) : 0)
                }
                out.append(.bars(t, subtitle, rows, more: items.count - top.count))
            case .notes(let t, let lines):
                if !lines.isEmpty { out.append(.bullets(t, lines)) }
            }
        }
        if o.includeAssumptions && !r.assumptions.isEmpty {
            out.append(.table(DeckTable(title: "Assumptions", columns: ["Assumption", "Value"],
                                        rows: r.assumptions.map { [DeckCell(text: $0.0), DeckCell(text: $0.1)] })))
        }
        return out
    }

    /// `subtitle` replaces the generated "n of m checks need attention" caption.
    static func checkBlocks(_ title: String, _ checks: [SolutionCheck], _ o: DeckOptions, subtitle caption: String = "") -> [DeckBlock] {
        // Stable sort, worst first.
        let sorted = checks.enumerated().sorted { ($0.element.status, $0.offset) < ($1.element.status, $1.offset) }.map(\.element)
        let open = sorted.filter { $0.status != .ready }
        let shown = o.includeReadyChecks ? sorted : open
        let passed = checks.count - open.count
        var subtitle = open.isEmpty ? "All \(checks.count) checks passed" : "\(open.count) of \(checks.count) checks need attention"
        if !open.isEmpty && passed > 0 && !o.includeReadyChecks { subtitle += " · \(passed) passed (not listed)" }
        if !caption.isEmpty { subtitle = caption }
        guard !shown.isEmpty else { return [.bullets(title, [subtitle + (caption.isEmpty ? "." : "")])] }
        let rows = shown.map { c in
            [DeckCell(text: c.status.label, bold: true, fill: .status(c.status), color: .rgb("FFFFFF")),
             DeckCell(text: c.area), DeckCell(text: c.title, bold: true), DeckCell(text: c.summary)]
        }
        var out: [DeckBlock] = [.table(DeckTable(title: title, subtitle: subtitle, columns: ["Status", "Area", "Check", "Result"], rows: rows,
                                                 fixed: [0: 1.05]))]
        out += open.prefix(max(0, o.issueDetails)).map { .issue($0) }
        return out
    }

    static func formatted(_ v: Double, _ format: ValueFormat) -> String {
        switch format {
        case .count: return Fmt.int(Int(v.rounded()))
        case .capacityMiB: return Fmt.capacity(mib: v)
        case .currency: return SFmt.usd(v)
        case .number(let unit): return SFmt.num(v) + (unit.isEmpty ? "" : " " + unit)
        }
    }
}

// MARK: - Drawing

enum DeckColor {
    case scheme(String)
    /// A scheme colour at an opacity in percent. Washes and muted text use this rather than a tint so they read on
    /// dark templates too: a tint towards white turns into white-on-white when the template's text is light.
    case alpha(String, Int)
    case rgb(String)

    static let muted = DeckColor.alpha("tx1", 72)
    static let hairline = DeckColor.alpha("tx1", 25)
    static let band = DeckColor.alpha("accent1", 18)
    static let tile = DeckColor.alpha("accent1", 12)

    static func status(_ s: CheckStatus) -> DeckColor {
        switch s {
        case .blocker: return .rgb("C62828")
        case .warning: return .rgb("B26A00")
        case .info: return .rgb("1565C0")
        case .ready: return .rgb("2E7D32")
        }
    }

    var xml: String {
        switch self {
        case .scheme(let v): return "<a:schemeClr val=\"\(v)\"/>"
        case .alpha(let v, let pct): return "<a:schemeClr val=\"\(v)\"><a:alpha val=\"\(pct * 1000)\"/></a:schemeClr>"
        case .rgb(let hex): return "<a:srgbClr val=\"\(hex)\"/>"
        }
    }
    var fill: String { "<a:solidFill>\(xml)</a:solidFill>" }
}

struct Rect { var x, y, w, h: Int }

let emuPerInch = 914_400
let emuPerPoint = 12_700
func inch(_ v: Double) -> Int { Int(v * Double(emuPerInch)) }

func xmlEscape(_ s: String) -> String {
    var out = ""
    out.reserveCapacity(s.count)
    for ch in s.unicodeScalars {
        switch ch {
        case "&": out += "&amp;"
        case "<": out += "&lt;"
        case ">": out += "&gt;"
        case "\"": out += "&quot;"
        case "\t", "\n", "\r": out += " "
        default: if ch.value >= 0x20 && !(0xFFFE...0xFFFF).contains(ch.value) { out.unicodeScalars.append(ch) }
        }
    }
    return out
}

struct Run {
    var text: String
    var size: Double
    var bold = false
    var color: DeckColor?
    var italic = false
    /// Shown in capitals (the text itself is unchanged, so it can still be edited or searched as written).
    var caps = false

    var xml: String {
        "<a:r><a:rPr lang=\"en-US\" sz=\"\(Int(size * 100))\"\(bold ? " b=\"1\"" : "")\(italic ? " i=\"1\"" : "")\(caps ? " cap=\"all\"" : "") dirty=\"0\">"
            + "\(color.map(\.fill) ?? "")</a:rPr><a:t>\(xmlEscape(text))</a:t></a:r>"
    }
}

/// Estimated text metrics, for wrapping and pagination (PowerPoint lays text out itself on open).
enum TextFit {
    /// Average glyph width as a fraction of the font size; generous so estimates err towards more lines.
    static let glyph = 0.52

    static func lines(_ text: String, width: Int, size: Double) -> Int {
        let perLine = max(1, Int(Double(width) / (size * glyph * Double(emuPerPoint))))
        var total = 0
        for para in text.split(separator: "\n", omittingEmptySubsequences: false) {
            var lines = 1, used = 0
            for word in para.split(separator: " ") {
                let n = word.count
                if used == 0 { used = n } else if used + 1 + n <= perLine { used += 1 + n } else { lines += 1; used = n }
                while used > perLine { lines += 1; used -= perLine }
            }
            total += lines
        }
        return max(1, total)
    }

    static func lineHeight(_ size: Double) -> Int { Int(size * 1.2 * Double(emuPerPoint)) }

    static func height(_ text: String, width: Int, size: Double) -> Int { lines(text, width: width, size: size) * lineHeight(size) }
}

/// Collects one slide's shapes.
struct SlideXML {
    var shapes = ""
    private var nextID = 2

    mutating func id() -> Int { defer { nextID += 1 }; return nextID }

    /// A text box or filled shape. `paras` are complete <a:p> elements.
    mutating func shape(_ r: Rect, paras: [String] = [], geom: String = "rect", fill: DeckColor? = nil, line: DeckColor? = nil,
                        anchor: String = "t", inset: Int = inch(0.05), autofit: Bool = false) {
        let n = id()
        let body = paras.isEmpty ? "<a:p><a:endParaRPr lang=\"en-US\" dirty=\"0\"/></a:p>" : paras.joined()
        shapes += "<p:sp><p:nvSpPr><p:cNvPr id=\"\(n)\" name=\"Shape \(n)\"/><p:cNvSpPr\(fill == nil ? " txBox=\"1\"" : "")/><p:nvPr/></p:nvSpPr>"
            + "<p:spPr><a:xfrm><a:off x=\"\(r.x)\" y=\"\(r.y)\"/><a:ext cx=\"\(max(r.w, 0))\" cy=\"\(max(r.h, 0))\"/></a:xfrm><a:prstGeom prst=\"\(geom)\"><a:avLst/></a:prstGeom>"
            + (fill?.fill ?? "<a:noFill/>") + "<a:ln>" + (line.map { $0.fill } ?? "<a:noFill/>") + "</a:ln></p:spPr>"
            + "<p:txBody><a:bodyPr wrap=\"square\" lIns=\"\(inset)\" tIns=\"\(inset)\" rIns=\"\(inset)\" bIns=\"\(inset)\" anchor=\"\(anchor)\" rtlCol=\"0\">"
            + (autofit ? "<a:normAutofit/>" : "<a:noAutofit/>") + "</a:bodyPr><a:lstStyle/>\(body)</p:txBody></p:sp>"
    }

    /// A placeholder from the slide's layout (position and style come from the template), or a text box when the layout has none.
    /// Each line is a paragraph.
    /// `fontScale` (0–1) shrinks the text the way PowerPoint's autofit would, which it only applies once a slide is edited.
    mutating func placeholder(_ ph: Placeholder?, fallback: Rect, lines: [String], size: Double, bold: Bool = false, color: DeckColor? = nil, fontScale: Double = 1) {
        guard let ph else {
            shape(fallback, paras: lines.map { para([Run(text: $0, size: size, bold: bold, color: color)]) }, anchor: "b", autofit: true)
            return
        }
        let n = id()
        let attrs = (ph.type.map { " type=\"\($0)\"" } ?? "") + (ph.idx.map { " idx=\"\($0)\"" } ?? "")
        let body = lines.map { "<a:p><a:r><a:rPr lang=\"en-US\" dirty=\"0\"/><a:t>\(xmlEscape($0))</a:t></a:r></a:p>" }.joined()
        shapes += "<p:sp><p:nvSpPr><p:cNvPr id=\"\(n)\" name=\"Placeholder \(n)\"/><p:cNvSpPr><a:spLocks noGrp=\"1\"/></p:cNvSpPr><p:nvPr><p:ph\(attrs)/></p:nvPr></p:nvSpPr>"
            + "<p:spPr/><p:txBody><a:bodyPr><a:normAutofit\(fontScale < 1 ? " fontScale=\"\(Int(fontScale * 100_000))\"" : "")/></a:bodyPr><a:lstStyle/>\(body)</p:txBody></p:sp>"
    }

    mutating func table(_ r: Rect, widths: [Int], heights: [Int], rows: [[DeckCell]], header: Int, numeric: Set<Int>, size: Double) {
        let n = id()
        var x = "<p:graphicFrame><p:nvGraphicFramePr><p:cNvPr id=\"\(n)\" name=\"Table \(n)\"/><p:cNvGraphicFramePr><a:graphicFrameLocks noGrp=\"1\"/></p:cNvGraphicFramePr><p:nvPr/></p:nvGraphicFramePr>"
            + "<p:xfrm><a:off x=\"\(r.x)\" y=\"\(r.y)\"/><a:ext cx=\"\(widths.reduce(0, +))\" cy=\"\(heights.reduce(0, +))\"/></p:xfrm>"
            + "<a:graphic><a:graphicData uri=\"http://schemas.openxmlformats.org/drawingml/2006/table\"><a:tbl><a:tblPr firstRow=\"1\" bandRow=\"1\"/><a:tblGrid>"
            + widths.map { "<a:gridCol w=\"\($0)\"/>" }.joined() + "</a:tblGrid>"
        let border = "<a:ln w=\"6350\">\(DeckColor.hairline.fill)</a:ln>"
        let none = "<a:ln w=\"0\"><a:noFill/></a:ln>"
        for (i, row) in rows.enumerated() {
            x += "<a:tr h=\"\(heights[i])\">"
            let isHeader = i < header
            var covered = 0
            for (c, cell) in row.enumerated() {
                if covered > 0 {
                    covered -= 1
                    x += "<a:tc hMerge=\"1\"><a:txBody><a:bodyPr/><a:lstStyle/><a:p><a:endParaRPr lang=\"en-US\" dirty=\"0\"/></a:p></a:txBody><a:tcPr/></a:tc>"
                    continue
                }
                covered = max(0, min(cell.span, row.count - c) - 1)
                let align = numeric.contains(c) ? "<a:pPr algn=\"r\"/>" : ""
                let color = cell.color ?? (isHeader ? .scheme("bg1") : nil)
                let run = cell.text.isEmpty ? "<a:endParaRPr lang=\"en-US\" sz=\"\(Int(size * 100))\" dirty=\"0\"/>"
                    : Run(text: cell.text, size: size, bold: cell.bold || isHeader, color: color).xml
                let fill = cell.fill ?? (isHeader ? .scheme("accent1") : (i - header) % 2 == 1 ? .band : nil)
                x += "<a:tc\(covered > 0 ? " gridSpan=\"\(covered + 1)\"" : "")><a:txBody><a:bodyPr/><a:lstStyle/><a:p>\(align)\(run)</a:p></a:txBody>"
                    + "<a:tcPr marL=\"\(inch(0.08))\" marR=\"\(inch(0.08))\" marT=\"\(inch(0.04))\" marB=\"\(inch(0.04))\" anchor=\"ctr\">"
                    + borders(left: none, right: none, top: none, bottom: border)
                    + (fill?.fill ?? "<a:noFill/>") + "</a:tcPr></a:tc>"
            }
            x += "</a:tr>"
        }
        shapes += x + "</a:tbl></a:graphicData></a:graphic></p:graphicFrame>"
    }

    /// Cell borders in the order a:tcPr requires; `ln` elements renamed to lnL/lnR/lnT/lnB.
    private func borders(left: String, right: String, top: String, bottom: String) -> String {
        func rename(_ ln: String, _ tag: String) -> String {
            ln.replacingOccurrences(of: "<a:ln ", with: "<a:\(tag) ").replacingOccurrences(of: "</a:ln>", with: "</a:\(tag)>")
        }
        return rename(left, "lnL") + rename(right, "lnR") + rename(top, "lnT") + rename(bottom, "lnB")
    }

    func xml() -> String {
        "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>\n"
            + "<p:sld xmlns:a=\"http://schemas.openxmlformats.org/drawingml/2006/main\" xmlns:r=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships\" xmlns:p=\"http://schemas.openxmlformats.org/presentationml/2006/main\">"
            + "<p:cSld><p:spTree><p:nvGrpSpPr><p:cNvPr id=\"1\" name=\"\"/><p:cNvGrpSpPr/><p:nvPr/></p:nvGrpSpPr>"
            + "<p:grpSpPr><a:xfrm><a:off x=\"0\" y=\"0\"/><a:ext cx=\"0\" cy=\"0\"/><a:chOff x=\"0\" y=\"0\"/><a:chExt cx=\"0\" cy=\"0\"/></a:xfrm></p:grpSpPr>"
            + shapes + "</p:spTree></p:cSld><p:clrMapOvr><a:masterClrMapping/></p:clrMapOvr></p:sld>"
    }
}

func para(_ runs: [Run], align: String? = nil, bullet: Bool = false, spaceBefore: Double = 0) -> String {
    var ppr = ""
    if bullet {
        ppr = "<a:pPr marL=\"\(inch(0.3))\" indent=\"-\(inch(0.3))\"\(align.map { " algn=\"\($0)\"" } ?? "")>"
            + (spaceBefore > 0 ? "<a:spcBef><a:spcPts val=\"\(Int(spaceBefore * 100))\"/></a:spcBef>" : "")
            + "<a:buFont typeface=\"Arial\"/><a:buChar char=\"•\"/></a:pPr>"
    } else if align != nil || spaceBefore > 0 {
        ppr = "<a:pPr\(align.map { " algn=\"\($0)\"" } ?? "")>" + (spaceBefore > 0 ? "<a:spcBef><a:spcPts val=\"\(Int(spaceBefore * 100))\"/></a:spcBef>" : "") + "<a:buNone/></a:pPr>"
    }
    return "<a:p>\(ppr)\(runs.map(\.xml).joined())</a:p>"
}
