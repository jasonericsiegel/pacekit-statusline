#!/usr/bin/env bash
# Pacekit installer for Claude Code.
#
# Copies statusline.sh to ~/.claude/pacekit/ and points Claude Code's statusLine
# setting at it. Run it again to update. Run it with --uninstall to remove Pacekit
# and bring back the status line you had before.
#
#   curl -fsSL https://raw.githubusercontent.com/jasonericsiegel/pacekit-statusline/main/install.sh | bash
#   bash install.sh               # from a clone: installs the statusline.sh beside it
#   bash install.sh --update     # fetch the newest script from GitHub, even beside a local copy
#   bash install.sh --uninstall
#
# Needs bash and jq. Honors CLAUDE_CONFIG_DIR if you keep Claude Code's config elsewhere.

set -u

RAW_BASE="${PACEKIT_RAW_BASE:-https://raw.githubusercontent.com/jasonericsiegel/pacekit-statusline/main}"
REFRESH_SECONDS=30

say()  { printf '%s\n' "$*"; }
fail() { printf 'Pacekit: %s\n' "$*" >&2; exit 1; }

usage() {
    cat <<'EOF'
Usage: install.sh [--update | --uninstall]

  (no option)   Install or update Pacekit and point Claude Code's status line at it.
  --update      Same, but always fetch the newest script from GitHub.
  --uninstall   Remove Pacekit and restore the status line you had before it.
  --help        Show this help.

Pacekit lives in ~/.claude/pacekit/ (or $CLAUDE_CONFIG_DIR/pacekit/).
EOF
}

mode=install
fetch_latest=0
case "${1:-}" in
    "") ;;
    --uninstall|uninstall) mode=uninstall ;;
    --update|update) fetch_latest=1 ;;
    -h|--help|help) usage; exit 0 ;;
    *) usage >&2; exit 2 ;;
esac

if ! command -v jq >/dev/null 2>&1; then
    cat >&2 <<'EOF'
Pacekit needs jq, and it isn't installed. Install it, then run this again:

  macOS            brew install jq
  Ubuntu, Debian   sudo apt install jq
  Fedora           sudo dnf install jq
  Arch             sudo pacman -S jq
  Windows          winget install jqlang.jq   (then reopen Git Bash)
EOF
    exit 1
fi

if [ -n "${CLAUDE_CONFIG_DIR:-}" ]; then
    CLAUDE_DIR="$CLAUDE_CONFIG_DIR"
    COMMAND="\"$CLAUDE_DIR/pacekit/statusline.sh\""
else
    CLAUDE_DIR="$HOME/.claude"
    # A literal tilde keeps settings.json portable; Claude Code runs the command in a shell that expands it.
    # shellcheck disable=SC2088
    COMMAND="~/.claude/pacekit/statusline.sh"
fi
PACEKIT_DIR="$CLAUDE_DIR/pacekit"
SCRIPT="$PACEKIT_DIR/statusline.sh"
PREVIOUS="$PACEKIT_DIR/previous-statusline.json"
SETTINGS="$CLAUDE_DIR/settings.json"

WORK=$(mktemp -d "${TMPDIR:-/tmp}/pacekit.XXXXXX") || fail "couldn't create a temporary folder."
trap 'rm -rf "$WORK"' EXIT

# Read settings.json, or start from {} when there isn't one. A file jq can't parse stops
# everything before any change, so a hand-edited settings.json is never overwritten.
current_settings() {
    if [ -f "$SETTINGS" ]; then
        jq -e 'type == "object"' "$SETTINGS" >/dev/null 2>&1 \
            || fail "$SETTINGS isn't valid JSON, so nothing was changed. Fix it, then run this again."
        cat "$SETTINGS"
    else
        printf '{}'
    fi
}

# Write settings.json through a temp file in the same folder, so a failure never leaves half a file.
write_settings() {
    local tmp="$SETTINGS.pacekit-tmp"
    cat > "$tmp" || { rm -f "$tmp"; fail "couldn't write $SETTINGS."; }
    mv "$tmp" "$SETTINGS" || { rm -f "$tmp"; fail "couldn't replace $SETTINGS."; }
}

is_pacekit_line() { printf '%s' "$1" | grep -q 'pacekit/statusline\.sh'; }

