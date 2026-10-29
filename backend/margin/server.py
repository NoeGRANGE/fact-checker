import asyncio
import hashlib
import json
from pathlib import Path

from fastapi import FastAPI, HTTPException
from fastapi.responses import FileResponse, StreamingResponse
from pydantic import BaseModel, Field

from .pipeline import check, resolve_models

app = FastAPI(title="Margin")
STATIC = Path(__file__).parent / "static"
# shortcut: in-memory cache, lost on restart; move to redis/sqlite if this gets hosted
cache: dict[str, list] = {}


class CheckIn(BaseModel):
    text: str = Field("", max_length=2000)
    image_b64: str | None = Field(None, max_length=12_000_000)


@app.get("/")
def playground():
    return FileResponse(STATIC / "index.html")


@app.get("/health")
async def health():
    return {"ok": True, "models": await resolve_models()}


@app.post("/check")
async def check_route(body: CheckIn):
    if not body.text.strip() and not body.image_b64:
        raise HTTPException(400, "Send some text or an image to check.")
    key = hashlib.sha256((body.text + (body.image_b64 or "")).encode()).hexdigest()

    async def stream():
        if key in cache:
            for ev in cache[key]:
                await asyncio.sleep(0.08)  # replay at a readable pace
                yield f"data: {json.dumps({**ev, 'cached': True})}\n\n"
            return
        q: asyncio.Queue = asyncio.Queue()

        async def run():
            try:
                cache[key] = await check(body.text, body.image_b64, emit=q.put)
            except Exception as e:  # surface the reason to the panel instead of a dead stream
                await q.put({"type": "error", "message": str(e)[:300]})
            await q.put(None)

        task = asyncio.create_task(run())
        while (ev := await q.get()) is not None:
            yield f"data: {json.dumps(ev)}\n\n"
        await task

    return StreamingResponse(stream(), media_type="text/event-stream")
