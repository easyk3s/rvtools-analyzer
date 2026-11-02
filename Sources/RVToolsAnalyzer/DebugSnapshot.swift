import AppKit
import RVToolsCore

/// Developer aid: renders every page to PNG after an export loads, without needing Screen Recording permission.
///   RVTA_SNAPSHOT_DIR=/tmp/shots [RVTA_APPEARANCE=light|dark] [RVTA_SNAPSHOT_QUIT=1] RVToolsAnalyzer <export>
@MainActor
enum DebugSnapshot {
    private static var started = false

    static func runIfRequested(_ model: AppModel) {
        let env = ProcessInfo.processInfo.environment
        guard !started, let dir = env["RVTA_SNAPSHOT_DIR"], !dir.isEmpty else { return }
        started = true
        let base = URL(fileURLWithPath: dir)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        switch env["RVTA_APPEARANCE"] {
        case "dark": NSApp.appearance = NSAppearance(named: .darkAqua)
        case "light": NSApp.appearance = NSAppearance(named: .aqua)
        default: break   // follow the system
        }

        let logURL = base.appendingPathComponent("snapshot.log")
        func log(_ s: String) {
            let line = "\(Date()) \(s)\n"
            if let h = try? FileHandle(forWritingTo: logURL) { h.seekToEndOfFile(); h.write(line.data(using: .utf8)!); try? h.close() }
            else { try? line.write(to: logURL, atomically: true, encoding: .utf8) }
        }

        Task { @MainActor in
            if let w = mainWindow() {
                w.setContentSize(NSSize(width: 1500, height: 960))
                w.center()
                w.makeKeyAndOrderFront(nil)
                NSApp.activate(ignoringOtherApps: true)
            }
            let inv = model.report?.inventory
            let worstVM = inv?.vms.max { $0.issueCount < $1.issueCount }?.id
            let busiestHost = inv?.hosts.max { $0.issueCount < $1.issueCount }?.id
            let fullestDS = inv?.datastores.max { $0.usedPct < $1.usedPct }?.id
            // The storage-path map is only interesting for a datastore with paths (a local disk has none).
            let pathiestDS = inv?.datastores.max { $0.lunPaths < $1.lunPaths }?.id ?? fullestDS
            var steps: [(String, () -> Void)] = [
                ("01-overview", { model.sidebar = .overview }),
                ("02-issues", { model.focusRule = model.report?.groups.first?.rule; model.sidebar = .issues }),
                ("03-compute-clusters", { model.computeTab = 0; model.sidebar = .compute }),
                ("04-compute-hosts", { model.selectedHostID = busiestHost; model.computeTab = 1; model.sidebar = .compute }),
                ("05-vms", { model.selectedVMID = worstVM; model.sidebar = .vms }),
                ("06-storage", { model.storageTab = 0; model.sidebar = .storage }),
                ("07-datastores", { model.selectedDatastoreID = fullestDS; model.storageTab = 1; model.sidebar = .storage }),
                ("08-network", {
                    model.selectedPortGroupID = inv?.portGroups.max { $0.vmCount < $1.vmCount }?.id
                    model.networkTab = 0
                    model.sidebar = .network
                }),
                ("09-configuration", { model.sidebar = .configuration }),
                ("10-lifecycle", { model.sidebar = .lifecycle }),
                ("11-correlations", { model.sidebar = .correlations }),
                ("12-raw", { model.sidebar = .rawData }),
                ("13-overview-again", { model.sidebar = .overview }),
            ] + SolutionCatalog.all.enumerated().flatMap { i, s -> [(String, () -> Void)] in
                [("\(20 + i * 3)-\(s.id)-select", { model.solutionTab[s.id] = 0; model.sidebar = .solution(s) }),
                 ("\(21 + i * 3)-\(s.id)-assumptions", { model.solutionTab[s.id] = 1; model.sidebar = .solution(s) }),
                 ("\(22 + i * 3)-\(s.id)-results", { model.solutionTab[s.id] = 2; model.sidebar = .solution(s) })]
            } + (SolutionCatalog.solution(id: "vcfsizing").map { s -> [(String, () -> Void)] in
                // VCF 9 Sizing again with the vSphere Foundation edition, then back to its defaults.
                [("60-vcfsizing-vvf-results", {
                    model.solutionParams[s.id, default: ParamValues()].values["edition"] = .choice(1)
                    model.solutionTab[s.id] = 2
                    model.sidebar = .solution(s)
                 }),
                 ("61-vcfsizing-reset", { model.solutionParams[s.id]?.values["edition"] = nil; model.sidebar = .overview })]
            } ?? [])
            if let trend = model.trend {
                let resized = trend.changes.first { $0.kind == .resized }?.key
                steps = [
                    ("30-trend-summary", { model.sidebar = .trendSummary }),
                    ("31-trend-changes", { model.trendChangesTab = 0; model.sidebar = .trendChanges }),
                    ("32-trend-vm-history", { model.trendVMKey = resized; model.sidebar = .trendChanges }),
                    ("33-trend-infrastructure", { model.trendVMKey = nil; model.trendChangesTab = 1; model.sidebar = .trendChanges }),
                    ("34-trend-growth", { model.sidebar = .trendGrowth }),
                    ("35-trend-capacity", { model.sidebar = .trendCapacity }),
                    ("36-snapshot-vm", { if let resized { model.revealTrendVM(resized) } }),
                    ("37-first-snapshot-overview", { model.trendSnapshot = 0; model.sidebar = .overview }),
                    ("38-backup-assumptions", {
                        model.trendSnapshot = trend.snapshots.count - 1
                        model.solutionTab["backup"] = 1
                        if let backup = SolutionCatalog.solution(id: "backup") { model.sidebar = .solution(backup) }
                    }),
                ] + SolutionCatalog.custom.filter { $0.parameters.contains { $0.observed != nil } }.enumerated().map { i, s in
                    ("\(39 + i)-\(s.id)-assumptions", { model.solutionTab[s.id] = 1; model.sidebar = .solution(s) })
                }
            }
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            for (name, setup) in steps {
                setup()
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                log("\(name): " + capture(to: base.appendingPathComponent(name + ".png")))
            }
            // Relationship maps, rendered the way Export › This Map as an Image writes them.
            if model.trend == nil, let inv = model.report?.inventory {
                let busiestPG = inv.portGroups.max { $0.vmCount < $1.vmCount }?.id
                let maps: [(String, RelFocus?)] = [
                    ("50-map-vm", worstVM.map { .vm($0) }), ("51-map-host", busiestHost.map { .host($0) }),
                    ("52-map-cluster", inv.clusters.first.map { .cluster($0.id) }), ("53-map-datastore", fullestDS.map { .datastore($0) }),
                    ("54-map-portgroup", busiestPG.map { .portGroup($0) }),
                    ("55-map-storage-paths", pathiestDS.map { .storagePaths($0) }),
                ]
                for (name, focus) in maps {
                    guard let focus, let map = RelationshipBuilder.map(focus, in: inv), let png = RelationshipMapImage.png(map, subtitle: model.projectTitle) else { continue }
                    try? png.write(to: base.appendingPathComponent(name + ".png"))
                    log("\(name): \(map.focus.name), \(map.nodes.count) objects, \(map.links.count) links")
                }
            }
            if env["RVTA_SNAPSHOT_QUIT"] == "1" { NSApp.terminate(nil) }
        }
    }

