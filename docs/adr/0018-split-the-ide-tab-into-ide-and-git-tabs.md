---
status: accepted
---

# Split the IDE tab into IDE and Git tabs

The permanent second tab no longer splits its width between `fresh .` and
`lazygit`. It now runs only `fresh .`, full width, at the Git root of the
conversation's checkout or worktree.

A new permanent third tab, Git, runs `lazygit` alone, full width, at the same
working directory. It shares IDE's rules: eager startup with the conversation
runtime, non-closable, non-renameable, and fixed ahead of every shell tab.

Shell tabs can still be reordered by dragging, but cannot move before Git.

Conan Code's local tab metadata needs no schema change: `main` and `ide` keep
their existing stable IDs, and `git` is a new fixed ID recognized the same way,
so metadata persisted before this change loads unaffected.

This supersedes ADR 0012's IDE tab description: the second tab is no longer a
60/40 split of two tools; IDE and Git are now two independent single-tool
tabs.
