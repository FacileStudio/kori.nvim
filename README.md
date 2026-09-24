# kori.nvim

Neovim integration for [kori](https://github.com/FacileStudio/kori), the terminal coding agent.

Run kori in a pane beside your code, and see what it changed in the buffer you are already editing. Files reload when kori writes them, edits are marked in place, and you step through them with `]r` / `[r` without leaving the editor.

The cursor is never moved for you by default. kori tells you it changed something and marks where; jumping there is your keypress, or an opt-in mode.

## Requirements

- Neovim 0.10 or newer
- kori 0.76 or newer on `$PATH`

## Install

With [lazy.nvim](https://github.com/folke/lazy.nvim):

```lua
{
  "FacileStudio/kori.nvim",
  opts = {},
}
```

Or clone it and put the directory on your `runtimepath`. The hook shim has to be on `$PATH`:

```sh
ln -s "$PWD/bin/kori-nvim" ~/.local/bin/kori-nvim
```

## The kori hook

No kori release offers a socket yet, so the plugin learns about edits the way kori already lets anything learn about them: hooks. Add both of these to `~/.kori.yml`, or to a project's `.kori.yml`:

```yaml
hooks:
  - name: kori.nvim
    on: after_tool_call
    match: [edit_file, write_file, run_command]
    run: kori-nvim emit
    timeout: 2s
    async: true
  - name: kori.nvim
    on: before_tool_call
    match: [edit_file, write_file, run_command]
    run: kori-nvim before
    timeout: 2s
    async: false
```

`run_command` is in the list because a shell command can edit a file in place, and the plugin ports kori's own parser for those commands. Leave it out and only `edit_file` and `write_file` are reported.

The first hook reports an edit after it landed. The second is what lets the plugin say which lines changed in a file you never opened in Neovim: `write_file` and `run_command` report no old text, so without a copy of the file taken beforehand there is nothing to compare against. `kori-nvim before` hands the plugin the paths the tool is about to touch and waits for it to read them, so the tool cannot overwrite the file first. That is why it is `async: false`: an async hook would let the tool run before the copy was taken, which is the whole thing it is there to prevent. The wait is bounded, and skipped entirely when no Neovim is watching, so it costs a few milliseconds per editing call and nothing at all when you run kori without Neovim open.

`on:` takes one event per entry, so this is two entries rather than one. Both blocks are verified against kori's own config loader. kori asks before running a hook it has not seen in a project before; that prompt is per repo.

The shim writes one JSON line per edit into `$XDG_RUNTIME_DIR/kori-nvim/`, which the plugin tails. That directory is `0700` and the files are `0600`, because the payload carries the text of the file kori edited. The plugin deletes it on startup, so it does not outlive the session. While it is watching, the plugin also leaves a `plugin` file there holding its pid; that is how the `before` shim knows whether anyone is there to answer.

Check it with `:checkhealth kori` if nothing happens. It reports a missing `before_tool_call` hook, since edits still land without one, just without line numbers for files you had not opened.

## What you get

| Mapping | Command | What it does |
|---|---|---|
| `]r` | | next edit kori made in this buffer |
| `[r` | | previous edit |
| `<leader>ko` | `:KoriToggle` | toggle the chat pane: a right-hand split running kori |
| `<leader>kc` | `:KoriChanges` | every file and hunk kori changed, `⏎` opens at the first hunk |
| `<leader>kp` | `:KoriPeek` | float showing the last edit with context, without taking focus |
| `<leader>kr` | `:KoriRevert` | revert the kori edit under the cursor |
| | `:KoriRevertAll` | revert every kori edit in this file |
| | `:KoriStart [cmd]` | open the pane, optionally running something other than kori |
| | `:KoriClear` | forget every recorded edit |
| | `:KoriStatus` | report the pane, the session and the root |
| | `:KoriHealth` | health check |
| `<leader>ks` | `:KoriSend [text]` | send the selection and context to the session |
| | `:KoriAsk [text]` | send the whole buffer and context to the session |

`:KoriSend` and `:KoriAsk` need an attached kori session over the IDE socket, which no kori release ships yet. They warn instead of silently doing nothing. Reverting does not: it works on the payload kori's hook already delivers.

The pane opens to the right in its own buffer, so it never takes over the file you are editing, and it works from the dashboard. A followed edit opens beside it rather than over it, so the chat stays on screen while kori works. Toggling it off hides the window but leaves kori running, so toggling back returns to the same session. After kori exits, `:KoriStart` starts a fresh one.

Statusline:

```lua
require("kori").statusline()  -- "kori ◑ 3", or "" when kori changed nothing
```

`◑` means an edit landed in the last two seconds, `●` means the session has edits. Attach it to lualine's `lualine_x` or heirline.

## Configuration

```lua
require("kori").setup({
  enabled = true,
  root = nil,          -- project root; defaults to the cwd
  spool_dir = nil,     -- where the shim writes; defaults to $XDG_RUNTIME_DIR/kori-nvim
  follow = "off",      -- "off" | "peek" | "open"
  keymaps = true,      -- never overrides a mapping you already have
  notify = true,
  reload = { enabled = true, debounce_ms = 120 },
  marks = { enabled = true, signs = true, virtual_text = true },
  ui = { panel_height = 10, term_width = 80 },
})
```

`follow` decides what happens when an edit lands:

- `"off"` (default): a notification and marks. Nothing moves.
- `"peek"`: a float opens beside your cursor with the changed lines, does not take focus, closes after four seconds.
- `"open"`: the cursor lands on the first changed line. A file already on screen is reached by moving the cursor there. Anything else opens in a window left of the chat pane when one is open, so the chat stays on screen, and in its own tab when the pane is closed.

Follow never takes the cursor out of a window you are typing in, and chatting with kori counts: while the cursor is in the pane your keystrokes are going there. The file still opens beside the pane, you just keep the cursor. With no pane to put it beside there is nowhere to show the file without interrupting you, so the follow is skipped until you are back in normal mode. A file kori edited that has unsaved changes in a buffer is never followed either.

Set `vim.g.kori_nvim_no_defaults = true` before the plugin loads to skip the automatic `setup()` and configure it yourself.

## How it works

```
kori runs edit_file
  └─ hook: after_tool_call ──▶ kori-nvim emit ──▶ $XDG_RUNTIME_DIR/kori-nvim/<key>.ndjson
                                                          │
                                     fs_event on the directory
                                                          ▼
                                              diff buffer vs disk
                                                          │
                                    reload, then marks at the changed lines
```

The changed lines are not read out of the hook payload. They come from diffing the buffer against the file on disk, which is exact and works for any tool. The payload only says *which file* kori touched.

Two consequences worth knowing:

- A buffer with unsaved changes is never clobbered, and gets no marks while it disagrees with disk, because line numbers would be wrong. You get a warning naming the file instead; the marks come back when you reload it.
- A file that is not open in a buffer is recorded in `:KoriChanges` and gets its marks when you open it. A file kori edits twice while closed is diffed from the first edit's content.

What counts as the "before" side of that diff, in order: the buffer, when it is open and agrees with disk; otherwise the copy taken by the `before_tool_call` hook, when there is one; otherwise the old text `edit_file` reports, spliced back into the file's current content. So a file you never opened is diffed against the copy taken just before the tool call, and a file kori creates is diffed against nothing, which reports every line as added. Without the `before` hook the last case still works and the others fall back to the old text, which `write_file` and `run_command` do not carry — that is why the hook is worth adding.

`run_command` edits are covered too, as far as they can be: a shell command does not name the file it wrote, so the plugin parses the in-place edit commands kori itself understands (`sed -i`, `awk -i`, `perl -i`) and takes the path from there. Anything with real shell syntax — a pipe, a redirect, a glob, a variable, a `&&` chain — is refused rather than guessed at, so a command like `sed -i ... f.go 2>/dev/null` is reported as nothing rather than as the wrong file. In practice kori often chains a command to its own follow-up, such as `sed -i ... f.go && cat f.go`, and that is refused too: the marker is real but the command shape no longer proves which file changed.

## Roadmap

The design, the survey of how other editors' agent plugins solved the same problems, and the open questions are recorded in the plan:

https://mycelium.facile.studio/artifacts/2026-09-24-kori-nvim-a-neovim-extension-for-kori-plan-d88b22

Next: the IDE socket in kori (`~/.kori/ide/<pid>.json` plus a unix socket, spoken by `docs/ide-protocol.md` in the kori repo) so the plugin can also send a prompt built from your selection, relay approvals, and drop the hook shim entirely. The client for it already exists in `lua/kori/ide/` and is tested against a fake session, but no kori release serves the socket yet, so the hook remains the working path. That integration is the next real milestone: two halves that agree on paper and have never met.

## Tests

```sh
make test
```

Runs every file in `tests/`, 354 checks in total:

- `run.lua` — the diff-to-line-ranges logic, the reload and stale-buffer guards, the before-hook handshake, and the shim end to end
- `follow.lua` — every `follow = "open"` outcome: beside the pane, in its own tab, and the refusals
- `cmdedit.lua` — the port of kori's in-place command parser, including what it refuses
- `revert.lua` — `:KoriRevert` and its safety floor
- `notify.lua` — the per-file notification coalescing
- `ide.lua` — the socket client against a fake session on a `vim.uv` pipe
- `pane.lua` — the chat pane never takes over the buffer you are editing
- `live.lua` — the watcher fires when the shim writes while the plugin is running

## License

Apache-2.0, same as kori.
