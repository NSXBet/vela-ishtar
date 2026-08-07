# Builds, tests, and releases Vela Ishtar (Xcode-less CLT toolchain).
# Why: `swift test` needs explicit -F/-rpath flags to find Testing.framework
# on machines without Xcode; `make release` packages the .app for the
# Homebrew tap. RELEVANT FILES: build.sh, Package.swift, Casks/vela-ishtar.rb

FW := /Library/Developer/CommandLineTools/Library/Developer/Frameworks
LIB := /Library/Developer/CommandLineTools/Library/Developer/usr/lib
VERSION := $(shell /usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" Info.plist)

.PHONY: test build run release readme-version

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
release: readme-version build
	@echo "Packaging Vela Ishtar $(VERSION)…"
	cd build && zip -qry "VelaIshtar-$(VERSION).zip" "Vela Ishtar.app"
	@shasum -a 256 "build/VelaIshtar-$(VERSION).zip" | awk '{print "SHA256: " $$1}'
	@echo "Upload with: gh release create v$(VERSION) build/VelaIshtar-$(VERSION).zip --repo NSXBet/vela-ishtar --title \"Vela Ishtar $(VERSION)\""

# Syncs the README's versioned bits from their sources of truth so the docs
# can't drift from the binary: Info.plist is the version of record, and the
# test badge counts @Test/func test across the suite. Run as part of
# `make release`; safe to run alone after a version bump.
TESTS := $(shell grep -rhoE '@Test|func test' Tests/ | wc -l | tr -d ' ')
readme-version:
	@sed -i '' -E \
		"s|releases/download/v[0-9]+\.[0-9]+\.[0-9]+/VelaIshtar-[0-9]+\.[0-9]+\.[0-9]+\.zip|releases/download/v$(VERSION)/VelaIshtar-$(VERSION).zip|g; \
		 s|unzip VelaIshtar-[0-9]+\.[0-9]+\.[0-9]+\.zip|unzip VelaIshtar-$(VERSION).zip|g" \
		README.md
	@sed -i '' -E \
		"s|tests-[0-9]+%20passing|tests-$(TESTS)%20passing|g; s|# [0-9]+ unit tests|# $(TESTS) unit tests|g" \
		README.md
	@echo "README synced: version $(VERSION), $(TESTS) tests"
