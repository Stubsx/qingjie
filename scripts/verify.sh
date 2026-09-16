#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
swift test -c release
python3 -m unittest discover -s scripts -p 'test_*.py'
./scripts/build.sh
python3 scripts/verify_identity.py
dist/轻截.app/Contents/MacOS/QingJie --smoke-test
