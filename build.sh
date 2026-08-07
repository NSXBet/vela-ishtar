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

# Generate the version bullet's what's-new list from CHANGELOG.md so it can
# never drift from the shipped release (the hand-kept array in PopoverView
# did). One `version<TAB>one-liner` per line, top 3 sections; the one-liner
# is the summary paragraph right after each `## [x.y.z]` header. Parsed by
# Sources/VelaCore/WhatsNew.swift at runtime.
mkdir -p "$APP/Contents/Resources"
awk '
  /^## \[/ {
    if (section < 3) {
      section++
      # Pull the bare version from between the brackets.
      match($0, /\[[^]]+\]/)
      ver = substr($0, RSTART + 1, RLENGTH - 2)
      grab = 1   # next non-empty line is this section one-liner
    } else { grab = 0 }
    next
  }
  grab && NF && $0 !~ /^#/ {
    # First non-empty, non-heading line after the header: the summary
    # sentence. The !~ /^#/ guard stops a section with no summary paragraph
    # from emitting its "### Fixed" subheading as the one-liner.
    gsub(/\r/, "")
    printf "%s\t%s\n", ver, $0
    grab = 0
  }
' CHANGELOG.md > "$APP/Contents/Resources/whatsnew.txt"

# Strip quarantine (dev machines may have copied this repo) and ad-hoc sign
# so the Keychain item and login item behave consistently between rebuilds.
xattr -cr "$APP"
codesign --force --sign - "$APP"

echo "Built $APP"
echo "Run with: open \"$APP\""
