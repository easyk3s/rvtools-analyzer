import SwiftUI
import AppKit
import UniformTypeIdentifiers
import RVToolsCore

/// Results-page card for files a custom solution returns in its `exports` list
/// (for example an ODIN Sizer JSON). Each file can be saved to disk or copied to the clipboard.
struct ExportsCard: View {
    let exports: [SolutionExport]
    @State private var status = ""

    var body: some View {
        Card("Exports", subtitle: "Files produced by this solution") {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(exports) { export in
                    HStack(alignment: .center, spacing: 12) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(export.title).font(.callout.weight(.semibold))
                            Text(export.fileName).font(.caption).foregroundStyle(.secondary)
                            Text(sizeLabel(export)).font(.caption2).foregroundStyle(.tertiary)
                        }
                        .textSelection(.enabled)
                        Spacer()
                        Button("Copy") { copy(export) }.buttonStyle(.bordered)
                        Button("Save…") { save(export) }.buttonStyle(.borderedProminent)
                    }
                    Divider()
                }
                if !status.isEmpty {
                    Text(status).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    private func sizeLabel(_ export: SolutionExport) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(export.content.utf8.count), countStyle: .file)
    }

    private func copy(_ export: SolutionExport) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(export.content, forType: .string)
        status = "Copied \(export.fileName) to the clipboard."
    }

    private func save(_ export: SolutionExport) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = export.fileName
        panel.canCreateDirectories = true
        let ext = (export.fileName as NSString).pathExtension
        if !ext.isEmpty, let type = UTType(filenameExtension: ext) { panel.allowedContentTypes = [type] }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try export.content.write(to: url, atomically: true, encoding: .utf8)
            status = "Saved \(url.lastPathComponent)."
        } catch {
            status = "Couldn't save the file: \(error.localizedDescription)"
        }
    }
}

/// Makes any web address inside a line of text clickable. Everything else is left exactly as written.
func linkifiedText(_ string: String) -> AttributedString {
    var attributed = AttributedString(string)
    guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else { return attributed }
    let whole = NSRange(string.startIndex..., in: string)
    for match in detector.matches(in: string, options: [], range: whole) {
        guard let url = match.url,
              let stringRange = Range(match.range, in: string),
              let range = Range(stringRange, in: attributed) else { continue }
        attributed[range].link = url
    }
    return attributed
}
