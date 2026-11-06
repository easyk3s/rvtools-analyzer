import Foundation

// Public list prices for Azure and AWS, downloaded on request and cached on disk. Only public price
// lists are fetched — no inventory data is ever sent.
//   Azure: Retail Prices API (prices.azure.com) — pay-as-you-go, reservations and managed disks.
//   AWS:   the public price files behind aws.amazon.com pricing pages (b0.p.awsstatic.com) — on-demand
//          EC2 (Linux / Windows) and EBS. Commitment prices aren't published there.

public enum CloudProvider: String, Codable, CaseIterable, Sendable {
    case azure, aws
    public var name: String { self == .azure ? "Azure" : "AWS" }
}

public struct CloudRegion: Hashable, Sendable {
    public let code: String
    public let name: String
}

public enum CloudRegions {
    public static let azure: [CloudRegion] = [
        ("eastus", "East US"), ("eastus2", "East US 2"), ("centralus", "Central US"), ("northcentralus", "North Central US"),
        ("southcentralus", "South Central US"), ("westus", "West US"), ("westus2", "West US 2"), ("westus3", "West US 3"),
        ("canadacentral", "Canada Central"), ("uksouth", "UK South"), ("westeurope", "West Europe"), ("northeurope", "North Europe"),
        ("germanywestcentral", "Germany West Central"), ("francecentral", "France Central"), ("swedencentral", "Sweden Central"),
        ("australiaeast", "Australia East"), ("southeastasia", "Southeast Asia"), ("japaneast", "Japan East"),
        ("centralindia", "Central India"), ("brazilsouth", "Brazil South"),
    ].map { CloudRegion(code: $0.0, name: $0.1) }

    /// Names must match the AWS price-list "Location" strings.
    public static let aws: [CloudRegion] = [
        ("us-east-1", "US East (N. Virginia)"), ("us-east-2", "US East (Ohio)"), ("us-west-1", "US West (N. California)"),
        ("us-west-2", "US West (Oregon)"), ("ca-central-1", "Canada (Central)"), ("eu-west-1", "EU (Ireland)"),
        ("eu-west-2", "EU (London)"), ("eu-central-1", "EU (Frankfurt)"), ("eu-west-3", "EU (Paris)"), ("eu-north-1", "EU (Stockholm)"),
        ("ap-southeast-2", "Asia Pacific (Sydney)"), ("ap-southeast-1", "Asia Pacific (Singapore)"), ("ap-northeast-1", "Asia Pacific (Tokyo)"),
        ("ap-south-1", "Asia Pacific (Mumbai)"), ("sa-east-1", "South America (Sao Paulo)"),
    ].map { CloudRegion(code: $0.0, name: $0.1) }

    public static func list(_ p: CloudProvider) -> [CloudRegion] { p == .azure ? azure : aws }
    public static func name(_ p: CloudProvider, _ code: String) -> String { list(p).first { $0.code == code }?.name ?? code }
}

public struct InstanceOffer: Codable, Hashable, Sendable {
    public let name: String
    public let family: String
    public let category: String
    public let vcpu: Int
    public let memoryGiB: Double
    public var linuxHourly: Double?
    public var windowsHourly: Double?
    public var reserved1yHourly: Double?
    public var reserved3yHourly: Double?
    /// Further named rates from custom price lists (e.g. "savingsPlan1y", "monthly"); nil for downloaded list prices.
    public var prices: [String: Double]?

    public var displayName: String { name.replacingOccurrences(of: "Standard_", with: "") }
}

/// An Azure VMware Solution host SKU's node rates in one region. AVS is sold by the whole host, not per VM, so these
/// are kept apart from `instances`: a node is never a candidate for right-sizing a single VM.
/// Only the "VCF BYOL" SKUs are published now — the node price carries no Broadcom licence (see `AVSNodes`).
public struct AVSNodeOffer: Codable, Hashable, Sendable {
    /// The host type as Microsoft names it: "AV36", "AV36P", "AV48", "AV52", "AV64".
    public let sku: String
    public var paygHourly: Double?
    public var reserved1yHourly: Double?
    public var reserved3yHourly: Double?

    public init(sku: String, paygHourly: Double? = nil, reserved1yHourly: Double? = nil, reserved3yHourly: Double? = nil) {
        self.sku = sku; self.paygHourly = paygHourly; self.reserved1yHourly = reserved1yHourly; self.reserved3yHourly = reserved3yHourly
    }

