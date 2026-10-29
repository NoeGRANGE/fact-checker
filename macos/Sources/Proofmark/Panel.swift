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
        case "research": return Color(red: 0.50, green: 0.83, blue: 1.00)
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
        super.init(contentRect: NSRect(x: 0, y: 0, width: 440, height: 200),
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

    @MainActor func show(_ check: Check, keepPosition: Bool = false) {
        self.check?.cancel()
        self.check = check
        let maxHeight = (NSScreen.main?.visibleFrame.height ?? 900) * 0.72
        let host = NSHostingController(rootView: PanelView(
            check: check, maxHeight: maxHeight, close: { [weak self] in self?.dismiss() },
            research: { [weak self] text in self?.show(Check(mode: .research, text: text, image: nil, app: check.app), keepPosition: true) }))
        host.sizingOptions = [.preferredContentSize]
        contentViewController = host
        if keepPosition && isVisible { return }

        // Open just under the mouse, kept on screen
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main!
        let vf = screen.visibleFrame
        let x = min(max(mouse.x - 40, vf.minX + 12), vf.maxX - 452)
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

private struct HeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

struct PanelView: View {
    @ObservedObject var check: Check
    var maxHeight: CGFloat
    var close: () -> Void
    var research: (String) -> Void
    @State private var copied = false
    @State private var contentHeight: CGFloat = 40

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            // Scrolls only once the results outgrow the screen
            ScrollView {
                ResultView(check: check, research: research)
                    .background(GeometryReader { Color.clear.preference(key: HeightKey.self, value: $0.size.height) })
            }
            .scrollIndicators(.never)
            .frame(height: min(contentHeight, maxHeight))
            .onPreferenceChange(HeightKey.self) { h in withAnimation(.snappy) { contentHeight = h } }
            if check.error == nil && !check.trace.isEmpty { TraceFooter(check: check, startOpen: true) }
        }
        .padding(18)
        .frame(width: 440, alignment: .leading)
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
            RoundedRectangle(cornerRadius: 2).fill(Style.ink(check.mode == .research ? "research" : nil))
                .frame(width: 14, height: 8).rotationEffect(.degrees(-8))
            Text(check.mode == .research ? "PROOFMARK · RESEARCH" : "PROOFMARK").font(Style.mono).tracking(2.4)
            if !check.app.isEmpty {
                Text("· \(check.app)").font(Style.mono).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            if copied { Text("COPIED").font(Style.mono).foregroundStyle(Style.ink("true")) }
            Button(action: close) { Image(systemName: "xmark").font(.system(size: 10, weight: .bold)) }
                .buttonStyle(.plain).foregroundStyle(.secondary)
        }
    }

    func copy() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(check.markdown, forType: .string)
        withAnimation { copied = true }
    }
}

