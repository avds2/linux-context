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
	@PYTHONDONTWRITEBYTECODE=1 python3 -B -S -m py_compile lib/*.py
	@find . -type d -name __pycache__ -prune -exec rm -rf {} +
	@find . -type f \( -name '*.pyc' -o -name '*.pyo' \) -delete

version:
	@./bin/linux-context --version
