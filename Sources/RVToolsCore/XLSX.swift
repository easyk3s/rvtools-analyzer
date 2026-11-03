import Foundation

/// One worksheet / CSV file: header row + string cells. Every value is kept as text; typed access
/// happens later through `Parse`, so xlsx and csv inputs behave identically.
public struct RawTable {
    public var name: String
    public var headers: [String]
    public var rows: [[String]]
}

enum XLSXReader {
    static func read(url: URL) throws -> [RawTable] {
        let zip = try ZipArchive(url: url)
        guard zip.contains("xl/workbook.xml") else {
            throw RVToolsError.notRVTools("\(url.lastPathComponent) is not an Excel workbook")
        }
        let workbook = WorkbookParser.parse(try zip.read("xl/workbook.xml"))
        let rels = zip.contains("xl/_rels/workbook.xml.rels") ? RelsParser.parse(try zip.read("xl/_rels/workbook.xml.rels")) : [:]

        func resolve(_ target: String) -> String {
            var t = target
            if t.hasPrefix("/") { return String(t.dropFirst()) }
            while t.hasPrefix("./") { t.removeFirst(2) }
            if t.hasPrefix("../") { return String(t.dropFirst(3)) }
            return "xl/" + t
        }

        let sstPath = rels.values.first(where: { $0.type.hasSuffix("/sharedStrings") }).map { resolve($0.target) } ?? "xl/sharedStrings.xml"
        let stylesPath = rels.values.first(where: { $0.type.hasSuffix("/styles") }).map { resolve($0.target) } ?? "xl/styles.xml"
        let sst = zip.contains(sstPath) ? SharedStringsParser.parse(try zip.read(sstPath)) : []
        let dateStyles = zip.contains(stylesPath) ? StylesParser.parse(try zip.read(stylesPath)) : []

        var sheets: [(name: String, path: String)] = workbook.sheets.compactMap { sheet in
            guard let r = rels[sheet.rid] else { return nil }
            return (sheet.name, resolve(r.target))
        }
        if sheets.isEmpty {
            // Fallback for workbooks without relationship ids we understand.
            var i = 1
            while zip.contains("xl/worksheets/sheet\(i).xml") {
                sheets.append(("Sheet\(i)", "xl/worksheets/sheet\(i).xml")); i += 1
            }
        }

        final class Box: @unchecked Sendable {
            var tables: [RawTable?]
            var error: Error?
            let lock = NSLock()
            init(_ n: Int) { tables = Array(repeating: nil, count: n) }
        }
        let box = Box(sheets.count)
        DispatchQueue.concurrentPerform(iterations: sheets.count) { i in
            do {
                let xml = try zip.read(sheets[i].path)
                let table = SheetParser(sst: sst, dateStyles: dateStyles, date1904: workbook.date1904).parse(xml, name: sheets[i].name)
                box.lock.lock(); box.tables[i] = table; box.lock.unlock()
            } catch {
                box.lock.lock(); box.error = error; box.lock.unlock()
            }
        }
        if let error = box.error { throw error }
        return box.tables.compactMap { $0 }
    }
}

// MARK: - Small SAX helpers

@inline(__always) private func localName(_ qName: String) -> Substring {
    if let i = qName.lastIndex(of: ":") { return qName[qName.index(after: i)...] }
    return Substring(qName)
}

/// Excel escapes control characters in cell text as _xHHHH_.
func decodeExcelEscapes(_ s: String) -> String {
    guard s.contains("_x") else { return s }
    var out = ""
    var i = s.startIndex
    while i < s.endIndex {
        if s[i] == "_", let end = s.index(i, offsetBy: 7, limitedBy: s.endIndex), end <= s.endIndex,
           s.index(after: i) < s.endIndex, s[s.index(after: i)] == "x", s[s.index(before: end)] == "_",
           let code = UInt32(s[s.index(i, offsetBy: 2)..<s.index(before: end)], radix: 16),
           let scalar = Unicode.Scalar(code) {
            out.unicodeScalars.append(scalar)
            i = end
        } else {
            out.append(s[i]); i = s.index(after: i)
        }
    }
    return out
}

