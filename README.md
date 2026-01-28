# Clawd Widget

Desktop widget for monitoring Clawdbot cron jobs and status.

## Build

```bash
zig build
```

## Run

```bash
zig build run
```

## How it works

1. Reads `~/.clawdbot/clawdbot.json` for gateway config
2. Connects to `http://localhost:{port}/tools/invoke`
3. Calls `{"tool": "cron", "action": "list"}`
4. Displays job status

## Requires

- Clawdbot Gateway running
- Zig 0.13.0 or newer

## Future

- [ ] GUI with Raylib
- [ ] System tray integration
- [ ] Live updates via timer
- [ ] Cross-platform builds (Linux/Windows/Mac)
