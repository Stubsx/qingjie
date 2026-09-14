#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
swift test -c release
./scripts/build.sh
python3 scripts/verify_identity.py
dist/轻截.app/Contents/MacOS/QingJie --smoke-test