    /// The published rate for a term, or nil when Microsoft doesn't offer the SKU on that term in this region.
    public func hourly(_ term: AVSTerm) -> Double? {
        switch term {
        case .payg: return paygHourly
        case .reserved1y: return reserved1yHourly
        case .reserved3y: return reserved3yHourly
        }
    }
}

public enum AVSTerm: Int, CaseIterable, Sendable {
    case payg = 0, reserved1y, reserved3y
    public var label: String { ["Pay-as-you-go", "1-year reserved", "3-year reserved"][rawValue] }
}

/// An Azure storage service that can back an AVS datastore, so capacity can be added without buying nodes.
/// Azure NetApp Files is billed per GiB of the capacity pool; Elastic SAN per GiB provisioned, split between the
/// base units (which carry the IOPS and throughput) and cheaper additional capacity units.
public struct AVSDatastoreOffer: Codable, Hashable, Sendable {
    /// "anf" (NFSv3) or "esan" (iSCSI / VMFS).
    public let kind: String
    /// The service level as Azure names it: "Standard", "Premium", "Ultra", "Premium LRS", "Premium ZRS".
    public let tier: String
    /// USD per GiB per month of provisioned capacity, at the primary (base) rate.
    public var perGiBMonth: Double
    /// Elastic SAN only: the cheaper rate for capacity beyond the base units.
    public var extraPerGiBMonth: Double?
    /// Elastic SAN only: Microsoft requires at least a 16 TiB base size for an AVS datastore.
    public var minTiB: Double?

    public init(kind: String, tier: String, perGiBMonth: Double, extraPerGiBMonth: Double? = nil, minTiB: Double? = nil) {
        self.kind = kind; self.tier = tier; self.perGiBMonth = perGiBMonth
        self.extraPerGiBMonth = extraPerGiBMonth; self.minTiB = minTiB
    }

    public var id: String { kind + "|" + tier }
    public var label: String { (kind == "anf" ? "Azure NetApp Files" : "Elastic SAN") + " — " + tier }
    public var shortLabel: String { (kind == "anf" ? "ANF" : "ESAN") + " " + tier }
    /// NFS and iSCSI volumes are not vSAN, so vSAN storage policies and FTT don't multiply their capacity —
    /// each service protects its own data. Microsoft's pages state no multiplier for them.
    public var protectedByService: Bool { true }
}

public struct RegionPrices: Codable, Sendable {
    public let provider: CloudProvider
    public let region: String
    public let fetched: Date
    public var instances: [InstanceOffer]
    /// Azure: monthly price per disk tier ("P10", "E10", "S10"). AWS: $ per GB-month per volume type ("gp3", "gp2", "st1").
    public var storage: [String: Double]
    /// Azure VMware Solution node rates. Optional so price files cached before AVS was priced still decode;
    /// nil or empty means the region's prices predate it and need downloading again.
    public var avsNodes: [AVSNodeOffer]? = nil
    /// Azure storage that can back an AVS datastore (Azure NetApp Files, Elastic SAN). Optional for the same reason.
    public var avsDatastores: [AVSDatastoreOffer]? = nil
}

public enum PricingError: LocalizedError {
    case http(Int, String)
    case empty(String)

    public var errorDescription: String? {
        switch self {
        case .http(let code, let host): return "HTTP \(code) from \(host)"
        case .empty(let s): return s
        }
    }
}

/// In-memory + on-disk cache of downloaded region prices (thread-safe).
public final class PriceStore: @unchecked Sendable {
    public static let shared = PriceStore()
    public static let maxAge: TimeInterval = 7 * 86_400

    private let lock = NSLock()
    private var regions: [String: RegionPrices] = [:]
    private var _version = 0

    public var version: Int { lock.lock(); defer { lock.unlock() }; return _version }

