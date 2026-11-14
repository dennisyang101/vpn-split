SHELLS := vpn-split vpn-split.1m.sh install.command uninstall.command tests/test.sh
.PHONY: check test lint
check: test lint

test:
	/bin/bash tests/test.sh
	python3 tests/test_integration.py

lint:
	@set -e; for f in $(SHELLS); do /bin/bash -n "$$f"; done
	shellcheck -x -P SCRIPTDIR $(SHELLS)
