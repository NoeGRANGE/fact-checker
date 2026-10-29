"""Fact-check pipeline: Nemotron splits claims, Tavily searches both sides and extracts sources,
Nemotron judges, and code verifies every quoted sentence really exists in the source."""

import asyncio
import json
import os
import re
import sys
import time
from urllib.parse import urlparse

import httpx
from openai import AsyncOpenAI

TAVILY = "https://api.tavily.com"
llm = AsyncOpenAI(
    base_url=os.environ.get("NEBIUS_BASE_URL", "https://api.tokenfactory.nebius.com/v1/"),
    api_key=os.environ.get("NEBIUS_API_KEY", "missing"),
)
http = httpx.AsyncClient(timeout=40)

# Picked from env, else auto-detected from the Token Factory model list (see resolve_models)
MODELS = {
    "fast": os.environ.get("MODEL_FAST", ""),
    "judge": os.environ.get("MODEL_JUDGE", ""),
    "vision": os.environ.get("MODEL_VISION", ""),
}
WANT = {"fast": ["nemotron", "nano"], "judge": ["nemotron", "ultra"], "vision": ["nemotron", "vl"]}

TRUSTED = (".gov", ".gouv.fr", ".edu", ".int", ".europa.eu", "nih.gov", "who.int", "reuters.com",
           "apnews.com", "afp.com", "bbc.co.uk", "bbc.com", "nature.com", "science.org", "snopes.com",
           "fullfact.org", "politifact.com", "factcheck.org", "britannica.com", "wikipedia.org",
           "scientificamerican.com", "nytimes.com", "theguardian.com", "lemonde.fr", "insee.fr")
NO_TEXT = ("youtube.com", "youtu.be", "tiktok.com", "instagram.com", "facebook.com", "x.com", "twitter.com")


async def resolve_models():
    if all(MODELS.values()):
        return MODELS
    ids = [m.id for m in (await llm.models.list()).data]
    for role, words in WANT.items():
        if not MODELS[role]:
            hits = [i for i in ids if all(w in i.lower() for w in words)
                    and (role == "vision" or "vl" not in i.lower())]
            MODELS[role] = hits[0] if hits else ""
    if not MODELS["fast"]:
        raise RuntimeError(f"No Nemotron Nano model found on Token Factory. Available: {ids}")
    MODELS["judge"] = MODELS["judge"] or next((i for i in ids if "nemotron" in i.lower() and "super" in i.lower()
                                               and "vl" not in i.lower()), MODELS["fast"])
    return MODELS


async def ask_json(model, system, user, max_tokens=1200):
    # Reasoning off + JSON mode: measured 1.2s for Ultra vs 3-13s with thinking, and no malformed JSON
    r = await llm.chat.completions.create(
        model=model, temperature=0.1, max_tokens=max_tokens, response_format={"type": "json_object"},
        extra_body={"chat_template_kwargs": {"enable_thinking": False}},
        messages=[{"role": "system", "content": system}, {"role": "user", "content": user}],
    )
    text = re.sub(r"<think>.*?</think>", "", r.choices[0].message.content or "", flags=re.S)
    m = re.search(r"\{.*\}", text, re.S)
    if not m:
        raise ValueError(f"Model returned no JSON: {text[:200]}")
    return json.loads(m.group(0))


async def tavily(endpoint, **body):
    r = await http.post(f"{TAVILY}/{endpoint}", json=body,
                        headers={"Authorization": f"Bearer {os.environ.get('TAVILY_API_KEY', '')}"})
    r.raise_for_status()
    return r.json()


def domain(url):
    return urlparse(url).netloc.removeprefix("www.")


def trust(url):
    d = domain(url)
    return any(d.endswith(t) or d == t.lstrip(".") for t in TRUSTED)


def norm(s):
    s = s.lower().replace("’", "'").replace("‘", "'").replace("“", '"').replace("”", '"')
    s = s.replace("–", "-").replace("—", "-")
    return re.sub(r"\s+", " ", s).strip()


