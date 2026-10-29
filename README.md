# Margin

**Highlight anything on your Mac. Margin tells you if it's true.**

Select a sentence in any app (Slack, Mail, Safari, a PDF, Notes) and press **⌥Space**. A glass panel opens next to your cursor. Within seconds the claim gets marked with a highlighter colour for its verdict, followed by the exact quotes that support it and the earliest source found. Press **⌥⇧Space** to check a screenshot region instead: tweets saved as images, slides, video frames.

Built for the Nebius × NVIDIA Global AI Hackathon, track **Best Apps and Agents**.

## Run it (2 minutes)

You need macOS 14+, the Xcode command line tools (`xcode-select --install`) and [uv](https://docs.astral.sh/uv/) (`brew install uv`).

```bash
git clone <this repo> margin && cd margin
./run.sh            # first run creates .env, add your two keys in it
./run.sh            # builds Margin.app, opens it, starts the local backend
```

Keys:
- `NEBIUS_API_KEY` from [Nebius Token Factory](https://tokenfactory.nebius.com)
- `TAVILY_API_KEY` from [Tavily](https://app.tavily.com)

On first launch macOS asks for **Accessibility** access (needed to read the selected text). Grant it in System Settings → Privacy & Security → Accessibility, then press ⌥Space again. For region checks, macOS also asks for **Screen Recording** access.

No Mac? Open **http://127.0.0.1:8787** for the web playground. It runs the same pipeline.

## How it works

```
 Margin.app (Swift)           local backend (FastAPI)                    Nebius Token Factory
 ⌥Space → selected text  ──►  1. split into claims + write queries  ──►  Nemotron 3 Nano
 ⌥⇧Space → screenshot         0. image → text                       ──►  Nemotron 3.5 Super VL
        ▲                     2. search to CONFIRM and to CHALLENGE ──►  Tavily /search (×2, parallel)
        │ live SSE events     3. read the best sources in full      ──►  Tavily /extract
        └──────────────────   4. judge from the sources only        ──►  Nemotron 3 Ultra
                              5. drop any quote not found verbatim  (plain code, no model)
                              6. find the earliest dated coverage   ──►  Tavily /search (news)
```

Every step streams to the panel as soon as it finishes, so you watch the sources arrive before the verdict lands.

### How we use Tavily

Tavily is the backbone of the evidence, not a single search pasted into a prompt.

- **Adversarial search.** For each claim, Nemotron writes one query that would confirm it and one that would debunk it. Both run in parallel with `search_depth=advanced` and `chunks_per_source`, and the right `topic` (`news`, `finance`, `general`). `time_range` is added when the claim is about recent events. The verdict weighs both sides, and the best challenging source is always read.
- **Extract as ground truth.** `/extract` pulls the full text of the top sources. The judge must quote sentences from them, and plain code checks each quote character by character against the extracted text. Any quote that isn't really there gets dropped, and the panel says so. A verdict with no verified quote is capped at 40% confidence.
- **Origin tracing.** For numbers and quotes, a `news` search on the exact phrase is sorted by `published_date` to show where the claim first appeared.
- **Visible trace.** The panel footer lists every Tavily call live: endpoint, intent, query, result count and latency.

### How we use NVIDIA Nemotron on Nebius Token Factory

We route each step to the right size of model, as the track suggests:

| Step | Model | Why |
|---|---|---|
| Split claims, write confirm/challenge queries | Nemotron 3 Nano 30B | Runs on every check: 0.8s |
| Read screenshots | Nemotron 3.5 Super VL | Vision: transcribes the claims, ignores UI chrome (2.4s) |
| Judge the evidence | Nemotron 3 Ultra 550B | Strongest reasoning, for the step that decides the verdict |

We measured every step during the hackathon. With reasoning traces turned off (`enable_thinking: false`) and JSON mode on, Ultra judges six sources in about 1.2s, against 3 to 13s with traces on, and it never returned malformed JSON. Verdict quality held on our test set, so the biggest model also ended up being the fastest way to judge.

All calls go through Token Factory's OpenAI-compatible API (`https://api.tokenfactory.nebius.com/v1/`). Model IDs are auto-detected from the Token Factory model list (Nano, Ultra, Super VL), or can be pinned in `.env` (`MODEL_FAST`, `MODEL_JUDGE`, `MODEL_VISION`).

Token Factory sped us up because one OpenAI-compatible client covers three Nemotron sizes plus a vision model. Switching a step to a bigger or smaller model was a one-line change, so we could tune latency against quality during the hackathon.

## Project layout

```
backend/margin/pipeline.py   the fact-check agent (Tavily + Nemotron + quote verification)
backend/margin/server.py     FastAPI, streams events over SSE, serves the web playground
backend/margin/static/       web playground
macos/Sources/Margin/        menu bar app: hotkeys, selection capture, panel
run.sh                       build + launch everything
```

Test the pipeline from the terminal:

```bash
cd backend && uv run --env-file ../.env python -m margin.pipeline "The Great Wall of China is visible from space."
uv run python test_pipeline.py   # quote-verification self-checks
```

## License

MIT
