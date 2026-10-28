#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
mkdir -p artifacts dist
xcrun swift scripts/generate-icon.swift
iconutil --convert icns artifacts/MacMirror.iconset --output macos/Resources/MacMirror.icns
python3 scripts/generate-xcode.py
xcodebuild -project MacMirror.xcodeproj -scheme MacMirror -configuration Release -derivedDataPath build build > artifacts/xcode-build.log 2>&1
rm -rf dist/MacMirror.app
cp -R build/Build/Products/Release/MacMirror.app dist/MacMirror.app
codesign --verify --deep --strict dist/MacMirror.app
# Keep permission dialogs and macOS relaunches pointing to the delivered copy.
ls_register=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
"$ls_register" -u "$PWD/build/Build/Products/Release/MacMirror.app"
"$ls_register" -f "$PWD/dist/MacMirror.app"
print "Aplicativo: $PWD/dist/MacMirror.app"
if [[ ! -x /opt/homebrew/bin/ffmpeg && ! -x /usr/local/bin/ffmpeg && -z ${MACMIRROR_FFMPEG:-} ]]; then
  print 'Dependência FFmpeg ausente. Consulte README.md antes de transmitir.'
fi
