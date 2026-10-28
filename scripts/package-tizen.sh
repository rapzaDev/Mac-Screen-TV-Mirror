#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
if ! command -v tizen >/dev/null; then
  print 'Tizen CLI não instalado. Siga docs/TIZEN.md. Este script não instala SDK nem altera a TV.'
  exit 1
fi
if [[ $# -ne 1 ]]; then
  print 'Uso: ./scripts/package-tizen.sh NOME_DO_PERFIL_DE_CERTIFICADO'
  exit 1
fi
mkdir -p dist/tizen
# Keep the fallback receiver identical to the tested web receiver, adding the Samsung platform API.
cp receiver/web/receiver.js receiver/tizen/receiver.js
python3 - <<'PY'
from pathlib import Path
s=Path('receiver/web/index.html').read_text().replace('<script src="receiver.js">','<script src="$WEBAPIS/webapis/webapis.js"></script><script src="receiver.js">')
Path('receiver/tizen/index.html').write_text(s)
PY
tizen build-web -- receiver/tizen
tizen package -t wgt -s "$1" -o dist/tizen -- receiver/tizen/.buildResult
