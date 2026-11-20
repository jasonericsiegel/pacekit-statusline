#!/usr/bin/env bash
# Pacekit plugin, start of each Claude Code session: when the plugin has updated, install the
# status line script it now ships, so plugin users never have to run /pacekit:setup update.
#
# It replaces ~/.claude/pacekit/statusline.sh (or $CLAUDE_CONFIG_DIR/pacekit/statusline.sh) only
# when all of these hold, and otherwise does nothing:
#   - /pacekit:setup or install.sh put that copy there, as a plain file (not a symlink)
#   - the statusLine setting in settings.json still runs it
#   - the plugin's script has a higher version number, and passes the checks install.sh runs
# It never edits settings.json, prints nothing (Claude Code would hand any output to Claude),
# and always exits 0. PACEKIT_AUTO_UPDATE=off, or an empty file at ~/.claude/pacekit-no-auto-update,
# turns it off.

exec >/dev/null 2>&1

CLAUDE_DIR=${CLAUDE_CONFIG_DIR:-$HOME/.claude}
PACEKIT_DIR="$CLAUDE_DIR/pacekit"
SCRIPT="$PACEKIT_DIR/statusline.sh"
SETTINGS="$CLAUDE_DIR/settings.json"
BUNDLED="${CLAUDE_PLUGIN_ROOT:-}/statusline.sh"

[ "${PACEKIT_AUTO_UPDATE:-on}" = off ] && exit 0
[ -e "$CLAUDE_DIR/pacekit-no-auto-update" ] && exit 0
[ -n "${CLAUDE_PLUGIN_ROOT:-}" ] && [ -f "$BUNDLED" ] || exit 0
[ -f "$SCRIPT" ] && [ ! -L "$SCRIPT" ] || exit 0

# The PACEKIT_VERSION="x.y.z" line near the top of a Pacekit script.
version_of() {
    local line
    line=$(grep -m 1 '^PACEKIT_VERSION=' "$1") || return 1
    line=${line#PACEKIT_VERSION=}
    printf '%s' "${line//\"/}"
}
# Same comparison as statusline.sh: $1 > $2, numerically part by part; junk is never newer.
PK_VER_RE='^[0-9]+(\.[0-9]+)*$'
pk_newer() {
    local a=$1 b=$2 x y
    [[ $a =~ $PK_VER_RE ]] && [[ $b =~ $PK_VER_RE ]] || return 1
    while [ -n "$a$b" ]; do
        x=${a%%.*}; y=${b%%.*}; x=$((10#${x:-0})); y=$((10#${y:-0}))
        [ "$x" -gt "$y" ] && return 0
        [ "$x" -lt "$y" ] && return 1
        case $a in *.*) a=${a#*.} ;; *) a="" ;; esac
        case $b in *.*) b=${b#*.} ;; *) b="" ;; esac
    done
    return 1
}

# The usual case, nothing new, stops here without starting jq.
pk_newer "$(version_of "$BUNDLED")" "$(version_of "$SCRIPT")" || exit 0

# Only a status line Pacekit set up gets replaced.
command -v jq >/dev/null 2>&1 && [ -f "$SETTINGS" ] || exit 0
line=$(jq -r 'if type == "object" then .statusLine.command // "" else "" end' "$SETTINGS") || exit 0
case $line in *pacekit/statusline.sh*) ;; *) exit 0 ;; esac

# Check the copy that will be installed, as install.sh does, then swap it in with one rename.
NEW="$PACEKIT_DIR/.statusline.sh.$$"
trap 'rm -f "$NEW"' EXIT
cp "$BUNDLED" "$NEW" || exit 0
head -n 1 "$NEW" | grep -q '^#!.*bash' && bash -n "$NEW" || exit 0
sample='{"model":{"display_name":"Opus"},"context_window":{"context_window_size":200000,"used_percentage":10},"workspace":{"current_dir":"/"}}'
printf '%s' "$sample" | PACEKIT_LIMITS_FILE=/dev/null PACEKIT_STAMPS=off PACEKIT_UPDATE_CHECK=off bash "$NEW" || exit 0
chmod +x "$NEW" && mv -f "$NEW" "$SCRIPT"
exit 0
