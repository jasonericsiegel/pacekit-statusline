#!/bin/bash

# Environment overrides:
# PACEKIT_ICONS: material or emoji; otherwise detect the terminal's icon style.
# PACEKIT_MARGIN: decimal columns reserved outside the status line (default 4).
# PACEKIT_SESSIONS_DIR: session registry directory (default configured sessions directory).
# PACEKIT_BILLING_TYPE: billing type instead of the account profile's value.
# PACEKIT_NOW: epoch seconds instead of the current clock, for deterministic renders.
# PACEKIT_STAMPS: off disables both best-effort stamp writes.
# PACEKIT_CTX_DIR: context stamp directory (default /tmp).
# PACEKIT_LIMITS_FILE: account rate-limit stamp path (default /tmp/pacekit-limits).

# Native Windows jq emits CRLF; Unix jq needs no normalization or extra process.
case "$OSTYPE" in
    msys*|cygwin*) jq() { command jq "$@" | tr -d '\r'; } ;;
esac

# Select character handling once, including all name/title slicing. Probe in a quiet
# subshell so an unavailable locale cannot warn or inherit a previous UTF-8 setting.
# With no installed UTF-8 locale, fall back to C without diagnostics.
PK_CTYPE=C
for PK_LOCALE in "${LC_ALL:-${LC_CTYPE:-${LANG:-C}}}" C.UTF-8 en_US.UTF-8; do
    case "$PK_LOCALE" in
        *UTF-8*|*utf-8*|*UTF8*|*utf8*)
            if (LC_ALL=C; export LC_ALL="$PK_LOCALE"; PK_PROBE='é'; [ "${#PK_PROBE}" -eq 1 ]) 2>/dev/null; then
                PK_CTYPE=$PK_LOCALE; break
            fi ;;
    esac
done
# LC_ALL would override both categories; JSON numbers always use a decimal point.
unset LC_ALL
export LC_CTYPE="$PK_CTYPE" LC_NUMERIC=C

# Matches .claude-plugin/plugin.json and the CHANGELOG (tests and the release check enforce it).
PACEKIT_VERSION="1.1.0"

CLAUDE_DIR=${CLAUDE_CONFIG_DIR:-$HOME/.claude}

# Read JSON input from stdin
input=$(cat)

# ANSI color codes — the severity ladder uses copied xterm256 values so this
# script ships standalone without reading a palette file:
# green 114 done/fine · yellow 221 getting close · red 210 over a limit · violet 177 step in now ·
# blue 111 just so you know. Color marks status only; plain values (cost, times, names) stay
# uncolored. Keep the copied values consistent when changing the ladder.
BOLD=$'\033[1m'
SUCCESS=$'\033[38;5;114m'
WARNING=$'\033[38;5;221m'
DANGER=$'\033[38;5;210m'
CRITICAL=$'\033[38;5;177m'
INFO=$'\033[38;5;111m'      # sky blue — the cold-cache snowflake
DIM=$'\033[2m'
# Dim variants — darker xterm colors for empty bar segments (avoids DIM attribute)
SUCCESS_DIM=$'\033[38;5;65m'
WARNING_DIM=$'\033[38;5;136m'
DANGER_DIM=$'\033[38;5;95m'
CRITICAL_DIM=$'\033[38;5;96m'
FG_DIM=$'\033[38;5;244m'
FG_LIGHT=$'\033[38;5;252m'
RESET=$'\033[0m'

# Icon set. Ghostty bundles the Nerd Font symbols, so there we draw Material Design glyphs;
# they are plain text, so they take ANSI color like
# the rest of the line. Elsewhere, emoji and Unicode symbols that every terminal has.
# Escapes are UTF-8 bytes (bash 3.2 has no \U): fire U+F0238, snowflake U+F0717,
# folder-open-outline U+F0DCF, source-branch U+F062C,
# account U+F0004.
case "$PACEKIT_ICONS" in
    material|emoji) PK_ICONS=$PACEKIT_ICONS ;;
    *) if [ "$TERM_PROGRAM" = "ghostty" ]; then PK_ICONS=material; else PK_ICONS=emoji; fi ;;
esac
if [ "$PK_ICONS" = "material" ]; then
    ICON_FIRE=$'\xf3\xb0\x88\xb8'; ICON_COLD=$'\xf3\xb0\x9c\x97'
    ICON_WORKTREE=$'\xf3\xb0\xb7\x8f'; ICON_BRANCH=$'\xf3\xb0\x98\xac'
    ICON_PEER=$'\xf3\xb0\x80\x84'
    ICON_GAP=" "   # two spaces looked too loose in Ghostty (2026-10-12)
else
    ICON_FIRE="🔥"; ICON_COLD="❄️"; ICON_WORKTREE="⑂"; ICON_BRANCH="⎇"; ICON_PEER="👤"
    ICON_GAP=" "
fi

# Segment separator — dim middle dot, breathing space on both sides. SEP_NARROW is the
# width-pressed fallback: the dot drops to plain double-spacing (saves a column per separator),
# the last squeeze applied on lines 1 and 2 when they still overflow after everything else.
SEP=" ${FG_DIM}·${RESET} "
SEP_NARROW="  "

