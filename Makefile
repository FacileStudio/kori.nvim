NVIM ?= nvim
TESTS := $(wildcard tests/*.lua)

.PHONY: test test-unit test-pane test-live lint

test:
	@fail=0; for f in $(TESTS); do \
		echo "== $$f"; \
		$(NVIM) --headless -u NONE -l "$$f" || fail=1; \
	done; \
	exit $$fail

test-unit:
	$(NVIM) --headless -u NONE -l tests/run.lua

test-pane:
	$(NVIM) --headless -u NONE -l tests/pane.lua

test-live:
	$(NVIM) --headless -u NONE -l tests/live.lua

lint:
	luacheck lua/ tests/ 2>/dev/null || echo "luacheck not installed, skipped"
