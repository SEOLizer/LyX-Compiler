# Root Makefile — delegates to compiler/Makefile
# Build output: ./lyxc (at repo root)

.PHONY: build debug test clean e2e

build:
	$(MAKE) -C compiler build

debug:
	$(MAKE) -C compiler debug

test:
	$(MAKE) -C compiler test

e2e:
	$(MAKE) -C compiler e2e

clean:
	$(MAKE) -C compiler clean
