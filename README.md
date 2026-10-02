# Claude Code Telegram Notification Hooks

Enhanced Claude Code notification system that sends different Telegram messages based on notification type and context.

## Features

- **🚀 Session Start**: Notifies when Claude Code session begins
- **🔐 Tool Approval**: Alerts when Claude requests permission to use tools
- **🙋 Agent Needs Input**: Alerts when a background agent is waiting on you
- **✅ Task Completed**: Completion notification with the first line of Claude's reply and session duration
- **🤖 Subagent Completed**: Notifies when subagent tasks finish, including the agent type (e.g. `Explore`)
- **🏁 Session End**: Final notification when session closes, with total duration
- **💻 macOS Desktop Notifications**: Native notifications alongside Telegram alerts (macOS only)
- **🏷️ Project + Session Name**: Every notification shows the project folder and the session name, so parallel sessions are easy to tell apart. New sessions on a feature branch are auto-named after the branch

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
        "matcher": "permission_prompt|agent_needs_input",
        "hooks": [
          {
            "type": "command",
            "command": "./scripts/claude-notification-handler.sh",
            "async": true
          }
        ]
      }
    ],
    "Stop": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "./scripts/claude-notification-handler.sh",
            "async": true
          }
        ]
      }
    ],
    "SubagentStop": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "./scripts/claude-notification-handler.sh",
            "async": true
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

Why the config looks like this:

- **`async: true`** on Notification/Stop/SubagentStop runs the handler in the background, so a slow or failing Telegram request (up to 3 retries × 10s) never blocks Claude.
- **SessionStart stays synchronous** because its JSON output names the session (`sessionTitle`); async hooks have their output discarded. The handler detaches its own Telegram call on SessionStart, so startup is not delayed.
- **SessionEnd stays synchronous** so the final notification is sent before Claude Code exits.
- **Notification matcher `permission_prompt|agent_needs_input`** only forwards notifications that need you. Remove the matcher to receive every notification type (idle prompts, auth, MCP dialogs, …) as a generic 🔔.

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
| Session Start | 🚀 | Claude Code starts | Project name, action |
| Tool Approval | 🔐 | Permission request | Project name, approval details |
| Agent Needs Input | 🙋 | Background agent waiting | Project name, agent message |
| Task Complete | ✅ | Main task done | Project name, reply preview, duration |
| Subagent Complete | 🤖 | Subagent task done | Project name, agent type, reply preview |
| Session End | 🏁 | Session closes | Project name, total duration |

### Message Format

Telegram:

```
<b>my-project</b> · <i>fix-auth-flow</i>
✅ Task Complete
Fixed the token refresh race in auth middleware
⏱ 12m 40s
```

Desktop: the project is the title, the session name is the subtitle.

The preview line is the first non-empty line of Claude's final message (`last_assistant_message`), with markdown markers stripped and capped at 120 characters. The duration line appears only when the handler saw this session's SessionStart.

The session name is resolved in this order (omitted if none is found):

1. `session_title` from the hook input (SessionStart only — set via `--name`, `/rename`, or a hook's `sessionTitle`)
2. The latest `/rename` title in the session transcript (`custom-title` entry)
3. Claude's auto-generated title in the transcript (`ai-title` entry)

**Auto-naming**: on `SessionStart` with `source: startup`, when no title is set yet, the handler names the session after the current git branch (same effect as `/rename`). It skips `main`, `master`, detached HEAD and non-git folders, so Claude's own auto-generated title can take over there.

Steps 2–3 read the transcript JSONL at `transcript_path`, an internal format that may change between Claude Code versions, and require `jq`. The project name is the basename of the hook's `cwd`.

## Improvements

This notification system includes several reliability and security enhancements:

- **Robust JSON Parsing**: Uses `jq` when available, with fallback to grep/sed
- **Safe Encoding**: HTML-escapes dynamic text and lets `curl --data-urlencode` handle UTF-8 (Chinese/emoji session names work)
- **Error Handling**: 3-attempt retry logic with 10-second timeout for network resilience
- **Duration Validation**: Sanity checks prevent invalid duration calculations (>24h)
- **Graceful Failures**: Never blocks Claude Code even if notifications fail
- **Unified Handler**: All hook types use the same well-tested script
- **macOS Desktop Notifications**: Native system notifications with platform detection and graceful fallback

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

### Desktop Notifications

macOS desktop notifications are **built-in and enabled by default**. They work alongside Telegram notifications and use `terminal-notifier` for enhanced functionality.

**Features:**
- **Click-to-activate:** Click any notification to bring Terminal to the front
- Automatic platform detection (macOS only)
- Event-specific messages with appropriate details
- Sound alerts for important events (Tool Approval, Task Complete, etc.)
- Graceful fallback to basic `osascript` if `terminal-notifier` not installed
- Never blocks hook execution on failure

#### Installing terminal-notifier (Recommended)

For clickable notifications that activate your terminal when clicked:

```bash
brew install terminal-notifier
```

**Benefits:**
- Click notifications to jump back to your terminal
- **Automatic terminal detection** - supports all major terminals via `$TERM_PROGRAM` with frontmost app fallback
- No additional configuration needed
- Works with all notification types
- Falls back to basic notifications if not installed

**Supported Terminals:**
- Terminal.app (default fallback)
- iTerm2
- Ghostty
- Alacritty
- kitty
- WezTerm
- Warp
- Hyper
- Tabby
- Rio
- VS Code integrated terminal
- Any other terminal (auto-detected via frontmost app fallback)

**Note:** Due to macOS terminal limitations, notifications bring the terminal app to the front but cannot navigate to a specific tab. You'll need to manually locate the correct tab after clicking.

**Disabling Notifications:**

Use environment variables to toggle each notification channel:

```bash
# Disable desktop notifications only
export CLAUDE_NOTIFY_DESKTOP="false"

# Disable Telegram notifications only
export CLAUDE_NOTIFY_TELEGRAM="false"

# Disable all notifications
export CLAUDE_NOTIFY_DESKTOP="false"
export CLAUDE_NOTIFY_TELEGRAM="false"
```

Both default to `true` (enabled). Add to your shell profile to persist.

All toggles:

| Variable | Default | Effect when `false` |
|----------|---------|---------------------|
| `CLAUDE_NOTIFY_TELEGRAM` | `true` | No Telegram messages |
| `CLAUDE_NOTIFY_DESKTOP` | `true` | No macOS desktop notifications |
| `CLAUDE_NOTIFY_AUTO_TITLE` | `true` | Don't name new sessions after the git branch |
| `CLAUDE_NOTIFY_MESSAGE_PREVIEW` | `true` | Don't include the first line of Claude's reply. Note: with previews on, part of your conversation is sent to Telegram |

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
