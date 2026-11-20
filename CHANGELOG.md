# Changelog

## 1.1.0 (2026-11-20)

### Added

- Plugin installs now update themselves. Once Claude Code has the new plugin version, Pacekit installs its status line at the start of your next session, so you no longer run `/pacekit:setup update`. It replaces only the copy `/pacekit:setup` installed, never goes back a version, and leaves your settings alone. To keep the version you have, create an empty file at `~/.claude/pacekit-no-auto-update`.

### Fixed

- Chinese, Japanese and Korean characters now count as two columns, the width terminals draw them, so a title, folder or branch name in those languages fits a narrow pane instead of running past its edge. Two columns go to Unicode's East Asian Wide and Fullwidth characters: CJK ideographs and radicals, Hiragana, Katakana, Bopomofo, Hangul, Yi, CJK punctuation and vertical forms, and fullwidth letters and signs. Emoji in names, other than the ones Pacekit draws itself, still count as one.

## 1.0.0 (2026-11-17)

Pacekit's own repository and first release as a plugin. Everything below changed since 0.2.

### Added

- A one-line installer, `install.sh`, that copies the script to `~/.claude/pacekit/` and points Claude Code's `statusLine` setting at it. It keeps your other settings, saves the status line it replaces, and brings that one back with `--uninstall`.
- A Claude Code plugin with a `/pacekit:setup` command that runs the same installer.
- A notice on line 1 (`🆕 Pacekit 1.1.0 is out`) when a newer version is out, with the command that updates your install. Pacekit checks GitHub for the version number once a day, in the background. `PACEKIT_UPDATE_CHECK=off` turns it off. `install.sh --update` and `/pacekit:setup update` fetch the newest script.
- The session's title as a new top line: your `/rename` name, otherwise Claude Code's own title, read from what Claude Code passes in (or its transcript on older versions). Create `~/.claude/pacekit-hide-title` to turn it off.
- A prompt-cache countdown (`🔥 48m`) that counts down while you're away and walks the pace colors as the cache runs low, then shows a bold blue `❄️ cold`.
- The session's name (`👤 fd`) at the start of the git line, so side-by-side sessions are easy to tell apart.
- Nerd Font icons in Ghostty, which take the line's colors. `PACEKIT_ICONS` picks a set by hand.
- Weekly-only plans: when Claude Code sends only the 7-day window, it shows alone.
- `PACEKIT_STAMPS=off` to stop the two usage files, and `PACEKIT_CTX_DIR` to move the context one.
- Support for `CLAUDE_CONFIG_DIR`, Windows' Git Bash (built, not yet tested), and Linux systems without a US English locale.

### Changed

- Each line now keeps its answer at narrow widths: the colored context %, model, effort, and cache minutes; each window's label and colored pace; the session, worktree, and branch. Long names show in full on wide terminals.
- Elapsed time reads in whole hours mid-window (`2h / 5h`). Minutes show only in the first hour of a window and the last hour of the 5-hour one.
- The context size reads `45% of 1M`, so a slash only ever means a fraction of a window.
- A window that reset while you were idle shows an empty dim bar and its clock, with no pace, instead of the `↻` glyph.
- Session cost is bold light gray instead of cyan, so color only ever means status. It stays hidden on subscriptions, including before the first reply.
- Lines fit to the terminal width minus 4, the columns Claude Code keeps for itself. `PACEKIT_MARGIN` changes it.
- The empty part of a red or violet bar is a darker shade of its color, so a nearly empty bar no longer looks full.

### Removed

- The idle-wait indicator (🖐️) and the shortened session label on line 1. The new title line replaces the label.

### Fixed

- Narrow lines spilling past the edge: 🔥 and 👤 now count as two columns.
- Folder names, titles, or paths containing backslashes could break the line.
- A folder reached through a symlink, or one with `[` in its name, showed its full path as the subfolder.
- Windows' jq added stray characters to every value.
- Session lookup failed when the home folder's path had a space in it.
- A very narrow window with a title showing could print an error.
- Durations no longer show a zero unit (`4h0m` is `4h`).

## 0.2 (2026-06-30)