def quote_found(quote, source_text):
    """Every fragment of the quote (split on ellipses) must appear verbatim in the source."""
    parts = [p.strip(" .\"'") for p in re.split(r"\.\.\.|…", norm(quote))]
    parts = [p for p in parts if len(p) > 12]
    return bool(parts) and all(p in source_text for p in parts)


def best_passages(raw, claim, n=5, size=600):
    """Keep the paragraphs that share the most words with the claim, so the judge reads less."""
    words = set(re.findall(r"\w{4,}", claim.lower()))
    paras = [p.strip() for p in re.split(r"\n\s*\n|\n", raw or "") if len(p.strip()) > 60]
    scored = sorted(paras, key=lambda p: -len(words & set(re.findall(r"\w{4,}", p.lower()))))
    return [p[:size] for p in scored[:n]]


CLAIMS_PROMPT = """You split text into checkable factual claims and write web search queries.
Return JSON only:
{"claims":[{"text":"<claim, self-contained, max 25 words>","kind":"number|quote|fact|opinion",
"query_for":"<query that would confirm it>","query_against":"<query that would debunk or correct it>",
"topic":"general|news|finance","recent":true|false}]}
Rules: at most 3 claims, most important first. Kind "opinion" is ONLY for subjective taste or values
("this movie is great"); a statement that is checkable, even obviously false, is a "fact".
query_against must differ from query_for: it hunts for debunks and corrections (use words like myth, false,
actually, debunked, correction). Keep the language of the text in claims,
but write queries in English unless the topic is local. "recent" is true only for events of the last 12 months."""

JUDGE_PROMPT = """You are a rigorous fact-checker. Judge the claim ONLY from the numbered sources given.
Return JSON only:
{"label":"true|mostly_true|misleading|false|unverifiable","confidence":<integer 0-100>,
"summary":"<2 short sentences, plain English, say what is actually true>",
"quotes":[{"source":"S1","text":"<sentence copied EXACTLY, character for character, from that source>"}]}
Rules: 1 to 3 quotes, each copied verbatim (no paraphrase, no added words). If sources disagree or are weak, say so
and lower confidence. If nothing relevant is in the sources, label "unverifiable"."""


