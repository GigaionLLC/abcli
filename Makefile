# abctl — build / test / lint
BINARY  := abctl
VERSION ?= $(shell git describe --tags --always --dirty 2>/dev/null || echo dev)
LDFLAGS := -X github.com/GigaionLLC/abcli/internal/cli.version=$(VERSION)

.PHONY: build test vet lint fmt tidy clean

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
