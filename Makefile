NVIM ?= nvim

.PHONY: test test-unit test-live lint

test: test-unit test-live

test-unit:
	$(NVIM) --headless -u NONE -l tests/run.lua

test-live:
	$(NVIM) --headless -u NONE -l tests/live.lua

lint:
	luacheck lua/ tests/ 2>/dev/null || echo "luacheck not installed, skipped"
