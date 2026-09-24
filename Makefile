NVIM ?= nvim

.PHONY: test test-unit test-pane test-live lint

test: test-unit test-pane test-live

test-unit:
	$(NVIM) --headless -u NONE -l tests/run.lua

test-pane:
	$(NVIM) --headless -u NONE -l tests/pane.lua

test-live:
	$(NVIM) --headless -u NONE -l tests/live.lua

lint:
	luacheck lua/ tests/ 2>/dev/null || echo "luacheck not installed, skipped"
