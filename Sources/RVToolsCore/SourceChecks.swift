import Foundation

/// Something wrong with one export as it was read, found before its rows are merged with other exports: once merged,
/// a good file's columns and rows can hide a file that added nothing.
public struct SourceIssue: Hashable, Sendable {
    public let source: String
    public let message: String
    public let impact: String
    public let level: Level

    public enum Level: Sendable {
        /// Small enough to mention with the file's notes, without raising it on every page and in every deck.
        case note
        case warning
        /// None of this export's VMs were read, so every figure leaves it out.
        case noVMsRead
    }

    public var text: String { "\(source): \(message)" }
}

enum SourceChecks {
    /// A real export's header is its first row. One that's further down was usually sorted along with the data
    /// (Excel does this when it doesn't see a header row), so the rows above it are data too, and the first row, which
    /// the reader took as the header, is one of them. Rows too sparse to be data, such as a title, are dropped.
    /// Returns nil unless a later row is clearly the RVTools header, so renamed headers are left to `ColumnMatcher`.
    static func restoringHeader(_ raw: RawTable) -> (table: RawTable, row: Int)? {
        guard let columns = ColumnMatcher.canonicalColumns(for: raw.name) else { return nil }
        let expected = Set(columns.map(Table.normalize))
        let needed = max(5, expected.count / 2)
        func isHeader(_ cells: [String]) -> Bool { Set(cells.map(Table.normalize)).intersection(expected).count >= needed }
        guard !isHeader(raw.headers), let at = raw.rows.firstIndex(where: isHeader) else { return nil }

        let found = raw.rows[at].map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        let headers = found.indices.map { found[$0].isEmpty ? "Column \($0 + 1)" : found[$0] }
        let filled = found.filter { !$0.isEmpty }.count
        func isData(_ cells: [String]) -> Bool { cells.filter { !$0.isEmpty }.count * 2 >= filled }
        // The reader names blank header cells "Column N"; as a row of data they go back to being blank.
        let firstRow = raw.headers.indices.map { raw.headers[$0] == "Column \($0 + 1)" ? "" : raw.headers[$0] }
        let above = ([firstRow] + raw.rows[..<at]).filter(isData)
        let rows = (above + raw.rows[(at + 1)...]).map { r in
            r.count < headers.count ? r + Array(repeating: "", count: headers.count - r.count) : r
        }
        return (RawTable(name: raw.name, headers: headers, rows: rows), at + 2)
    }

    /// Rows that repeat the RVTools header, left behind by moving a header up or by pasting exports together. Read as
    /// data, one would be a VM called "VM". Returns nil when there are none.
    static func removingRepeatedHeaders(_ raw: RawTable) -> (table: RawTable, removed: Int)? {
        guard let columns = ColumnMatcher.canonicalColumns(for: raw.name) else { return nil }
        let expected = Set(columns.map(Table.normalize))
        let needed = max(5, expected.count / 2)
        let rows = raw.rows.filter { Set($0.map(Table.normalize)).intersection(expected).count < needed }
        guard rows.count < raw.rows.count else { return nil }
        return (RawTable(name: raw.name, headers: raw.headers, rows: rows), raw.rows.count - rows.count)
    }

    /// `tables` are one export's tabs once its columns are settled.
    static func evaluate(source: String, tables raws: [RawTable]) -> [SourceIssue] {
        var out: [SourceIssue] = []
        func add(_ message: String, _ impact: String, level: SourceIssue.Level = .warning) {
            out.append(SourceIssue(source: source, message: message, impact: impact, level: level))
        }
        func table(_ name: String) -> Table? {
            raws.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }.map(Table.init(raw:))
        }
        /// RVTools repeats a one-cell placeholder on tabs it didn't fill, which isn't data.
        func dataRows(_ t: Table) -> [[String]] { t.rows.filter { r in r.filter { !$0.isEmpty }.count > 1 } }

