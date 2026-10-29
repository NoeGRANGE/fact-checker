import AppKit
import SwiftUI

/// Highlighter inks: each verdict marks the claim the way a fact-checker would with a real marker.
enum Style {
    static func ink(_ label: String?) -> Color {
        switch label {
        case "true": return Color(red: 0.49, green: 0.95, blue: 0.60)
        case "mostly_true": return Color(red: 0.78, green: 0.95, blue: 0.42)
        case "misleading": return Color(red: 1.00, green: 0.82, blue: 0.25)
        case "false": return Color(red: 1.00, green: 0.44, blue: 0.64)
        case "unverifiable": return Color(red: 0.76, green: 0.76, blue: 0.84)
        default: return Color(red: 1.00, green: 0.88, blue: 0.30)
        }
    }

    static func word(_ label: String) -> String {
        ["true": "True", "mostly_true": "Mostly true", "misleading": "Misleading",
         "false": "False", "unverifiable": "Unverifiable"][label] ?? label
    }

    static let mono = Font.system(size: 10.5, weight: .medium, design: .monospaced)
    static let paper = Color(red: 0.07, green: 0.07, blue: 0.09)
}

final class CheckPanel: NSPanel {
    private var check: Check?
    private var anchorTop: CGFloat = 0

    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 420, height: 200),
                   styleMask: [.nonactivatingPanel, .fullSizeContentView, .borderless],
                   backing: .buffered, defer: true)
        isFloatingPanel = true
        level = .floating
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true
        isMovableByWindowBackground = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        NotificationCenter.default.addObserver(forName: NSWindow.didResizeNotification, object: self, queue: .main) { [weak self] _ in
            self?.pinTop()
        }
    }

    override var canBecomeKey: Bool { true }

    @MainActor func show(_ check: Check) {
        self.check?.cancel()
        self.check = check
        let host = NSHostingController(rootView: PanelView(check: check, close: { [weak self] in self?.dismiss() }))
        host.sizingOptions = [.preferredContentSize]
        contentViewController = host

        // Open just under the mouse, kept on screen
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main!
        let vf = screen.visibleFrame
        let x = min(max(mouse.x - 40, vf.minX + 12), vf.maxX - 432)
        anchorTop = min(mouse.y - 18, vf.maxY - 12)
        setFrameTopLeftPoint(NSPoint(x: x, y: anchorTop))
        alphaValue = 0
        makeKeyAndOrderFront(nil)
        NSAnimationContext.runAnimationGroup { $0.duration = 0.18; animator().alphaValue = 1 }
    }

    /// Content grows as results stream in: keep the top edge still and grow downward, never off screen.
    private func pinTop() {
        guard let vf = screen?.visibleFrame else { return }
        let top = max(anchorTop, vf.minY + frame.height + 12)
        if abs(frame.maxY - top) > 0.5 { setFrameTopLeftPoint(NSPoint(x: frame.minX, y: top)) }
    }

    func dismiss() {
        check?.cancel()
        orderOut(nil)
    }

    override func cancelOperation(_ sender: Any?) { dismiss() }
}

