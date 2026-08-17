V ?= v

.PHONY: build test fmt clean

build:
	mkdir -p bin
	$(V) -o bin/vfrps ./cmd/vfrps
	$(V) -o bin/vfrpc ./cmd/vfrpc

test:
	$(V) -stats test .

fmt:
	$(V) fmt -w .

clean:
	rm -rf bin
