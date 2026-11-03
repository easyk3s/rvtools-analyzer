import Foundation

// Prices a custom solution can read. Nothing here touches the network: built-in prices come from
// `PriceStore` (downloaded earlier, cached or saved in a project), custom prices from `.rvaprices` files.

/// A user price list (`Name.rvaprices`, JSON). Either a full price sheet per region, or negotiated rates
/// layered on the built-in Azure / AWS list prices (`basedOn` + discounts + per-instance overrides).
public struct PriceList: Codable, Sendable, Identifiable {
    public static let fileExtension = "rvaprices"
    public static let currentFormat = 1

    public var formatVersion: Int?
    /// Provider id scripts use, e.g. "acme-ea-azure".
    public var id: String
    public var name: String
    /// ISO 4217 code; USD when omitted.
    public var currency: String?
    public var source: String?
    public var effective: String?
    public var notes: String?
    /// "azure" or "aws": start from those downloaded list prices.
    public var basedOn: String?
    /// Applied to every instance rate of the base prices.
    public var discountPct: Double?
    public var storageDiscountPct: Double?
    public var regions: [Region]?

    public struct Region: Codable, Sendable {
        public var region: String
        public var name: String?
        public var discountPct: Double?
        public var storageDiscountPct: Double?
        /// Added, or replacing (field by field) the base instance of the same name. Prices here are never discounted.
        public var instances: [Instance]?
        public var storage: [String: Double]?
        /// Anything else a solution needs (per-node, per-GB, per-month figures).
        public var extra: [String: Double]?
    }

    public struct Instance: Codable, Sendable {
        public var name: String
        public var family: String?
        public var category: String?
        public var vcpu: Int?
        public var memoryGiB: Double?
        public var linuxHourly: Double?
        public var windowsHourly: Double?
        public var reserved1yHourly: Double?
        public var reserved3yHourly: Double?
        public var prices: [String: Double]?

        func merged(onto base: InstanceOffer?) -> InstanceOffer {
            var o = InstanceOffer(name: name, family: family ?? base?.family ?? "", category: category ?? base?.category ?? "",
                                  vcpu: vcpu ?? base?.vcpu ?? 0, memoryGiB: memoryGiB ?? base?.memoryGiB ?? 0)
            o.linuxHourly = linuxHourly ?? base?.linuxHourly
            o.windowsHourly = windowsHourly ?? base?.windowsHourly
            o.reserved1yHourly = reserved1yHourly ?? base?.reserved1yHourly
            o.reserved3yHourly = reserved3yHourly ?? base?.reserved3yHourly
            o.prices = prices.map { (base?.prices ?? [:]).merging($0) { _, new in new } } ?? base?.prices
            return o
        }
    }

    public var currencyCode: String { (currency ?? "USD").uppercased() }
    public var baseProvider: CloudProvider? { basedOn.flatMap { CloudProvider(rawValue: $0.lowercased()) } }
    public var regionCodes: [String] { (regions ?? []).map(\.region) }

    public static func read(_ url: URL) throws -> PriceList {
        let data: Data
        do { data = try Data(contentsOf: url) } catch { throw ExtensionError("Can't read \(url.lastPathComponent)") }
        do { return try JSONDecoder().decode(PriceList.self, from: data) } catch {
            throw ExtensionError("\(url.lastPathComponent): \(describeDecodingError(error))")
        }
    }

    /// Problems that stop the list from being used (empty when valid).
    public var problems: [String] {
        var p: [String] = []
        if let f = formatVersion, f > Self.currentFormat { p.append("needs a newer version of RVTools Analyzer (format \(f))") }
        if !ExtensionID.isValid(id) { p.append("id “\(id)” must be up to 64 lowercase letters, digits, dots, dashes or underscores") }
        if CloudProvider(rawValue: id) != nil { p.append("id “\(id)” is reserved for the built-in list prices") }
        if name.trimmingCharacters(in: .whitespaces).isEmpty { p.append("name is empty") }
        if let b = basedOn, CloudProvider(rawValue: b.lowercased()) == nil { p.append("basedOn must be “azure” or “aws”") }
        if basedOn == nil && regionCodes.isEmpty { p.append("add at least one region, or set basedOn to start from the built-in list prices") }
        if regionCodes.contains(where: { $0.isEmpty }) { p.append("every region needs a region code") }
        if Set(regionCodes).count != regionCodes.count { p.append("a region is listed more than once") }
        let discounts = [discountPct, storageDiscountPct] + (regions ?? []).flatMap { [$0.discountPct, $0.storageDiscountPct] }
        if discounts.compactMap({ $0 }).contains(where: { $0 < 0 || $0 >= 100 }) { p.append("discounts must be at least 0 and below 100") }
        if (regions ?? []).contains(where: { ($0.instances ?? []).contains { $0.name.isEmpty } }) { p.append("every instance needs a name") }
        return p
    }
}