struct PanelView: View {
    @ObservedObject var check: Check
    var close: () -> Void
    @State private var showTrace = false
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            if let err = check.error {
                Text(err).font(.system(size: 13)).foregroundStyle(.white.opacity(0.85))
            } else if check.claims.isEmpty {
                pending
            } else {
                ForEach(check.claims) { ClaimView(claim: $0) }
            }
            if check.error == nil && (!check.trace.isEmpty) { footer }
        }
        .padding(18)
        .frame(width: 420, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
        .background(glass)
        .environment(\.colorScheme, .dark)
        .background(Button("") { copy() }.keyboardShortcut("c", modifiers: .command).hidden())
    }

    @ViewBuilder var glass: some View {
        let shape = RoundedRectangle(cornerRadius: 22, style: .continuous)
        if #available(macOS 26.0, *) {
            shape.fill(Style.paper.opacity(0.55)).glassEffect(.regular, in: shape)
        } else {
            shape.fill(.ultraThinMaterial).overlay(shape.fill(Style.paper.opacity(0.6)))
                .overlay(shape.strokeBorder(.white.opacity(0.12)))
        }
    }

    var header: some View {
        HStack(spacing: 8) {
            RoundedRectangle(cornerRadius: 2).fill(Style.ink(nil)).frame(width: 14, height: 8).rotationEffect(.degrees(-8))
            Text("MARGIN").font(Style.mono).tracking(2.4)
            if !check.app.isEmpty {
                Text("· \(check.app)").font(Style.mono).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            if copied { Text("COPIED").font(Style.mono).foregroundStyle(Style.ink("true")) }
            Button(action: close) { Image(systemName: "xmark").font(.system(size: 10, weight: .bold)) }
                .buttonStyle(.plain).foregroundStyle(.secondary)
        }
    }

    var pending: some View {
        VStack(alignment: .leading, spacing: 10) {
            if !check.input.isEmpty {
                MarkerText(text: check.input, ink: Style.ink(nil), done: false).lineLimit(4)
            }
            Text(check.status.uppercased()).font(Style.mono).tracking(1.2).foregroundStyle(.secondary)
        }
    }

    var footer: some View {
        VStack(alignment: .leading, spacing: 6) {
            Divider().opacity(0.4)
            Button { withAnimation(.snappy) { showTrace.toggle() } } label: {
                HStack(spacing: 6) {
                    Text(check.finished.map { "\($0.calls) TAVILY CALLS · \(String(format: "%.1f", Double($0.ms) / 1000))s" }
                         ?? "\(check.trace.count) TAVILY CALLS…")
                    Image(systemName: showTrace || check.finished == nil ? "chevron.up" : "chevron.down")
                    Spacer()
                    Text("⌘C COPY")
                }
                .font(Style.mono).tracking(1).foregroundStyle(.secondary).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            // Trace stays open while the check runs: watching Tavily work is part of the show
            if showTrace || check.finished == nil {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(check.trace) { TraceRow(line: $0) }
                    if !check.models.isEmpty {
                        Text(check.models.map { $0.components(separatedBy: "/").last ?? $0 }.joined(separator: " · "))
                            .font(Style.mono).foregroundStyle(.tertiary).padding(.top, 4)
                    }
                }
                .transition(.opacity)
            }
        }
    }

    func copy() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(check.markdown, forType: .string)
        withAnimation { copied = true }
    }
}

struct TraceRow: View {
    var line: TraceLine
    var body: some View {
        HStack(spacing: 6) {
            Text(line.endpoint.uppercased())
                .font(.system(size: 9, weight: .bold, design: .monospaced))
                .foregroundStyle(.black)
                .padding(.horizontal, 4).padding(.vertical, 1)
                .background(Style.ink(nil), in: RoundedRectangle(cornerRadius: 3))
            Text(line.label).font(Style.mono).foregroundStyle(.secondary).frame(width: 62, alignment: .leading)
            Text(line.query).font(Style.mono).lineLimit(1).truncationMode(.tail).foregroundStyle(.primary.opacity(0.8))
            Spacer(minLength: 4)
            Text("\(line.count) · \(line.ms)ms").font(Style.mono).foregroundStyle(.tertiary)
        }
        .transition(.move(edge: .top).combined(with: .opacity))
    }
}

