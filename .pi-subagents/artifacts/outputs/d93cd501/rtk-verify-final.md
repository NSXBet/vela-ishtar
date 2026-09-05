# rtk-router verification — final report

## CHECK 0 — Config / routing files: PASS
- `~/.pi/agent/extensions/rtk-router.ts` routes:
  - Direct read-only verbs (`SAFE_DIRECT`): `ls`, `find`, `wc`, `diff`.
  - `git` subcommands (`SAFE_GIT`): `status`, `diff`, `log`, `show` only.
  - Explicitly excluded from routing: `grep`, `rg` (doc comment: leading-dash patterns would be misparsed by rtk), anything with shell metacharacters (`|&;<>()$\`!\n`), env prefixes (`VAR=...`), existing `rtk`/`hypa` invocations, and `ls` invocations containing `-h`.
- `~/.hypa/config.json` is valid JSON: `{"exclude_commands": ["rtk"]}` — contains `"rtk"` in `exclude_commands`. Confirmed.

## CHECK 1 — `ls -laR Sources`: PASS
Output was rtk-style: mode + size columns (`755  App/`, `644  main.swift  14.4K`), no `total` lines, no owner/group/date columns.

## CHECK 2 — `ls -h Sources`: PASS
Output:
```
App
VelaCore
```
Normal directory listing, not rtk usage/help text. The router's `-h` guard works.

## CHECK 3 — `grep -rn "import" Sources/VelaCore/Models.swift`: PASS
Output:
```
Sources/VelaCore/Models.swift:11:import Foundation
```
Native grep `file:line:content` format — not routed to rtk.

## CHECK 4 — `wc -l Sources/VelaCore/Models.swift`: INFORMATIONAL
Output:
```
155
```
This is rtk-style (rewritten: `wc` is in SAFE_DIRECT). Native `wc -l` would print `155 Sources/VelaCore/Models.swift`. The filename is NOT present in the rtk output — only the bare count.

## CHECK 5 — Mutating/composite commands (static inspection of `shouldRewrite`): PASS
- `git commit -m x` → NOT rewritten (`commit` not in SAFE_GIT).
- `rm -rf /tmp/x` → NOT rewritten (`rm` not in SAFE_DIRECT and not a safe git subcommand).
- `ls | head` → NOT rewritten (SHELL_META matches `|`).
- `VAR=1 ls` → NOT rewritten (ENV_PREFIX regex matches).
- `ls && rm x` → NOT rewritten (SHELL_META matches `&`).

## FINAL
ALL CHECKS PASS (Check 4 note: rtk-routed `wc -l` drops the filename from output — informational only per task).