### Added
- **Effort tag** — the session's reasoning effort (`.effort.level`) renders as a light-gray tag (normal weight, secondary to the model) right after the model on line 1 (`Opus 4.8 High`), capitalized as `Low`/`Medium`/`High`/`XHigh`/`Max`. It reflects the live in-session value, including mid-session `/effort` changes, and is hidden entirely on models that don't support the effort parameter. Under width pressure (gated on a dominant session label) it abbreviates but never disappears: after the model version drops, a long level **shortens** (`Medium` → `Med`, any word over four chars → its first three, so future levels never break), but the tag itself is a permanent anchor like the model name — it is never dropped, so the effort signal is always visible. The model name stays anchored throughout.
- **Three-line layout on Pro/Max** — context on line 1, both rate-limit windows on line 2, and git on its own line 3. Line 3 is a reliable home for git because Claude Code draws its permission-mode indicator on a separate row *below* the statusline. On a pay-as-you-go API plan there are no rate-limit windows, so it stays two lines: a clean line 1, with session cost (leading) and git on line 2.
- **Width-responsive compression** — on every render the statusline measures each line against the terminal width (`COLUMNS`, on Claude Code v2.1.153+) and compresses only the lines that overflow, only as far as they need, with no fixed breakpoints and no state kept between renders. Each line sheds its own least-important details first: **line 1** stays intact until a long session label crowds it (the label is ≥ half the line), then drops the model version (`4.8`) and finally the context-window size (`1M`) — the model name (`Opus`) is a permanent anchor that never disappears; **line 2** shrinks its bars 5→3 first (cheap, big recovery — and global, so the context bar shrinks too), then drops the fill %, then the 5h/7d totals; **line 3** (git) compresses only the subfolder — shedding ancestor folders one level at a time (a leading `…/` marks the hidden ones), then truncating the child folder's own characters (only while a branch is present to keep in view), then dropping the subfolder entirely — never the worktree or branch. As a final squeeze, the `·` segment separator collapses to plain spacing on any line that still overflows. A bar's color, its pace, and the front-loaded session label itself never compress. Older Claude Code without `COLUMNS` renders full width as before.
- **Idle-wait indicator** — a `🖐️` and elapsed-time token on line 1 showing how long the session has been waiting on you; appears only while Claude is idle and clears on your next prompt (backed by silent `Stop`/`UserPromptSubmit` hooks keyed by session id).
- **Session-title shortening** — drops the leading verb and any consecutive leading connectives, prepositions, or particles from Claude Code's auto-generated title so the distinguishing words lead (e.g. "Read from Mac Notes app" → "Mac Notes app", "Optimize session title format" → "Session title format"). Only *leading* particles are dropped — a mid-title preposition is preserved ("Switch from Anthropic API **to** subscription" → "Anthropic API to subscription") — and a title that is an interrogative or nothing but a verb plus particles is left intact; the shortener never emits a leading particle or an empty label.
- **Session cost for API plans** — estimated cost in its own cyan, shown **only for API / pay-as-you-go users** where `total_cost_usd` is real spend; suppressed on Pro/Max subscriptions, where it's only an API-equivalent token estimate.
- Fully responsive subdirectory path — shown in full when it fits (`code/acme-api/src/handlers`), then sheds folders outermost-first as the terminal narrows (`…/src/handlers` → `…/handlers`), truncates the child folder to a 3-letter stem only to keep a branch visible (`…/han…`), and drops the subfolder entirely as a last resort — and a 24-character cap (with ellipsis) on long worktree and branch names.
- End-to-end test harness (`test_statusline.sh`).
- **Context-usage stamp** — every render writes the live context-window fill (`<pct> <size> <epoch>`) to `/tmp/pacekit-ctx-<session_id>`, so other tools can read the budget the model can't see itself.

### Changed
- Rate-limit windows now show time **elapsed** into each window (counting up toward `5h`/`7d`) instead of time-until-reset, matching the pace indicators.
- **Honest reset handling** — when a window's reset time has passed in the frozen idle snapshot, the (now stale) usage % is replaced with a cycle glyph `↻` and a dim-green empty bar, while the elapsed clock keeps counting into the new window. Because the limits are account-wide, a freshly-reset window's usage is genuinely unknown (not zero), so the `↻` is honest where a `0%` would mislead; the dim green keeps the state from reading as a broken or blank window. Self-corrects on your next message when a fresh snapshot arrives. When **both** windows are just-reset at once, git takes line 2 that turn and there is no line 3 — falling back to the two `↻` windows only when there's no repo info to show.

### Security
- Numeric-only validation of `total_cost_usd` before it enters arithmetic / awk, preventing shell injection via crafted statusline JSON.

## 0.1 (2026-05-05)

### Added
- Two-line statusline showing context usage, 5-hour window, 7-day window, model, worktree, subdirectory, and git branch
- Threshold-colored context fill bar (green < 40%, yellow 40–49%, red 50–59%, violet ≥ 60%)
- Velocity-colored rate-limit bars based on pace = `(usage% / elapsed%) − 1` (green ≤ -10%, yellow -10–0%, red 0–10%, violet > 10%)
- Pace number displayed alongside each rate-limit window (e.g. `(-25%)`, `(+46%)`)
- Time-until-reset display for both 5h and 7d windows
- Auto-hide of line 2 on non-Pro/Max plans (when rate-limit fields aren't sent)
- Worktree basename + subdirectory + branch display, with branch hidden when it duplicates the worktree name