struct ClaimView: View {
    var claim: ClaimState

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            MarkerText(text: claim.text, ink: Style.ink(claim.verdict?.label), done: claim.verdict != nil)
            if let v = claim.verdict {
                HStack(spacing: 10) {
                    Text(Style.word(v.label).uppercased())
                        .font(.system(size: 12, weight: .bold, design: .monospaced)).tracking(1.6)
                        .foregroundStyle(Style.ink(v.label))
                    Ruler(value: v.confidence, ink: Style.ink(v.label))
                    Text("\(v.confidence)").font(Style.mono).foregroundStyle(.secondary)
                }
                Text(v.summary).font(.system(size: 13)).foregroundStyle(.white.opacity(0.88))
                    .fixedSize(horizontal: false, vertical: true)
                ForEach(v.quotes.prefix(2), id: \.self) { QuoteView(quote: $0, ink: Style.ink(v.label)) }
                HStack(spacing: 10) {
                    if let o = claim.origin {
                        Link(destination: URL(string: o.url)!) {
                            Text("EARLIEST FOUND · \(o.domain) · \(o.date)")
                        }
                    }
                    if v.rejected > 0 {
                        Text("\(v.rejected) UNVERIFIED QUOTE\(v.rejected > 1 ? "S" : "") DROPPED")
                    }
                }
                .font(Style.mono).foregroundStyle(.secondary)
            } else {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.mini)
                    Text(claim.status.uppercased()).font(Style.mono).tracking(1.2).foregroundStyle(.secondary)
                    if !claim.sources.isEmpty {
                        Text("· \(claim.sources.count) SOURCES").font(Style.mono).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .animation(.snappy, value: claim.verdict?.label)
    }
}

/// The signature element: the claim gets "highlighted" with a marker, character by character, in the verdict's ink.
struct MarkerText: View {
    var text: String
    var ink: Color
    var done: Bool
    @State private var reveal = 0
    @State private var pulse = false

    var body: some View {
        Text(attributed)
            .font(.system(size: 16.5, weight: .regular, design: .serif))
            .lineSpacing(3)
            .fixedSize(horizontal: false, vertical: true)
            .opacity(done ? 1 : (pulse ? 0.75 : 1))
            .onAppear {
                withAnimation(.easeInOut(duration: 0.9).repeatForever()) { pulse = true }
                if done { reveal = text.count }
            }
            .onChange(of: done) { _, isDone in if isDone { sweep() } }
    }

    var attributed: AttributedString {
        var s = AttributedString(text)
        s.foregroundColor = .white.opacity(0.92)
        if done {
            let end = s.index(s.startIndex, offsetByCharacters: min(reveal, text.count))
            s[s.startIndex..<end].backgroundColor = ink.opacity(0.9)
            s[s.startIndex..<end].foregroundColor = .black
        } else {
            s.backgroundColor = ink.opacity(0.16)
        }
        return s
    }

    func sweep() {
        pulse = false
        reveal = 0
        let total = text.count
        Task { @MainActor in
            for step in 1...24 {
                try? await Task.sleep(nanoseconds: 22_000_000)
                reveal = total * step / 24
            }
        }
    }
}

/// Confidence as ten ruler ticks, like the scale printed in a notebook margin.
struct Ruler: View {
    var value: Int
    var ink: Color
    var body: some View {
        HStack(spacing: 2.5) {
            ForEach(0..<10, id: \.self) { i in
                Capsule().fill(i < (value + 5) / 10 ? ink : .white.opacity(0.14))
                    .frame(width: 2.5, height: i % 5 == 4 ? 11 : 7)
            }
        }
    }
}

struct QuoteView: View {
    var quote: Quote
    var ink: Color
    var body: some View {
        Link(destination: URL(string: quote.url) ?? URL(string: "about:blank")!) {
            HStack(alignment: .top, spacing: 10) {
                Capsule().fill(ink).frame(width: 3)
                VStack(alignment: .leading, spacing: 4) {
                    Text("“\(quote.text)”").font(.system(size: 13, design: .serif)).italic()
                        .foregroundStyle(.white.opacity(0.9)).multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                    Text([quote.domain, quote.date.map { String($0.prefix(16)) }].compactMap { $0 }.joined(separator: " · ").uppercased())
                        .font(Style.mono).foregroundStyle(.secondary)
                }
            }
        }
        .buttonStyle(.plain)
    }
}
