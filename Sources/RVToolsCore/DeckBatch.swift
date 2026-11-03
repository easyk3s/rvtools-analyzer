import Foundation

/// A list of solution decks to make from one export, e.g. the ones handed to a customer after an assessment.
/// Stored as JSON (`.rvadecks`); relative paths resolve against the recipe's folder.
public struct DeckRecipe: Codable, Sendable {
    public struct Deck: Codable, Sendable {
        /// Solution id, built-in or custom (`rvtools-cli --list-solutions`).
        public var solution: String
        /// File name and deck title; defaults to the solution's title.
        public var name: String?
        /// Assumption overrides, as with `--set name=value`.
        public var set: [String: String]?
        public init(solution: String, name: String? = nil, set: [String: String]? = nil) { self.solution = solution; self.name = name; self.set = set }
    }
    /// Shown on the upload page.
    public var title: String?
    /// A .pptx/.potx used by every deck that doesn't name its own.
    public var template: String?
    public var decks: [Deck]
    /// Where `template` resolves from; set by `load`.
    public var baseURL: URL?

    enum CodingKeys: String, CodingKey { case title, template, decks }

    public init(title: String? = nil, template: String? = nil, decks: [Deck], baseURL: URL? = nil) {
        self.title = title; self.template = template; self.decks = decks; self.baseURL = baseURL
    }

    public static func load(_ url: URL) throws -> DeckRecipe {
        var r = try JSONDecoder().decode(DeckRecipe.self, from: Data(contentsOf: url))
        r.baseURL = url.deletingLastPathComponent()
        return r
    }

    public var templateURL: URL? {
        guard let t = template, !t.isEmpty else { return nil }
        let expanded = (t as NSString).expandingTildeInPath
        return expanded.hasPrefix("/") ? URL(fileURLWithPath: expanded) : URL(fileURLWithPath: expanded, relativeTo: baseURL).standardizedFileURL
    }

    /// Problems that would stop a deck being made (unknown solution, missing template), checked before any upload.
    public func problems() -> [String] {
        var out: [String] = []
        if decks.isEmpty { out.append("The recipe lists no decks.") }
        if let t = templateURL, !FileManager.default.fileExists(atPath: t.path) { out.append("Template not found: \(t.path)") }
        for d in decks where SolutionCatalog.solution(id: d.solution) == nil { out.append("Unknown solution “\(d.solution)”") }
        return out
    }
}

/// One deck made by `DeckBatch`, or why it couldn't be.
public struct DeckOutput: Sendable {
    public var name: String
    public var fileName: String
    public var data: Data?
    public var error: String?
    public var notes: [String]
}

/// Makes every deck in a recipe from one load of the export(s), with default VM selections and assumptions.
public enum DeckBatch {
    public static func run(_ recipe: DeckRecipe, inputs: [URL], customer: String? = nil, only: Set<String>? = nil) throws -> [DeckOutput] {
        let ds = try Dataset.load(inputs)
        let r = Analyzer.run(InventoryBuilder.build(ds), thresholds: Thresholds(), acknowledgements: [])
        let inv = r.inventory
        let customer = customer?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let subtitle = customer.isEmpty ? ds.sources.map(\.lastPathComponent).joined(separator: ", ") : customer
        let date = "Exported \(Fmt.dateTime(ds.reportDate))"
        let prefix = customer.isEmpty ? "" : safeFileName(customer) + " - "

        return recipe.decks.filter { only?.contains($0.solution) ?? true }.map { deck in
            guard let found = SolutionCatalog.solution(id: deck.solution) else {
                return DeckOutput(name: deck.name ?? deck.solution, fileName: "", error: "Unknown solution “\(deck.solution)”", notes: [])
            }
            let title = deck.name ?? found.title
            let fileName = prefix + safeFileName(title) + ".pptx"
            var s = found
            if var scripted = found as? ScriptedSolution { scripted.findings = r.groups; s = scripted }
            var selections: [String: [VM]] = [:]
            for sel in s.selections {
                let ids = s.initialSelection(inv, for: sel)
                selections[sel.id] = inv.vms.filter { ids.contains($0.id) }
            }
            var notes: [String] = []
            let values = ParamValues.parsing(deck.set ?? [:], for: s) { notes.append($0) }
            let result = s.run(vms: selections[s.selections.first?.id ?? ""] ?? [], selections: selections, inventory: inv, values: values)
            if result.failed {
                return DeckOutput(name: title, fileName: fileName, error: "The solution failed: " + result.log.suffix(3).joined(separator: " · "), notes: notes)
            }
            do {
                let data = try result.pptx(DeckOptions(title: title, subtitle: subtitle, date: date, template: recipe.templateURL))
                return DeckOutput(name: title, fileName: fileName, data: data, notes: notes)
            } catch {
                return DeckOutput(name: title, fileName: fileName, error: error.localizedDescription, notes: notes)
            }
        }
    }

    /// The decks that were made, as one .zip.
    public static func zip(_ outputs: [DeckOutput]) -> Data {
        var z = ZipWriter()
        for o in outputs { if let d = o.data { z.add(o.fileName, d) } }
        return z.finish()
    }

    public static func safeFileName(_ s: String) -> String {
        let bad = CharacterSet(charactersIn: "/\\:*?\"<>|").union(.controlCharacters)
        return s.components(separatedBy: bad).joined(separator: "-").trimmingCharacters(in: .whitespaces)
    }
}

public extension ParamValues {
    /// Assumptions from `name=value` strings (as with `--set`): numbers, choice indexes, on/off, comma lists or cluster names.
    static func parsing(_ raw: [String: String], for s: any Solution, base: ParamValues = ParamValues(), unknown: (String) -> Void = { _ in }) -> ParamValues {
        var v = base
        for (name, value) in raw {
            guard let spec = s.parameters.first(where: { $0.id == name }) else {
                unknown("unknown parameter '\(name)' — available: \(s.parameters.map(\.id).joined(separator: ", "))")
                continue
            }
            switch spec.kind {
            case .number: if let x = Double(value) { v.values[name] = .number(x) }
            case .choice: if let x = Int(value) { v.values[name] = .choice(x) }
            case .toggle: v.values[name] = .flag(["1", "true", "yes", "on"].contains(value.lowercased()))
            case .multi: v.values[name] = .selection(value.split(separator: ",").compactMap { Int($0) })
            case .host: v.values[name] = .names(value.isEmpty ? [] : [value.trimmingCharacters(in: .whitespaces)])
            case .clusters: v.values[name] = .names(value.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty })
            }
        }
        return v
    }
}
