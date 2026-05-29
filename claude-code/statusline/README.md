# Claude Code Status Line

A two-line status bar for Claude Code showing:

- **Line 1:** Model | Context window usage | Token counts (↑input ↓output) | Cache hit rate | Estimated cost
- **Line 2:** Working directory | Git branch | 5-hour rate limit | 7-day rate limit

## Requirements

- `jq`
- `bc`
- `git`

## Install

```bash
git clone https://github.com/Zaki0207/ai-cli-kit.git
cd ai-cli-kit/claude-code/statusline
bash install.sh
```

Then restart Claude Code.

## Uninstall

Remove the `statusLine` key from `~/.claude/settings.json` and delete `~/.claude/statusline-command.sh`.