    public var cacheDirectory: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("RVToolsAnalyzer/pricing", isDirectory: true)
    }

    private static func key(_ p: CloudProvider, _ r: String) -> String { p.rawValue + "|" + r }

    private func file(_ p: CloudProvider, _ r: String) -> URL {
        cacheDirectory.appendingPathComponent("\(p.rawValue)-\(r).json")
    }

    public func prices(_ p: CloudProvider, _ region: String) -> RegionPrices? {
        lock.lock(); defer { lock.unlock() }
        return regions[PriceStore.key(p, region)]
    }

    /// Loads cached price files (no network). Stale files (older than `maxAge`) are still loaded but reported.
    @discardableResult
    public func loadFromDisk(_ p: CloudProvider, regions list: [String]) -> [String] {
        var missing: [String] = []
        for r in list where prices(p, r) == nil {
            if let data = try? Data(contentsOf: file(p, r)), let rp = try? JSONDecoder().decode(RegionPrices.self, from: data) {
                store(rp)
            } else {
                missing.append(r)
            }
        }
        return missing
    }

    /// Downloads current public list prices and caches them. Returns an error message per failed region.
    public func download(_ p: CloudProvider, regions list: [String]) async -> [String: String] {
        var errors: [String: String] = [:]
        for r in list {
            do {
                let rp = p == .azure ? try await AzurePrices.fetch(region: r) : try await AWSPrices.fetch(region: r)
                store(rp)
                try? FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
                if let data = try? JSONEncoder().encode(rp) { try? data.write(to: file(p, r)) }
            } catch {
                errors[r] = error.localizedDescription
            }
        }
        return errors
    }

    /// Regions with prices in memory or in the disk cache (no network).
    public func availableRegions(_ p: CloudProvider) -> [String] {
        lock.lock()
        var codes = Set(regions.values.filter { $0.provider == p }.map(\.region))
        lock.unlock()
        let files = (try? FileManager.default.contentsOfDirectory(atPath: cacheDirectory.path)) ?? []
        for f in files where f.hasPrefix(p.rawValue + "-") && f.hasSuffix(".json") {
            codes.insert(String(f.dropFirst(p.rawValue.count + 1).dropLast(5)))
        }
        let order = CloudRegions.list(p).map(\.code)
        return codes.sorted { (order.firstIndex(of: $0) ?? .max, $0) < (order.firstIndex(of: $1) ?? .max, $1) }
    }

    /// Prices for a region from memory, falling back to the disk cache (no network).
    public func cachedPrices(_ p: CloudProvider, _ region: String) -> RegionPrices? {
        if let rp = prices(p, region) { return rp }
        loadFromDisk(p, regions: [region])
        return prices(p, region)
    }

    /// Makes saved price snapshots current (e.g. from a project) without touching the disk cache.
    public func importSnapshots(_ list: [RegionPrices]) {
        for rp in list { store(rp) }
    }

    private func store(_ rp: RegionPrices) {
        lock.lock()
        regions[PriceStore.key(rp.provider, rp.region)] = rp
        _version += 1
        lock.unlock()
    }
}

// MARK: - Azure

/// Azure VM sizes whose memory follows a fixed GiB-per-vCPU ratio (the Retail Prices API has no specs).
enum AzureSizes {
    static func spec(_ sku: String) -> (family: String, category: String, vcpu: Int, memoryGiB: Double)? {
        guard let m = regexMatch(sku, #"^Standard_([DEF])(\d+)(a?)s_v([256])$"#), let n = Int(m[2]) else { return nil }
        let letter = m[1].uppercased(), amd = m[3].lowercased() == "a", gen = m[4]
        switch (letter, gen) {
        case ("D", "5"), ("D", "6"):
            return ("D\(amd ? "a" : "")sv\(gen)", "General purpose", n, Double(n) * 4)
        case ("E", "5"), ("E", "6"):
            if gen == "6" && n > 64 { return nil }
            return ("E\(amd ? "a" : "")sv\(gen)", "Memory optimized", n, n >= 96 ? 672 : Double(n) * 8)
        case ("F", "2") where !amd:
            return ("Fsv2", "Compute optimized", n, Double(n) * 2)
        default:
            return nil
        }
    }
}

/// Azure VMware Solution host types, from Microsoft's "Azure VMware Solution private cloud architecture" and
/// "What is Azure VMware Solution?" pages (read 2026-11-06). The Retail Prices API carries rates but no specs, so the
/// hardware stays here — update this table when Microsoft changes the host table.
public enum AVSNodes {
    public static let source = "Microsoft Learn — Azure VMware Solution private cloud architecture (host table)"

    public struct Spec: Sendable {
        /// Physical cores per node (every SKU is dual-socket).
        public let cores: Int
        public let clockGHz: Double
        public let memoryGiB: Double
        /// Raw vSAN capacity-tier size, decimal TB as Microsoft states it (the cache tier holds no VM data).
        public let capacityTB: Double
        public let cpu: String
        public let vsan: String
        public var sockets: Int { 2 }
    }

