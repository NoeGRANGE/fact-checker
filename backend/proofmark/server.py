import asyncio
import hashlib
import json
from pathlib import Path

from fastapi import FastAPI, HTTPException
from fastapi.responses import FileResponse, StreamingResponse
from pydantic import BaseModel, Field

from .pipeline import check, research, resolve_models

app = FastAPI(title="Proofmark")
STATIC = Path(__file__).parent / "static"
# shortcut: in-memory cache, lost on restart; move to redis/sqlite if this gets hosted
cache: dict[str, list] = {}


class CheckIn(BaseModel):
    text: str = Field("", max_length=2000)
    image_b64: str | None = Field(None, max_length=12_000_000)


class ResearchIn(BaseModel):
    text: str = Field(..., min_length=1, max_length=1500)


@app.get("/")
def playground():
    return FileResponse(STATIC / "index.html")


@app.get("/logo.svg")
def logo():
    return FileResponse(STATIC / "logo.svg")


@app.get("/health")
async def health():
    return {"ok": True, "models": await resolve_models()}


def sse(key, job):
    """Streams a pipeline's events as SSE, and replays them from cache on repeat requests."""
    async def stream():
        if key in cache:
            for ev in cache[key]:
                await asyncio.sleep(0.004 if ev["type"] == "report" else 0.08)  # replay at a readable pace
                yield f"data: {json.dumps({**ev, 'cached': True})}\n\n"
            return
        q: asyncio.Queue = asyncio.Queue()

        async def run():
            try:
                cache[key] = await job(q.put)
            except Exception as e:  # surface the reason to the panel instead of a dead stream
                await q.put({"type": "error", "message": str(e)[:300]})
            await q.put(None)

        task = asyncio.create_task(run())
        while (ev := await q.get()) is not None:
            yield f"data: {json.dumps(ev)}\n\n"
        await task

    return StreamingResponse(stream(), media_type="text/event-stream")


def key_of(*parts):
    return hashlib.sha256("\x00".join(parts).encode()).hexdigest()


@app.post("/check")
async def check_route(body: CheckIn):
    if not body.text.strip() and not body.image_b64:
        raise HTTPException(400, "Send some text or an image to check.")
    return sse(key_of("check", body.text, body.image_b64 or ""),
               lambda emit: check(body.text, body.image_b64, emit=emit))


@app.post("/research")
async def research_route(body: ResearchIn):
    return sse(key_of("research", body.text), lambda emit: research(body.text, emit=emit))
