#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
[[ -d dist/MacMirror.app ]] || ./scripts/build.sh
open dist/MacMirror.app
