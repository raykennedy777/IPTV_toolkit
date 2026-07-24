.PHONY: test lint

# Run the bats suite (macOS bash 3.2 + Linux bash 4+ if available).
test:
	./tests/run.sh

# Optional shellcheck lint of the two bash scripts (no-op if shellcheck absent).
lint:
	@if command -v shellcheck >/dev/null 2>&1; then \
		shellcheck iptv_toolkit.sh iptv_toolkit_mac.sh; \
	else \
		echo "shellcheck not installed — skipping lint."; \
	fi
