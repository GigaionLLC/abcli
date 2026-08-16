# abctl — build / test / lint
BINARY  := abctl
VERSION ?= $(shell git describe --tags --always --dirty 2>/dev/null || echo dev)
LDFLAGS := -X github.com/GigaionLLC/abcli/internal/cli.version=$(VERSION)

.PHONY: build test vet lint fmt tidy clean \
        gui-check gui-test gui-macos gui-windows gui-windows-installer gui-windows-msix \
        gui-linux gui-clean

build:            ## build the binary into bin/
	go build -ldflags "$(LDFLAGS)" -o bin/$(BINARY) ./cmd/abctl

test:             ## run the test suite with the race detector
	go test -race ./...

vet:
	go vet ./...

lint:             ## requires golangci-lint
	golangci-lint run

fmt:
	gofmt -w .

tidy:
	go mod tidy

clean:
	rm -rf bin

# --- abgui (the cross-platform Flutter GUI) — logic in scripts/build-gui-flutter.sh ---
# check/test run anywhere (including `./tool/flutter.sh` in Docker); each platform target
# must run ON that platform — Flutter does not cross-compile desktop.
gui-check:        ## dart format check + flutter analyze
	./scripts/build-gui-flutter.sh check
gui-test:         ## flutter test (offline, no credentials)
	./scripts/build-gui-flutter.sh test
gui-macos:        ## build + embed abctl + sign/notarize → .dmg + .zip   (macOS host only)
	./scripts/build-gui-flutter.sh macos
gui-windows:      ## build + embed abctl → .zip                          (Windows host only)
	./scripts/build-gui-flutter.sh windows
# The next two REPACKAGE what gui-windows built; they never rebuild, because the release signs
# the binaries in place between them. Run gui-windows first or they refuse.
gui-windows-installer: ## Inno Setup → abgui-setup-x64.exe              (after gui-windows)
	./scripts/build-gui-flutter.sh windows-installer
gui-windows-msix: ## Microsoft Store package → .msix                    (after gui-windows)
	./scripts/build-gui-flutter.sh windows-msix
gui-linux:        ## build + embed abctl → .AppImage + .tar.gz           (Linux host only)
	./scripts/build-gui-flutter.sh linux
gui-clean:        ## remove Flutter build products + packaged artifacts
	./scripts/build-gui-flutter.sh clean