private final class WorkbookParser: NSObject, XMLParserDelegate {
    struct Sheet { let name: String; let rid: String }
    var sheets: [Sheet] = []
    var date1904 = false

    static func parse(_ data: Data) -> WorkbookParser {
        let d = WorkbookParser()
        let p = XMLParser(data: data); p.delegate = d; p.parse()
        return d
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?, attributes: [String: String] = [:]) {
        switch localName(elementName) {
        case "sheet":
            let rid = attributes.first(where: { $0.key == "id" || $0.key.hasSuffix(":id") })?.value ?? ""
            sheets.append(Sheet(name: attributes["name"] ?? "Sheet\(sheets.count + 1)", rid: rid))
        case "workbookPr":
            let v = (attributes["date1904"] ?? "").lowercased()
            date1904 = v == "1" || v == "true"
        default: break
        }
    }
}

private final class RelsParser: NSObject, XMLParserDelegate {
    var rels: [String: (type: String, target: String)] = [:]

    static func parse(_ data: Data) -> [String: (type: String, target: String)] {
        let d = RelsParser()
        let p = XMLParser(data: data); p.delegate = d; p.parse()
        return d.rels
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?, attributes: [String: String] = [:]) {
        guard localName(elementName) == "Relationship", let id = attributes["Id"], let target = attributes["Target"] else { return }
        rels[id] = (attributes["Type"] ?? "", target)
    }
}

private final class SharedStringsParser: NSObject, XMLParserDelegate {
    var strings: [String] = []
    var current = ""
    var inText = false
    var inPhonetic = false

    static func parse(_ data: Data) -> [String] {
        let d = SharedStringsParser()
        let p = XMLParser(data: data); p.delegate = d; p.parse()
        return d.strings
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?, attributes: [String: String] = [:]) {
        switch localName(elementName) {
        case "si": current = ""
        case "rPh": inPhonetic = true
        case "t": inText = !inPhonetic
        default: break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if inText { current += string }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        switch localName(elementName) {
        case "t": inText = false
        case "rPh": inPhonetic = false
        case "si": strings.append(decodeExcelEscapes(current))
        default: break
        }
    }
}

/// Returns, per cellXfs index, whether that style formats numbers as dates.
private final class StylesParser: NSObject, XMLParserDelegate {
    var numFmts: [Int: String] = [:]
    var xfFormats: [Int] = []
    var inCellXfs = false

    static func parse(_ data: Data) -> [Bool] {
        let d = StylesParser()
        let p = XMLParser(data: data); p.delegate = d; p.parse()
        return d.xfFormats.map { StylesParser.isDateFormat(id: $0, code: d.numFmts[$0]) }
    }

    static func isDateFormat(id: Int, code: String?) -> Bool {
        if (14...22).contains(id) || (27...36).contains(id) || (45...47).contains(id) || (50...58).contains(id) { return true }
        guard let code else { return false }
        var cleaned = ""
        var inQuote = false, inBracket = false
        for ch in code {
            if ch == "\"" { inQuote.toggle(); continue }
            if inQuote { continue }
            if ch == "[" { inBracket = true; continue }
            if ch == "]" { inBracket = false; continue }
            if inBracket { continue }
            cleaned.append(ch)
        }
        let lower = cleaned.lowercased()
        if lower == "general" { return false }
        return lower.contains { "dmyhs".contains($0) }
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?, attributes: [String: String] = [:]) {
        switch localName(elementName) {
        case "numFmt":
            if let id = Int(attributes["numFmtId"] ?? ""), let code = attributes["formatCode"] { numFmts[id] = code }
        case "cellXfs": inCellXfs = true
        case "xf" where inCellXfs: xfFormats.append(Int(attributes["numFmtId"] ?? "0") ?? 0)
        default: break
        }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        if localName(elementName) == "cellXfs" { inCellXfs = false }
    }
}

private final class SheetParser: NSObject, XMLParserDelegate {
    let sst: [String]
    let dateStyles: [Bool]
    let epoch: Date
    let formatter: DateFormatter

