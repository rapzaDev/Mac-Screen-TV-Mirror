#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
mkdir -p artifacts
swift test > artifacts/tests.log 2>&1
cat artifacts/tests.log
node --check receiver/web/receiver.js
node --check receiver/tizen/receiver.js
python3 -c 'import xml.etree.ElementTree as E; E.parse("receiver/tizen/config.xml")'

node scripts/test-receiver.cjs