    /// Microsoft gives RAM in GB and storage in decimal TB ("1 TB Raw = 1000000000000 bytes").
    public static let specs: [String: Spec] = [
        "AV36": Spec(cores: 36, clockGHz: 2.3, memoryGiB: 576, capacityTB: 15.20,
                     cpu: "2 × Intel Xeon Gold 6140, 18 cores @ 2.3 GHz", vsan: "OSA · 3.2 TB NVMe cache"),
        "AV36P": Spec(cores: 36, clockGHz: 2.6, memoryGiB: 768, capacityTB: 19.20,
                      cpu: "2 × Intel Xeon Gold 6240, 18 cores @ 2.6 GHz", vsan: "OSA · 1.5 TB cache"),
        "AV48": Spec(cores: 48, clockGHz: 2.6, memoryGiB: 1_024, capacityTB: 25.60,
                     cpu: "2 × Intel Xeon Gold 6442Y, 24 cores @ 2.6 GHz", vsan: "ESA"),
        "AV52": Spec(cores: 52, clockGHz: 2.7, memoryGiB: 1_536, capacityTB: 38.40,
                     cpu: "2 × Intel Xeon Platinum 8270, 26 cores @ 2.7 GHz", vsan: "OSA · 1.5 TB cache"),
        "AV64": Spec(cores: 64, clockGHz: 2.8, memoryGiB: 1_024, capacityTB: 15.36,
                     cpu: "2 × Intel Xeon Platinum 8370C, 32 cores @ 2.8 GHz", vsan: "OSA · 3.84 TB NVMe cache"),
    ]

    /// Largest first, so the comparison tables read from the biggest node down.
    public static let order = ["AV64", "AV52", "AV48", "AV36P", "AV36"]

    /// Hard limits from the same pages.
    public static let minHostsPerCluster = 3
    public static let recommendedHostsPerCluster = 4
    public static let maxHostsPerCluster = 16
    public static let maxHostsPerPrivateCloud = 96
    public static let maxClustersPerPrivateCloud = 12
    /// vSAN keeps 25% of usable capacity for the SLA, so only 75% can hold VM data.
    public static let vsanUsablePct = 75.0
    /// The AVS-managed resource pool on the first cluster, which can't be changed.
    public static let managementReservationGHz = 46.0
    public static let managementReservationGiB = 171.88
    /// AV64 can only extend a private cloud that was built on one of these SKUs.
    public static let av64Prerequisites = ["AV36", "AV36P", "AV48", "AV52"]
    /// Default maximum Azure NetApp Files datastores (Microsoft's stated default).
    public static let maxANFDatastores = 64
    /// Microsoft requires at least a 16 TiB base size for an Elastic SAN backing an AVS datastore.
    public static let elasticSANMinTiB = 16.0

    public static func spec(_ sku: String) -> Spec? { specs[sku] }
}

enum AzurePrices {
    struct Page: Decodable {
        let Items: [Item]
        let NextPageLink: String?
    }

    struct Item: Decodable {
        let armSkuName: String
        let retailPrice: Double
        let type: String
        let reservationTerm: String?
        let productName: String
        let skuName: String
        let meterName: String
        /// e.g. "1 Hour", "1 GiB/Hour", "1 GiB/Month" — optional so a missing field never fails a whole page.
        let unitOfMeasure: String?
    }

    static func query(_ filter: String) async throws -> [Item] {
        var comps = URLComponents(string: "https://prices.azure.com/api/retail/prices")!
        comps.queryItems = [URLQueryItem(name: "$filter", value: filter)]
        var next = comps.url
        var items: [Item] = []
        var pages = 0
        while let url = next, pages < 80 {
            let (data, response) = try await URLSession.shared.data(from: url)
            if let http = response as? HTTPURLResponse, http.statusCode != 200 { throw PricingError.http(http.statusCode, url.host ?? "") }
            let page = try JSONDecoder().decode(Page.self, from: data)
            items += page.Items
            next = page.NextPageLink.flatMap { URL(string: $0) }
            pages += 1
        }
        return items
    }

