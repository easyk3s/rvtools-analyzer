import AppKit
import RVToolsCore
import SwiftUI

@main
struct RVToolsAnalyzerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var model = AppModel.shared

    var body: some Scene {
        Window("RVTools Analyzer", id: "main") {
            ContentView()
                .environment(model)
                .frame(minWidth: 1100, minHeight: 720)
        }
        .defaultSize(width: 1440, height: 900)
        .commands {
            CommandGroup(replacing: .appInfo) {
                Button("About \(BuildInfo.name)") { BuildInfo.showAboutPanel() }
            }
            CommandGroup(replacing: .help) {
                Button("RVTools Analyzer on GitHub") { model.openRepository() }
            }
            CommandGroup(replacing: .newItem) {
                Button("Open…") { model.presentOpenPanel() }.keyboardShortcut("o")
                Button("Compare Snapshots…") { model.presentTrendPanel() }.keyboardShortcut("o", modifiers: [.command, .option])
                Menu("Open Recent Project") {
                    ForEach(model.recentProjects, id: \.self) { url in
                        Button(url.deletingPathExtension().lastPathComponent) { model.open([url]) }
                    }
                    if !model.recentProjects.isEmpty {
                        Divider()
                        Button("Clear Menu") { model.clearRecentProjects() }
                    }
                }
                .disabled(model.recentProjects.isEmpty)
            }
            // Closing a window and closing the project are different things, so both are named. The Relationship Map
            // window group drops its default commands (below); otherwise its own "Close" replaces this whole group.
            CommandGroup(replacing: .saveItem) {
                Button("Close Window") { NSApp.keyWindow?.performClose(nil) }.keyboardShortcut("w")
                Button("Close Project") { model.close() }.keyboardShortcut("w", modifiers: [.command, .shift]).disabled(model.report == nil)
                Divider()
                Button("Save Project") { model.saveProject() }.keyboardShortcut("s").disabled(model.report == nil)
                Button("Save Project As…") { model.saveProjectAs() }.keyboardShortcut("s", modifiers: [.command, .shift]).disabled(model.report == nil)
                Divider()
                Button("Project Notes…") { model.showProjectInfo = true }.disabled(model.report == nil)
            }
            CommandMenu("Export") {
                ForEach(ExportKind.allCases) { kind in
                    Button("\(kind.rawValue) as CSV…") { model.export(kind) }.disabled(model.report == nil)
                }
                Divider()
                Button("All CSV Files to Folder…") { model.exportAll() }.keyboardShortcut("e", modifiers: [.command, .shift]).disabled(model.report == nil)
                Divider()
                Button("Trend Report to Folder…") { model.exportTrend() }.disabled(model.trend == nil)
            }
            CommandMenu("Solutions") {
                Button("Install Solution or Price List…") { model.presentInstallPanel() }
                Button("Reload Custom Solutions") { model.reloadExtensions() }.keyboardShortcut("r", modifiers: [.command, .shift])
                Divider()
                Button("Open Solutions Folder") { model.openFolder(SolutionLibrary.directory) }
                Button("Open Price Lists Folder") { model.openFolder(PriceLibrary.directory) }
                Divider()
                Button("Install Examples") { model.installExamples() }.disabled(model.bundledExamplesURL == nil)
                Button("Authoring Guide") { model.openAuthoringGuide() }.disabled(model.authoringGuideURL == nil)
            }
            CommandMenu("Go") {
                ForEach(Array(SidebarItem.allCases.enumerated()), id: \.element) { i, item in
                    Button(item.rawValue) { model.sidebar = item }
                        .keyboardShortcut(KeyEquivalent(Character("\((i + 1) % 10)")), modifiers: .command)
                        .disabled(model.report == nil)
                }
                Divider()
                ForEach(SidebarItem.trendPages) { item in
                    Button(item.rawValue) { model.sidebar = item }.disabled(model.trend == nil)
                }
            }
        }

        WindowGroup("Relationship Map", id: RelationshipMapWindow.windowID, for: RelFocus.self) { $focus in
            if let focus {
                RelationshipMapWindow(focus: focus).environment(model)
            }
        }
        .defaultSize(width: 1320, height: 840)
        .commandsRemoved()

        Settings {
            SettingsView().environment(model)
        }
    }
}

