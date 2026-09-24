# Changelog

All notable changes to kori.nvim. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and versions follow
[Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.1.0] - 2026-09-24

First release.

### Added

- Reload a file kori wrote, keeping the cursor and view, with a guard that
  never clobbers a buffer holding unsaved changes.
- Marks at the changed lines, as extmarks and signs, navigable with `]r` and
  `[r`.
- `:KoriChanges`, a list of every file and hunk kori changed, opening the file
  under the cursor at its first hunk.
- `:KoriPeek`, a float showing the last edit with context, without taking focus.
- `follow = "off" | "peek" | "open"`, deciding what happens when an edit lands.
  `"open"` reaches a file already on screen by moving the cursor, and opens any
  other file in its own tab rather than a split.
- `:KoriToggle` and `:KoriStart`, a right-hand chat pane with its own buffer, so
  it never takes over the file being edited. Toggling hides the window and
  leaves kori running.
- `:KoriRevert` and `:KoriRevertAll`, splicing a kori edit's old text back in,
  with a safety floor that refuses rather than guessing.
- `run_command` coverage: a port of kori's in-place edit command parser
  (`sed -i`, `awk -i`, `perl -i`), refusing anything carrying real shell syntax.
- Per-file edit notifications, coalesced so a burst yields one message.
- `kori.statusline()`, a statusline fragment.
- An IDE socket client in `lua/kori/ide/`, tested against a fake session.
  No kori release serves the socket yet, so it is inert in practice.
- `:KoriSend` and `:KoriAsk`, sending the selection or the buffer to a session.
  They warn when no session is attached, which is every case today.
- `:KoriHealth`, checking Neovim, kori, the shim and the spool permissions.

### Fixed

- The chat pane no longer hijacks the buffer you are editing. `vsplit` shows the
  same buffer in the new window, so a terminal opened there converted every
  window showing it; the pane now has its own buffer.
- A spool directory's permissions are read correctly by the health check.
