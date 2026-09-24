# kori.nvim

Neovim integration for [kori](https://github.com/FacileStudio/kori), the terminal coding agent.

Run kori in a pane beside your code, and see what it changed in the buffer you are already editing: files reload when kori writes them, edits are marked in place, and you step through them without leaving the editor.

Status: design phase. Nothing is implemented yet.

## What it will do

- **Reload.** Watch the files kori writes and `:checktime` shortly after, never clobbering a buffer you have modified.
- **Mark.** Every edit lands as an extmark and a sign where it happened; `]r` / `[r` step through them.
- **Review.** A changes panel listing the files the session touched, and a revert that refuses to run when the hunk is no longer what kori wrote.
- **Ask.** Send the current selection, with `file:line` and git context, to the running kori session.
- **Statusline.** What kori is doing, without looking away.

The cursor is not moved for you by default. kori tells you it changed something and marks where; opening the file and jumping to the change is a keypress, or an opt-in `follow` mode.

## Requirements

- Neovim >= 0.10
- kori on `$PATH`

## Design

The plan, including the prior-art survey that shaped it and the open questions, is recorded here:

https://mycelium.facile.studio/artifacts/2026-09-24-kori-nvim-a-neovim-extension-for-kori-plan-d88b22

In short, two layers:

1. A hook shim (`kori-nvim emit`) writes one NDJSON line per tool call to a unix socket. Needs no kori changes.
2. A kori `ide` surface: `~/.kori/ide/<pid>.json` plus a socket, so the plugin and kori can talk both ways.

## License

Apache-2.0, same as kori.
