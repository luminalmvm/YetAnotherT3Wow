#!/usr/bin/env bash
# Runs the synthetic WGC end-to-end test over cell sizes and scale factors. Usage: scripts/dev/run-e2e-matrix.sh [holdMs] [gapMs] [tag]
set -u
cd "$(dirname "$0")/../../companion"
HOLD=${1:-200}; GAP=${2:-120}; TAG=${3:-run}
mkdir -p test-results
for cell in 1 2 4; do
  for scale in 1 1.25 1.5; do
    out="test-results/e2e-${TAG}-c${cell}-s${scale}.json"
    timeout 240 node dist/testing/e2eCapture.js --cell "$cell" --scale "$scale" --hold-ms "$HOLD" --gap-ms "$GAP" --json "$out" > /dev/null 2>&1
    node -e 'const j=require(process.argv[1]);const r=j.result;console.log(`cell=${j.config.cell} scale=${j.config.scale} hold=${j.config.holdMs} msgs=${r.messagesMatched}/${r.messagesExpected} parts=${r.partsDecoded}/${r.partsShown} decodeFail=${JSON.stringify(r.decodeFailures)} lat p50=${r.latencyMs.p50} p95=${r.latencyMs.p95} arrFps=${JSON.stringify(r.helper&&r.helper.arrivedFps)}`)' "$PWD/$out" 2>/dev/null || echo "cell=$cell scale=$scale: no result"
  done
done