async def check(text, image_b64=None, emit=None):
    """Runs the full pipeline, calling emit(event_dict) as each step finishes. Returns the list of events."""
    events, t0 = [], time.perf_counter()
    stats = {"tavily_calls": 0}

    async def send(ev):
        ev["t"] = round((time.perf_counter() - t0) * 1000)
        events.append(ev)
        if emit:
            await emit(ev)

    async def tav(endpoint, claim_id, label, **body):
        s = time.perf_counter()
        stats["tavily_calls"] += 1
        data = await tavily(endpoint, **body)
        await send({"type": "trace", "claim": claim_id, "endpoint": endpoint, "label": label,
                    "query": body.get("query") or ", ".join(domain(u) for u in body.get("urls", [])),
                    "ms": round((time.perf_counter() - s) * 1000),
                    "count": len(data.get("results", []))})
        return data

    models = await resolve_models()

    if image_b64:
        if not models["vision"]:
            raise RuntimeError("No Nemotron Omni vision model available on Token Factory")
        await send({"type": "status", "text": "Reading the image"})
        r = await llm.chat.completions.create(model=models["vision"], temperature=0, max_tokens=800, messages=[
            {"role": "user", "content": [
                {"type": "text", "text": "Transcribe the factual statements visible in this screenshot, verbatim. "
                                         "Ignore UI chrome, usernames and buttons. Output only the text."},
                {"type": "image_url", "image_url": {"url": f"data:image/png;base64,{image_b64}"}}]}])
        text = re.sub(r"<think>.*?</think>", "", r.choices[0].message.content or "", flags=re.S).strip()
        await send({"type": "transcript", "text": text, "model": models["vision"]})

    await send({"type": "status", "text": "Finding the claims"})
    parsed = await ask_json(models["fast"], CLAIMS_PROMPT, text[:2000])
    claims = [c for c in parsed.get("claims", []) if c.get("text")][:3]
    for i, c in enumerate(claims):
        c["id"] = i
    await send({"type": "claims", "model": models["fast"],
                "claims": [{"id": c["id"], "text": c["text"], "kind": c.get("kind", "fact")} for c in claims]})

    async def one(c):
        try:
            await judge_claim(c)
        except Exception as e:  # one failing claim must not sink the others
            await send({"type": "verdict", "claim": c["id"], "label": "unverifiable", "confidence": 0, "quotes": [],
                        "rejected": 0, "summary": f"Couldn't check this one: {str(e)[:120]}"})

    async def judge_claim(c):
        cid = c["id"]
        if c.get("kind") == "opinion":
            await send({"type": "verdict", "claim": cid, "label": "unverifiable", "confidence": 0,
                        "summary": "This is an opinion, not a checkable fact.", "quotes": [], "rejected": 0})
            return
        common = {"search_depth": "advanced", "max_results": 5, "topic": c.get("topic", "general"),
                  "chunks_per_source": 3}
        if c.get("recent"):
            common["time_range"] = "year"
        pro, con = await asyncio.gather(
            tav("search", cid, "confirm", query=c.get("query_for") or c["text"], **common),
            tav("search", cid, "challenge", query=c.get("query_against") or c["text"], **common))

        seen, sources = set(), []
        for side, res in (("confirm", pro), ("challenge", con)):
            for r in res.get("results", []):
                if r["url"] not in seen:
                    seen.add(r["url"])
                    sources.append({**r, "side": side})
        # Video and social pages have no readable text for /extract
        sources = [s for s in sources if not domain(s["url"]).endswith(NO_TEXT)]
        sources.sort(key=lambda r: (not trust(r["url"]), -r.get("score", 0)))
        # Read the top 3, but always include the best source from the challenging side
        top = sources[:3]
        best_con = next((s for s in sources if s["side"] == "challenge"), None)
        if best_con and best_con not in top:
            top = top[:2] + [best_con]
        await send({"type": "sources", "claim": cid, "sources": [
            {"url": s["url"], "domain": domain(s["url"]), "title": s.get("title", ""), "side": s["side"],
             "trusted": trust(s["url"]), "date": s.get("published_date"),
             "snippet": re.sub(r"\s+", " ", s.get("content", ""))[:400]} for s in sources[:8]]})

        raw = {}
        if top:
            ext = await tav("extract", cid, "read", urls=[s["url"] for s in top], extract_depth="basic")
            raw = {r["url"]: r.get("raw_content", "") for r in ext.get("results", [])}

        blocks, texts = [], {}
        for i, s in enumerate(top + [x for x in sources if x not in top][:3]):
            sid = f"S{i + 1}"
            passages = best_passages(raw.get(s["url"], ""), c["text"])
            body = "\n".join([s.get("content", "")] + passages)
            texts[sid] = (s, norm(s.get("content", "") + " " + raw.get(s["url"], "")))
            blocks.append(f"[{sid}] {domain(s['url'])} {s.get('published_date') or ''}\n{body}")

        await send({"type": "status", "claim": cid, "text": "Weighing the evidence"})
        v = await ask_json(models["judge"], JUDGE_PROMPT,
                           f"CLAIM: {c['text']}\n\nSOURCES:\n" + "\n\n".join(blocks), max_tokens=2000)

        quotes, rejected = [], 0
        for q in v.get("quotes", []):
            s, src_text = texts.get(q.get("source"), (None, ""))
            if s and quote_found(q.get("text", ""), src_text):
                quotes.append({"text": q["text"].strip(), "url": s["url"], "domain": domain(s["url"]),
                               "date": s.get("published_date")})
            else:
                rejected += 1
        conf = int(v.get("confidence", 50))
        label = v.get("label", "unverifiable")
        if not quotes and label != "unverifiable":
            conf = min(conf, 40)  # a verdict with no verified evidence can't be confident
        await send({"type": "verdict", "claim": cid, "label": label, "confidence": conf,
                    "summary": v.get("summary", ""), "quotes": quotes, "rejected": rejected,
                    "model": models["judge"]})

    async def origin(c):
        if c.get("kind") not in ("number", "quote"):
            return
        try:
            await find_origin(c)
        except Exception:
            pass  # origin is a bonus, never an error

    async def find_origin(c):
        res = await tav("search", c["id"], "origin", query=f"\"{c['text'][:120]}\"", topic="news",
                        max_results=10, search_depth="basic")
        dated = sorted((r for r in res.get("results", []) if r.get("published_date")),
                       key=lambda r: r["published_date"])
        if dated:
            r = dated[0]
            await send({"type": "origin", "claim": c["id"], "url": r["url"], "domain": domain(r["url"]),
                        "title": r.get("title", ""), "date": r["published_date"]})

    await asyncio.gather(*(one(c) for c in claims), *(origin(c) for c in claims))
    await send({"type": "done", "tavily_calls": stats["tavily_calls"], "ms": round((time.perf_counter() - t0) * 1000)})
    return events


