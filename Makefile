# abctl — build / test / lint
BINARY  := abctl
VERSION ?= $(shell git describe --tags --always --dirty 2>/dev/null || echo dev)
LDFLAGS := -X github.com/GigaionLLC/abcli/internal/cli.version=$(VERSION)

.PHONY: build test vet lint fmt tidy clean gui gui-app gui-run gui-test gui-clean

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

# --- abgui (the macOS Swift GUI) — macOS only; all logic in scripts/build-gui.sh ---
gui:              ## compile the Swift app (debug)
	./scripts/build-gui.sh build
gui-app:          ## assemble the unsigned universal abgui.app (embeds abctl)
	./scripts/build-gui.sh app
gui-run:          ## build + launch abgui locally
	./scripts/build-gui.sh run
gui-test:         ## swift test (offline, no credentials)
	./scripts/build-gui.sh test
gui-clean:        ## remove Swift build products + the .app
	./scripts/build-gui.sh clean
