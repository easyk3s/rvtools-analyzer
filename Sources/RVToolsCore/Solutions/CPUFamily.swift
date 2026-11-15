import Foundation

/// A host's CPU generation, as vSphere's EVC modes order them, and the server platform family it belongs to.
/// Hosts of one family (Skylake and Cascade Lake, say) are interchangeable in practice; across families a cluster needs
/// EVC set to the oldest generation for vMotion, which hides the newer CPUs' features.
public struct CPUBaseline: Hashable, Sendable {
    /// "Intel", "AMD" or "" when unknown.
    public let vendor: String
    /// The EVC mode key for this generation (e.g. "intel-cascadelake"); "" when unknown.
    public let evc: String
    /// Order within the vendor: a lower rank is an older generation.
    public let rank: Int
    /// e.g. "Cascade Lake".
    public let name: String
    /// `CPUFamily` key.
    public let family: String

    public static let unknown = CPUBaseline(vendor: "", evc: "", rank: -1, name: "Unknown CPU", family: CPUFamily.unknown)

    /// From the host's highest EVC mode (its own generation), else from the CPU model name.
    public static func of(_ h: Host) -> CPUBaseline {
        let model = fromModel(h.cpuModel)
        if let g = fromEVC(h.evcMax) {
            // The model can name a generation EVC has no mode of its own for (Emerald Rapids runs as Sapphire Rapids).
            if let m = model, m.evc == g.evc, m.name != g.name { return m }
            return g
        }
        return model ?? .unknown
    }

    static let intelEVC: [(String, String)] = [
        ("intel-merom", "Merom"), ("intel-penryn", "Penryn"), ("intel-nehalem", "Nehalem"), ("intel-westmere", "Westmere"),
        ("intel-sandybridge", "Sandy Bridge"), ("intel-ivybridge", "Ivy Bridge"), ("intel-haswell", "Haswell"),
        ("intel-broadwell", "Broadwell"), ("intel-skylake", "Skylake"), ("intel-cascadelake", "Cascade Lake"),
        ("intel-icelake", "Ice Lake"), ("intel-sapphirerapids", "Sapphire Rapids"), ("intel-graniterapids", "Granite Rapids"),
    ]
    static let amdEVC: [(String, String)] = [
        ("amd-rev-e", "Rev E"), ("amd-rev-f", "Rev F"), ("amd-greyhound-no3dnow", "Greyhound (no 3DNow!)"), ("amd-greyhound", "Greyhound"),
        ("amd-bulldozer", "Bulldozer"), ("amd-piledriver", "Piledriver"), ("amd-steamroller", "Steamroller"),
        ("amd-zen", "Zen (EPYC 7001)"), ("amd-zen2", "Zen 2 (EPYC 7002)"), ("amd-zen3", "Zen 3 (EPYC 7003)"),
        ("amd-zen4", "Zen 4 (EPYC 9004)"), ("amd-zen5", "Zen 5 (EPYC 9005)"),
    ]

    static func intel(_ rank: Int, name: String? = nil) -> CPUBaseline {
        let e = intelEVC[rank]
        let family = rank <= 7 ? "intel-legacy" : (rank <= 9 ? "intel-sp12" : (rank == 10 ? "intel-sp3" : (rank == 11 ? "intel-sp45" : "intel-x6")))
        return CPUBaseline(vendor: "Intel", evc: e.0, rank: rank, name: name ?? e.1, family: family)
    }

    static func amd(_ rank: Int) -> CPUBaseline {
        let e = amdEVC[rank]
        let family = rank <= 6 ? "amd-legacy" : (rank <= 9 ? "amd-sp3" : "amd-sp5")
        return CPUBaseline(vendor: "AMD", evc: e.0, rank: rank, name: e.1, family: family)
    }

    public static func fromEVC(_ key: String) -> CPUBaseline? {
        let k = key.lowercased().trimmingCharacters(in: .whitespaces)
        if let i = intelEVC.firstIndex(where: { $0.0 == k }) { return intel(i) }
        if let i = amdEVC.firstIndex(where: { $0.0 == k }) { return amd(i) }
        return nil
    }