        guard let info = table("vInfo") else {
            add("no vInfo tab, so none of its VMs were read", "VMs on other tabs were rebuilt from them, with fewer details, and start unselected in solutions", level: .noVMsRead)
            return out
        }
        let infoRows = dataRows(info)
        let cVM = info.col("VM")
        if infoRows.isEmpty {
            // Nothing to read if the hosts really have no VMs, which an export from one empty host does.
            let hosts = table("vHost")
            let hostRows = hosts.map(dataRows) ?? []
            let cVMs = hosts?.col("# VMs total") ?? hosts?.col("# VMs")
            let noVMs = cVMs != nil && !hostRows.isEmpty && !hostRows.contains { $0.d0(cVMs) != 0 }
            if !noVMs { add("vInfo has no rows, so none of its VMs were read", "VMs on other tabs were rebuilt from them, with fewer details, and start unselected in solutions", level: .noVMsRead) }
        } else if cVM == nil {
            add("vInfo has no VM column, so its \(Fmt.int(infoRows.count)) row(s) couldn't be read as VMs",
                "VMs on other tabs were rebuilt from them, with fewer details, and start unselected in solutions", level: .noVMsRead)
        }

        // Columns that hold nothing on any row: a figure that's zero everywhere is a column that wasn't read.
        let figures: [(tab: String, columns: [String], impact: String)] = [
            ("vInfo", ["CPUs", "Memory", "Provisioned MiB", "In Use MiB"], "VM totals and sizing are understated or derived from other tabs"),
            ("vHost", ["# Cores", "# Memory"], "Host capacity and vCPU:core ratios are unavailable"),
            ("vDatastore", ["Capacity MiB"], "Datastore capacity and free space are unavailable"),
            ("vDisk", ["Capacity MiB"], "Per-disk sizes are unavailable"),
            ("vPartition", ["Consumed MiB"], "Sizing that uses guest used space falls back to VM in-use"),
        ]
        for figure in figures {
            guard let t = table(figure.tab) else { continue }
            let rows = dataRows(t)
            guard !rows.isEmpty else { continue }
            let empty = figure.columns.filter { name in
                guard let c = t.col(name) else { return true }
                return !rows.contains { $0.d0(c) != 0 }
            }
            if !empty.isEmpty {
                add("\(figure.tab) has \(Fmt.int(rows.count)) row(s) but \(empty.joined(separator: ", ")) \(empty.count == 1 ? "is" : "are") blank or zero on all of them", figure.impact)
            }
        }

        // Tabs RVTools fills whenever an environment has VMs.
        if !infoRows.isEmpty {
            for name in ["vHost", "vDatastore", "vDisk"] {
                if let t = table(name), dataRows(t).isEmpty {
                    add("\(name) has no rows, though vInfo has \(Fmt.int(infoRows.count))", "Figures from \(name) are missing for this export")
                }
            }
        }

        // RVTools lists every VM on each VM tab, so a name that's only on the others was removed from vInfo (see `restoreVMsMissingFromVInfo`).
        if let cVM, !infoRows.isEmpty {
            let inInfo = Set(infoRows.map { $0.s(cVM) })
            var elsewhere = Set<String>()
            for name in ["vCPU", "vMemory", "vDisk", "vTools"] {
                guard let t = table(name), let c = t.col("VM") else { continue }
                for r in dataRows(t) where !r.s(c).isEmpty && !inInfo.contains(r.s(c)) { elsewhere.insert(r.s(c)) }
            }
            if !elsewhere.isEmpty {
                var capacity = 0.0
                if let t = table("vDisk"), let c = t.col("VM") {
                    let cCap = t.col("Capacity MiB")
                    for r in dataRows(t) where elsewhere.contains(r.s(c)) { capacity += r.d0(cCap) }
                }
                let names = elsewhere.sorted().prefix(3).joined(separator: ", ")
                let more = elsewhere.count > 3 ? " and \(Fmt.int(elsewhere.count - 3)) more" : ""
                add("\(Fmt.int(elsewhere.count)) VM(s) on other tabs aren't in vInfo, so they were rebuilt from those tabs\(capacity > 0 ? " (\(Fmt.capacity(mib: capacity)) of disks)" : ""): \(names)\(more)",
                    "They have fewer details, and solutions leave them out until you select them. Rows may have been deleted from vInfo before the file was shared",
                    // A handful can be VMs created or removed while RVTools was reading the tabs.
                    level: elsewhere.count * 100 < infoRows.count ? .note : .warning)
            }
        }
        return out
    }
}
