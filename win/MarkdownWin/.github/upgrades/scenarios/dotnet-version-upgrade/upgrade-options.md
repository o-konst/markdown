# Upgrade Options — MarkdownWin

Assessment: 1 project (`MarkdownWin.csproj`, WinUI 3 / Windows App SDK, SDK-style, `net8.0-windows10.0.19041.0`) → `net10.0-windows10.0.19041.0`; 20 issues (1 mandatory TFM change, 19 potential API source/behavioral changes across 6 files); no package vulnerabilities.

## Strategy

### Upgrade Strategy
Single project on modern .NET with no dependency graph — a single atomic pass is the only sensible ordering.

| Value | Description |
|-------|-------------|
| **All-at-Once** (selected) | Upgrade the project's target framework and packages in one pass, then build and fix all resulting issues. |

## Compatibility

### Unsupported API Handling
The assessment flagged 4 source-incompatible and 15 behavioral-change API occurrences for .NET 10.

| Value | Description |
|-------|-------------|
| **Fix Inline** (selected) | Resolve every flagged API change within the same task, including complex ones — no stubs and no deferred cleanup work. |
| Defer Complex Changes | Apply simple replacements inline; stub out complex ones and create follow-up resolution subtasks. |
