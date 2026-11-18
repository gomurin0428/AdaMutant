GPRBUILD ?= gprbuild
PYTHON ?= python3
# Libadalang and its dependencies come from Alire: gprbuild runs in the
# environment of the Alire workspace.  With the projects already on
# GPR_PROJECT_PATH, run "make ALR_EXEC=".
ALR_EXEC ?= alr exec --

.PHONY: all build test unit e2e clean

all: build

build:
	$(ALR_EXEC) $(GPRBUILD) -p -q -P adamutant.gpr

unit:
	$(ALR_EXEC) $(GPRBUILD) -p -q -P tests/unit/unit_tests.gpr
	tests/unit/bin/unit_tests

e2e: build
	$(PYTHON) tests/e2e/run_e2e.py

test: unit e2e

clean:
	rm -rf bin lib obj tests/unit/bin tests/unit/obj
	rm -rf examples/*/obj examples/*/bin examples/*/.adamutant