RESEARCH_BRIEF = """Write a concise, well-sourced briefing for someone who just highlighted this while reading:
"{text}"
Under 350 words. Use 3 or 4 sections, each starting with a '## ' heading. Lead with what matters most,
include concrete numbers and dates, and cite sources inline."""

TLDR_PROMPT = """Summarize the research report for a busy reader. Return JSON only:
{"tldr":"<one or two plain sentences, the answer itself>",
"follow_ups":["<short follow-up question>","<short follow-up question>"]}"""


async def research(text, emit=None):
    """Deep dive on a highlighted topic: Tavily /research streams plan, searches and a cited report,
    then Nemotron writes the TL;DR and follow-up questions."""
    events, t0 = [], time.perf_counter()

    async def send(ev):
        ev["t"] = round((time.perf_counter() - t0) * 1000)
        events.append(ev)
        if emit:
            await emit(ev)

    models = await resolve_models()
    await send({"type": "status", "text": "Planning the research"})
    report, sources, seen = "", [], {}
    body = {"input": RESEARCH_BRIEF.format(text=text[:1500]), "model": "mini", "stream": True}
    async with http.stream("POST", f"{TAVILY}/research", json=body, timeout=180,
                           headers={"Authorization": f"Bearer {os.environ.get('TAVILY_API_KEY', '')}"}) as r:
        r.raise_for_status()
        async for line in r.aiter_lines():
            if not line.startswith("data: "):
                continue
            delta = json.loads(line[6:])["choices"][0]["delta"]
            calls = delta.get("tool_calls") or {}
            for resp in calls.get("tool_response", []):
                for src in resp.get("sources", []):
                    seen.setdefault(src["url"], src)
            for call in calls.get("tool_call", []):
                await send({"type": "trace", "endpoint": "research", "label": call.get("name", "").lower(),
                            "query": "; ".join(call.get("queries", [])) or call.get("arguments", ""),
                            "ms": 0, "count": len(call.get("queries", []))})
                await send({"type": "status", "text": call.get("arguments", "")})
            if isinstance(delta.get("content"), str):
                report += delta["content"]
                await send({"type": "report", "delta": delta["content"]})
            if delta.get("sources"):
                sources = [{"url": s["url"], "title": s.get("title", ""), "domain": domain(s["url"])}
                           for s in delta["sources"]]
                await send({"type": "research_sources", "sources": sources})

    if not sources and seen:  # some streams skip the final source list: fall back to what the searches found
        sources = [{"url": u, "title": x.get("title", ""), "domain": domain(u)} for u, x in list(seen.items())[:20]]
        await send({"type": "research_sources", "sources": sources})
    if report:
        try:
            s = await ask_json(models["fast"], TLDR_PROMPT, report[:8000], max_tokens=400)
            await send({"type": "tldr", "text": s.get("tldr", ""), "follow_ups": s.get("follow_ups", [])[:3],
                        "model": models["fast"]})
        except Exception:
            pass  # the report stands on its own
    await send({"type": "done", "tavily_calls": 1, "ms": round((time.perf_counter() - t0) * 1000)})
    return events


if __name__ == "__main__":
    async def show(ev):
        print(json.dumps(ev, ensure_ascii=False))
    asyncio.run(check(" ".join(sys.argv[1:]) or "Humans only use 10% of their brain.", emit=show))
