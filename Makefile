GPRBUILD ?= gprbuild
PYTHON ?= python3

.PHONY: all build test unit e2e clean

all: build

build:
	$(GPRBUILD) -p -q -P adamutant.gpr

unit:
	$(GPRBUILD) -p -q -P tests/unit/unit_tests.gpr
	tests/unit/bin/unit_tests

e2e: build
	$(PYTHON) tests/e2e/run_e2e.py

test: unit e2e

clean:
	rm -rf bin lib obj tests/unit/bin tests/unit/obj
	rm -rf examples/*/obj examples/*/bin examples/*/.adamutant
