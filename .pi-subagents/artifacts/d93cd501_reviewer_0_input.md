# Task for reviewer

Narrow verification task. Run EXACTLY the checks below, report PASS/FAIL for each with the actual output you observed, then stop. Do NOT investigate Hypa or rtk internals. Do NOT read source code beyond the two files named in check 0. Do NOT debug exit codes. If something is ambiguous, mark it UNCLEAR and move on. Budget: finish in under 12 tool calls.

CONTEXT: A Pi extension at ~/.pi/agent/extensions/rtk-router.ts rewrites certain plain bash commands to run through `rtk`. Hypa (~/.hypa/config.json) excludes `rtk` so those are not double-compressed. rtk output looks like `644  main.swift  14.4K`; native `ls -laR` output has `total` lines plus owner/group/date columns.

CHECK 0: Read ~/.pi/agent/extensions/rtk-router.ts and ~/.hypa/config.json. State which verbs are routed, which are excluded, and confirm the config is valid JSON containing "rtk" in exclude_commands.

CHECK 1: Run `ls -laR Sources`. PASS if output is rtk-style (mode + size columns, no `total` lines).

CHECK 2: Run `ls -h Sources`. PASS if it prints a normal directory listing (App, VelaCore) and NOT rtk usage/help text.

CHECK 3: Run `grep -rn "import" Sources/VelaCore/Models.swift`. PASS if output looks like native grep (file:line:content), i.e. NOT routed to rtk.

CHECK 4: Run `wc -l Sources/VelaCore/Models.swift`. Report whether output is rtk-style or native, and whether the filename is still present. This is informational, not pass/fail.

CHECK 5: Confirm mutating commands are untouched by inspecting the routing logic only (no execution): state whether `git commit -m x`, `rm -rf /tmp/x`, `ls | head`, `VAR=1 ls`, and `ls && rm x` would be rewritten.

FINAL: One short verdict line: either "ALL CHECKS PASS" or list the failing check numbers with the concrete problem.

---
**Output:**
Write your findings to exactly this path: /Users/nsx001215/Desktop/Projects/aihub-menu-bar/.pi-subagents/artifacts/outputs/d93cd501/rtk-verify-final.md
This path is authoritative for this run.
Ignore any other output filename or output path mentioned elsewhere, including output destinations in the base agent prompt, system prompt, or task instructions.