# Width-aware compression. Claude Code v2.1.153+ exports COLUMNS/LINES to the
# statusline script (it captures our stdout, so tput/`$(stty)` can't see the tty).
# We compress per line, measured against this budget, recomputed every render and
# never persisted — so a terminal resize is picked up on the next render, never
# "locked in". Absent COLUMNS (older Claude Code, non-interactive) -> no budget,
# so output is full-width exactly as before.
# Display width in terminal cells. Pure bash (no fork — the ladders call this often): strip the
# SGR escapes, count characters in a UTF-8 locale (a C locale would count bytes, and every ▮ is
# three), then add one cell for each double-width emoji (🔥 👤 🆕; ❄️ already counts two, its
# variation selector included) and one for each wide East Asian character. Undercounting either
# made narrow lines overflow.
#
# Wide characters (Unicode East Asian Wide and Fullwidth) counted as two cells, by code point:
#   U+1100-115F  Hangul Jamo initial consonants
#   U+2E80-2FFF  CJK and Kangxi radicals, ideographic description characters
#   U+3000-4DBF  CJK punctuation, Hiragana, Katakana, Bopomofo, Hangul compatibility Jamo,
#                enclosed CJK, CJK compatibility, CJK Extension A
#   U+4E00-9FFF  CJK Unified Ideographs
#   U+A000-A4C6  Yi syllables and radicals
#   U+AC00-D7A3  Hangul syllables
#   U+F900-FAFF  CJK Compatibility Ideographs
#   U+FE10-FE19, U+FE30-FE6B  vertical, compatibility and small forms
#   U+FF00-FF60, U+FFE0-FFE6  fullwidth forms
#   U+20000-3FFFF  CJK Extension B onward (planes 2 and 3)
# They are matched as UTF-8 bytes with LC_CTYPE=C for a moment, a few pattern removals per
# string, so a long name costs no more than a short one. Bash 3.2 bracket ranges over high bytes
# misfire ([\xe5-\xe9] matched \xe3 and \xf0), so every bracket lists its bytes outright. Other emoji in names still count one cell.
# With no UTF-8 locale installed (PK_CTYPE=C) everything counts bytes: a wide character counts
# three, so lines over-shorten rather than overflow, and cuts can split a character (as before).
PK_ESC_RE=$'\033\[[0-9;]*m'
PK_X=$'\xe1'; PK_E2=$'\xe2'; PK_E3=$'\xe3'; PK_E4=$'\xe4'; PK_EA=$'\xea'; PK_ED=$'\xed'; PK_EF=$'\xef'; PK_F0=$'\xf0'
PK_W_85=$'\x80\x81\x82\x83\x84\x85\x86\x87\x88\x89\x8a\x8b\x8c\x8d\x8e\x8f\x90\x91\x92\x93\x94\x95\x96\x97\x98\x99\x9a\x9b\x9c\x9d\x9e\x9f'                       # U+1140-115F
PK_W_E2=$'\xba\xbb\xbc\xbd\xbe\xbf'                       # U+2E80-2FFF
PK_W_E4=$'\x80\x81\x82\x83\x84\x85\x86\x87\x88\x89\x8a\x8b\x8c\x8d\x8e\x8f\x90\x91\x92\x93\x94\x95\x96\x97\x98\x99\x9a\x9b\x9c\x9d\x9e\x9f\xa0\xa1\xa2\xa3\xa4\xa5\xa6\xa7\xa8\xa9\xaa\xab\xac\xad\xae\xaf\xb0\xb1\xb2\xb3\xb4\xb5\xb6'                       # U+4000-4DBF (U+4DC0-4DFF hexagrams are narrow)
PK_W_E4+=$'\xb8\xb9\xba\xbb\xbc\xbd\xbe\xbf'                      # U+4E00-4FFF
PK_W_E5=$'\xe5\xe6\xe7\xe8\xe9'                       # U+5000-9FFF
PK_W_EA=$'\x80\x81\x82\x83\x84\x85\x86\x87\x88\x89\x8a\x8b\x8c\x8d\x8e\x8f\x90\x91\x92'                       # U+A000-A4BF
PK_W_93=$'\x80\x81\x82\x83\x84\x85\x86'                       # U+A4C0-A4C6
PK_W_EA+=$'\xb0\xb1\xb2\xb3\xb4\xb5\xb6\xb7\xb8\xb9\xba\xbb\xbc\xbd\xbe\xbf'                      # U+AC00-AFFF
PK_W_EB=$'\xeb\xec'                       # U+B000-CFFF
PK_W_ED=$'\x80\x81\x82\x83\x84\x85\x86\x87\x88\x89\x8a\x8b\x8c\x8d\x8e\x8f\x90\x91\x92\x93\x94\x95\x96\x97\x98\x99\x9a\x9b\x9c\x9d'                       # U+D000-D77F
PK_W_9E=$'\x80\x81\x82\x83\x84\x85\x86\x87\x88\x89\x8a\x8b\x8c\x8d\x8e\x8f\x90\x91\x92\x93\x94\x95\x96\x97\x98\x99\x9a\x9b\x9c\x9d\x9e\x9f\xa0\xa1\xa2\xa3'                       # U+D780-D7A3
PK_W_EF=$'\xa4\xa5\xa6\xa7\xa8\xa9\xaa\xab'                       # U+F900-FAFF
PK_W_B8=$'\x90\x91\x92\x93\x94\x95\x96\x97\x98\x99'$'\xb0\xb1\xb2\xb3\xb4\xb5\xb6\xb7\xb8\xb9\xba\xbb\xbc\xbd\xbe\xbf'   # U+FE10-FE19, U+FE30-FE3F
PK_W_B9=$'\x80\x81\x82\x83\x84\x85\x86\x87\x88\x89\x8a\x8b\x8c\x8d\x8e\x8f\x90\x91\x92\x93\x94\x95\x96\x97\x98\x99\x9a\x9b\x9c\x9d\x9e\x9f\xa0\xa1\xa2\xa3\xa4\xa5\xa6\xa7\xa8\xa9\xaa\xab'                       # U+FE40-FE6B
PK_W_BD=$'\x80\x81\x82\x83\x84\x85\x86\x87\x88\x89\x8a\x8b\x8c\x8d\x8e\x8f\x90\x91\x92\x93\x94\x95\x96\x97\x98\x99\x9a\x9b\x9c\x9d\x9e\x9f\xa0'                       # U+FF40-FF60
PK_W_BF=$'\xa0\xa1\xa2\xa3\xa4\xa5\xa6'                       # U+FFE0-FFE6
PK_W_F0=$'\xa0\xa1\xa2\xa3\xa4\xa5\xa6\xa7\xa8\xa9\xaa\xab\xac\xad\xae\xaf\xb0\xb1\xb2\xb3\xb4\xb5\xb6\xb7\xb8\xb9\xba\xbb\xbc\xbd\xbe\xbf'                       # U+20000-3FFFF
PK_W_LEADS=$'\xe1\xe2\xe3\xe4\xea\xed\xef\xf0'$PK_W_E5$PK_W_EB   # a wide character starts with one of these
PK_W_ANY=$'\x80\x81\x82\x83\x84\x85\x86\x87\x88\x89\x8a\x8b\x8c\x8d\x8e\x8f\x90\x91\x92\x93\x94\x95\x96\x97\x98\x99\x9a\x9b\x9c\x9d\x9e\x9f\xa0\xa1\xa2\xa3\xa4\xa5\xa6\xa7\xa8\xa9\xaa\xab\xac\xad\xae\xaf\xb0\xb1\xb2\xb3\xb4\xb5\xb6\xb7\xb8\xb9\xba\xbb\xbc\xbd\xbe\xbf'
# Sets PK_W to the display width of $1 (no subshell; vis_width prints it).
pk_width() {
    local s=$1
    while [[ $s =~ $PK_ESC_RE ]]; do s=${s//"${BASH_REMATCH[0]}"/}; done
    local narrow=${s//🔥/}; narrow=${narrow//👤/}; narrow=${narrow//🆕/}   # one at a time: bash 3.2 brackets match bytes
    local chars=${#s}
    PK_W=$(( chars + chars - ${#narrow} ))
    [ "$PK_CTYPE" = C ] && return
    LC_CTYPE=C
    local bytes=${#s}
    if [ "$bytes" -ne "$chars" ] && [[ $s == *[$PK_W_LEADS]* ]]; then
        local r=${s//${PK_F0}[$PK_W_F0]??/}
        local four=$(( (bytes - ${#r}) / 4 )) left=${#r}
        r=${r//$PK_X$'\x84'?/};           r=${r//$PK_X$'\x85'[$PK_W_85]/}
        r=${r//${PK_E2}[$PK_W_E2]?/};       r=${r//$PK_E3??/}
        r=${r//${PK_E4}[$PK_W_E4]?/};       r=${r//[$PK_W_E5]??/}
        r=${r//${PK_EA}[$PK_W_EA]?/};       r=${r//$PK_EA$'\x93'[$PK_W_93]/}
        r=${r//[$PK_W_EB]??/}
        r=${r//${PK_ED}[$PK_W_ED]?/};       r=${r//$PK_ED$'\x9e'[$PK_W_9E]/}
        r=${r//${PK_EF}[$PK_W_EF]?/}
        r=${r//$PK_EF$'\xb8'[$PK_W_B8]/}; r=${r//$PK_EF$'\xb9'[$PK_W_B9]/}
        r=${r//$PK_EF$'\xbc'[$PK_W_ANY]/}; r=${r//$PK_EF$'\xbd'[$PK_W_BD]/}
        r=${r//$PK_EF$'\xbf'[$PK_W_BF]/}
        PK_W=$(( PK_W + four + (left - ${#r}) / 3 ))
    fi
    LC_CTYPE=$PK_CTYPE
}
vis_width() { pk_width "$1"; printf '%s' "$PK_W"; }
# Sets PK_CUT to the longest leading part of $1 that fits in $2 cells. A cut that would land
# between the two cells of a wide character drops that character instead of overshooting.
pk_cut() {
    local s=$1 max=$2 t
    pk_width "$s"; if [ "$PK_W" -le "$max" ]; then PK_CUT=$s; return; fi
    t=$max; [ "$t" -gt "${#s}" ] && t=${#s}
    pk_width "${s:0:$t}"
    while [ "$PK_W" -gt "$max" ]; do                 # each character dropped frees at least one cell
        t=$(( t - (PK_W - max) )); [ "$t" -lt 0 ] && t=0
        pk_width "${s:0:$t}"
    done
    while [ "$t" -lt "${#s}" ]; do                   # then take back any narrow ones that still fit
        pk_width "${s:0:$((t + 1))}"; [ "$PK_W" -le "$max" ] || break; t=$((t + 1))
    done
    PK_CUT=${s:0:$t}
}
# end of width helpers
# Claude Code draws the status row 2 cells in and stops 2 short of the right edge, clipping anything
# longer with … (measured on v2.1.301 with a digit ruler: COLUMNS=32 showed 28 cells). A margin of 2
# let full-budget lines lose their tail to that …. The margin is configurable if a release moves it.
PK_MARGIN=4
case "$PACEKIT_MARGIN" in ''|*[!0-9]*) ;; *) PK_MARGIN=$((10#$PACEKIT_MARGIN)) ;; esac
PK_BUDGET=9999
case "$COLUMNS" in ''|*[!0-9]*) ;; *)
    if [ "$COLUMNS" -gt 0 ]; then PK_BUDGET=$((10#$COLUMNS - PK_MARGIN)); fi ;;
esac
[ "$PK_BUDGET" -lt 0 ] && PK_BUDGET=0

# Extract fields
MODEL_DISPLAY=$(echo "$input" | jq -r '.model.display_name // "Unknown"')
MODEL_DISPLAY=$(echo "$MODEL_DISPLAY" | sed -E 's/ *\([^)]*\) *$//')
# Reasoning effort (.effort.level): low/medium/high/xhigh/max. Reflects the live in-session
# value (mid-session /effort changes included). Absent when the model doesn't support effort
# -> // empty yields "" and the tag never renders.
EFFORT_LEVEL=$(echo "$input" | jq -r '.effort.level // empty')
CONTEXT_SIZE=$(echo "$input" | jq -r '(.context_window.context_window_size // 200000) | floor')
# Prompt cache (.prompt_cache, Claude Code v2.1.251+): absent until the first API response, and
# caching_observed=false when the provider never reports cache tokens. Booleans are read as 1/0
# via an explicit == true test — jq's `// empty` would swallow a legitimate false. expires_at is
# epoch seconds (null while cold); ttl ("1h"/"5m") scales the countdown's color ramp.
PC_OBSERVED=$(echo "$input" | jq -r 'if .prompt_cache.caching_observed == true then 1 else 0 end')
PC_WARM=$(echo "$input" | jq -r 'if .prompt_cache.warm == true then 1 else 0 end')
PC_EXPIRES=$(echo "$input" | jq -r '(.prompt_cache.expires_at // empty) | floor')
PC_TTL=$(echo "$input" | jq -r '.prompt_cache.ttl // empty')
case "$PC_EXPIRES" in ''|*[!0-9]*) PC_EXPIRES="" ;; esac
# ttl is "1h" / "5m"; anything else (absent, unreadable, zero) is treated as 1h.
PC_TTL_S=3600
PC_TTL_N=${PC_TTL%[hm]}
case "$PC_TTL_N" in ''|*[!0-9]*) ;; *)
    case "$PC_TTL" in
        *h) PC_TTL_S=$(( 10#$PC_TTL_N * 3600 )) ;;
        *m) PC_TTL_S=$(( 10#$PC_TTL_N * 60 )) ;;
    esac ;;
esac
[ "$PC_TTL_S" -gt 0 ] || PC_TTL_S=3600
CTX_PERCENT=$(echo "$input" | jq -r '.context_window.used_percentage // 0' | cut -d. -f1)

# Rate limits (Max/Pro, absent before first API response)
FIVE_H_PCT=$(echo "$input" | jq -r '.rate_limits.five_hour.used_percentage // empty')
FIVE_H_RESET=$(echo "$input" | jq -r '(.rate_limits.five_hour.resets_at // empty) | floor')
SEVEN_D_PCT=$(echo "$input" | jq -r '.rate_limits.seven_day.used_percentage // empty')
SEVEN_D_RESET=$(echo "$input" | jq -r '(.rate_limits.seven_day.resets_at // empty) | floor')

# Session cost & duration — always present in the cost object (not Pro/Max-gated).
# NOTE: total_cost_usd is an API-rate ESTIMATE (what the session would cost at
# pay-as-you-go rates). It is populated even on Pro/Max subscriptions — it is NOT
# 0 for in-plan usage — so it is meaningless as a real charge for subscribers.
# That's why the cost UI is gated on rate_limits presence below, not on this value.
COST_USD=$(echo "$input" | jq -r '.cost.total_cost_usd // 0')
case "$COST_USD" in ''|*[!0-9.]*) COST_USD=0 ;; esac   # numeric-only guard before awk

# Session id — keys the context-usage stamp below. Absent/empty -> no stamp is written.
SESSION_ID=$(echo "$input" | jq -r '.session_id // empty')

# Peer name — the handle other Claude Code sessions use to message this one (ListAgents /
# SendMessage). Claude Code keeps a live registry, one JSON per process, in its sessions directory;
# match ours by session id, newest file first. A derived name is "<folder>-<suffix>" and the
# folder already shows on the git line, so only the suffix renders; a name you set shows whole.
# A launcher that picks a free "<folder>-<xx>" up front (CLAUDE_CODE_SESSION_NAME) leaves no
# nameSource, so that shape — this folder, then 2-3 hex characters — counts as derived too.
# No match -> no segment.
SESSIONS_DIR=${PACEKIT_SESSIONS_DIR:-$CLAUDE_DIR/sessions}
PEER_NAME=""
if [ -n "$SESSION_ID" ] && [ -d "$SESSIONS_DIR" ]; then
    PEER_REG=""
    # Scan contents once, then compare glob entries without splitting filenames.
    PEER_MATCHES=$'\n'"$(grep -lF "\"$SESSION_ID\"" "$SESSIONS_DIR"/*.json 2>/dev/null)"$'\n'
    for PEER_FILE in "$SESSIONS_DIR"/*.json; do
        [ -f "$PEER_FILE" ] || continue
        case "$PEER_MATCHES" in *$'\n'"$PEER_FILE"$'\n'*)
            if [ -z "$PEER_REG" ] || [ "$PEER_FILE" -nt "$PEER_REG" ]; then PEER_REG=$PEER_FILE; fi ;;
        esac
    done
    [ -n "$PEER_REG" ] && PEER_NAME=$(jq -r '(.name // "") as $n
        | ((.cwd // "") | sub("/+$"; "") | split("/") | (last // "") | ascii_downcase | gsub("\\s+"; "-")) as $f
        | if .nameSource == "derived"
             or ($f != "" and ($n | startswith($f + "-")) and ($n | ltrimstr($f + "-") | test("^[0-9a-f]{2,3}$")))
          then ($n | sub(".*-"; "")) else $n end' "$PEER_REG" 2>/dev/null)
fi

# Session title — its own top line, above the context line. Claude Code passes it as session_name:
# the /rename (or --name) name, else its AI title. A default "<folder>-<hex>" name (for the launch
# folder or the current one) is no title, so it falls through. Older versions keep it only in the transcript, on lines of their own:
# {"type":"ai-title","aiTitle":…} each time it names the session, {"type":"custom-title",
# "customTitle":…} after a /rename. The last /rename wins; without one, the latest auto title. A
# title line starts its line (a message quoting one never does), so grep first: transcripts run to
# tens of MB. No session_name, no transcript, and no title -> no line.
SESSION_TITLE=$(echo "$input" | jq -r '[.workspace.project_dir, .workspace.current_dir, .cwd
        | strings | sub("/+$"; "") | split("/") | (last // "") | ascii_downcase | gsub("\\s+"; "-")
        | select(. != "")] as $fs
    | (.session_name // "" | gsub("\\s+"; " ") | ltrimstr(" ") | rtrimstr(" ")) as $n
    | if any($fs[]; . as $f | ($n | startswith($f + "-")) and ($n | ltrimstr($f + "-") | test("^[0-9a-f]{2,3}$")))
      then "" else $n end' 2>/dev/null)
TRANSCRIPT=$(echo "$input" | jq -r '.transcript_path // empty')
if [ -z "$SESSION_TITLE" ] && [ -n "$TRANSCRIPT" ] && [ -f "$TRANSCRIPT" ]; then
    SESSION_TITLE=$(grep -E '^\{"type":"(ai|custom)-title"' "$TRANSCRIPT" 2>/dev/null \
        | jq -rs --arg sid "$SESSION_ID" 'map(select($sid == "" or .sessionId == $sid))
            | ((map(select(.type == "custom-title") | .customTitle // empty) | last)
               // (map(select(.type == "ai-title") | .aiTitle // empty) | last) // "")
            | gsub("\\s+"; " ") | ltrimstr(" ") | rtrimstr(" ")' 2>/dev/null)
fi

# Branch — always from git (source of truth)
CURRENT_DIR=$(echo "$input" | jq -r '.workspace.current_dir // empty')
BRANCH=$(git -C "$CURRENT_DIR" symbolic-ref --quiet --short HEAD 2>/dev/null)
[ -z "$BRANCH" ] && BRANCH=$(echo "$input" | jq -r '.worktree.branch // empty')

# Worktree / checkout name — basename of the git worktree root (exact, no prefix stripping).
# Subdir = relative path from worktree root to cwd (empty when at root).
WORKTREE_ROOT=$(git -C "$CURRENT_DIR" rev-parse --show-toplevel 2>/dev/null)
if [ -n "$WORKTREE_ROOT" ]; then
    WORKTREE_NAME=$(basename "$WORKTREE_ROOT")
    SUBDIR=$(git -C "$CURRENT_DIR" rev-parse --show-prefix 2>/dev/null)
    SUBDIR=${SUBDIR%/}
else
    WORKTREE_NAME=$(basename "$CURRENT_DIR" 2>/dev/null)
    SUBDIR=""
fi

# Format context window size in M/K
format_k() {
    local num=$1
    if [ $num -ge 1000000 ]; then
        printf "%dM" $((num / 1000000))
    elif [ $num -ge 100000 ]; then
        printf "%dK" $((num / 1000))
    elif [ $num -ge 1000 ]; then
        printf "%dK" $(( (num + 500) / 1000 ))
    else
        echo "$num"
    fi
}
CTX_WINDOW_K=$(format_k $CONTEXT_SIZE)

# Build a colored bar for a given percentage.
# Fills with ▮ (narrow vertical rectangle), pads with dim-color ▮.
# Args: $1=pct, $2=ANSI fg color code, $3=width (default 5), $4=dim color
EMPTY_COLOR=$'\033[38;5;240m'
build_bar() {
    local pct=$1
    local color=$2
    local width=${3:-5}
    local dim_color=${4:-$EMPTY_COLOR}
    [ "$width" -le 0 ] && return
    local filled=$(( (pct * width + 50) / 100 ))
    [ $filled -gt $width ] && filled=$width
    [ $filled -lt 0 ] && filled=0
    local empty=$((width - filled))
    local bar=""
    local i
    for ((i=0; i<filled; i++)); do bar+="${color}▮"; done
    local pad=""
    for ((i=0; i<empty; i++)); do pad+="${dim_color}▮"; done
    printf "%s%s%s" "$bar" "$pad" "$RESET"
}

# Capitalize an effort level for display. Known levels get exact forms (xhigh -> XHigh, which
# naive title-casing would get wrong); an unknown non-empty value is generically title-cased so
# a future level still renders sanely. Empty in -> empty out (the tag then never renders).
cap_effort() {
    case "$1" in
        "")     ;;
        low)    printf 'Low' ;;
        medium) printf 'Medium' ;;
        high)   printf 'High' ;;
        xhigh)  printf 'XHigh' ;;
        max)    printf 'Max' ;;
        *)      printf '%s%s' "$(printf '%s' "${1%"${1#?}"}" | tr '[:lower:]' '[:upper:]')" "${1#?}" ;;
    esac
}

# Abbreviate an effort display word for the narrow-width ladder rung. Length-based, NOT a per-level
# map, so a level added in a future Claude Code never breaks: any word longer than 4 chars collapses
# to its first 3 (Medium -> Med, XHigh -> XHi, a hypothetical Ultra -> Ult); Low/High/Max already fit
# and pass through unchanged (the abbreviate rung is then a harmless no-op for them).
abbr_effort() {
    if [ "${#1}" -gt 4 ]; then printf '%s' "${1:0:3}"; else printf '%s' "$1"; fi
}

# Threshold coloring for context (not a time window)
threshold_color() {
    local pct=$1
    if [ $pct -ge 60 ]; then echo "$CRITICAL"
    elif [ $pct -ge 50 ]; then echo "$DANGER"
    elif [ $pct -ge 40 ]; then echo "$WARNING"
    else echo "$SUCCESS"
    fi
}
threshold_color_dim() {
    local pct=$1
    if [ $pct -ge 60 ]; then echo "$CRITICAL_DIM"
    elif [ $pct -ge 50 ]; then echo "$DANGER_DIM"
    elif [ $pct -ge 40 ]; then echo "$WARNING_DIM"
    else echo "$SUCCESS_DIM"
    fi
}

# Velocity coloring — compare usage% to elapsed% of the window.
# Args: $1=usage pct, $2=seconds remaining, $3=window total seconds
# Rules (consistent at all elapsed values — no "too early to tell" grace):
#   Ratio-based pace: (usage/elapsed - 1) * 100 = % over pace
#   > 10  -> critical (violet)
#   >= 0  -> danger (red)
#   > -10 -> warning (yellow)
#   <= -10 -> success (green)
# Echoes "COLOR PACE" (e.g. "\033[...m 15")
velocity_info() {
    local usage=$1
    local remaining=$2
    local total=$3
    if [ -z "$remaining" ] || [ -z "$total" ]; then echo "$SUCCESS 0"; return; fi
    local elapsed=$((total - remaining))
    [ $elapsed -lt 0 ] && elapsed=0
    local elapsed_pct=$(( elapsed * 100 / total ))
    [ $elapsed_pct -lt 1 ] && elapsed_pct=1
    local pace=$(( (usage * 100 / elapsed_pct) - 100 ))
    local color
    if [ $pace -gt 10 ]; then color="$CRITICAL"
    elif [ $pace -ge 0 ]; then color="$DANGER"
    elif [ $pace -gt -10 ]; then color="$WARNING"
    else color="$SUCCESS"
    fi
    echo "$color $pace"
}
velocity_info_dim() {
    local usage=$1
    local remaining=$2
    local total=$3
    if [ -z "$remaining" ] || [ -z "$total" ]; then echo "$SUCCESS_DIM"; return; fi
    local elapsed=$((total - remaining))
    [ $elapsed -lt 0 ] && elapsed=0
    local elapsed_pct=$(( elapsed * 100 / total ))
    [ $elapsed_pct -lt 1 ] && elapsed_pct=1
    local pace=$(( (usage * 100 / elapsed_pct) - 100 ))
    if [ $pace -gt 10 ]; then echo "$CRITICAL_DIM"
    elif [ $pace -ge 0 ]; then echo "$DANGER_DIM"
    elif [ $pace -gt -10 ]; then echo "$WARNING_DIM"
    else echo "$SUCCESS_DIM"
    fi
}

# Elapsed-into-window — counts UP from window start, like context %/pace which also climb.
# Takes seconds-remaining + window total; elapsed = total - remaining. Renders XdYh | XhYm | Xm.
#
# Minute precision is rationed: mid-window a ticking minute digit is churn nobody acts on, so
# the label coarsens to whole hours (2h / 5h). Minutes come back only in the endgame — $3 is
# the seconds-remaining threshold at which "36 minutes left" becomes a real decision. The
# under-1h case is exempt in the other direction: minutes are all there is that early, and
# "0h" would say nothing. The XdYh form never carries minutes at all — a window measured in
# days is not one you steer by the minute, and the third unit would only cost width.
format_elapsed() {
    local remaining=$1
    local total=$2
    local mins_below=${3:-0}
    [ -z "$remaining" ] && return
    local elapsed=$((total - remaining))
    [ $elapsed -lt 0 ] && elapsed=0
    local days=$((elapsed / 86400))
    local hours=$(( (elapsed % 86400) / 3600 ))
    local mins=$(( (elapsed % 3600) / 60 ))
    local show_mins=0
    [ "$remaining" -le "$mins_below" ] && show_mins=1
    if [ $days -gt 0 ]; then
        if [ $hours -gt 0 ]; then printf "%dd%dh" $days $hours; else printf "%dd" $days; fi
    elif [ $hours -gt 0 ]; then
        if [ $show_mins -eq 1 ] && [ $mins -gt 0 ]; then printf "%dh%dm" $hours $mins; else printf "%dh" $hours; fi
    else printf "%dm" $mins
    fi
}

# Current epoch seconds. Honors the clock override so tests can freeze time and exercise velocity, cache-life,
# and window-reset paths deterministically against the same instant. Unset -> real clock.
now_epoch() {
    if [ -n "$PACEKIT_NOW" ]; then printf '%s' "$PACEKIT_NOW"; else date +%s; fi
}

# Seconds-until-reset helper for velocity calc
secs_until() {
    local epoch=$1
    [ -z "$epoch" ] && { echo ""; return; }
    local now; now=$(now_epoch)
    local diff=$((epoch - now))
    [ $diff -lt 0 ] && diff=0
    echo $diff
}

# Compact duration label from a raw millisecond delta — Xm | XhYm | XdYh (same
# shape as format_elapsed; takes ms, not seconds). Sole caller is the 🔥 cache-life
# indicator below; the standalone ◷ session-duration segment was removed.
format_duration() {
    local ms=${1:-0}
    local secs=$((ms / 1000))
    local days=$((secs / 86400))
    local hours=$(( (secs % 86400) / 3600 ))
    local mins=$(( (secs % 3600) / 60 ))
    if [ $days -gt 0 ]; then
        if [ $hours -gt 0 ]; then printf "%dd%dh" $days $hours; else printf "%dd" $days; fi
    elif [ $hours -gt 0 ]; then
        if [ $mins -gt 0 ]; then printf "%dh%dm" $hours $mins; else printf "%dh" $hours; fi
    else printf "%dm" $mins
    fi
}

# Cost — formats a USD float for display, or empty when zero/absent (hidden on line 1).
# Sub-cent but non-zero renders "<$0.01"; otherwise "$X.XX".
format_cost() {
    local raw=${1:-0}
    local positive=$(awk -v c="$raw" 'BEGIN { print (c > 0) ? 1 : 0 }')
    [ "$positive" != "1" ] && { echo ""; return; }
    local rounded=$(awk -v c="$raw" 'BEGIN { printf "%.2f", c }')
    if [ "$rounded" = "0.00" ]; then echo "<\$0.01"
    else echo "\$${rounded}"
    fi
}

# Subdir at a "keep level" — how many trailing path components to show. k >= the
# component count returns the FULL path verbatim (no ellipsis); 0 < k < count
# returns "…/" + the last k components, signalling hidden ancestors. The split is
# glob-safe (read -ra, not parts=($path)) so a component like "[archive]" can't
# glob-expand against the filesystem.
subdir_at_level() {
    local path=$1 k=$2
    local parts; IFS='/' read -ra parts <<< "$path"
    local n=${#parts[@]}
    if [ "$k" -ge "$n" ]; then printf '%s' "$path"; return; fi
    local out="" i
    for (( i = n - k; i < n; i++ )); do out+="/${parts[$i]}"; done
    printf '…%s' "$out"
}

# Cap a name at $2 cells (default 24) with a trailing ellipsis. 24 is the standing cap; the
# line-3 ladder lifts it on a wide terminal and tightens it on a narrow one.
cap_name() {
    pk_cut "$1" "${2:-24}"
    if [ "$PK_CUT" = "$1" ]; then printf '%s' "$1"; else printf '%s…' "$PK_CUT"; fi
}

# Single line: context | 5h rate | 7d rate | model + branch
CTX_COLOR=$(threshold_color $CTX_PERCENT)
CTX_COLOR_DIM=$(threshold_color_dim $CTX_PERCENT)
FIVE_H_TOTAL=$((5 * 3600))
SEVEN_D_TOTAL=$((7 * 86400))

# Split the model display into name + version so the line-1 width ladder can drop the version
# ("Opus 4.8" -> "Opus") independently of the name. The version is the trailing number.dots token;
# a display with no such token (e.g. "Unknown") leaves MODEL_VER empty, so the version-drop rung
# is simply a no-op there.
MODEL_NAME="$MODEL_DISPLAY"
MODEL_VER=""
case "$MODEL_DISPLAY" in
    *' '[0-9]*)
        _last=${MODEL_DISPLAY##* }
        case "$_last" in
            *[!0-9.]*) ;;                               # trailing token not pure number.dots -> no split
            *) MODEL_NAME=${MODEL_DISPLAY% *}; MODEL_VER=$_last ;;
        esac
        ;;
esac

# Effort tag — the session's reasoning effort, shown bare right after the model on
# line 1 (e.g. "Opus 4.8 High"). Rendered in light gray at NORMAL weight (not bold) so it reads
# as secondary to the bold model name. EFFORT_DISP is the full display word ("" when the model
# doesn't support effort -> nothing renders, line 1 byte-identical to before). render_line1 wraps
# it (full or abbreviated) per the PK_E_ABBR lever; the body is not precomputed here because the
# width ladder rebuilds it each pass.
EFFORT_DISP=$(cap_effort "$EFFORT_LEVEL")

# Context-usage stamp — persist the live context-window fill for other local consumers.
# Keyed by session_id, overwritten
# every render so it's always fresh; "<pct> <size> <epoch>". Best-effort — a failed write
# never affects rendering.
if [ "$PACEKIT_STAMPS" != off ] && [ -n "$SESSION_ID" ]; then
    echo "${CTX_PERCENT} ${CONTEXT_SIZE} $(now_epoch)" 2>/dev/null > "${PACEKIT_CTX_DIR:-/tmp}/pacekit-ctx-$SESSION_ID" || true
fi

# Rate-limit stamp — the 5h / 7d windows are account-wide, so one file for every session:
# "<5h_pct> <5h_resets_at> <7d_pct> <7d_resets_at> <epoch>". Long unattended runs read it to
# pause before the limit instead of hitting it. Written only when rate_limits arrived, and only for
# a real Claude Code session (a UUID session_id), so a hand-run fixture ("x", "fit-1") can't write
# a fake 100% that tools reading the file would act on.
PK_UUID_RE='^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$'
# A plan with no 5h limit (weekly only) still writes it, with the missing window as "0 0".
if [ "$PACEKIT_STAMPS" != off ] && { [ -n "$FIVE_H_PCT" ] || [ -n "$SEVEN_D_PCT" ]; } && [[ $SESSION_ID =~ $PK_UUID_RE ]]; then
    echo "${FIVE_H_PCT:-0} ${FIVE_H_RESET:-0} ${SEVEN_D_PCT:-0} ${SEVEN_D_RESET:-0} $(now_epoch)" \
        2>/dev/null > "${PACEKIT_LIMITS_FILE:-/tmp/pacekit-limits}" || true
fi

# Cache-life indicator — the prompt cache's remaining warm time: how long before being away
# costs a full re-cache. 🔥 48m counts DOWN (each render recomputes from expires_at against the live clock,
# so a refreshInterval tick or any re-render moves it) and flips to a bold blue "❄️ cold" once the
# cached prefix goes cold — Claude Code re-runs the statusline exactly at expires_at, so the flip
# lands on time; and because the flip is computed here from the clock, a frozen snapshot that still
# says warm:true past its expires_at also renders cold. Minutes are rounded UP so the last stretch
# reads 🔥 1m, never a lying 🔥 0m. Nothing renders until the first API response, or when the
# provider never reports cache tokens (caching_observed=false) — the line is then byte-identical
# to before the feature. The countdown walks the pace colors as fractions of the TTL: more than
# 1/3 left green, 1/6 yellow, 1/20 red, then violet (1h cache: 20m, 10m, 3m). Going cold is the
# bad state, so it is bold, in its own color, and named. Built by a function so the line-1 ladder
# can re-render it with PK_K_ABBR=1 (bare glyph: no countdown, no "cold") under width pressure;
# the glyph itself never drops.
build_cache() {
    CACHE_BODY=""
    [ "$PC_OBSERVED" != "1" ] && return
    local now; now=$(now_epoch)
    if [ "$PC_WARM" = "1" ] && [ -n "$PC_EXPIRES" ] && [ "$PC_EXPIRES" -gt "$now" ]; then
        local left=$((PC_EXPIRES - now))
        local left_min=$(( (left + 59) / 60 ))
        local color="$CRITICAL"
        if   [ $((left * 3))  -gt "$PC_TTL_S" ]; then color="$SUCCESS"
        elif [ $((left * 6))  -gt "$PC_TTL_S" ]; then color="$WARNING"
        elif [ $((left * 20)) -gt "$PC_TTL_S" ]; then color="$DANGER"
        fi
        # The minutes ARE the signal (how long you can step away for free) and never drop; under
        # width pressure the glyph butts against them instead (🔥 48m -> 🔥48m), except with
        # Material icons, which Ghostty squeezes to one cell against a letter.
        local gap="$ICON_GAP"
        [ "${PK_K_GAP:-1}" -eq 0 ] && [ "$PK_ICONS" != "material" ] && gap=""
        CACHE_BODY="${color}${ICON_FIRE}${gap}$(format_duration $((left_min * 60000)))${RESET}"
    elif [ "${PK_K_ABBR:-0}" -eq 1 ]; then          # the blue snowflake alone says cold
        CACHE_BODY="${BOLD}${INFO}${ICON_COLD}${RESET}"
    else
        CACHE_BODY="${BOLD}${INFO}${ICON_COLD}${ICON_GAP}cold${RESET}"
    fi
}
build_cache

# Cost is shown ONLY for API/pay-as-you-go users (no rate_limits), where total_cost_usd is
# real money. On Pro/Max subscriptions it's just an API-equivalent token estimate, so we hide it.
# It is NOT placed on line 1: on API plans there is no rate-limit line, so line 2 is free —
# cost leads line 2 (in its own cyan, off the good->bad spectrum) and git follows it (see the
# print block). That keeps line 1 from becoming one over-stuffed line. Computed here, rendered below.
# Rate limits are absent before the first API response of a session, so "no rate limits" alone
# misfires on a fresh subscription session and flashes a bogus dollar figure. Cross-check the
# account profile: ~/.claude.json .oauthAccount.billingType is "stripe_subscription" on Pro/Max.
# Any subscription signal (profile OR rate-limit windows) hides cost; only API users see it.
# An explicit billing override takes precedence over the profile lookup.
BILLING_PROFILE="$HOME/.claude.json"
if [ -n "$CLAUDE_CONFIG_DIR" ] && [ -f "$CLAUDE_DIR/.claude.json" ]; then BILLING_PROFILE="$CLAUDE_DIR/.claude.json"; fi
BILLING_TYPE=${PACEKIT_BILLING_TYPE-$(jq -r '.oauthAccount.billingType // empty' "$BILLING_PROFILE" 2>/dev/null)}
COST_TEXT=""
if [ -z "$FIVE_H_PCT" ] && [ -z "$SEVEN_D_PCT" ] && [ "$BILLING_TYPE" != "stripe_subscription" ]; then
    COST_TEXT=$(format_cost "$COST_USD")
fi

# Git meta (⑂ worktree /subdir ⎇ branch) as a standalone segment with NO leading separator,
# so the print block below can place it on line 3 (Pro/Max) or line 2 after cost (API). Built
# once here. Branch hidden when it duplicates the worktree name.
# Ladder levers (set by fit_git): PK_G_WT / PK_G_BR cap the worktree and branch names (999 = no
# cap); PK_G_GAP=0 butts each icon against its name; PK_G_NS=0 drops the branch's namespace
# ("feature/etl-v2" -> "etl-v2"). The peer name keeps the standing 25 cap and never shrinks.
SHOW_BRANCH=0
[ -n "$BRANCH" ] && [ "$BRANCH" != "$WORKTREE_NAME" ] && SHOW_BRANCH=1
build_git() {  # $1 = subdir display string — built via a fn so we can swap a compressed subdir
    local g="" gap="$ICON_GAP" br="$BRANCH"
    [ "${PK_G_GAP:-1}" -eq 0 ] && gap=""
    [ "${PK_G_NS:-1}" -eq 0 ] && br=${BRANCH##*/}
    # Peer name leads the line — the address another session messages. Never compressed.
    [ -n "$PEER_NAME" ] && g+="${FG_LIGHT}${ICON_PEER}${gap}$(cap_name "$PEER_NAME")${RESET}"
    [ -n "$PEER_NAME" ] && [ -n "$WORKTREE_NAME" ] && g+=" "
    [ -n "$WORKTREE_NAME" ] && g+="${FG_LIGHT}${ICON_WORKTREE}${gap}$(cap_name "$WORKTREE_NAME" "${PK_G_WT:-999}")${RESET}"
    [ -n "$1" ] && g+="${FG_DIM}/$1${RESET}"
    [ "$SHOW_BRANCH" -eq 1 ] && g+=" ${FG_LIGHT}${ICON_BRANCH}${gap}$(cap_name "$br" "${PK_G_BR:-999}")${RESET}"
    printf '%s' "$g"
}
# Build the git segment to fit the available width — the responsive line-3 (and API line-2)
# ladder. Rungs, applied in order and only while the segment still overflows (re-measured
# after each step):
#   0  everything whole — no name cap at all, so a wide terminal shows a long branch in full
#   1  worktree and branch capped at 24 chars + …
#   2  subfolder: drop outermost ancestors one level at a time -> "…/<last k>", then the child
#      only, then truncate the child to "…/<3+ chars>…" (only while a branch renders, since
#      the point is to keep the branch visible), then drop the subfolder entirely
#   3  the branch drops its namespace (feature/etl-v2 -> etl-v2)
#   4  icons butt against their names (⑂ name -> ⑂name) — emoji icons only
#   5  the worktree and branch share what's left: the longer name shortens first, neither
#      below 3 chars + …
# The peer name, the worktree, and the branch never drop; past rung 5 the terminal clips.
# $1 = reserve: visible width already spent on this line before git (0 on line 3;
# cost+separator on API line 2). No COLUMNS (PK_BUDGET 9999) -> rung 1, the standing cap.
# Sets FIT_SEG (the segment) and FIT_CUT=1 when names had to shorten (rung 5). Not called in a
# subshell, so the caller can read both.
fit_git() {
    local reserve=${1:-0}
    local budget=$((PK_BUDGET - reserve))
    PK_G_WT=999; PK_G_BR=999; PK_G_GAP=1; PK_G_NS=1
    local seg
    FIT_CUT=0
    if [ "$PK_BUDGET" -ge 9999 ]; then PK_G_WT=24; PK_G_BR=24; FIT_SEG=$(build_git "$SUBDIR"); return; fi
    seg=$(build_git "$SUBDIR")
    [ "$(vis_width "$seg")" -le "$budget" ] && { FIT_SEG=$seg; return; }
    PK_G_WT=24; PK_G_BR=24
    seg=$(build_git "$SUBDIR")
    [ "$(vis_width "$seg")" -le "$budget" ] && { FIT_SEG=$seg; return; }
    if [ -n "$SUBDIR" ]; then
        local parts; IFS='/' read -ra parts <<< "$SUBDIR"
        local n=${#parts[@]} k
        for (( k = n - 1; k >= 1; k-- )); do
            seg=$(build_git "$(subdir_at_level "$SUBDIR" "$k")")
            [ "$(vis_width "$seg")" -le "$budget" ] && { FIT_SEG=$seg; return; }
        done
        local child=${parts[$((n-1))]}
        if [ "$SHOW_BRANCH" -eq 1 ] && [ ${#child} -gt 4 ]; then
            local t=${#child}
            while [ "$t" -gt 3 ]; do
                t=$((t-1))
                seg=$(build_git "…/${child:0:$t}…")
                [ "$(vis_width "$seg")" -le "$budget" ] && { FIT_SEG=$seg; return; }
            done
        fi
    fi
    seg=$(build_git "")                                  # subfolder gone
    [ "$(vis_width "$seg")" -le "$budget" ] && { FIT_SEG=$seg; return; }
    [ "$SHOW_BRANCH" -eq 1 ] && { PK_G_NS=0; seg=$(build_git ""); }
    [ "$(vis_width "$seg")" -le "$budget" ] && { FIT_SEG=$seg; return; }
    # Not with Material icons: Ghostty draws a Nerd Font icon two cells wide only when a space
    # follows it, and squeezes it into one cell against a letter, too small to read.
    if [ "$PK_ICONS" != "material" ]; then
        PK_G_GAP=0; seg=$(build_git "")
        [ "$(vis_width "$seg")" -le "$budget" ] && { FIT_SEG=$seg; return; }
    fi
    # Share the remainder in display cells (a capped name is its chars + 1 for the …): shorten the
    # longer name first, one cell at a time, to a floor of 4 cells (3 chars + …).
    pk_width "$seg"; local over=$(( PK_W - budget ))
    pk_width "$WORKTREE_NAME"; local wt=$PK_W wt_full=$PK_W br=0 br_full=0
    [ "$wt" -gt 24 ] && wt=25
    if [ "$SHOW_BRANCH" -eq 1 ]; then pk_width "${BRANCH##*/}"; br=$PK_W; br_full=$PK_W; [ "$br" -gt 24 ] && br=25; fi
    while [ "$over" -gt 0 ]; do
        if [ "$br" -ge "$wt" ] && [ "$br" -gt 4 ]; then br=$((br-1))
        elif [ "$wt" -gt 4 ]; then wt=$((wt-1))
        elif [ "$br" -gt 4 ]; then br=$((br-1))
        else break; fi
        over=$((over-1))
    done
    # A name cut to n cells shows n-1 cells + …; one already within its cells is left alone.
    [ "$wt" -lt "$wt_full" ] && PK_G_WT=$((wt - 1))
    [ "$SHOW_BRANCH" -eq 1 ] && [ "$br" -lt "$br_full" ] && PK_G_BR=$((br - 1))
    FIT_CUT=1
    FIT_SEG=$(build_git "")
}
fit_git 0; GIT_SEG=$FIT_SEG

# Git is never on line 1. On Pro/Max it rides line 3 (or line 2 when both windows just reset);
# on API plans it follows cost on line 2. All of that happens in the print block below.

# Line-1 width ladder. Line 1 = bar + pct% + model/context meta + cache-life. When the
# terminal narrows, the model/context adornments shed in increasing order of signal: model version
# ("4.8") first, then the effort tag abbreviates ("Medium" -> "Med"), then the context-window size
# ("1M"), then the cache countdown minutes (🔥 48m -> 🔥). The model NAME ("Opus"), the effort tag,
# the bar, pct%, and cache glyph are permanent anchors that never drop. render_line1
# composes the line at a given bar width honoring the levers; fit_line1 runs the ladder against
# PK_BUDGET, re-measuring after each rung.
render_line1() {
    local bars=$1
    local bar; bar=$(build_bar "$CTX_PERCENT" "$CTX_COLOR" "$bars" "$CTX_COLOR_DIM")
    local meta="${BOLD}${CTX_COLOR}${CTX_PERCENT}%${RESET}"
    # "of" pairs the used-% with the window size ("45% of 1M"), so it travels with the size lever.
    # Not "/": a slash means a fraction (3h / 5h), and a percent over a size isn't one.
    [ "${PK_C_SIZE:-1}" -eq 1 ] && meta+=" ${FG_DIM}of${RESET} ${BOLD}${FG_LIGHT}${CTX_WINDOW_K}${RESET}"
    local model=""
    [ "${PK_C_NAME:-1}" -eq 1 ] && model="$MODEL_NAME"
    if [ "${PK_C_VER:-1}" -eq 1 ] && [ -n "$MODEL_VER" ]; then
        if [ -n "$model" ]; then model="$model $MODEL_VER"; else model="$MODEL_VER"; fi
    fi
    [ -n "$model" ] && meta+=" ${BOLD}${FG_LIGHT}${model}${RESET}"
    # Effort tag joins the model block with a plain space (like the version/size), so it sits between
    # the model and the · that precedes the cache-life. One ladder lever: PK_E_ABBR=1 swaps the
    # full word for its short form (Medium -> Med). The tag is a permanent anchor — it abbreviates
    # but never drops (the PK_C_EFF guard is kept for the empty-effort case, never set to 0).
    if [ "${PK_C_EFF:-1}" -eq 1 ] && [ -n "$EFFORT_DISP" ]; then
        local ed="$EFFORT_DISP"
        [ "${PK_E_ABBR:-0}" -eq 1 ] && ed=$(abbr_effort "$ed")
        meta+=" ${FG_LIGHT}${ed}${RESET}"
    fi
    # Cache-life hangs off a separator; PK_C_SEP=0 collapses the dot to plain spacing.
    local sep="$SEP"
    [ "${PK_C_SEP:-1}" -eq 0 ] && sep="$SEP_NARROW"
    [ "${PK_C_SEP:-1}" -eq 2 ] && sep=" "
    local out="${meta}"
    [ -n "$bar" ] && out="${bar} ${meta}"
    build_cache                                   # honors PK_K_ABBR, so re-render per ladder pass
    [ -n "$CACHE_BODY" ] && out+="${sep}${CACHE_BODY}"
    printf '%s' "$out"
}
fit_line1() {
    local bars=$1
    PK_C_VER=1; PK_C_NAME=1; PK_C_SIZE=1; PK_C_SEP=1; PK_C_EFF=1; PK_E_ABBR=0; PK_K_ABBR=0; PK_K_GAP=1
    LINE1=$(render_line1 "$bars")
    [ "$PK_BUDGET" -ge 9999 ] && return                       # no COLUMNS -> full width, as before
    [ "$(vis_width "$LINE1")" -le "$PK_BUDGET" ] && return     # already fits -> nothing to shed
    # Line 1 must always say how full context is (the colored %), which model and effort this
    # session runs, and how long the cache stays warm (🔥 minutes, or the blue ❄️). Support sheds
    # first, re-measured after each step:
    #   1. the · before the cache        2. the word "cold" (❄️ cold -> ❄️; the snowflake says it)
    #   3. context size (of 1M)          4. effort shortens (Medium->Med)   5. model version (4.8)
    #   6. bar 5->3 (API plans; on Pro/Max line 2 did it)            7. one space before the cache
    #   8. the context bar (the colored % says the same)   9. 🔥 48m -> 🔥48m (emoji icons)
    [ "$(vis_width "$LINE1")" -gt "$PK_BUDGET" ] && { PK_C_SEP=0;   LINE1=$(render_line1 "$bars"); }
    [ "$(vis_width "$LINE1")" -gt "$PK_BUDGET" ] && { PK_K_ABBR=1;  LINE1=$(render_line1 "$bars"); }
    [ "$(vis_width "$LINE1")" -gt "$PK_BUDGET" ] && { PK_C_SIZE=0;  LINE1=$(render_line1 "$bars"); }
    [ "$(vis_width "$LINE1")" -gt "$PK_BUDGET" ] && { PK_E_ABBR=1;  LINE1=$(render_line1 "$bars"); }
    [ "$(vis_width "$LINE1")" -gt "$PK_BUDGET" ] && { PK_C_VER=0;   LINE1=$(render_line1 "$bars"); }
    [ "$(vis_width "$LINE1")" -gt "$PK_BUDGET" ] && [ "$bars" -gt 3 ] && { bars=3; LINE1=$(render_line1 "$bars"); }
    [ "$(vis_width "$LINE1")" -gt "$PK_BUDGET" ] && { PK_C_SEP=2;   LINE1=$(render_line1 "$bars"); }
    [ "$(vis_width "$LINE1")" -gt "$PK_BUDGET" ] && { bars=0;       LINE1=$(render_line1 "$bars"); }
    [ "$(vis_width "$LINE1")" -gt "$PK_BUDGET" ] && { PK_K_GAP=0;   LINE1=$(render_line1 "$bars"); }
}
fit_line1 5

# Render one rate-limit window segment: bar, usage%, pace, elapsed-into-window, label.
# Args: $1=usage pct (raw), $2=reset epoch, $3=window total secs, $4=label (5h/7d)
#
# Reset-passed-while-idle: the statusline reads a frozen JSON snapshot whose resets_at can
# fall into the past when the session sits idle across a window boundary. The window has
# really rolled over, so the snapshot's usage% is stale (it describes the PREVIOUS window).
# We know the new window's elapsed precisely (now − last reset, mod window) but NOT its
# usage — no API call has refreshed it. So rather than fabricate a 0% or show the stale
# old %, render the window with a dim-green empty bar, its clock, and no fill or pace: "this window
# just reset — its real number returns on your next message". The bar is dim green (SUCCESS_DIM),
# not neutral gray, so the state reads as a fresh window rather than a broken/blank one. (A ↻
# glyph used to mark it; dropped 2026-10-15 — the empty bar and missing pace already say it.)
# The limits are account-wide, so
# a freshly-reset window's usage is genuinely unknown (another session may have spent it), not
# zero. It self-corrects on the next message (which pulls a fresh snapshot). NOW_EPOCH is
# computed once by the caller so both windows judge "passed" against the same instant.
render_window() {
    local usage_raw=$1 reset=$2 total=$3 label=$4
    local usage; usage=$(printf '%.0f' "$usage_raw")
    # Endgame threshold — how close to reset before the label spends width on minutes.
    # Only the 5h window ever reaches it in an hours-shaped label: by the time the 7d has
    # hours left it is six days in, and the XdYh form carries no minutes (see format_elapsed).
    local mins_below=3600
    # What a window must always say: WHICH window (the 5h/7d label) and whether you'll run out
    # before it resets (the colored, signed pace). Everything else is support that the line-2
    # ladder sheds as width runs out:
    #   PK_W_FILL=0    drop the fill % (the bar already shows it)
    #   PK_W_PARENS=0  drop the pace parentheses (with the fill gone they set nothing apart)
    #   PK_W_BARS=0    drop the bar (color + pace carry the risk; the limits are account-wide, so
    #                  every pane repeats them, and the bar is the first thing a narrow pane spares)
    #   PK_W_TIGHT=1   "3h / 5h" -> "3h/5h"
    #   PK_W_ELAPSED=0 drop the elapsed clock; the label moves to the front: "5h +1%"
    local color pace color_dim remaining reset_now=0
    if [ -n "$reset" ] && [ "$NOW_EPOCH" -ge "$reset" ]; then
        reset_now=1
        remaining=$(( total - (NOW_EPOCH - reset) % total ))
        color="$SUCCESS_DIM"; color_dim="$SUCCESS_DIM"
    else
        remaining=$(secs_until "$reset")
        read color pace <<< "$(velocity_info "$usage" "$remaining" "$total")"
        color_dim=$(velocity_info_dim "$usage" "$remaining" "$total")
    fi
    local elapsed_text; elapsed_text=$(format_elapsed "$remaining" "$total" "$mins_below")
    local bar=""
    if [ "$reset_now" -eq 1 ]; then bar=$(build_bar 0 "$SUCCESS_DIM" "${PK_W_BARS:-5}" "$SUCCESS_DIM")
    else bar=$(build_bar "$usage" "$color" "${PK_W_BARS:-5}" "$color_dim"); fi
    # The signal: the colored signed pace, with the fill % ahead of it while there's room. A window
    # that reset while idle has none (its usage is unknown until the next message).
    local sig=""
    if [ "$reset_now" -eq 0 ]; then
        local sign=""; [ "$pace" -ge 0 ] && sign="+"
        sig="${BOLD}${color}${sign}${pace}%${RESET}"
        [ "${PK_W_PARENS:-1}" -eq 1 ] && sig="(${sig})"
        [ "${PK_W_FILL:-1}" -eq 1 ] && sig="${color_dim}${usage}%${RESET} ${sig}"
    fi
    local lab="${FG_LIGHT}${label}${RESET}"
    if [ "${PK_W_ELAPSED:-1}" -eq 0 ]; then
        if [ -n "$sig" ]; then printf '%s' "${lab} ${sig}"; else printf '%s' "$lab"; fi   # minimum
        return
    fi
    local slash=" ${FG_DIM}/${RESET} "; [ "${PK_W_TIGHT:-0}" -eq 1 ] && slash="${FG_DIM}/${RESET}"
    local out="${FG_LIGHT}${elapsed_text:-}${RESET}${slash}${lab}"
    [ -n "$sig" ] && out="${sig} ${out}"
    [ -n "$bar" ] && out="${bar} ${out}"
    printf '%s' "$out"
}

# Line 2 — rendered when at least one rate-limit window is present (Pro/Max plans). A plan
# with no 5h limit sends only seven_day, so line 2 shows the 7d window alone. On non-Pro/Max
# plans both fields are absent and the line is hidden entirely.
#
# Layout is fixed (no toggle): line 2 = both rate-limit windows, line 3 = git. Git always
# has a reliable home on line 3 — Claude Code renders its own permission-mode indicator on a
# separate row BELOW the statusline, so a third statusline line is not clobbered. The one
# exception is the both-windows-just-reset case: two unmeasured windows say nothing, so
# git takes line 2 that turn and there is no line 3 (see the both-reset block below).
# Update notice. Once a day, in the background so the line never waits, read the latest version
# number from the repo's plugin.json: one small file, nothing downloaded or run. The answer and when
# it was asked live in pacekit/latest-version as "<epoch> <version>"; the time is stamped before
# asking, so a failed check also waits a day. While a newer version is out, line 1 says so until the
# session's title arrives, with the command that updates this install. PACEKIT_UPDATE_CHECK=off
# turns it all off.
PK_VER_RE='^[0-9]+(\.[0-9]+)*$'
pk_newer() {   # $1 > $2, numerically part by part (1.10 > 1.9, 1.0 == 1.0.0); junk is never newer
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
UPDATE_LINE=""
if [ "${PACEKIT_UPDATE_CHECK:-on}" != "off" ]; then
    PK_UPD_FILE="$CLAUDE_DIR/pacekit/latest-version"
    PK_UPD_AT=0; PK_UPD_VER=""
    [ -f "$PK_UPD_FILE" ] && read -r PK_UPD_AT PK_UPD_VER < "$PK_UPD_FILE" 2>/dev/null
    case "$PK_UPD_AT" in ''|*[!0-9]*) PK_UPD_AT=0 ;; esac
    PK_UPD_NOW=$(now_epoch)
    if [ $((PK_UPD_NOW - PK_UPD_AT)) -ge 86400 ]; then
        mkdir -p "$CLAUDE_DIR/pacekit" 2>/dev/null
        printf '%s %s\n' "$PK_UPD_NOW" "$PK_UPD_VER" > "$PK_UPD_FILE" 2>/dev/null
        PK_UPD_URL=${PACEKIT_UPDATE_URL:-https://raw.githubusercontent.com/jasonericsiegel/pacekit-statusline/main/.claude-plugin/plugin.json}
        (
            v=$(curl -fsSL --max-time 5 "$PK_UPD_URL" 2>/dev/null | jq -r '.version // empty' 2>/dev/null | tr -d '\r')
            if [[ $v =~ $PK_VER_RE ]]; then
                printf '%s %s\n' "$PK_UPD_NOW" "$v" > "$PK_UPD_FILE.$$" && mv "$PK_UPD_FILE.$$" "$PK_UPD_FILE"
            fi
        ) </dev/null >/dev/null 2>&1 &
    fi
    if [ -z "$SESSION_TITLE" ] && pk_newer "$PK_UPD_VER" "$PACEKIT_VERSION"; then
        PK_UPD_DO="run its install line again"
        for _d in "$CLAUDE_DIR"/plugins/cache/*/pacekit; do [ -d "$_d" ] && PK_UPD_DO="run /pacekit:setup update"; done
        for _u in "🆕 Pacekit $PK_UPD_VER is out · $PK_UPD_DO" "🆕 Pacekit $PK_UPD_VER is out" "🆕 $PK_UPD_VER"; do
            if [ "$(vis_width "$_u")" -le "$PK_BUDGET" ]; then UPDATE_LINE=$_u; break; fi
        done
    fi
fi

# The session title, when there is one, goes on top of all of them in the model name's style,
# cut with … to the width budget.
# A title drawn elsewhere drops this line when the configured pacekit-hide-title flag exists.
if [ -n "$SESSION_TITLE" ] && [ "$PK_BUDGET" -gt 0 ] && [ ! -e "$CLAUDE_DIR/pacekit-hide-title" ]; then
    _t=$SESSION_TITLE
    pk_width "$_t"; if [ "$PK_W" -gt "$PK_BUDGET" ]; then pk_cut "$_t" $((PK_BUDGET - 1)); _t="${PK_CUT}…"; fi
    printf '%s\n' "${BOLD}${FG_LIGHT}${_t}${RESET}"
elif [ -n "$UPDATE_LINE" ]; then
    printf '%s\n' "${INFO}${UPDATE_LINE}${RESET}"
fi
if [ -n "$FIVE_H_PCT" ] || [ -n "$SEVEN_D_PCT" ]; then
    NOW_EPOCH=$(now_epoch)
    build_limits() {                                # rebuildable so the ladder can re-render both windows
        FIVE_SEG=""; SEVEN_SEG=""
        [ -n "$FIVE_H_PCT" ]  && FIVE_SEG=$(render_window "$FIVE_H_PCT" "$FIVE_H_RESET" "$FIVE_H_TOTAL" "5h")
        [ -n "$SEVEN_D_PCT" ] && SEVEN_SEG=$(render_window "$SEVEN_D_PCT" "$SEVEN_D_RESET" "$SEVEN_D_TOTAL" "7d")
        local sep="$SEP"; [ "${PK_W_SEP:-1}" -eq 0 ] && sep="$SEP_NARROW"
        if [ -n "$FIVE_SEG" ] && [ -n "$SEVEN_SEG" ]; then LIMITS_SEG="${FIVE_SEG}${sep}${SEVEN_SEG}"
        else LIMITS_SEG="${FIVE_SEG}${SEVEN_SEG}"; fi
    }
    # Width-aware line-2 ladder. Each step applies to BOTH windows together and fires only if line 2
    # still overflows; support goes before signal (see render_window): 1) bars 5->3  2) fill %
    # 3) pace parentheses  4) bars  5) "3h / 5h" -> "3h/5h"  6) the · between windows
    # 7) elapsed clocks, leaving "5h +1%  7d -68%". The label and the colored pace never drop.
    PK_W_FILL=1; PK_W_BARS=5; PK_W_SEP=1; PK_W_PARENS=1; PK_W_TIGHT=0; PK_W_ELAPSED=1; build_limits
    if [ "$PK_BUDGET" -lt 9999 ]; then
        [ "$(vis_width "$LIMITS_SEG")" -gt "$PK_BUDGET" ] && { PK_W_BARS=3;    build_limits; }
        [ "$(vis_width "$LIMITS_SEG")" -gt "$PK_BUDGET" ] && { PK_W_FILL=0;    build_limits; }
        [ "$(vis_width "$LIMITS_SEG")" -gt "$PK_BUDGET" ] && { PK_W_PARENS=0;  build_limits; }
        [ "$(vis_width "$LIMITS_SEG")" -gt "$PK_BUDGET" ] && { PK_W_BARS=0;    build_limits; }
        [ "$(vis_width "$LIMITS_SEG")" -gt "$PK_BUDGET" ] && { PK_W_TIGHT=1;   build_limits; }
        [ "$(vis_width "$LIMITS_SEG")" -gt "$PK_BUDGET" ] && { PK_W_SEP=0;     build_limits; }
        [ "$(vis_width "$LIMITS_SEG")" -gt "$PK_BUDGET" ] && { PK_W_ELAPSED=0; build_limits; }
    fi
    # Bar size is shared — the line-1 context bar shrinks 5->3 with the window bars, then re-runs
    # its own ladder at that size. When the window bars drop entirely the context bar stays at 3:
    # context is this session's own signal, while the limits repeat in every pane.
    _ctx_bars=$PK_W_BARS; [ "$_ctx_bars" -lt 3 ] && _ctx_bars=3
    fit_line1 "$_ctx_bars"

    # Fixed layout: windows hold line 2, git rides line 3 (show=1). The only exception is
    # every present window just reset while idle (a missing window counts as reset) -> both usages are unknown (account-wide, not
    # re-measured). Two unmeasured windows say nothing useful, so git takes line 2 that turn and
    # there is no line 3 (show=0). The empty-GIT_SEG guard below still falls back to the two reset
    # windows when there is no repo.
    show=1
    _reset5=0; _reset7=0
    if [ -z "$FIVE_H_PCT" ] || { [ -n "$FIVE_H_RESET" ] && [ "$NOW_EPOCH" -ge "$FIVE_H_RESET" ]; }; then _reset5=1; fi
    if [ -z "$SEVEN_D_PCT" ] || { [ -n "$SEVEN_D_RESET" ] && [ "$NOW_EPOCH" -ge "$SEVEN_D_RESET" ]; }; then _reset7=1; fi
    if [ "$_reset5" -eq 1 ] && [ "$_reset7" -eq 1 ]; then
        show=0
    fi

    # Empty GIT_SEG (no repo) -> fall back to limits rather than render a blank line 2.
    LINE3=""
    if [ "$show" -eq 1 ] || [ -z "$GIT_SEG" ]; then
        LINE2="$LIMITS_SEG"
        # Windows hold line 2; git gets its own reliable line 3 (Claude Code's permission-mode
        # indicator renders on a separate row below the statusline, so line 3 is not clobbered).
        [ -n "$GIT_SEG" ] && LINE3="$GIT_SEG"
    else
        LINE2="$GIT_SEG"
    fi
    if [ -n "$LINE3" ]; then
        printf "%s\n%s\n%s\n" "$LINE1" "$LINE2" "$LINE3"
    else
        printf "%s\n%s\n" "$LINE1" "$LINE2"
    fi
else
    # API / pay-as-you-go: no rate-limit windows, so line 2 is free. Cost leads it (own cyan),
    # git follows. Line 1 stays clean (context, model, idle, label). No line 3. When there is
    # neither cost nor git, fall back to a single line 1 — exactly the original behavior.
    LINE2=""
    if [ -n "$COST_TEXT" ]; then
        COST_SEG="${BOLD}${FG_LIGHT}${COST_TEXT}${RESET}"
        LINE2="$COST_SEG"
        # Git shares line 2 with cost here, so re-fit it against the width cost already
        # spent (cost segment + separator) rather than the whole line — keeps line 2 in budget.
        # If sharing would shorten the worktree or branch names, git takes its own line 3 instead:
        # who and where this session is outranks keeping the statusline to two lines.
        _solo=$GIT_SEG
        fit_git $(( $(vis_width "$COST_SEG") + $(vis_width "$SEP") ))
        if [ "$FIT_CUT" -eq 1 ]; then LINE3=$_solo; GIT_SEG=""; else GIT_SEG=$FIT_SEG; fi
    fi
    if [ -n "$GIT_SEG" ]; then
        if [ -n "$LINE2" ]; then LINE2="${LINE2}${SEP}${GIT_SEG}"; else LINE2="$GIT_SEG"; fi
    fi
    if [ -n "${LINE3:-}" ]; then
        printf "%s\n%s\n%s\n" "$LINE1" "$LINE2" "$LINE3"
    elif [ -n "$LINE2" ]; then
        printf "%s\n%s\n" "$LINE1" "$LINE2"
    else
        printf "%s\n" "$LINE1"
    fi
fi