/// Prices for one provider and region in the shape scripts receive (`pricing.get`).
public struct PriceSheet: Codable, Sendable {
    public var provider: String
    public var providerName: String
    public var region: String
    public var regionName: String
    public var currency: String
    public var source: String
    /// When the underlying list prices were downloaded (built-in or based-on lists).
    public var fetched: Date?
    public var effective: String?
    public var builtIn: Bool
    public var stale: Bool
    public var instances: [InstanceOffer]
    public var storage: [String: Double]
    public var extra: [String: Double]
}

public struct PriceProviderInfo: Codable, Sendable, Hashable {
    public var id: String
    public var name: String
    public var installed: Bool
    public var builtIn: Bool
    public var currency: String
    public var basedOn: String?
    public var source: String
    public var effective: String?
    public var origin: String
    /// Regions with prices available now.
    public var regions: [String]
}

/// A price sheet a solution read during a run (so projects can keep it).
public struct PriceRef: Hashable, Sendable {
    public let provider: String
    public let region: String
    public init(provider: String, region: String) { self.provider = provider; self.region = region }
}

/// Installed, solution-bundled and project price lists.
public final class PriceLibrary: @unchecked Sendable {
    public static let shared = PriceLibrary()

    public enum Origin: Sendable, Hashable {
        case installed, commandLine, solution(String), project

        public var label: String {
            switch self {
            case .installed: return "Installed"
            case .commandLine: return "Command line"
            case .solution(let id): return "Bundled with \(id)"
            case .project: return "From the open project"
            }
        }
    }

    public struct Entry: Sendable, Identifiable {
        public var id: String { list.id }
        public let list: PriceList
        public let url: URL?
        public let origin: Origin
    }

    public struct Issue: Sendable, Hashable, Identifiable {
        public var id: String { path + "|" + message }
        public let path: String
        public let message: String
    }

    public static var directory: URL { SolutionLibrary.supportDirectory.appendingPathComponent("Price Lists", isDirectory: true) }

    private let lock = NSLock()
    private var entries: [String: Entry] = [:]
    private var projectEntries: [String: Entry] = [:]
    private var _issues: [Issue] = []
    private var _version = 0
    private var _extraFiles: [URL] = []

    private func locked<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    public var version: Int { locked { _version } }
    public var issues: [Issue] { locked { _issues } }
    /// Individual `.rvaprices` files to load besides the Price Lists folder (command line).
    public var extraFiles: [URL] {
        get { locked { _extraFiles } }
        set { locked { _extraFiles = newValue } }
    }

    /// Every usable list: installed, command-line and solution lists, then project lists that aren't installed.
    public var all: [Entry] {
        locked {
            (Array(entries.values) + projectEntries.values.filter { entries[$0.id] == nil })
                .sorted { $0.list.name.localizedCaseInsensitiveCompare($1.list.name) == .orderedAscending }
        }
    }

    /// The installed list wins over a project's copy of the same id.
    public func entry(_ id: String) -> Entry? { locked { entries[id] ?? projectEntries[id] } }