    /// Xeon Scalable model numbers carry the generation in their second digit (Gold 6248R: 2nd gen, Cascade Lake), E5/E7 in
    /// their version suffix, and EPYC in their last digit.
    static func fromModel(_ model: String) -> CPUBaseline? {
        let m = model.lowercased()
        if m.contains("xeon") {
            if let g = regexMatch(m, #"(platinum|gold|silver|bronze)\s+(\d)(\d)\d\d"#), let gen = Int(g[3]) {
                switch gen {
                case 1: return intel(8)
                case 2: return intel(9)
                case 3: return intel(10)
                case 4: return intel(11)
                case 5: return intel(11, name: "Emerald Rapids")
                default: break
                }
            }
            if regexMatch(m, #"xeon(\(r\))?\s+6\d{3}"#) != nil { return intel(12) }
            if let g = regexMatch(m, #"e[57]-\d{4}[a-z]?\s*v(\d)"#), let v = Int(g[1]) {
                return v == 2 ? intel(5) : (v == 3 ? intel(6) : (v >= 4 ? intel(7) : nil))
            }
            if regexMatch(m, #"e[57]-\d{4}"#) != nil { return intel(4) }
        }
        if m.contains("epyc"), let g = regexMatch(m, #"epyc\s+(\d)[0-9a-z]{2}(\d)"#), let series = Int(g[1]), let gen = Int(g[2]) {
            if series == 7, (1...3).contains(gen) { return amd(6 + gen) }
            if [4, 8, 9].contains(series), gen == 4 { return amd(10) }
            if series == 9, gen == 5 { return amd(11) }
        }
        return nil
    }
}

/// Server platform families: hosts that can share a cluster without EVC hiding much.
public enum CPUFamily {
    public static let unknown = "unknown"

    static let labels: [String: String] = [
        "intel-legacy": "Intel Xeon E5/E7 (Broadwell or older)",
        "intel-sp12": "Intel Xeon Scalable 1st–2nd gen (Skylake, Cascade Lake)",
        "intel-sp3": "Intel Xeon Scalable 3rd gen (Ice Lake)",
        "intel-sp45": "Intel Xeon Scalable 4th–5th gen (Sapphire, Emerald Rapids)",
        "intel-x6": "Intel Xeon 6 (Granite Rapids)",
        "amd-legacy": "AMD Opteron",
        "amd-sp3": "AMD EPYC 7001–7003 (Zen–Zen 3)",
        "amd-sp5": "AMD EPYC 9004–9005 (Zen 4–Zen 5)",
        unknown: "Unknown CPU",
    ]

    public static func label(_ key: String) -> String { labels[key] ?? key }

    /// Families of each vendor, oldest first.
    public static let intelOrder = ["intel-legacy", "intel-sp12", "intel-sp3", "intel-sp45", "intel-x6"]
    public static let amdOrder = ["amd-legacy", "amd-sp3", "amd-sp5"]

    /// The family's place among its vendor's families, oldest 0; nil when unknown.
    public static func index(_ key: String) -> Int? { intelOrder.firstIndex(of: key) ?? amdOrder.firstIndex(of: key) }

    /// A shorter name for tables, e.g. "Xeon SP 1–2".
    public static func short(_ key: String) -> String {
        [
            "intel-legacy": "Xeon E5/E7", "intel-sp12": "Xeon SP 1–2", "intel-sp3": "Xeon SP 3", "intel-sp45": "Xeon SP 4–5",
            "intel-x6": "Xeon 6", "amd-legacy": "Opteron", "amd-sp3": "EPYC 7003-", "amd-sp5": "EPYC 9004+", unknown: "Unknown",
        ][key] ?? key
    }

    /// The families of an export's hosts in one cluster, for pickers: (key, label, host count), most hosts first.
    public static func present(in inv: Inventory, cluster: String) -> [(key: String, label: String, count: Int)] {
        let hosts = inv.hosts.filter { $0.clusterKey == cluster && !$0.isVirtual }
        let counts = Dictionary(grouping: hosts) { CPUBaseline.of($0).family }.mapValues(\.count)
        return counts.map { (key: $0.key, label: label($0.key), count: $0.value) }.sorted { ($1.count, $0.key) < ($0.count, $1.key) }
    }
}

/// Steps for retiring old hosts, finer than families: Skylake and Cascade Lake share a family but not a fate on ESX 9.
public enum CPURetirement {
    public struct Tier: Sendable {
        public let name: String
        public let short: String
        /// The oldest `CPUBaseline.rank` this tier keeps.
        public let minRank: Int
    }

    public static let intel = [
        Tier(name: "Xeon SP 1st gen (Skylake)", short: "Skylake", minRank: 8),
        Tier(name: "Xeon SP 2nd gen (Cascade Lake)", short: "Cascade Lake", minRank: 9),
        Tier(name: "Xeon SP 3rd gen (Ice Lake)", short: "Ice Lake", minRank: 10),
        Tier(name: "Xeon SP 4th–5th gen (Sapphire, Emerald Rapids)", short: "Sapphire/Emerald Rapids", minRank: 11),
        Tier(name: "Xeon 6 (Granite Rapids)", short: "Granite Rapids", minRank: 12),
    ]
    public static let amd = [
        Tier(name: "EPYC 7001 (Zen)", short: "EPYC 7001", minRank: 7),
        Tier(name: "EPYC 7002 (Zen 2)", short: "EPYC 7002", minRank: 8),
        Tier(name: "EPYC 7003 (Zen 3)", short: "EPYC 7003", minRank: 9),
        Tier(name: "EPYC 9004 (Zen 4)", short: "EPYC 9004", minRank: 10),
        Tier(name: "EPYC 9005 (Zen 5)", short: "EPYC 9005", minRank: 11),
    ]

    public static func tiers(_ vendor: String) -> [Tier] { vendor == "Intel" ? intel : (vendor == "AMD" ? amd : []) }

    /// A generation's tier: 0 is older than the first tier, k is `tiers[k - 1]`; nil when unknown.
    public static func tier(_ g: CPUBaseline) -> Int? {
        guard g.rank >= 0, !g.vendor.isEmpty else { return nil }
        return tiers(g.vendor).filter { $0.minRank <= g.rank }.count
    }

    /// With choice k (0 keeps everything), hosts of tiers below k are retired.
    public static func isRetired(_ g: CPUBaseline, choice: Int) -> Bool {
        guard choice > 0, let t = tier(g) else { return false }
        return t < choice
    }

    public static func short(_ vendor: String, tier: Int) -> String {
        if tier == 0 { return vendor == "Intel" ? "Xeon E5/E7" : "Opteron" }
        let ts = tiers(vendor)
        return tier <= ts.count ? ts[tier - 1].short : "?"
    }
}
