import Foundation

/// A saved session, stored as a package directory (`Name.rvaproj`):
///
///     Name.rvaproj/
///       project.json      settings: scope, thresholds, acknowledged findings, per-solution VM selections, assumptions, notes
///       sources/…         copies of the RVTools exports (so the project survives the originals moving)
///                         — trend projects keep one sources/snapshot-N/ folder per point in time
///       prices/…          cloud price snapshots used by the estimates (reproducible later), plus copies of the
///                         custom price lists (.rvaprices) custom solutions read
///
/// Being plain files, projects can live anywhere — local disk, iCloud Drive or a OneDrive / SharePoint folder.
public struct ProjectFile: Codable, Sendable {
    public static let fileExtension = "rvaproj"
    public static let currentFormat = 1
    public static let trendMode = "trend"

    public var formatVersion = ProjectFile.currentFormat
    public var name: String
    public var notes = ""
    public var created: Date
    public var modified: Date
    /// Source files, relative to the package.
    public var sources: [String] = []
    /// Where the sources were originally loaded from (informational).
    public var originalSources: [String] = []
    public var scopeID = "all"
    public var thresholds = Thresholds()
    public var solutionSelections: [String: [String]] = [:]
    public var solutionParams: [String: ParamValues] = [:]
    public var solutionTabs: [String: Int] = [:]
    /// Findings and whole checks acknowledged on the Issues page.
    public var acknowledgements: [Acknowledgement]?
    public var page: String?
    /// nil for a normal session; "trend" for a trend comparison.
    public var mode: String?
    /// Trend projects: source files (relative) per snapshot.
    public var snapshotGroups: [[String]]?
    /// Columns chosen for exports with non-standard headers, so reopening doesn't ask again.
    public var columnMapping: ColumnChoices?

    public init(name: String) {
        self.name = name
        created = Date()
        modified = created
    }

    public var isTrend: Bool { mode == ProjectFile.trendMode }

    public static func isProject(_ url: URL) -> Bool { url.pathExtension.lowercased() == fileExtension }

    /// Source files per snapshot (a single group for normal sessions).
    public func sourceGroups(in url: URL) -> [[URL]] {
        (snapshotGroups ?? [sources]).map { $0.map { url.appendingPathComponent($0) } }
    }

    private static var encoder: JSONEncoder {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        e.dateEncodingStrategy = .iso8601
        return e
    }

    /// Reads a project; returns it with the absolute URLs of its embedded sources and its price snapshots.
    public static func read(_ url: URL) throws -> (project: ProjectFile, sources: [URL], prices: [RegionPrices], priceLists: [PriceList]) {
        let data: Data
        do { data = try Data(contentsOf: url.appendingPathComponent("project.json")) } catch {
            throw RVToolsError.unreadable("\(url.lastPathComponent) is not a readable RVTools Analyzer project")
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let project = try decoder.decode(ProjectFile.self, from: data)
        guard project.formatVersion <= currentFormat else {
            throw RVToolsError.unreadable("\(url.lastPathComponent) was saved by a newer version of RVTools Analyzer")
        }
        let sources = project.sources.map { url.appendingPathComponent($0) }
        if let missing = sources.first(where: { !FileManager.default.fileExists(atPath: $0.path) }) {
            throw RVToolsError.unreadable("The project is missing its source file \(missing.lastPathComponent)")
        }
        let priceFiles = (try? FileManager.default.contentsOfDirectory(at: url.appendingPathComponent("prices"), includingPropertiesForKeys: nil)) ?? []
        let prices = priceFiles.filter { $0.pathExtension == "json" }.compactMap { try? JSONDecoder().decode(RegionPrices.self, from: Data(contentsOf: $0)) }
        let lists = priceFiles.filter { $0.pathExtension == PriceList.fileExtension }.compactMap { try? PriceList.read($0) }
        return (project, sources, prices, lists)
    }

    /// Writes the project. With `copySources` the whole package is rebuilt with copies of those files;
    /// without it only project.json and the price snapshots are rewritten (autosave).
    public static func write(_ project: ProjectFile, to url: URL, copySources: [URL]?, prices: [RegionPrices], priceLists: [PriceList] = []) throws -> ProjectFile {
        guard let sources = copySources else {
            var p = project
            p.modified = Date()
            try writeContents(p, prices: prices, priceLists: priceLists, into: url)
            return p
        }
        return try write(project, to: url, copyGroups: [sources], prices: prices, priceLists: priceLists)
    }

    /// Rebuilds the package with copies of the given source groups (one group per trend snapshot) and swaps it
    /// into place atomically.
    public static func write(_ project: ProjectFile, to url: URL, copyGroups groups: [[URL]], prices: [RegionPrices], priceLists: [PriceList] = []) throws -> ProjectFile {
        let fm = FileManager.default
        var p = project
        p.modified = Date()
        let parent = url.deletingLastPathComponent()
        let staging = (try? fm.url(for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: parent, create: true)) ?? fm.temporaryDirectory
        let tmp = staging.appendingPathComponent(UUID().uuidString + "." + fileExtension, isDirectory: true)
        try fm.createDirectory(at: tmp.appendingPathComponent("sources"), withIntermediateDirectories: true)
        var all: [String] = []
        var perGroup: [[String]] = []
        for (g, group) in groups.enumerated() {
            let base = groups.count > 1 ? "sources/snapshot-\(g + 1)/" : "sources/"
            var rels: [String] = []
            for src in group {
                // CSV exports keep their folder so each export stays grouped.
                let folder = src.pathExtension.lowercased() == "csv" ? src.deletingLastPathComponent().lastPathComponent + "/" : ""
                var rel = base + folder + src.lastPathComponent
                var n = 2
                while all.contains(rel) { rel = base + folder + "\(n)-" + src.lastPathComponent; n += 1 }
                let dest = tmp.appendingPathComponent(rel)
                try fm.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
                try fm.copyItem(at: src, to: dest)
                rels.append(rel)
                all.append(rel)
            }
            perGroup.append(rels)
        }
        p.sources = all
        p.snapshotGroups = groups.count > 1 ? perGroup : nil
        if p.originalSources.isEmpty { p.originalSources = groups.flatMap { $0.map(\.path) } }
        try writeContents(p, prices: prices, priceLists: priceLists, into: tmp)
        if fm.fileExists(atPath: url.path) {
            _ = try fm.replaceItemAt(url, withItemAt: tmp)
        } else {
            try fm.moveItem(at: tmp, to: url)
        }
        try? fm.removeItem(at: staging)
        return p
    }

    private static func writeContents(_ p: ProjectFile, prices: [RegionPrices], priceLists: [PriceList], into dir: URL) throws {
        try encoder.encode(p).write(to: dir.appendingPathComponent("project.json"), options: .atomic)
        let pricesDir = dir.appendingPathComponent("prices")
        try? FileManager.default.removeItem(at: pricesDir)
        guard !prices.isEmpty || !priceLists.isEmpty else { return }
        try FileManager.default.createDirectory(at: pricesDir, withIntermediateDirectories: true)
        for rp in prices {
            try JSONEncoder().encode(rp).write(to: pricesDir.appendingPathComponent("\(rp.provider.rawValue)-\(rp.region).json"))
        }
        for list in priceLists {
            try encoder.encode(list).write(to: pricesDir.appendingPathComponent("\(list.id).\(PriceList.fileExtension)"))
        }
    }
}
