---
project: Core Tasks
author: Developer
status: Active
date: 2026-06-19
---

# Current Sprint

- [ ] Implement socket timeout handling
    > **Context:** Prevent hanging instances from dropped peers.
    > **Notes:** Look at `src/net.c` near line 42.

- [x] Refactor connection pool
    > **Completed:** 2026-06-19 git:a1b2c3d
    > **Notes:** Reduces memory usage by 30%.

# Backlog

- [ ] Add telemetry
    > **Context:** Depends on the pool refactor above.
