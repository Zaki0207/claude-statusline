#!/bin/sh
# Claude Code status line (two lines):
#   Line 1: model | effort  |  Ctx: used/total (pct%) [████░░░░]  |  Tokens: cumIn↑ cumOut↓  cache: X%
#   Line 2: cwd  [git-branch]  |  5h: X% [████░░░░] reset: HH:MM  |  7d: Y% [████░░░░] reset: MM-DD HH:MM
#
# Note on token fields:
#   total_input_tokens  = cumulative session input (grows each turn) — shown as ↑
#   output tokens       = locally accumulated per session via /tmp file — shown as ↓
#   cache: = cache hit rate (cache_read / total_input * 100)

input=$(cat)

# ANSI color codes
COLOR_GREEN='\033[32m'
COLOR_YELLOW='\033[33m'
COLOR_RED='\033[31m'
COLOR_RESET='\033[0m'
COLOR_CYAN='\033[36m'
COLOR_MAGENTA='\033[35m'
COLOR_BLUE='\033[34m'
COLOR_DARK_GRAY='\033[90m'
COLOR_WHITE='\033[97m'

# ── Helper: pick color based on percentage ─────────────────────────────────
# Usage: pick_color <pct_integer>
# Prints the ANSI escape for the appropriate color.
pick_color() {
  _pct=$1
  if [ "$_pct" -ge 80 ]; then
    printf '%s' "$COLOR_RED"
  elif [ "$_pct" -ge 50 ]; then
    printf '%s' "$COLOR_YELLOW"
  else
    printf '%s' "$COLOR_GREEN"
  fi
}

# ── Helper: render a progress bar ─────────────────────────────────────────
# Usage: make_bar <pct_integer> <width>
# Returns a colored string like: \033[32m████░░░░\033[0m
make_bar() {
  _pct=$1
  _width=$2
  _filled=$(( _pct * _width / 100 ))
  _empty=$(( _width - _filled ))
  _color=$(pick_color "$_pct")
  _bar=""
  _i=0
  while [ "$_i" -lt "$_filled" ]; do
    _bar="${_bar}█"
    _i=$(( _i + 1 ))
  done
  _i=0
  while [ "$_i" -lt "$_empty" ]; do
    _bar="${_bar}░"
    _i=$(( _i + 1 ))
  done
  printf '%b%s%b' "$_color" "$_bar" "$COLOR_RESET"
}

# ── 1. Working directory (shorten $HOME to ~) ──────────────────────────────
cwd=$(echo "$input" | jq -r '.cwd // .workspace.current_dir // empty')
if [ -n "$cwd" ]; then
  home="$HOME"
  case "$cwd" in
    "$home"*) cwd="~${cwd#$home}" ;;
  esac
fi

# ── 2. Git branch (skip optional locks to avoid hanging) ──────────────────
git_branch=""
if [ -n "$cwd" ]; then
  real_cwd=$(echo "$cwd" | sed "s|^~|$HOME|")
  git_branch=$(git -C "$real_cwd" --no-optional-locks symbolic-ref --short HEAD 2>/dev/null)
fi

# ── 3. Model + effort ─────────────────────────────────────────────────────
model=$(echo "$input" | jq -r '.model.id // empty')
# Strip "claude-" prefix for brevity (e.g. claude-sonnet-4-6 → sonnet-4-6)
if [ -n "$model" ]; then
  model=$(echo "$model" | sed 's/^claude-//')
fi
effort_level=$(echo "$input" | jq -r '.effort.level // empty')
thinking_tokens=$(echo "$input" | jq -r '.context_window.current_usage.thinking_tokens // empty')
if [ -n "$model" ] && [ -n "$effort_level" ]; then
  model="$model | effort: $effort_level"
fi

# ── 4. Context window ─────────────────────────────────────────────────────
used_pct=$(echo "$input" | jq -r '.context_window.used_percentage // empty')
ctx_total=$(echo "$input" | jq -r '.context_window.context_window_size // empty')
ctx_used=$(echo "$input"  | jq -r '.context_window.total_input_tokens // empty')

# ── 5. Token statistics (current turn, from the most recent API response) ──
# Every value reflects the latest turn only. Claude Code no longer exposes
# session-cumulative totals (total_input_tokens became current-context as of
# v2.1.132), so we display the per-turn figures it provides directly and never
# accumulate locally.
#   total_input_tokens  = total input this turn (input + cache_creation + cache_read)  → ↑
#   total_output_tokens = output tokens from the most recent response                  → ↓
#   current_usage.*     = per-component breakdown of the same turn (used for cache %)
turn_in=$(echo "$input"  | jq -r '.context_window.total_input_tokens // empty')
turn_out=$(echo "$input" | jq -r '.context_window.total_output_tokens // .context_window.current_usage.output_tokens // empty')
cur_in=$(echo "$input"   | jq -r '.context_window.current_usage.input_tokens // empty')
cache_read=$(echo "$input"  | jq -r '.context_window.current_usage.cache_read_input_tokens // empty')
cache_write=$(echo "$input" | jq -r '.context_window.current_usage.cache_creation_input_tokens // empty')

