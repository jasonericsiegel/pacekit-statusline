---
description: Turn on the Pacekit status line, update it, or remove it. Use when the user asks to set up, install, update, enable, uninstall or remove Pacekit or its status line.
argument-hint: "[update | uninstall]"
allowed-tools: Bash(bash ${CLAUDE_PLUGIN_ROOT}/install.sh) Bash(bash ${CLAUDE_PLUGIN_ROOT}/install.sh --update) Bash(bash ${CLAUDE_PLUGIN_ROOT}/install.sh --uninstall)
---

# Set up Pacekit

Pacekit's script and installer ship inside this plugin. The installer copies the script to `~/.claude/pacekit/statusline.sh` (a stable path that survives plugin updates) and points the `statusLine` setting in the user's `settings.json` at it. It keeps any status line it replaces, so uninstalling brings that one back.

1. If the user asked to uninstall or remove Pacekit (or `$ARGUMENTS` says so), run:

   ```bash
   bash ${CLAUDE_PLUGIN_ROOT}/install.sh --uninstall
   ```

   If the user asked to update Pacekit (or `$ARGUMENTS` says update), run:

   ```bash
   bash ${CLAUDE_PLUGIN_ROOT}/install.sh --update
   ```

   Otherwise run:

   ```bash
   bash ${CLAUDE_PLUGIN_ROOT}/install.sh
   ```

2. Tell the user what the installer printed, in a sentence or two. On success, add that the status line appears on Claude Code's next redraw (after the next message at the latest), and that each new plugin version installs itself at the start of a session. `/pacekit:setup update` installs the newest one right away whenever line 1 says it's out.

3. If the installer says jq is missing, show the user its install line for their system and offer to run it. Run it only after they say yes, then run the installer again.

4. If it fails for any other reason, show the error and stop. Don't edit `settings.json` by hand.
