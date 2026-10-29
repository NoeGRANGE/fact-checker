import Foundation

/// One server-sent event from the backend. All fields optional: each event type uses a few.
struct Event: Decodable {
    var type: String
    var text: String?
    var claim: Int?
    var claims: [ClaimIn]?
    var endpoint: String?
    var label: String?
    var query: String?
    var ms: Int?
    var count: Int?
    var sources: [SourceIn]?
    var confidence: Int?
    var summary: String?
    var quotes: [Quote]?
    var rejected: Int?
    var url: String?
    var domain: String?
    var date: String?
    var tavily_calls: Int?
    var message: String?
    var model: String?
}

struct ClaimIn: Decodable { var id: Int; var text: String; var kind: String }
struct SourceIn: Decodable { var url: String; var domain: String; var side: String; var trusted: Bool }
struct Quote: Decodable, Hashable { var text: String; var url: String; var domain: String; var date: String? }

struct Verdict { var label: String; var confidence: Int; var summary: String; var quotes: [Quote]; var rejected: Int }
struct Origin { var domain: String; var url: String; var date: String }

struct ClaimState: Identifiable {
    var id: Int
    var text: String
    var status = "Searching both sides"
    var sources: [SourceIn] = []
    var verdict: Verdict?
    var origin: Origin?
}

struct TraceLine: Identifiable {
    let id = UUID()
    var endpoint: String, label: String, query: String, ms: Int, count: Int
}

@MainActor
final class Check: ObservableObject {
    let app: String
    @Published var input: String
    @Published var status = "Reading"
    @Published var claims: [ClaimState] = []
    @Published var trace: [TraceLine] = []
    @Published var models: [String] = []
    @Published var finished: (calls: Int, ms: Int)?
    @Published var error: String?
    private var task: Task<Void, Never>?

    static let server = URL(string: ProcessInfo.processInfo.environment["MARGIN_URL"] ?? "http://127.0.0.1:8787")!

    init(error: String, app: String) {
        self.app = app
        self.input = ""
        self.error = error
    }

    init(text: String, image: Data?, app: String) {
        self.app = app
        self.input = text
        task = Task { await run(text: text, image: image) }
    }

    func cancel() { task?.cancel() }

    private func run(text: String, image: Data?) async {
        var req = URLRequest(url: Check.server.appendingPathComponent("check"))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.timeoutInterval = 120
        var body: [String: Any] = ["text": text]
        if let image { body["image_b64"] = image.base64EncodedString() }
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        do {
            let (bytes, response) = try await URLSession.shared.bytes(for: req)
            if let http = response as? HTTPURLResponse, http.statusCode != 200 {
                error = "The Margin server answered \(http.statusCode)."
                return
            }
            for try await line in bytes.lines where line.hasPrefix("data: ") {
                if let ev = try? JSONDecoder().decode(Event.self, from: Data(line.dropFirst(6).utf8)) { apply(ev) }
            }
        } catch is CancellationError {
        } catch {
            self.error = "Can't reach the Margin server at \(Check.server.absoluteString). Start it with ./run.sh."
        }
    }

    private func apply(_ ev: Event) {
        if let m = ev.model, !models.contains(m) { models.append(m) }
        switch ev.type {
        case "status":
            if let i = ev.claim { claims[safe: i]?.status = ev.text ?? "" } else { status = ev.text ?? "" }
        case "transcript":
            input = ev.text ?? ""
        case "claims":
            claims = (ev.claims ?? []).map { ClaimState(id: $0.id, text: $0.text) }
            status = claims.isEmpty ? "No checkable claim found" : "Searching"
        case "trace":
            trace.append(TraceLine(endpoint: ev.endpoint ?? "", label: ev.label ?? "", query: ev.query ?? "",
                                   ms: ev.ms ?? 0, count: ev.count ?? 0))
        case "sources":
            if let i = ev.claim { claims[safe: i]?.sources = ev.sources ?? []; claims[safe: i]?.status = "Reading sources" }
        case "verdict":
            if let i = ev.claim {
                claims[safe: i]?.verdict = Verdict(label: ev.label ?? "unverifiable", confidence: ev.confidence ?? 0,
                                                   summary: ev.summary ?? "", quotes: ev.quotes ?? [], rejected: ev.rejected ?? 0)
            }
        case "origin":
            if let i = ev.claim, let d = ev.domain, let u = ev.url {
                claims[safe: i]?.origin = Origin(domain: d, url: u, date: String((ev.date ?? "").prefix(16)))
            }
        case "done":
            finished = (ev.tavily_calls ?? 0, ev.ms ?? 0)
        case "error":
            error = ev.message
        default: break
        }
    }

    /// Markdown summary for ⌘C, ready to paste in a reply.
    var markdown: String {
        claims.map { c in
            guard let v = c.verdict else { return "" }
            let src = v.quotes.map { "> \($0.text)\n> — \($0.url)" }.joined(separator: "\n")
            return "**\(Style.word(v.label))** (\(v.confidence)%): \(c.text)\n\(v.summary)\n\(src)"
        }.joined(separator: "\n\n") + "\n\n_Checked with Margin_"
    }
}

extension Array {
    subscript(safe i: Int) -> Element? {
        get { indices.contains(i) ? self[i] : nil }
        set { if let newValue, indices.contains(i) { self[i] = newValue } }
    }
}
