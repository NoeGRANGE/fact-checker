#!/bin/bash
# One command: builds Margin.app, opens it, and runs the local backend on :8787.
set -e
cd "$(dirname "$0")"

if [ ! -f .env ]; then
  cp .env.example .env
  echo "Created .env: add your NEBIUS_API_KEY and TAVILY_API_KEY, then run ./run.sh again."
  exit 1
fi

APP=build/Margin.app
if command -v swift >/dev/null; then
  echo "Building Margin.app…"
  (cd macos && swift build -c release -q)
  rm -rf "$APP" && mkdir -p "$APP/Contents/MacOS"
  cp macos/.build/release/Margin "$APP/Contents/MacOS/"
  cp macos/Info.plist "$APP/Contents/"
  codesign --force --sign - "$APP" 2>/dev/null
elif [ ! -d "$APP" ]; then
  echo "No Swift toolchain: install it with 'xcode-select --install', or put the prebuilt Margin.app from the GitHub release in ./build/"
  exit 1
fi

pkill -x Margin 2>/dev/null || true
open "$APP"
echo "Margin is in your menu bar. Select text anywhere and press ⌥Space."
echo "Web playground: http://127.0.0.1:8787"

cd backend
if command -v uv >/dev/null; then
  exec uv run --env-file ../.env uvicorn margin.server:app --port 8787 --log-level warning
fi
# No uv: plain venv + pip
[ -d .venv ] || python3 -m venv .venv
.venv/bin/pip install -q .
set -a; . ../.env; set +a
exec .venv/bin/uvicorn margin.server:app --port 8787 --log-level warning