    var rows: [[String]] = []
    var row: [String] = []
    var col = 0
    var cellType = ""
    var cellStyle = 0
    var text = ""
    var capturing = false
    var inInline = false

    init(sst: [String], dateStyles: [Bool], date1904: Bool) {
        self.sst = sst
        self.dateStyles = dateStyles
        var c = DateComponents()
        c.year = date1904 ? 1904 : 1899; c.month = date1904 ? 1 : 12; c.day = date1904 ? 1 : 30
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        epoch = cal.date(from: c)!
        formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
    }

    func parse(_ data: Data, name: String) -> RawTable {
        let p = XMLParser(data: data)
        p.delegate = self
        p.parse()

        guard let headerIndex = rows.firstIndex(where: { $0.contains { !$0.isEmpty } }) else {
            return RawTable(name: name, headers: [], rows: [])
        }
        var headers = rows[headerIndex].map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        while let last = headers.last, last.isEmpty { headers.removeLast() }
        // A first row much narrower than the rest is a title, not a header: keep the columns for `SourceChecks` to find.
        let widest = rows.map { r in (r.lastIndex { !$0.isEmpty } ?? -1) + 1 }.max() ?? 0
        if headers.count * 2 < widest { headers += Array(repeating: "", count: widest - headers.count) }
        for i in headers.indices where headers[i].isEmpty { headers[i] = "Column \(i + 1)" }
        let n = headers.count
        var body: [[String]] = []
        body.reserveCapacity(max(0, rows.count - headerIndex - 1))
        for r in rows.dropFirst(headerIndex + 1) {
            guard r.contains(where: { !$0.isEmpty }) else { continue }
            if r.count == n { body.append(r) }
            else if r.count < n { body.append(r + Array(repeating: "", count: n - r.count)) }
            else { body.append(Array(r[0..<n])) }
        }
        rows = []
        return RawTable(name: name, headers: headers, rows: body)
    }

    private static func columnIndex(_ ref: String) -> Int {
        var idx = 0
        for u in ref.utf8 {
            switch u {
            case 65...90: idx = idx * 26 + Int(u - 64)
            case 97...122: idx = idx * 26 + Int(u - 96)
            default: return max(0, idx - 1)
            }
        }
        return max(0, idx - 1)
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?, attributes: [String: String] = [:]) {
        switch localName(elementName) {
        case "row":
            row = []; row.reserveCapacity(rows.last?.count ?? 16); col = 0
        case "c":
            if let r = attributes["r"] { col = SheetParser.columnIndex(r) }
            cellType = attributes["t"] ?? ""
            cellStyle = Int(attributes["s"] ?? "") ?? 0
            text = ""; inInline = false; capturing = false
        case "v":
            capturing = true; text = ""
        case "is":
            inInline = true; text = ""
        case "t":
            if inInline { capturing = true }
        default: break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if capturing { text += string }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        switch localName(elementName) {
        case "v": capturing = false
        case "t": if inInline { capturing = false }
        case "c":
            let value = resolveCell()
            if !value.isEmpty {
                if col >= row.count { row.append(contentsOf: repeatElement("", count: col - row.count + 1)) }
                row[col] = value
            }
            col += 1
        case "row":
            rows.append(row)
        default: break
        }
    }

    private func resolveCell() -> String {
        switch cellType {
        case "s":
            if let i = Int(text), i >= 0, i < sst.count { return sst[i] }
            return ""
        case "inlineStr", "str", "e":
            return decodeExcelEscapes(text)
        case "b":
            return text == "1" ? "True" : (text == "0" ? "False" : text)
        default:
            if !text.isEmpty, cellStyle < dateStyles.count, dateStyles[cellStyle], let serial = Double(text), serial > 0 {
                let seconds = (serial * 86_400).rounded()
                return formatter.string(from: epoch.addingTimeInterval(seconds))
            }
            return text
        }
    }
}
