#!/bin/bash
# build.sh — builds "build/Vela Ishtar.app" with bare swiftc (no Xcode).
# Why: this machine (and the CI-free lean-team workflow) has Command Line
# Tools only; the reference pattern (claude-status-bar) proves a full
# LSUIElement menu bar app needs nothing more than swiftc + Info.plist +
# ad-hoc codesign. Sources/App and Sources/VelaCore compile as ONE module
# (no `import VelaCore` in App files — see commit d000f77).
# RELEVANT FILES: Info.plist, Sources/App/main.swift, Makefile
set -euo pipefail
cd "$(dirname "$0")"

APP="build/Vela Ishtar.app"
BIN="$APP/Contents/MacOS/VelaIshtar"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"

echo "Compiling Vela Ishtar (arm64, macOS 14+)…"
# Apple-Silicon-only internal build; add an x86_64 slice + lipo later only
# if a teammate is on Intel. -parse-as-library keeps top-level statements
# allowed only in main.swift (the app entry), which is the only file with
# top-level code.
swiftc -O -target arm64-apple-macos14.0 \
  Sources/VelaCore/*.swift Sources/App/*.swift \
  -o "$BIN" \
  -framework Cocoa -framework ServiceManagement -framework Security -framework QuartzCore

cp Info.plist "$APP/Contents/Info.plist"

# Strip quarantine (dev machines may have copied this repo) and ad-hoc sign
# so the Keychain item and login item behave consistently between rebuilds.
xattr -cr "$APP"
codesign --force --sign - "$APP"

echo "Built $APP"
echo "Run with: open \"$APP\""