# ── Helper: format token count (>= 1000 → X.Xk) ──────────────────────────
fmt_tokens() {
  _n=$1
  if [ "$_n" -ge 1000 ] 2>/dev/null; then
    printf '%.1fk' "$(echo "$_n / 1000" | bc -l)"
  else
    printf '%s' "$_n"
  fi
}

# ── 5b. Thinking tokens (appended to model string after fmt_tokens is defined) ──
if [ -n "$thinking_tokens" ] && [ "$thinking_tokens" -gt 0 ] 2>/dev/null; then
  think_fmt=$(fmt_tokens "$thinking_tokens")
  model="$model | think: $think_fmt"
fi

# ── 5c. Cache read share ───────────────────────────────────────────────────
# Share of this turn's input that came from cache reads (cheap), not a prefix
# hit rate. Denominator is the full current-turn input, summed from the three
# current_usage components so it stays self-consistent and avoids depending on
# total_input_tokens (null before the first API call; historically ambiguous).
#   cache_read / (input + cache_creation + cache_read) * 100
# Shown whenever caching is active this turn (any reads or writes), so a cold
# turn that only writes cache correctly reads 0% instead of vanishing.
cache_hit_str=""
_ci=${cur_in:-0}; _cw=${cache_write:-0}; _cr=${cache_read:-0}
if { [ "$_cr" -gt 0 ] 2>/dev/null || [ "$_cw" -gt 0 ] 2>/dev/null; }; then
  cache_total_in=$(( _ci + _cw + _cr ))
  if [ "$cache_total_in" -gt 0 ] 2>/dev/null; then
    cache_hit_pct=$(awk "BEGIN { printf \"%.0f\", ($_cr / $cache_total_in) * 100 }")
    cache_hit_str=$(printf '%bcache:%b %s%%' "$COLOR_DARK_GRAY" "$COLOR_RESET" "$cache_hit_pct")
  fi
fi

# ── 5d. Session cost ───────────────────────────────────────────────────────
# Use Claude Code's own client-side estimate (cost.total_cost_usd) rather than
# re-deriving it from token counts. Self-derivation double-counts cache tokens
# (total_input_tokens already includes cache_read + cache_creation) and mixes
# per-turn context counts with the locally accumulated output total.
cost_str=""
total_cost=$(echo "$input" | jq -r '.cost.total_cost_usd // empty')
if [ -n "$total_cost" ]; then
  cost_str=$(awk -v cost="$total_cost" \
    'BEGIN {
      # Color thresholds
      GREEN  = "\033[32m"
      YELLOW = "\033[33m"
      RED    = "\033[31m"
      RESET  = "\033[0m"

      if (cost >= 2.0) {
        color = RED
      } else if (cost >= 0.5) {
        color = YELLOW
      } else {
        color = GREEN
      }

      if (cost > 0 && cost < 0.01) {
        printf "%s<$0.01%s", color, RESET
      } else {
        printf "%s$%.2f%s", color, cost, RESET
      }
    }')
fi

# ── 6. Rate limits ────────────────────────────────────────────────────────
five_pct=$(echo "$input" | jq -r '.rate_limits.five_hour.used_percentage // empty')
week_pct=$(echo "$input" | jq -r '.rate_limits.seven_day.used_percentage // empty')
five_resets_at=$(echo "$input" | jq -r '.rate_limits.five_hour.resets_at // empty')
week_resets_at=$(echo "$input" | jq -r '.rate_limits.seven_day.resets_at // empty')

# ── 6. Reset times ────────────────────────────────────────────────────────
# 5h: HH:MM only
five_reset_time=""
if [ -n "$five_resets_at" ]; then
  five_reset_time=$(date -r "$five_resets_at" +%H:%M 2>/dev/null)
fi
# 7d: MM-DD HH:MM (date + time, since it's days away)
week_reset_time=""
if [ -n "$week_resets_at" ]; then
  week_reset_time=$(date -r "$week_resets_at" +"%m-%d %H:%M" 2>/dev/null)
fi

# ═══════════════════════════════════════════════════════════════════════════
# Build output
# ═══════════════════════════════════════════════════════════════════════════

BAR_WIDTH=8
SEP=$(printf '  %b|%b  ' "$COLOR_DARK_GRAY" "$COLOR_RESET")

# Section 1+2: directory and optional branch
dir_branch=$(printf '%b%s%b' "$COLOR_CYAN" "$cwd" "$COLOR_RESET")
if [ -n "$git_branch" ]; then
  dir_branch="$dir_branch  $(printf '%b[%s]%b' "$COLOR_MAGENTA" "$git_branch" "$COLOR_RESET")"
fi

