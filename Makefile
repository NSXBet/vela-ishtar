# Builds, tests, and releases Vela Ishtar (Xcode-less CLT toolchain).
# Why: `swift test` needs explicit -F/-rpath flags to find Testing.framework
# on machines without Xcode; `make release` packages the .app for the
# Homebrew tap. RELEVANT FILES: build.sh, Package.swift, Casks/vela-ishtar.rb

FW := /Library/Developer/CommandLineTools/Library/Developer/Frameworks
LIB := /Library/Developer/CommandLineTools/Library/Developer/usr/lib
VERSION := $(shell /usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" Info.plist)

.PHONY: test build run release

test:
	swift test -Xswiftc -F -Xswiftc "$(FW)" \
		-Xlinker -rpath -Xlinker "$(FW)" \
		-Xlinker -rpath -Xlinker "$(LIB)"

build:
	./build.sh

run: build
	open "build/Vela Ishtar.app"

# Packages the built .app as a versioned zip for the Homebrew cask.
# The zip goes to GitHub Releases; the cask in NSXBet/homebrew-tap points at it.
release: build
	@echo "Packaging Vela Ishtar $(VERSION)…"
	cd build && zip -qry "VelaIshtar-$(VERSION).zip" "Vela Ishtar.app"
	@shasum -a 256 "build/VelaIshtar-$(VERSION).zip" | awk '{print "SHA256: " $$1}'
	@echo "Upload with: gh release create v$(VERSION) build/VelaIshtar-$(VERSION).zip --repo NSXBet/vela-ishtar --title \"Vela Ishtar $(VERSION)\""
