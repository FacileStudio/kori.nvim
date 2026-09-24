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

kori has no socket yet, so the plugin learns about edits the way kori already lets anything learn about them: a hook. Add this to `~/.kori.yml`, or to a project's `.kori.yml`:

```yaml
hooks:
  - name: kori.nvim
    on: after_tool_call
    match: [edit_file, write_file]
    run: kori-nvim emit
    timeout: 2s
    async: true
```

The block is verified against kori's own config loader. `async: true` keeps it off the tool-call path. kori asks before running a hook it has not seen in a project before; that prompt is per repo.

The shim writes one JSON line per edit into `$XDG_RUNTIME_DIR/kori-nvim/`, which the plugin tails. That directory is `0700` and the files are `0600`, because the payload carries the text of the file kori edited. The plugin deletes it on startup, so it does not outlive the session.

Check it with `:checkhealth kori` if nothing happens.

## What you get

| Mapping | Command | What it does |
|---|---|---|
| `]r` | | next edit kori made in this buffer |
| `[r` | | previous edit |
| `<leader>ko` | `:KoriStart [cmd]` | open the chat pane, a right-hand split running kori |
| `<leader>kc` | `:KoriChanges` | every file and hunk kori changed, `⏎` opens at the first hunk |
| `<leader>kp` | `:KoriPeek` | float showing the last edit with context, without taking focus |
| | `:KoriClear` | forget every recorded edit |
| | `:KoriHealth` | health check |

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
- `"open"`: the file opens and the cursor lands on the first changed line. Skipped when you are not in normal mode or the current buffer has unsaved changes, so it can never interrupt typing or prompt you to abandon a file.

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

`run_command` edits are not covered yet: `match` above limits the hook to `edit_file` and `write_file` because a shell command does not name the file it wrote. kori's own diff package parses in-place edit commands (`sed -i` and friends) and the plugin will use that when the socket lands.

## Roadmap

The design, the survey of how other editors' agent plugins solved the same problems, and the open questions are recorded in the plan:

https://mycelium.facile.studio/artifacts/2026-09-24-kori-nvim-a-neovim-extension-for-kori-plan-d88b22

Next: a real socket in kori (`~/.kori/ide/<pid>.json` plus a unix socket) so the plugin can also send a prompt built from your selection, relay approvals, and drop the hook shim entirely.

## Tests

```sh
make test
```

`tests/run.lua` covers the diff-to-line-ranges logic, the reload and stale-buffer guards, and the shim end to end. `tests/live.lua` checks that the watcher fires when the shim writes while the plugin is running.

## License

Apache-2.0, same as kori.
