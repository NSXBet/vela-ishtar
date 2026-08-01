# Builds and tests for Vela Ishtar (Xcode-less CLT toolchain).
# Why: `swift test` needs explicit -F/-rpath flags to find Testing.framework
# on machines without Xcode; this wraps them so `make test` always works.
# RELEVANT FILES: build.sh, Package.swift

FW := /Library/Developer/CommandLineTools/Library/Developer/Frameworks
LIB := /Library/Developer/CommandLineTools/Library/Developer/usr/lib

.PHONY: test build run
test:
	swift test -Xswiftc -F -Xswiftc "$(FW)" \
		-Xlinker -rpath -Xlinker "$(FW)" \
		-Xlinker -rpath -Xlinker "$(LIB)"

build:
	./build.sh

run: build
	open "build/Vela Ishtar.app"
