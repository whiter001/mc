# Kimi-V Makefile — thin wrapper over build.sh
#
# All real work lives in ./build.sh. This file just translates `make` goals
# into build.sh invocations, so we don't maintain two parallel build systems.
# Prefer running build.sh directly; this Makefile exists for IDE/tooling
# that auto-discovers Makefiles.

.PHONY: all dev debug prod cross test fmt vet clean install uninstall help

all: dev

dev:
	@./build.sh dev

debug:
	@./build.sh debug

prod:
	@./build.sh prod

cross:
	@./build.sh cross

test:
	@./build.sh test

fmt:
	@./build.sh fmt

vet:
	@./build.sh vet

clean:
	@./build.sh clean

install:
	@./build.sh install

uninstall:
	@./build.sh uninstall

help:
	@./build.sh help