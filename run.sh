#!/bin/bash
# One command: builds Margin.app, opens it, and runs the local backend on :8787.
set -e
cd "$(dirname "$0")"

if [ ! -f .env ]; then
  cp .env.example .env
  echo "Created .env: add your NEBIUS_API_KEY and TAVILY_API_KEY, then run ./run.sh again."
  exit 1
fi
command -v uv >/dev/null || { echo "Missing uv: brew install uv"; exit 1; }
command -v swift >/dev/null || { echo "Missing Swift: xcode-select --install"; exit 1; }

echo "Building Margin.app…"
(cd macos && swift build -c release -q)
APP=build/Margin.app
rm -rf "$APP" && mkdir -p "$APP/Contents/MacOS"
cp macos/.build/release/Margin "$APP/Contents/MacOS/"
cp macos/Info.plist "$APP/Contents/"
codesign --force --sign - "$APP" 2>/dev/null

pkill -x Margin 2>/dev/null || true
open "$APP"
echo "Margin is in your menu bar. Select text anywhere and press ⌥Space."
echo "Web playground: http://127.0.0.1:8787"
cd backend && exec uv run --env-file ../.env uvicorn margin.server:app --port 8787 --log-level warning