/// The body shared by the floating panel and the history window.
struct ResultView: View {
    @ObservedObject var check: Check
    var research: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if let err = check.error {
                Text(err).font(.system(size: 13)).foregroundStyle(.white.opacity(0.85))
            } else if check.mode == .research {
                ResearchView(check: check, research: research)
            } else if check.claims.isEmpty {
                MarkerText(text: check.input, ink: Style.ink(nil), done: false).lineLimit(4)
                Text(check.status.uppercased()).font(Style.mono).tracking(1.2).foregroundStyle(.secondary)
                if check.finished != nil {
                    ActionLink(title: "RESEARCH THIS INSTEAD") { research(check.input) }
                }
            } else {
                ForEach(check.claims) { ClaimView(claim: $0, startOpen: $0.id == 0, research: research) }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Accordion row: the label stays, the content folds away.
struct Fold<Label: View, Content: View>: View {
    @State private var open: Bool
    let label: Label
    let content: Content

    init(open: Bool = false, @ViewBuilder label: () -> Label, @ViewBuilder content: () -> Content) {
        _open = State(initialValue: open)
        self.label = label()
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button { withAnimation(.snappy(duration: 0.25)) { open.toggle() } } label: {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    label
                    Spacer(minLength: 4)
                    Image(systemName: "chevron.right").font(.system(size: 9, weight: .bold))
                        .rotationEffect(.degrees(open ? 90 : 0)).foregroundStyle(.secondary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if open { content.transition(.opacity.combined(with: .move(edge: .top))) }
        }
    }
}

struct ActionLink: View {
    var title: String
    var action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Text(title)
                Image(systemName: "arrow.right")
            }
            .font(.system(size: 10.5, weight: .bold, design: .monospaced)).tracking(1.2)
            .foregroundStyle(.black)
            .padding(.horizontal, 9).padding(.vertical, 5)
            .background(Style.ink("research"), in: RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
    }
}

struct ClaimView: View {
    var claim: ClaimState
    var startOpen: Bool
    var research: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            MarkerText(text: claim.text, ink: Style.ink(claim.verdict?.label), done: claim.verdict != nil)
            if let v = claim.verdict {
                Fold(open: startOpen) {
                    HStack(spacing: 10) {
                        Text(Style.word(v.label).uppercased())
                            .font(.system(size: 12, weight: .bold, design: .monospaced)).tracking(1.6)
                            .foregroundStyle(Style.ink(v.label))
                        Ruler(value: v.confidence, ink: Style.ink(v.label))
                        Text("\(v.confidence)").font(Style.mono).foregroundStyle(.secondary)
                    }
                } content: {
                    details(v)
                }
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

    @ViewBuilder func details(_ v: Verdict) -> some View {
        Text(v.summary).font(.system(size: 13)).foregroundStyle(.white.opacity(0.88))
            .fixedSize(horizontal: false, vertical: true)
        ForEach(v.quotes.prefix(3), id: \.self) { QuoteView(quote: $0, ink: Style.ink(v.label)) }
        if !claim.sources.isEmpty {
            Fold {
                Text("ALL SOURCES · \(claim.sources.count)").font(Style.mono).tracking(1.2).foregroundStyle(.secondary)
            } content: {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(claim.sources, id: \.self) { SourceRow(source: $0) }
                }
            }
        }
        HStack(spacing: 10) {
            if let o = claim.origin, let url = URL(string: o.url) {
                Link(destination: url) { Text("EARLIEST FOUND · \(o.domain) · \(o.date)") }
            }
            if v.rejected > 0 {
                Text("\(v.rejected) UNVERIFIED QUOTE\(v.rejected > 1 ? "S" : "") DROPPED")
            }
        }
        .font(Style.mono).foregroundStyle(.secondary)
        ActionLink(title: "DIG DEEPER") { research(claim.text) }
    }
}

/// One source in the accordion: domain and title, unfolds to the passage Tavily found.
struct SourceRow: View {
    var source: Source
    var body: some View {
        Fold {
            HStack(spacing: 6) {
                if let side = source.side {
                    Text(side == "challenge" ? "AGAINST" : "FOR")
                        .font(.system(size: 8.5, weight: .bold, design: .monospaced))
                        .foregroundStyle(side == "challenge" ? Style.ink("false") : Style.ink("true"))
                        .frame(width: 44, alignment: .leading)
                }
                Text(source.domain).font(Style.mono).foregroundStyle(source.trusted == true ? .primary : .secondary)
                Text(source.title ?? "").font(.system(size: 11.5)).foregroundStyle(.secondary).lineLimit(1)
            }
        } content: {
            VStack(alignment: .leading, spacing: 6) {
                if let s = source.snippet, !s.isEmpty {
                    Text(s).font(.system(size: 12, design: .serif)).foregroundStyle(.white.opacity(0.8))
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let url = URL(string: source.url) {
                    Link(destination: url) { Text("OPEN \(source.domain.uppercased()) ↗").font(Style.mono) }
                }
            }
            .padding(.leading, 12)
        }
    }
}

struct ResearchView: View {
    @ObservedObject var check: Check
    var research: (String) -> Void

    var sections: [(title: String, body: String)] {
        var out: [(String, String)] = []
        for line in check.report.components(separatedBy: "\n") {
            if line.hasPrefix("#") {
                out.append((line.trimmingCharacters(in: CharacterSet(charactersIn: "# ")), ""))
            } else if out.isEmpty {
                if !line.trimmingCharacters(in: .whitespaces).isEmpty { out.append(("Overview", line)) }
            } else {
                out[out.count - 1].1 += line + "\n"
            }
        }
        return out
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            MarkerText(text: check.input, ink: Style.ink("research"), done: check.finished != nil)
            if let tldr = check.tldr {
                Text(tldr).font(.system(size: 14, design: .serif)).foregroundStyle(.white.opacity(0.95))
                    .fixedSize(horizontal: false, vertical: true)
            }
            if check.finished == nil {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.mini)
                    Text(check.status.uppercased()).font(Style.mono).tracking(1.2).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            ForEach(Array(sections.enumerated()), id: \.offset) { i, section in
                Fold(open: i == 0) {
                    Text(section.title).font(.system(size: 13, weight: .semibold)).multilineTextAlignment(.leading)
                } content: {
                    Text(markdown(section.body)).font(.system(size: 13)).foregroundStyle(.white.opacity(0.85))
                        .tint(Style.ink("research")).fixedSize(horizontal: false, vertical: true)
                }
                Divider().opacity(0.25)
            }
            if !check.researchSources.isEmpty {
                Fold {
                    Text("SOURCES · \(check.researchSources.count)").font(Style.mono).tracking(1.2).foregroundStyle(.secondary)
                } content: {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(Array(check.researchSources.enumerated()), id: \.offset) { i, s in
                            if let url = URL(string: s.url) {
                                Link(destination: url) {
                                    HStack(spacing: 6) {
                                        Text("\(i + 1)").font(Style.mono).foregroundStyle(Style.ink("research")).frame(width: 18, alignment: .trailing)
                                        Text(s.domain).font(Style.mono)
                                        Text(s.title ?? "").font(.system(size: 11.5)).foregroundStyle(.secondary).lineLimit(1)
                                    }
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }
            }
            if !check.followUps.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("KEEP DIGGING").font(Style.mono).tracking(1.2).foregroundStyle(.secondary)
                    ForEach(check.followUps, id: \.self) { q in
                        Button { research(q) } label: {
                            Text("→ \(q)").font(.system(size: 12.5, design: .serif)).multilineTextAlignment(.leading)
                                .foregroundStyle(Style.ink("research"))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    /// Inline markdown, with [n] citations turned into links to source n.
    func markdown(_ text: String) -> AttributedString {
        var md = text.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\n- ", with: "\n• ").replacingOccurrences(of: "\n* ", with: "\n• ")
        if md.hasPrefix("- ") || md.hasPrefix("* ") { md = "• " + md.dropFirst(2) }
        for (i, s) in check.researchSources.enumerated() {
            for cite in ["[\(i + 1)]", "【\(i + 1)】"] {
                md = md.replacingOccurrences(of: cite, with: "[[\(i + 1)]](\(s.url))")
            }
        }
        return (try? AttributedString(markdown: md, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(text)
    }
}

struct TraceFooter: View {
    @ObservedObject var check: Check
    @State private var open: Bool

    init(check: Check, startOpen: Bool) {
        self.check = check
        _open = State(initialValue: startOpen)
    }

    var title: String {
        guard let f = check.finished else { return "\(check.trace.count) TAVILY STEPS…" }
        let secs = String(format: "%.1f", Double(f.ms) / 1000)
        return check.mode == .research ? "TAVILY RESEARCH · \(check.trace.count) STEPS · \(secs)s" : "\(f.calls) TAVILY CALLS · \(secs)s"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Divider().opacity(0.4)
            Button { withAnimation(.snappy) { open.toggle() } } label: {
                HStack(spacing: 6) {
                    Text(title)
                    Image(systemName: open ? "chevron.up" : "chevron.down")
                    Spacer()
                    Text("⌘C COPY")
                }
                .font(Style.mono).tracking(1).foregroundStyle(.secondary).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            // Trace stays open while the check runs: watching Tavily work is part of the show
            if open || check.finished == nil {
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
}

struct TraceRow: View {
    var line: TraceLine
    var body: some View {
        HStack(spacing: 6) {
            Text(line.endpoint.uppercased())
                .font(.system(size: 9, weight: .bold, design: .monospaced))
                .foregroundStyle(.black)
                .padding(.horizontal, 4).padding(.vertical, 1)
                .background(Style.ink(line.endpoint == "research" ? "research" : nil), in: RoundedRectangle(cornerRadius: 3))
            Text(line.label).font(Style.mono).foregroundStyle(.secondary).frame(width: 66, alignment: .leading)
            Text(line.query).font(Style.mono).lineLimit(1).truncationMode(.tail).foregroundStyle(.primary.opacity(0.8))
            Spacer(minLength: 4)
            Text(line.ms > 0 ? "\(line.count) · \(line.ms)ms" : (line.count > 0 ? "\(line.count) queries" : ""))
                .font(Style.mono).foregroundStyle(.tertiary)
        }
        .transition(.move(edge: .top).combined(with: .opacity))
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
                if done { reveal = text.count } else {
                    withAnimation(.easeInOut(duration: 0.9).repeatForever()) { pulse = true }
                }
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

/// A verified quote: three lines folded, full text on click.
struct QuoteView: View {
    var quote: Quote
    var ink: Color
    @State private var expanded = false

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Capsule().fill(ink).frame(width: 3)
            VStack(alignment: .leading, spacing: 4) {
                Text("“\(quote.text)”").font(.system(size: 13, design: .serif)).italic()
                    .foregroundStyle(.white.opacity(0.9)).multilineTextAlignment(.leading)
                    .lineLimit(expanded ? nil : 3)
                    .fixedSize(horizontal: false, vertical: true)
                    .onTapGesture { withAnimation(.snappy) { expanded.toggle() } }
                HStack(spacing: 6) {
                    Text([quote.domain, quote.date.map { String($0.prefix(16)) }].compactMap { $0 }.joined(separator: " · ").uppercased())
                    if let url = URL(string: quote.url) { Link("↗", destination: url) }
                }
                .font(Style.mono).foregroundStyle(.secondary)
            }
        }
    }
}