    static func fetch(region: String) async throws -> RegionPrices {
        let vmFilter = "serviceName eq 'Virtual Machines' and armRegionName eq '\(region)' and (priceType eq 'Consumption' or priceType eq 'Reservation') "
            + "and (contains(armSkuName, 's_v5') or contains(armSkuName, 's_v6') or contains(armSkuName, 's_v2'))"
        var offers: [String: InstanceOffer] = [:]
        for i in try await query(vmFilter) {
            // The service also returns Cloud Services products ("Dasv5 Series Cloud Services") for the same SKUs,
            // priced like Windows but without "Windows" in the name — only real VM products count.
            guard i.productName.hasPrefix("Virtual Machines") else { continue }
            let label = (i.skuName + " " + i.meterName).lowercased()
            if label.contains("spot") || label.contains("low priority") { continue }
            guard let spec = AzureSizes.spec(i.armSkuName) else { continue }
            var o = offers[i.armSkuName] ?? InstanceOffer(name: i.armSkuName, family: spec.family, category: spec.category, vcpu: spec.vcpu, memoryGiB: spec.memoryGiB)
            switch i.type {
            case "Consumption":
                if i.productName.contains("Windows") { o.windowsHourly = i.retailPrice } else { o.linuxHourly = i.retailPrice }
            case "Reservation":
                // Reservation prices are the total for the term.
                if i.reservationTerm == "1 Year" { o.reserved1yHourly = i.retailPrice / 8_760 }
                if i.reservationTerm == "3 Years" { o.reserved3yHourly = i.retailPrice / 26_280 }
            default:
                break
            }
            offers[i.armSkuName] = o
        }
        guard !offers.isEmpty else { throw PricingError.empty("No Azure VM prices returned for \(region)") }

        let diskFilter = "serviceName eq 'Storage' and armRegionName eq '\(region)' and priceType eq 'Consumption' and "
            + "(productName eq 'Premium SSD Managed Disks' or productName eq 'Standard SSD Managed Disks' or productName eq 'Standard HDD Managed Disks')"
        var storage: [String: Double] = [:]
        for i in try await query(diskFilter) {
            let parts = i.meterName.split(separator: " ")   // "P10 LRS Disk" (skip ZRS, "Disk Mount", transactions)
            guard parts.count == 3, parts[1] == "LRS", parts[2] == "Disk" else { continue }
            storage[String(parts[0])] = i.retailPrice
        }
        // AVS is a separate query: if it fails, the VM and disk prices above are still worth keeping, and the AVS
        // solution asks for a refresh when node rates are missing.
        let avs = try? await fetchAVS(region: region)
        let datastores = try? await fetchAVSDatastores(region: region)
        return RegionPrices(provider: .azure, region: region, fetched: Date(), instances: Array(offers.values), storage: storage,
                            avsNodes: avs, avsDatastores: datastores)
    }

    /// Azure VMware Solution node rates. Only the "VCF BYOL" SKUs are priced now (the licence-included SKUs have been
    /// withdrawn), so Broadcom licensing is always brought separately. A region with no AVS returns an empty list
    /// rather than failing — the rest of the price list is still good.
    static func fetchAVS(region: String) async throws -> [AVSNodeOffer] {
        let filter = "productName eq 'Specialized Compute Azure VMware Solution' and armRegionName eq '\(region)' "
            + "and (priceType eq 'Consumption' or priceType eq 'Reservation')"
        var nodes: [String: AVSNodeOffer] = [:]
        for i in try await query(filter) {
            // "AV48 VCF BYOL" → AV48. Trial nodes are free and not buyable, so they're skipped.
            guard let m = regexMatch(i.skuName, #"^(AV\d+P?) VCF BYOL$"#) else { continue }
            let sku = m[1].uppercased()
            guard AVSNodes.spec(sku) != nil, i.retailPrice > 0 else { continue }
            var o = nodes[sku] ?? AVSNodeOffer(sku: sku)
            switch i.type {
            case "Consumption": o.paygHourly = i.retailPrice
            // Reservation prices are the total for the term, as with VMs.
            case "Reservation":
                if i.reservationTerm == "1 Year" { o.reserved1yHourly = i.retailPrice / 8_760 }
                if i.reservationTerm == "3 Years" { o.reserved3yHourly = i.retailPrice / 26_280 }
            default: break
            }
            nodes[sku] = o
        }
        return AVSNodes.order.compactMap { nodes[$0] }
    }

    /// Azure storage that can back an AVS datastore, so capacity can grow without more nodes:
    /// Azure NetApp Files capacity pools (Standard, Premium, Ultra — the levels AVS supports) and Elastic SAN.
    static func fetchAVSDatastores(region: String) async throws -> [AVSDatastoreOffer] {
        var out: [AVSDatastoreOffer] = []

        // ANF is quoted per GiB per hour. Only the plain service levels back AVS datastores — not the
        // "Double Encrypted", "Cool Access" or reserved-capacity variants.
        let anfFilter = "serviceName eq 'Azure NetApp Files' and armRegionName eq '\(region)' and priceType eq 'Consumption'"
        var anf: [String: Double] = [:]
        for i in try await query(anfFilter) {
            guard ["Standard", "Premium", "Ultra"].contains(i.skuName), i.meterName == "\(i.skuName) Capacity",
                  (i.unitOfMeasure ?? "").contains("GiB"), i.retailPrice > 0 else { continue }
            anf[i.skuName] = i.retailPrice * 730
        }
        for tier in ["Standard", "Premium", "Ultra"] {
            if let rate = anf[tier] { out.append(AVSDatastoreOffer(kind: "anf", tier: tier, perGiBMonth: rate)) }
        }

        // Elastic SAN is quoted per GiB per month, split into base units and additional capacity units.
        let esanFilter = "productName eq 'Azure Elastic SAN' and armRegionName eq '\(region)' and priceType eq 'Consumption'"
        var base: [String: Double] = [:], extra: [String: Double] = [:]
        for i in try await query(esanFilter) {
            guard i.retailPrice > 0 else { continue }
            if i.meterName.hasSuffix("Provisioned Base Unit") { base[i.skuName] = i.retailPrice }
            if i.meterName.hasSuffix("Provisioned Capacity Unit") { extra[i.skuName] = i.retailPrice }
        }
        for tier in ["Premium LRS", "Premium ZRS"] {
            guard let rate = base[tier] else { continue }
            out.append(AVSDatastoreOffer(kind: "esan", tier: tier, perGiBMonth: rate,
                                         extraPerGiBMonth: extra[tier], minTiB: AVSNodes.elasticSANMinTiB))
        }
        return out
    }
}

// MARK: - AWS

enum AWSPrices {
    static let base = "https://b0.p.awsstatic.com/pricing/2.0/meteredUnitMaps"
    static let families: Set<String> = ["m5", "m6i", "m6a", "m7i", "m7a", "r5", "r6i", "r6a", "r7i", "r7a", "c5", "c6i", "c6a", "c7i", "c7a", "t3"]

