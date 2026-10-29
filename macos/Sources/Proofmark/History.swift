import AppKit
import SwiftUI

struct HistoryEntry: Codable, Identifiable {
    var id = UUID()
    var date: Date
    var mode: Mode
    var app: String
    var input: String
    var labels: [String]
    var events: [String]  // raw SSE payloads, replayed to rebuild the exact panel
}

/// Past checks and research, kept on this Mac only.
@MainActor
final class HistoryStore: ObservableObject {
    static let shared = HistoryStore()
    @Published private(set) var entries: [HistoryEntry] = []
    private let file: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Proofmark", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("history.json")
    }()

    init() {
        if let data = try? Data(contentsOf: file),
           let saved = try? JSONDecoder().decode([HistoryEntry].self, from: data) { entries = saved }
    }

    func add(_ check: Check, events: [String]) {
        entries.insert(HistoryEntry(date: check.date, mode: check.mode, app: check.app, input: check.input,
                                    labels: check.labels, events: events), at: 0)
        entries = Array(entries.prefix(300))
        save()
    }

    func delete(_ id: UUID) {
        entries.removeAll { $0.id == id }
        save()
    }

    private func save() {
        try? JSONEncoder().encode(entries).write(to: file, options: .atomic)
    }
}

enum HistoryWindow {
    static var window: NSWindow?

    @MainActor static func show(research: @escaping (String) -> Void) {
        if window == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 920, height: 620),
                             styleMask: [.titled, .closable, .resizable, .miniaturizable, .fullSizeContentView],
                             backing: .buffered, defer: false)
            w.title = "Proofmark History"
            w.titlebarAppearsTransparent = true
            w.isReleasedWhenClosed = false
            w.appearance = NSAppearance(named: .darkAqua)
            w.contentViewController = NSHostingController(rootView: HistoryView(research: research))
            w.center()
            window = w
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}

struct HistoryView: View {
    @ObservedObject var store = HistoryStore.shared
    var research: (String) -> Void
    @State private var selection: UUID?
    @State private var query = ""

    var filtered: [HistoryEntry] {
        query.isEmpty ? store.entries : store.entries.filter { $0.input.localizedCaseInsensitiveContains(query) }
    }

    var body: some View {
        NavigationSplitView {
            List(filtered, selection: $selection) { entry in
                HistoryRow(entry: entry)
                    .tag(entry.id)
                    .contextMenu { Button("Delete", role: .destructive) { store.delete(entry.id) } }
            }
            .searchable(text: $query, placement: .sidebar, prompt: "Search your checks")
            .navigationSplitViewColumnWidth(min: 260, ideal: 300)
            .overlay {
                if store.entries.isEmpty {
                    Text("Nothing checked yet.\nSelect text anywhere and press ⌥Space.")
                        .font(.system(size: 13, design: .serif)).foregroundStyle(.secondary).multilineTextAlignment(.center)
                }
            }
        } detail: {
            if let entry = store.entries.first(where: { $0.id == selection }) {
                HistoryDetail(entry: entry, research: research).id(entry.id)
            } else {
                VStack(spacing: 10) {
                    RoundedRectangle(cornerRadius: 3).fill(Style.ink(nil)).frame(width: 28, height: 14).rotationEffect(.degrees(-8))
                    Text("Pick a check to see its verdict and sources").font(.system(size: 14, design: .serif)).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(minWidth: 760, minHeight: 460)
        .onAppear { selection = selection ?? store.entries.first?.id }
    }
}

struct HistoryRow: View {
    var entry: HistoryEntry
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 4) {
                ForEach(Array(entry.labels.prefix(3).enumerated()), id: \.offset) { _, label in
                    RoundedRectangle(cornerRadius: 2).fill(Style.ink(label)).frame(width: 12, height: 7).rotationEffect(.degrees(-8))
                }
                Text(entry.mode == .research ? "RESEARCH" : (entry.labels.first.map { Style.word($0).uppercased() } ?? "CHECK"))
                    .font(Style.mono).foregroundStyle(entry.mode == .research ? Style.ink("research") : Style.ink(entry.labels.first))
                Spacer()
                Text(entry.date, style: .relative).font(Style.mono).foregroundStyle(.tertiary)
            }
            Text(entry.input).font(.system(size: 13, design: .serif)).lineLimit(2)
            if !entry.app.isEmpty { Text(entry.app.uppercased()).font(Style.mono).foregroundStyle(.tertiary) }
        }
        .padding(.vertical, 4)
    }
}

struct HistoryDetail: View {
    @StateObject private var check: Check
    var research: (String) -> Void

    init(entry: HistoryEntry, research: @escaping (String) -> Void) {
        _check = StateObject(wrappedValue: Check(entry: entry))
        self.research = research
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("\(check.mode == .research ? "RESEARCH" : "CHECK") · \(check.app.uppercased()) · \(check.date.formatted(date: .abbreviated, time: .shortened))")
                    .font(Style.mono).tracking(1.2).foregroundStyle(.secondary)
                ResultView(check: check, research: research)
                TraceFooter(check: check, startOpen: false)
            }
            .padding(28)
            .frame(maxWidth: 640, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .background(Style.paper)
    }
}
