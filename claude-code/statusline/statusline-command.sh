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

# ── 5. Token statistics ───────────────────────────────────────────────────
# Fields used:
#   total_input_tokens          = cumulative input tokens for the session (grows each turn)
#   current_usage.output_tokens = output tokens from the most recent API response (not cumulative)
#   current_usage.cache_read_input_tokens    = cache tokens read this turn
#   current_usage.cache_creation_input_tokens = cache tokens written this turn
sess_in=$(echo "$input"   | jq -r '.context_window.total_input_tokens // empty')
cur_out=$(echo "$input"   | jq -r '.context_window.current_usage.output_tokens // empty')
cache_read=$(echo "$input"  | jq -r '.context_window.current_usage.cache_read_input_tokens // empty')
cache_write=$(echo "$input" | jq -r '.context_window.current_usage.cache_creation_input_tokens // empty')

# ── 5a. Accumulate output tokens locally per session ─────────────────────
# Uses /tmp/claude_statusline_output_<session_id>.txt to persist across refreshes.
# File format: "<last_cur_out>:<accumulated_total>"
# If cur_out differs from last recorded value → new response → add to total.
session_id=$(echo "$input" | jq -r '.session_id // empty')
if [ -n "$session_id" ]; then
  acc_file="/tmp/claude_statusline_output_${session_id}.txt"
else
  acc_file="/tmp/claude_statusline_output.txt"
fi

sess_out=0
if [ -n "$cur_out" ] && [ "$cur_out" -gt 0 ] 2>/dev/null; then
  if [ -f "$acc_file" ]; then
    last_cur=$(cut -d: -f1 "$acc_file" 2>/dev/null)
    acc_total=$(cut -d: -f2 "$acc_file" 2>/dev/null)
    # Ensure values are numeric
    last_cur=$(echo "$last_cur" | grep -E '^[0-9]+$' || echo 0)
    acc_total=$(echo "$acc_total" | grep -E '^[0-9]+$' || echo 0)
    if [ "$cur_out" != "$last_cur" ]; then
      # New response detected — add this turn's output to the accumulator
      acc_total=$(( acc_total + cur_out ))
      printf '%s:%s\n' "$cur_out" "$acc_total" > "$acc_file"
    fi
    sess_out="$acc_total"
  else
    # First time seeing this session — initialize with current output
    printf '%s:%s\n' "$cur_out" "$cur_out" > "$acc_file"
    sess_out="$cur_out"
  fi
fi

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

# ── 5c. Cache hit rate ─────────────────────────────────────────────────────
# cache_read / total_input * 100  (integer %)
cache_hit_str=""
if [ -n "$cache_read" ] && [ -n "$sess_in" ] && [ "$sess_in" -gt 0 ] 2>/dev/null && [ "$cache_read" -gt 0 ] 2>/dev/null; then
  cache_hit_pct=$(awk "BEGIN { printf \"%.0f\", ($cache_read / $sess_in) * 100 }")
  cache_hit_str=$(printf '%bcache:%b %s%%' "$COLOR_DARK_GRAY" "$COLOR_RESET" "$cache_hit_pct")
fi

# ── 5d. Estimated cost ─────────────────────────────────────────────────────
# Pricing per 1M tokens (input / output / cache_read / cache_write)
cost_str=""
raw_model_id=$(echo "$input" | jq -r '.model.id // empty')
if [ -n "$raw_model_id" ] && [ -n "$sess_in" ]; then
  # Determine pricing tier based on model id substring
  cost_str=$(awk -v model="$raw_model_id" \
                 -v t_in="${sess_in:-0}" \
                 -v t_out="${sess_out:-0}" \
                 -v t_cr="${cache_read:-0}" \
                 -v t_cw="${cache_write:-0}" \
    'BEGIN {
      # Default: unknown model → zero cost, skip display
      p_in = 0; p_out = 0; p_cr = 0; p_cw = 0; known = 0

      if (model ~ /opus/) {
        p_in = 15; p_out = 75; p_cr = 1.50; p_cw = 18.75; known = 1
      } else if (model ~ /haiku/) {
        p_in = 0.80; p_out = 4; p_cr = 0.08; p_cw = 1; known = 1
      } else if (model ~ /sonnet/) {
        p_in = 3; p_out = 15; p_cr = 0.30; p_cw = 3.75; known = 1
      }

      if (!known) { exit 0 }

      cost = (t_in * p_in + t_out * p_out + t_cr * p_cr + t_cw * p_cw) / 1000000

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

      if (cost < 0.01) {
        printf "%s<$0.01%s", color, RESET
      } else if (cost < 1.0) {
        printf "%s$%.2f%s", color, cost, RESET
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

# Section 5: token statistics
# Tokens: cumInput↑  cumOutput↓  cache: X%
token_str=""

if [ -n "$sess_in" ] || [ "$sess_out" -gt 0 ] 2>/dev/null; then
  token_part=$(printf '%bTokens:%b' "$COLOR_DARK_GRAY" "$COLOR_RESET")
  if [ -n "$sess_in" ]; then
    s_in_fmt=$(fmt_tokens "$sess_in")
    token_part="${token_part} $(printf '%b%s%b↑' "$COLOR_WHITE" "$s_in_fmt" "$COLOR_RESET")"
  fi
  if [ "$sess_out" -gt 0 ] 2>/dev/null; then
    s_out_fmt=$(fmt_tokens "$sess_out")
    token_part="${token_part} $(printf '%b%s%b↓' "$COLOR_WHITE" "$s_out_fmt" "$COLOR_RESET")"
  fi
  # Cache hit rate only (no cr/cw raw numbers)
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
  line1="${line1}${SEP}${cost_str}"
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