    static func files(in dir: URL) -> [URL] {
        // The URL-based listing fails with ENOTDIR on a symlinked folder, so list where it really is.
        ((try? FileManager.default.contentsOfDirectory(at: dir.resolvingSymlinksInPath(), includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension.lowercased() == PriceList.fileExtension }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    /// Rescans the Price Lists folder, command-line files and the lists bundled with solutions.
    public func reload(solutionFiles: [(url: URL, solutionID: String)] = []) {
        var found: [String: Entry] = [:]
        var issues: [Issue] = []
        func add(_ url: URL, _ origin: Origin) {
            do {
                let list = try PriceList.read(url)
                let problems = list.problems
                if !problems.isEmpty {
                    issues.append(Issue(path: url.path, message: problems.joined(separator: "; ")))
                } else if let existing = found[list.id] {
                    issues.append(Issue(path: url.path, message: "id “\(list.id)” is already used by \(existing.url?.path ?? existing.list.name) — ignored"))
                } else {
                    found[list.id] = Entry(list: list, url: url, origin: origin)
                }
            } catch {
                issues.append(Issue(path: url.path, message: error.localizedDescription))
            }
        }
        for url in Self.files(in: Self.directory) { add(url, .installed) }
        for url in extraFiles { add(url, .commandLine) }
        for (url, id) in solutionFiles { add(url, .solution(id)) }
        locked {
            entries = found
            _issues = issues
            _version += 1
        }
    }

    public var projectLists: [PriceList] { locked { projectEntries.values.map(\.list) } }

    /// Lists saved in the open project (used when the same id isn't installed).
    public func setProjectLists(_ lists: [PriceList]) {
        let valid = lists.filter { $0.problems.isEmpty }
        locked {
            projectEntries = Dictionary(valid.map { ($0.id, Entry(list: $0, url: nil, origin: .project)) }, uniquingKeysWith: { a, _ in a })
            _version += 1
        }
    }

    /// Copies a price list into the Price Lists folder, replacing an installed list with the same id. Call `reload` afterwards.
    @discardableResult
    public func install(_ url: URL) throws -> PriceList {
        let list = try PriceList.read(url)
        let problems = list.problems
        guard problems.isEmpty else { throw ExtensionError("\(url.lastPathComponent): " + problems.joined(separator: "; ")) }
        let fm = FileManager.default
        try fm.createDirectory(at: Self.directory, withIntermediateDirectories: true)
        let dest = Self.directory.appendingPathComponent("\(list.id).\(PriceList.fileExtension)")
        guard dest.resolvingSymlinksInPath() != url.resolvingSymlinksInPath() else { return list }
        for existing in Self.files(in: Self.directory) where existing.resolvingSymlinksInPath() == dest.resolvingSymlinksInPath() || (try? PriceList.read(existing))?.id == list.id {
            try fm.trashItem(at: existing, resultingItemURL: nil)
        }
        try fm.copyItem(at: url, to: dest)
        return list
    }

    /// Moves an installed list to the Trash. Call `reload` afterwards.
    public func remove(_ id: String) throws {
        guard let e = locked({ entries[id] }), let url = e.url else { return }
        guard e.origin == .installed else { throw ExtensionError("“\(e.list.name)” isn't in the Price Lists folder (\(e.origin.label)); remove it where it's loaded from.") }
        try FileManager.default.trashItem(at: url, resultingItemURL: nil)
    }

    // MARK: Resolving prices

    public func providerName(_ id: String) -> String {
        if let p = CloudProvider(rawValue: id) { return "\(p.name) list prices" }
        return entry(id)?.list.name ?? id
    }

    public func info(_ id: String) -> PriceProviderInfo {
        if let p = CloudProvider(rawValue: id) {
            return PriceProviderInfo(id: id, name: providerName(id), installed: true, builtIn: true, currency: "USD", basedOn: nil,
                                     source: Self.builtInSource(p), effective: nil, origin: "Built in", regions: regions(id))
        }
        guard let e = entry(id) else {
            return PriceProviderInfo(id: id, name: id, installed: false, builtIn: false, currency: "", basedOn: nil, source: "", effective: nil, origin: "Not installed", regions: [])
        }
        return PriceProviderInfo(id: id, name: e.list.name, installed: true, builtIn: false, currency: e.list.currencyCode, basedOn: e.list.baseProvider?.rawValue,
                                 source: e.list.source ?? "", effective: e.list.effective, origin: e.origin.label, regions: regions(id))
    }

    static func builtInSource(_ p: CloudProvider) -> String {
        p == .azure ? "Azure Retail Prices API (public list prices)" : "AWS public price list (on-demand)"
    }

    /// Region codes with prices available now (no network).
    public func regions(_ provider: String) -> [String] {
        if let p = CloudProvider(rawValue: provider) { return PriceStore.shared.availableRegions(p) }
        guard let e = entry(provider) else { return [] }
        guard let base = e.list.baseProvider else { return e.list.regionCodes }
        let available = PriceStore.shared.availableRegions(base)
        return e.list.regionCodes.isEmpty ? available : e.list.regionCodes.filter(available.contains)
    }

    /// Every region a provider can price (for region pickers), whether or not its prices are available yet.
    public func knownRegions(_ provider: String) -> [(code: String, name: String)] {
        if let p = CloudProvider(rawValue: provider) { return CloudRegions.list(p).map { ($0.code, $0.name) } }
        guard let e = entry(provider) else { return [] }
        if let base = e.list.baseProvider, e.list.regionCodes.isEmpty { return CloudRegions.list(base).map { ($0.code, $0.name) } }
        return (e.list.regions ?? []).map { r in (r.region, r.name ?? e.list.baseProvider.map { CloudRegions.name($0, r.region) } ?? r.region) }
    }

    public func sheet(_ provider: String, _ region: String) throws -> PriceSheet {
        if let p = CloudProvider(rawValue: provider) {
            guard let rp = PriceStore.shared.cachedPrices(p, region) else {
                throw ExtensionError("\(p.name) list prices for \(CloudRegions.name(p, region)) (\(region)) haven't been downloaded — use Download Prices.")
            }
            return Self.sheet(rp)
        }
        guard let e = entry(provider) else {
            throw ExtensionError("The price list “\(provider)” isn't installed — import it in Settings › Price Lists.")
        }
        return try resolve(e.list, region)
    }

    static func sheet(_ rp: RegionPrices) -> PriceSheet {
        PriceSheet(provider: rp.provider.rawValue, providerName: "\(rp.provider.name) list prices", region: rp.region,
                   regionName: CloudRegions.name(rp.provider, rp.region), currency: "USD", source: builtInSource(rp.provider),
                   fetched: rp.fetched, effective: nil, builtIn: true, stale: Date().timeIntervalSince(rp.fetched) > PriceStore.maxAge,
                   instances: rp.instances, storage: rp.storage, extra: [:])
    }

    func resolve(_ list: PriceList, _ code: String) throws -> PriceSheet {
        let r = list.regions?.first { $0.region == code }
        if r == nil && !(list.baseProvider != nil && list.regionCodes.isEmpty) {
            throw ExtensionError("“\(list.name)” has no prices for \(code) (it covers \(list.regionCodes.joined(separator: ", "))).")
        }
        var instances: [InstanceOffer] = []
        var storage: [String: Double] = [:]
        var fetched: Date?
        var stale = false
        var source = list.source ?? list.name
        if let base = list.baseProvider {
            guard let rp = PriceStore.shared.cachedPrices(base, code) else {
                throw ExtensionError("“\(list.name)” starts from \(base.name) list prices, which haven't been downloaded for \(CloudRegions.name(base, code)) (\(code)) — use Download Prices.")
            }
            let d = (r?.discountPct ?? list.discountPct ?? 0) / 100
            let sd = (r?.storageDiscountPct ?? list.storageDiscountPct ?? 0) / 100
            let off = { (v: Double?) in v.map { $0 * (1 - d) } }
            instances = rp.instances.map { o in
                var x = o
                x.linuxHourly = off(o.linuxHourly)
                x.windowsHourly = off(o.windowsHourly)
                x.reserved1yHourly = off(o.reserved1yHourly)
                x.reserved3yHourly = off(o.reserved3yHourly)
                x.prices = o.prices?.mapValues { $0 * (1 - d) }
                return x
            }
            storage = rp.storage.mapValues { $0 * (1 - sd) }
            fetched = rp.fetched
            stale = Date().timeIntervalSince(rp.fetched) > PriceStore.maxAge
            source += " — \(base.name) list prices downloaded \(Fmt.date(rp.fetched))"
                + (d > 0 ? ", less \(SFmt.num(d * 100))%" : "") + (sd > 0 ? " (storage less \(SFmt.num(sd * 100))%)" : "")
        }
        var index = Dictionary(instances.enumerated().map { ($1.name, $0) }, uniquingKeysWith: { a, _ in a })
        for i in r?.instances ?? [] {
            if let at = index[i.name] {
                instances[at] = i.merged(onto: instances[at])
            } else {
                index[i.name] = instances.count
                instances.append(i.merged(onto: nil))
            }
        }
        for (k, v) in r?.storage ?? [:] { storage[k] = v }
        let regionName = r?.name ?? list.baseProvider.map { CloudRegions.name($0, code) } ?? code
        return PriceSheet(provider: list.id, providerName: list.name, region: code, regionName: regionName, currency: list.currencyCode,
                          source: source, fetched: fetched, effective: list.effective, builtIn: false, stale: stale,
                          instances: instances, storage: storage, extra: r?.extra ?? [:])
    }
}
