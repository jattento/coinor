# TODO

1. Fix model limits
2. Remove the OS version validation
3. Add Isle support
4. Subagents running doesnt count for the spinning in progress symbol
5. Audit finding 39: split the three god objects (`AppCoordinator`,
   `AppShellSidebar`, `GhosttySurfaceView`) into the controllers named in the
   2026-08-16 quality audit. The concrete bugs that made this urgent
   (clipboard use-after-free, remote-host state leaks) already have owners
   inside those files; this item is the remaining mechanical extraction.
