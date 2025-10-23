# Claude Code Telegram Notification Hooks

Enhanced Claude Code notification system that sends different Telegram messages based on notification type and context.

## Features

- **🚀 Session Start**: Notifies when Claude Code session begins
- **🔐 Tool Approval**: Alerts when Claude requests permission to use tools
- **⏳ Waiting for Input**: Notifies when Claude has been idle for 60+ seconds
- **✅ Task Completed**: Sends completion notification with session duration
- **🤖 Subagent Completed**: Notifies when subagent tasks finish
- **🏁 Session End**: Final notification with total duration and memory usage

## Setup

### 1. Environment Variables

Set these environment variables for Telegram notifications:

```bash
export TELEGRAM_BOT_TOKEN="your_bot_token_here"
export TELEGRAM_CHAT_ID="your_chat_id_here"
```

Add them to your shell profile (~/.bashrc, ~/.zshrc, etc.) to persist across sessions.

### 2. Create Telegram Bot

1. Message [@BotFather](https://t.me/botfather) on Telegram
2. Send `/newbot` and follow instructions
3. Copy the bot token provided
4. Start a chat with your bot and send any message
5. Get your chat ID: `https://api.telegram.org/bot<TOKEN>/getUpdates`

### 3. Installation

**Option A: Interactive Setup (Recommended)**

1. Open Claude Code and run `/hooks`
2. For each hook event (SessionStart, Notification, Stop, SubagentStop, SessionEnd):
   - Select the event type
   - Add matcher (use `*` to match all)
   - Enter command: `./scripts/claude-notification-handler.sh`
   - Choose **User settings** for global config or **Project settings** for project-specific

**Option B: Manual Configuration**

Edit your Claude Code settings file:
- **Global**: `~/.claude/settings.json` (applies to all projects)
- **Project**: `.claude/settings.json` (shared with team)
- **Local**: `.claude/settings.local.json` (personal, not committed)

Add the hooks configuration (see `hooks.json.example` for reference):

```json
{
  "hooks": {
    "SessionStart": [
      {
        "matcher": "startup",
        "hooks": [
          {
            "type": "command",
            "command": "./scripts/claude-notification-handler.sh"
          }
        ]
      }
    ],
    "Notification": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "./scripts/claude-notification-handler.sh"
          }
        ]
      }
    ],
    "Stop": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "./scripts/claude-notification-handler.sh"
          }
        ]
      }
    ],
    "SubagentStop": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "./scripts/claude-notification-handler.sh"
          }
        ]
      }
    ],
    "SessionEnd": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "./scripts/claude-notification-handler.sh"
          }
        ]
      }
    ]
  }
}
```

**Note**: If using global configuration (`~/.claude/settings.json`), use absolute paths:
```json
"command": "/absolute/path/to/scripts/claude-notification-handler.sh"
```

### 4. Script Installation

**For Project-Specific Setup:**
```bash
# Make scripts executable
chmod +x scripts/claude-notification-handler.sh
chmod +x scripts/test-notifications.sh

# Optional: Copy example settings to .claude directory
mkdir -p .claude
cp .claude/settings.json.example .claude/settings.json
# Edit .claude/settings.json as needed
```

**For Global Setup:**
```bash
# Create a shared location
mkdir -p ~/claude-hooks
cp -r scripts ~/claude-hooks/
chmod +x ~/claude-hooks/scripts/*.sh

# Update hooks configuration to use absolute paths
# Edit ~/.claude/settings.json and use:
# "command": "/Users/your-username/claude-hooks/scripts/claude-notification-handler.sh"
```

## Testing

Test the notification system without waiting for actual Claude Code events:

```bash
# Run the test suite (automatically creates test environment)
./scripts/test-notifications.sh
```

You should receive 7 different Telegram notifications, one for each event type.

## Notification Types

| Event | Emoji | Trigger | Information Included |
|-------|-------|---------|---------------------|
| Session Start | 🚀 | Claude Code starts | Project, timestamp |
| Tool Approval | 🔐 | Permission request | Project, tool name, timestamp |
| Waiting | ⏳ | Idle 60+ seconds | Project, idle reason, timestamp |
| Task Complete | ✅ | Main task done | Project, duration, timestamp |
| Subagent Complete | 🤖 | Subagent task done | Project, duration, timestamp |
| Session End | 🏁 | Session closes | Project, total duration, timestamp |

## Improvements

This notification system includes several reliability and security enhancements:

- **Robust JSON Parsing**: Uses `jq` when available, with fallback to grep/sed
- **URL Encoding**: Properly encodes special characters for Telegram API safety
- **Error Handling**: 3-attempt retry logic with 10-second timeout for network resilience
- **Duration Validation**: Sanity checks prevent invalid duration calculations (>24h)
- **Graceful Failures**: Never blocks Claude Code even if notifications fail
- **Unified Handler**: All hook types use the same well-tested script

## Customization

### Modify Notification Messages

Edit `scripts/claude-notification-handler.sh` to customize:

- Emoji icons
- Message format
- Included information
- Pattern matching for notification types

### Add New Notification Types

1. Add new case in `claude-notification-handler.sh`
2. Add corresponding hook event via `/hooks` command or settings file
3. Test with `test-notifications.sh`

### Disable Specific Notifications

Edit your Claude Code settings file and remove unwanted hook events:

```json
{
  "hooks": {
    "SessionStart": [...],
    // "SubagentStop": [...],  // Remove or comment out to disable
    "Stop": [...]
  }
}
```

Or use `/hooks` command and delete specific hooks interactively.

## Troubleshooting

### No Notifications Received

1. **Check environment variables:**
   ```bash
   echo $TELEGRAM_BOT_TOKEN
   echo $TELEGRAM_CHAT_ID
   ```

2. **Verify bot token and chat ID:**
   ```bash
   curl "https://api.telegram.org/bot$TELEGRAM_BOT_TOKEN/getMe"
   ```

3. **Test manually:**
   ```bash
   curl -X POST "https://api.telegram.org/bot$TELEGRAM_BOT_TOKEN/sendMessage" \
     -d "chat_id=$TELEGRAM_CHAT_ID" \
     -d "text=Test message"
   ```

4. **Check script permissions:**
   ```bash
   ls -la scripts/claude-notification-handler.sh
   # Should show: -rwxr-xr-x (executable)
   ```

### Script Errors

Run the handler directly to see error messages:

```bash
echo '{"hook_event_name":"Stop"}' | ./scripts/claude-notification-handler.sh
```

### Hook Not Triggering

1. Verify hooks configuration location:
   - Run `/hooks` to check active hooks
   - Check `~/.claude/settings.json` for global hooks
   - Check `.claude/settings.json` for project hooks
2. Ensure script has executable permissions: `chmod +x scripts/claude-notification-handler.sh`
3. Verify script path is correct (use absolute paths for global config)
4. Check Claude Code output for hook errors
5. Restart Claude Code after configuration changes

## Advanced Usage

### Multiple Projects with Shared Scripts

1. Create shared script location:
```bash
mkdir -p ~/claude-hooks/scripts
cp scripts/claude-notification-handler.sh ~/claude-hooks/scripts/
chmod +x ~/claude-hooks/scripts/claude-notification-handler.sh
```

2. Configure global hooks with absolute path in `~/.claude/settings.json`:
```json
{
  "hooks": {
    "Notification": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "/Users/your-username/claude-hooks/scripts/claude-notification-handler.sh"
          }
        ]
      }
    ]
  }
}
```

3. Set environment variables in your shell profile (`~/.bashrc`, `~/.zshrc`):
```bash
export TELEGRAM_BOT_TOKEN="your_bot_token"
export TELEGRAM_CHAT_ID="your_chat_id"
```

### Add Desktop Notifications (macOS)

Combine with osascript in the handler script:

```bash
# In claude-notification-handler.sh, add:
osascript -e "display notification \"$DETAILS\" with title \"$TITLE\""
```

### Log Notifications to File

Add logging to the handler:

```bash
# In claude-notification-handler.sh, add:
echo "$(date): $HOOK_EVENT - $TITLE" >> ~/.claude/notifications.log
```

## Resources

- [Claude Code Hooks Documentation](https://docs.claude.com/en/docs/claude-code/hooks)
- [Telegram Bot API](https://core.telegram.org/bots/api)
- [Claude Code GitHub](https://github.com/anthropics/claude-code)

## License

MIT - Feel free to modify and distribute
