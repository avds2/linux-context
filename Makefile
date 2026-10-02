SHELL := /usr/bin/env bash

.PHONY: check test syntax python-check shell-check version

check: syntax test

test:
	TERM=xterm ./tests/run.sh

syntax: shell-check python-check

shell-check:
	@find bin collectors lib tests -type f -name '*.sh' -print0 | xargs -0 -n1 bash -n
	@bash -n bin/linux-context

python-check:
	@python3 -B -S -c 'from pathlib import Path; [compile(p.read_bytes(), str(p), "exec") for p in Path("lib").glob("*.py")]'

version:
	@./bin/linux-context --version
