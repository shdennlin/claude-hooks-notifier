# Claude Code Telegram Notification Hooks

Enhanced Claude Code notification system that sends different Telegram messages based on notification type and context.

## Features

- **🚀 Session Start**: Notifies when Claude Code session begins
- **🔐 Tool Approval**: Alerts when Claude requests permission to use tools
- **🙋 Agent Needs Input**: Alerts when a background agent is waiting on you
- **✅ Task Completed**: Completion notification with Claude's reply (expandable in Telegram) and session duration
- **🤖 Subagent Completed**: Notifies when subagent tasks finish, including the agent type (e.g. `Explore`)
- **🏁 Session End**: Final notification when session closes, with total duration
- **💻 macOS Desktop Notifications**: Native notifications alongside Telegram alerts (macOS only)
- **🏷️ Project + Session Name**: Every notification shows the project folder and the session name, so parallel sessions are easy to tell apart. New sessions on a feature branch are auto-named after the branch

## Setup (Plugin — Recommended)

1. Create a Telegram bot with [@BotFather](https://t.me/botfather) (`/newbot`), send your bot any message, then get your chat ID from `https://api.telegram.org/bot<TOKEN>/getUpdates`.
2. Install the plugin:

```
/plugin marketplace add shdennlin/claude-hooks-notifier
/plugin install session-notifier@shdennlin-notifier
```

   For a local checkout, use the path instead: `/plugin marketplace add /path/to/claude-notification-handler`.
3. Claude Code prompts for the bot token (stored in your system keychain), chat ID, and the on/off toggles. No settings files to edit.

Change options later in `/config`, or run `/plugin configure session-notifier`.

To try it without installing: `claude --plugin-dir .`, then `/plugin configure session-notifier`.

### Upgrading from manual hooks

Remove the old `claude-notification-handler.sh` entries from `~/.claude/settings.json` (or `.claude/settings.json`), otherwise every event notifies twice. Existing `TELEGRAM_BOT_TOKEN` / `CLAUDE_NOTIFY_*` environment variables still work as a fallback; plugin options take precedence.

## Setup (Manual Hooks)

Use this if you don't want a plugin.

```bash
export TELEGRAM_BOT_TOKEN="your_bot_token_here"
export TELEGRAM_CHAT_ID="your_chat_id_here"
```

Add them to your shell profile to persist, then copy the `hooks` block from `hooks.json.example` into `~/.claude/settings.json` (global), `.claude/settings.json` (project), or `.claude/settings.local.json` (personal), using the absolute path to `scripts/claude-notification-handler.sh` and `chmod +x scripts/*.sh`.

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
| Task Complete | ✅ | Main task done | Project name, duration, expandable reply |
| Subagent Complete | 🤖 | Subagent task done | Project name, agent type, expandable reply |
| Session End | 🏁 | Session closes | Project name, total duration |

### Message Format

Telegram:

```
<b>my-project</b> · <i>fix-auth-flow</i>
✅ Task Complete
⏱ 12m 40s
<blockquote expandable>Fixed the token refresh race in auth middleware
...full reply...</blockquote>
```

Desktop: the project is the title, the session name is the subtitle.

In Telegram, Claude's full final message (`last_assistant_message`) appears in a collapsed blockquote: the first few lines show, and you tap it to expand the rest. Inline-code backticks and `**` are stripped, and the text is capped at 3500 characters to stay under Telegram's message limit. The desktop notification shows only the first non-empty line, capped at 120 characters. The duration line appears only when the handler saw this session's SessionStart.

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
| `CLAUDE_NOTIFY_MESSAGE_PREVIEW` | `true` | Don't include Claude's reply (expandable full text in Telegram, first line on desktop). Note: when on, Claude's final reply is sent to Telegram |

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