# Section 4: context window with progress bar
ctx_str=""
if [ -n "$used_pct" ]; then
  pct_int=$(printf '%.0f' "$used_pct")
  bar=$(make_bar "$pct_int" "$BAR_WIDTH")
  color=$(pick_color "$pct_int")
  if [ -n "$ctx_total" ] && [ -n "$ctx_used" ]; then
    ctx_k=$(printf '%.0f' "$(echo "$ctx_used / 1000" | bc -l)")
    total_k=$(printf '%.0f' "$(echo "$ctx_total / 1000" | bc -l)")
    ctx_str=$(printf "Ctx: ${color}%sk/%sk (%s%%)${COLOR_RESET} [%b]" \
      "$ctx_k" "$total_k" "$pct_int" "$bar")
  else
    ctx_str=$(printf "Ctx: ${color}%s%%${COLOR_RESET} [%b]" "$pct_int" "$bar")
  fi
fi

# Section 5: token statistics (current turn)
# Tokens: <input>↑  <output>↓  cache: X%
# Each arrow is this turn's figure; nothing is accumulated across turns.
token_str=""

_in_pos=0;  [ "${turn_in:-0}"  -gt 0 ] 2>/dev/null && _in_pos=1
_out_pos=0; [ "${turn_out:-0}" -gt 0 ] 2>/dev/null && _out_pos=1
if [ "$_in_pos" -eq 1 ] || [ "$_out_pos" -eq 1 ]; then
  token_part=$(printf '%bTokens:%b' "$COLOR_DARK_GRAY" "$COLOR_RESET")
  if [ "$_in_pos" -eq 1 ]; then
    s_in_fmt=$(fmt_tokens "$turn_in")
    token_part="${token_part} $(printf '%b%s%b↑' "$COLOR_WHITE" "$s_in_fmt" "$COLOR_RESET")"
  fi
  if [ "$_out_pos" -eq 1 ]; then
    s_out_fmt=$(fmt_tokens "$turn_out")
    token_part="${token_part} $(printf '%b%s%b↓' "$COLOR_WHITE" "$s_out_fmt" "$COLOR_RESET")"
  fi
  # Cache read share (no raw cr/cw numbers)
  if [ -n "$cache_hit_str" ]; then
    token_part="${token_part}  ${cache_hit_str}"
  fi
  token_str="$token_part"
fi

# Section 6: rate limits with progress bars
# Each window shows its own reset time inline: "5h: X% [bar] reset: HH:MM"
limits=""
if [ -n "$five_pct" ]; then
  five_int=$(printf '%.0f' "$five_pct")
  bar5=$(make_bar "$five_int" "$BAR_WIDTH")
  color5=$(pick_color "$five_int")
  limits=$(printf "5h: ${color5}%s%%${COLOR_RESET} [%b]" "$five_int" "$bar5")
  if [ -n "$five_reset_time" ]; then
    limits="$limits $(printf '%breset: %s%b' "$COLOR_DARK_GRAY" "$five_reset_time" "$COLOR_RESET")"
  fi
fi
if [ -n "$week_pct" ]; then
  week_int=$(printf '%.0f' "$week_pct")
  bar7=$(make_bar "$week_int" "$BAR_WIDTH")
  color7=$(pick_color "$week_int")
  week_str=$(printf "7d: ${color7}%s%%${COLOR_RESET} [%b]" "$week_int" "$bar7")
  if [ -n "$week_reset_time" ]; then
    week_str="$week_str $(printf '%breset: %s%b' "$COLOR_DARK_GRAY" "$week_reset_time" "$COLOR_RESET")"
  fi
  if [ -n "$limits" ]; then
    limits="$limits  $week_str"
  else
    limits="$week_str"
  fi
fi

# ── Assemble Line 1: model + effort  |  context  |  token stats ───────────
line1=""

if [ -n "$model" ]; then
  line1=$(printf '%b%s%b' "$COLOR_BLUE" "$model" "$COLOR_RESET")
fi

if [ -n "$ctx_str" ]; then
  if [ -n "$line1" ]; then
    line1="${line1}${SEP}${ctx_str}"
  else
    line1="$ctx_str"
  fi
fi

if [ -n "$token_str" ]; then
  if [ -n "$line1" ]; then
    line1="${line1}${SEP}${token_str}"
  else
    line1="$token_str"
  fi
fi

# Append estimated cost at the end of Line 1
if [ -n "$cost_str" ]; then
  if [ -n "$line1" ]; then
    line1="${line1}${SEP}${cost_str}"
  else
    line1="$cost_str"
  fi
fi

# ── Assemble Line 2: directory + branch  |  rate limits ───────────────────
line2="$dir_branch"

if [ -n "$limits" ]; then
  line2="${line2}${SEP}${limits}"
fi

# ── Print both lines ───────────────────────────────────────────────────────
if [ -n "$line1" ] && [ -n "$line2" ]; then
  printf '%b\n%b' "$line1" "$line2"
elif [ -n "$line1" ]; then
  printf '%b' "$line1"
else
  printf '%b' "$line2"
fi
