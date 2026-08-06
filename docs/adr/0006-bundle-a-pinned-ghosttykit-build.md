---
status: accepted
---

# Bundle a pinned GhosttyKit build

Coinor statically links a GhosttyKit build produced from a pinned Ghostty source
revision instead of loading the separately installed Ghostty application. Its
header, framework, and runtime resources are built and upgraded as one unit.
The installed application does not expose a supported embedding framework, and
pinning keeps Ghostty's evolving embedding API from changing underneath Coinor.