    /// With snapshots on, nobody is there to answer the column sheet: images it and carries on with its matches.
    static func runIfRequested(columnReview model: AppModel) {
        guard let dir = ProcessInfo.processInfo.environment["RVTA_SNAPSHOT_DIR"], !dir.isEmpty else { return }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            try? FileManager.default.createDirectory(at: URL(fileURLWithPath: dir), withIntermediateDirectories: true)
            if let sheet = NSApp.windows.first(where: \.isSheet), let image = windowServerImage(sheet),
               let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) {
                try? png.write(to: URL(fileURLWithPath: dir).appendingPathComponent("00-column-mapping.png"))
            }
            model.finishColumnReview(model.columnReview?.plan)
        }
    }

    private static func mainWindow() -> NSWindow? {
        NSApp.windows.filter { $0.contentView != nil && $0.frame.width > 600 }.max { $0.frame.width < $1.frame.width }
    }

    private typealias WindowImageFn = @convention(c) (CGRect, UInt32, UInt32, UInt32) -> Unmanaged<CGImage>?

    /// An app may image its own windows without Screen Recording permission. The API is unavailable in the
    /// current SDK headers, so it is looked up at runtime; returns nil if it is gone.
    private static func windowServerImage(_ window: NSWindow) -> CGImage? {
        guard let sym = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGWindowListCreateImage") else { return nil }
        let fn = unsafeBitCast(sym, to: WindowImageFn.self)
        // CGRectNull, kCGWindowListOptionIncludingWindow, window id, kCGWindowImageBoundsIgnoreFraming
        return fn(CGRect.null, 1 << 3, UInt32(window.windowNumber), 1 << 0)?.takeRetainedValue()
    }

    private static func capture(to url: URL) -> String {
        guard let window = mainWindow(), let content = window.contentView else { return "no window" }
        if let image = windowServerImage(window), image.width > 100 {
            let rep = NSBitmapImageRep(cgImage: image)
            if let png = rep.representation(using: .png, properties: [:]), (try? png.write(to: url)) != nil {
                return "ok (window server) \(image.width)x\(image.height)"
            }
        }
        let view = content.superview ?? content
        guard view.bounds.width > 0, let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return "no bitmap for \(view.bounds)" }
        view.cacheDisplay(in: view.bounds, to: rep)
        guard let png = rep.representation(using: .png, properties: [:]) else { return "png encode failed" }
        do { try png.write(to: url); return "ok \(rep.pixelsWide)x\(rep.pixelsHigh)" } catch { return "write failed: \(error.localizedDescription)" }
    }
}