if [ "$mode" = uninstall ]; then
    if [ ! -f "$SETTINGS" ] && [ ! -d "$PACEKIT_DIR" ]; then
        say "Pacekit isn't installed here, so there was nothing to remove."
        exit 0
    fi
    if [ -f "$SETTINGS" ]; then
        settings=$(current_settings) || exit 1
        command_now=$(printf '%s' "$settings" | jq -r '.statusLine.command // ""')
        if is_pacekit_line "$command_now"; then
            if [ -f "$PREVIOUS" ] && jq -e 'type == "object"' "$PREVIOUS" >/dev/null 2>&1; then
                printf '%s' "$settings" | jq --slurpfile prev "$PREVIOUS" '.statusLine = $prev[0]' | write_settings
                say "Restored your previous status line: $(jq -r '.command // "(none)"' "$PREVIOUS")"
            else
                printf '%s' "$settings" | jq 'del(.statusLine)' | write_settings
                say "Removed Pacekit from your status line setting."
            fi
        elif [ -n "$command_now" ]; then
            say "Your status line isn't Pacekit ($command_now), so it was left as it is."
        fi
    fi
    rm -rf "$PACEKIT_DIR"
    say "Pacekit is uninstalled."
    exit 0
fi

# Find the script: beside this installer when run from a clone or the plugin, else download it.
# --update always downloads, so a plugin that hasn't updated itself still gets the newest script.
self="${BASH_SOURCE[0]:-}"
local_copy=""
if [ "$fetch_latest" -eq 0 ] && [ -n "$self" ] && [ -f "$self" ]; then
    candidate="$(cd "$(dirname "$self")" && pwd)/statusline.sh"
    [ -f "$candidate" ] && local_copy="$candidate"
fi

NEW="$WORK/statusline.sh"
if [ -n "$local_copy" ]; then
    cp "$local_copy" "$NEW" || fail "couldn't read $local_copy."
else
    url="$RAW_BASE/statusline.sh"
    if command -v curl >/dev/null 2>&1; then
        curl -fsSL "$url" -o "$NEW" 2>/dev/null || fail "couldn't download $url. Check your connection and try again."
    elif command -v wget >/dev/null 2>&1; then
        wget -qO "$NEW" "$url" || fail "couldn't download $url. Check your connection and try again."
    else
        fail "needs curl or wget to download Pacekit."
    fi
fi

# Make sure what we're about to install is the status line script and that it runs.
if ! head -n 1 "$NEW" | grep -q '^#!.*bash' || ! bash -n "$NEW" 2>/dev/null; then
    fail "the downloaded file isn't the Pacekit script, so nothing was changed. Try again in a minute."
fi
sample='{"model":{"display_name":"Opus"},"context_window":{"context_window_size":200000,"used_percentage":10},"workspace":{"current_dir":"/"}}'
printf '%s' "$sample" | PACEKIT_LIMITS_FILE=/dev/null PACEKIT_STAMPS=off PACEKIT_UPDATE_CHECK=off bash "$NEW" >/dev/null 2>&1 \
    || fail "Pacekit didn't run on this machine, so nothing was changed. Please report it with your OS and bash version."

# Check settings.json before touching anything on disk.
settings=$(current_settings) || exit 1

mkdir -p "$PACEKIT_DIR" || fail "couldn't create $PACEKIT_DIR."
mv "$NEW" "$SCRIPT" || fail "couldn't install $SCRIPT."
chmod +x "$SCRIPT" || fail "couldn't make $SCRIPT executable."

# Keep the status line we're replacing so --uninstall can bring it back. An update replaces
# Pacekit's own line, so the one saved before stays; any other line is the newest to keep.
old_line=$(printf '%s' "$settings" | jq -c '.statusLine // empty')
old_command=$(printf '%s' "$settings" | jq -r '.statusLine.command // ""')
if [ -n "$old_line" ] && ! is_pacekit_line "$old_command"; then
    printf '%s\n' "$old_line" > "$PREVIOUS"
    say "Saved your previous status line ($old_command). Run this again with --uninstall to bring it back."
fi

printf '%s' "$settings" \
    | jq --arg cmd "$COMMAND" --argjson refresh "$REFRESH_SECONDS" \
        '.statusLine = {type: "command", command: $cmd, refreshInterval: $refresh}' \
    | write_settings

if is_pacekit_line "$old_command"; then
    say "Pacekit updated."
else
    say "Pacekit installed."
fi
say "Claude Code shows it on its next redraw. If it doesn't appear, restart Claude Code."