/// Offers to save a customized session when the window's close button is clicked. Closing the only window quits the
/// app, but that path doesn't reliably reach `applicationShouldTerminate`, so the close itself is checked. The
/// window's own (SwiftUI) delegate keeps receiving every other delegate message.
struct WindowCloseGuard: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { GuardView() }
    func updateNSView(_ nsView: NSView, context: Context) { (nsView as? GuardView)?.install() }

    private final class GuardView: NSView {
        private var proxy: DelegateProxy?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            install()
        }

        func install() {
            guard let window, window.delegate !== proxy else { return }
            let p = DelegateProxy(original: window.delegate)
            proxy = p
            window.delegate = p
        }
    }

    private final class DelegateProxy: NSObject, NSWindowDelegate {
        /// Strong: the window only holds its delegate weakly.
        let original: NSWindowDelegate?

        init(original: NSWindowDelegate?) { self.original = original }

        override func responds(to aSelector: Selector!) -> Bool {
            super.responds(to: aSelector) || (original?.responds(to: aSelector) ?? false)
        }

        override func forwardingTarget(for aSelector: Selector!) -> Any? { original }

        func windowShouldClose(_ sender: NSWindow) -> Bool {
            if original?.windowShouldClose?(sender) == false { return false }
            return MainActor.assumeIsolated { AppModel.shared.confirmDiscardChanges() }
        }
    }
}

/// Which build is running, from keys `scripts/build-app.sh` writes into Info.plist.
/// Where the app keeps its preferences (assumptions, units, thresholds, recent projects, disabled solutions).
/// A run with `RVTA_SUPPORT_FOLDER` (documentation screenshots, isolated test runs) gets its own domain, cleared at
/// launch, so it starts from the defaults and never reads or changes the preferences of the app it was built as.
enum AppDefaults {
    static let store: UserDefaults = {
        guard let folder = ProcessInfo.processInfo.environment["RVTA_SUPPORT_FOLDER"], !folder.isEmpty else { return .standard }
        let name = "local.rvtools-analyzer.isolated." + folder.filter { $0.isLetter || $0.isNumber }
        guard let d = UserDefaults(suiteName: name) else { return .standard }
        d.removePersistentDomain(forName: name)
        return d
    }()
}

enum BuildInfo {
    private static func info(_ key: String) -> String? { Bundle.main.object(forInfoDictionaryKey: key) as? String }

    static let name = info("CFBundleName") ?? "RVTools Analyzer"
    /// A Dev build (`scripts/build-app.sh dev`): separate settings and custom solutions.
    /// `RVTA_HIDE_DEV_BADGE=1` hides the Dev markings in the window (used for documentation screenshots).
    static let isDev = info("RVTABuildVariant") == "dev" && ProcessInfo.processInfo.environment["RVTA_HIDE_DEV_BADGE"] != "1"
    /// `git describe` of the source, e.g. "v1.0-3-g1a2b3c4"; "-dirty" means built with uncommitted changes.
    static let build = info("RVTABuild")

    static func showAboutPanel() {
        var lines: [String] = []
        if isDev { lines.append("Dev build — its own settings and custom solutions (~/Library/Application Support/\(info("RVTASupportFolder") ?? name)).") }
        if let date = info("RVTABuildDate").flatMap({ ISO8601DateFormatter().date(from: $0) }) { lines.append("Built \(Fmt.dateTime(date)) UTC") }
        lines.append("Local RVTools analysis — data never leaves this Mac.")
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        let credits = NSAttributedString(string: lines.joined(separator: "\n"), attributes: [
            .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize),
            .foregroundColor: isDev ? NSColor.systemOrange : NSColor.secondaryLabelColor,
            .paragraphStyle: paragraph,
        ])
        var options: [NSApplication.AboutPanelOptionKey: Any] = [.credits: credits]
        if let build { options[.version] = build }
        NSApp.orderFrontStandardAboutPanel(options: options)
        NSApp.activate(ignoringOtherApps: true)
    }
}

/// Marks the Dev build in the window, so it's never mistaken for the installed app.
struct DevBuildBadge: View {
    var body: some View {
        if BuildInfo.isDev {
            Label("Dev build" + (BuildInfo.build.map { " · \($0)" } ?? ""), systemImage: "hammer.fill")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.orange)
                .lineLimit(1)
                .help("Separate settings and custom solutions from the installed RVTools Analyzer")
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        // Allow `RVToolsAnalyzer [--trend] <file-or-folder>...` from the command line.
        let paths = CommandLine.arguments.dropFirst().filter { !$0.hasPrefix("-") && FileManager.default.fileExists(atPath: $0) }
        if !paths.isEmpty {
            let urls = paths.map { URL(fileURLWithPath: $0) }
            let trend = CommandLine.arguments.contains("--trend")
            Task { @MainActor in trend ? AppModel.shared.openTrend(urls) : AppModel.shared.open(urls) }
        }
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        Task { @MainActor in AppModel.shared.open(urls) }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    /// Offers to save a customized, unsaved session (saved projects are written silently).
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        MainActor.assumeIsolated { AppModel.shared.confirmDiscardChanges() } ? .terminateNow : .terminateCancel
    }
}