    static func json(_ path: String) async throws -> [String: Any] {
        guard let url = URL(string: base + "/" + path) else { throw PricingError.empty("Bad URL \(path)") }
        let (data, response) = try await URLSession.shared.data(from: url)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 { throw PricingError.http(http.statusCode, url.host ?? "") }
        return (try JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
    }

    static func regionEntries(_ doc: [String: Any], _ name: String) -> [String: [String: Any]] {
        let regions = doc["regions"] as? [String: Any] ?? [:]
        return (regions[name] ?? regions.values.first) as? [String: [String: Any]] ?? [:]
    }

    static func fetch(region code: String) async throws -> RegionPrices {
        let name = CloudRegions.name(.aws, code)
        guard let encoded = name.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) else { throw PricingError.empty("Bad region \(name)") }
        var offers: [String: InstanceOffer] = [:]
        for os in ["Linux", "Windows"] {
            let doc = try await json("ec2/USD/current/ec2-ondemand-without-sec-sel/\(encoded)/\(os)/index.json")
            for (_, e) in regionEntries(doc, name) {
                guard let type = e["Instance Type"] as? String, let price = Double(e["price"] as? String ?? ""), price > 0,
                      let vcpu = Int(e["vCPU"] as? String ?? ""), let memory = e["Memory"] as? String else { continue }
                let family = String(type.split(separator: ".").first ?? "")
                guard families.contains(family), !type.contains("metal") else { continue }
                let gib = Double(memory.split(separator: " ").first.map { $0.replacingOccurrences(of: ",", with: "") } ?? "") ?? 0
                var o = offers[type] ?? InstanceOffer(name: type, family: family, category: e["Instance Family"] as? String ?? "", vcpu: vcpu, memoryGiB: gib)
                if os == "Linux" { o.linuxHourly = price } else { o.windowsHourly = price }
                offers[type] = o
            }
        }
        guard !offers.isEmpty else { throw PricingError.empty("No AWS EC2 prices returned for \(name)") }

        var storage: [String: Double] = [:]
        let ebs = regionEntries(try await json("ec2/USD/current/ebs.json"), name)
        let keys = ["gp3": "Storage General Purpose gp3 GB Mo", "gp2": "Storage General Purpose gp2 GB Mo", "st1": "Storage Throughput Optimized HDD st1 GB Mo"]
        for (type, k) in keys { if let p = Double(ebs[k]?["price"] as? String ?? "") { storage[type] = p } }
        return RegionPrices(provider: .aws, region: code, fetched: Date(), instances: Array(offers.values), storage: storage)
    }
}
