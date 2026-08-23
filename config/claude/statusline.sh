#!/bin/bash
input=$(cat)

model=$(echo "$input" | jq -r '.model.display_name // "unknown"')
cost=$(echo "$input" | jq -r '.cost.total_cost_usd // 0')
pct=$(echo "$input" | jq -r '.context_window.used_percentage // 0' | cut -d. -f1)
duration_ms=$(echo "$input" | jq -r '.cost.total_duration_ms // 0')
lines_added=$(echo "$input" | jq -r '.cost.total_lines_added // 0')
lines_removed=$(echo "$input" | jq -r '.cost.total_lines_removed // 0')
transcript_path=$(echo "$input" | jq -r '.transcript_path // empty')
cwd=$(echo "$input" | jq -r '.cwd // empty')

mins=$((duration_ms / 60000))
secs=$(((duration_ms % 60000) / 1000))

# Color codes using $'' so escape sequences are real bytes
RED=$'\033[31m'
YELLOW=$'\033[33m'
GREEN=$'\033[32m'
CYAN=$'\033[36m'
MAGENTA=$'\033[35m'
DEEPSKYBLUE=$'\033[38;2;0;191;255m'
BLUE=$'\033[34m'
ORANGE=$'\033[38;2;255;165;0m'
DIM=$'\033[2m'
BOLD=$'\033[1m'
RESET=$'\033[0m'

# Build 20-char progress bar, colored per-segment: green <50%, orange 50-70%, red 70-100%
bar_width=20
filled=$((pct * bar_width / 100))
empty=$((bar_width - filled))
bar=""
for ((i=0; i<filled; i++)); do
  seg_pct=$(( (i + 1) * 100 / bar_width ))
  if [ "$seg_pct" -ge 70 ]; then seg_color="$RED"
  elif [ "$seg_pct" -ge 50 ]; then seg_color="$ORANGE"
  else seg_color="$GREEN"; fi
  bar+="${seg_color}█${RESET}"
done
for ((i=0; i<empty; i++)); do bar+="░"; done

# Format cost
cost_fmt=$(printf '$%.2f' "$cost")

# Format duration
if [ "$mins" -gt 0 ]; then
  time_fmt="${mins}m ${secs}s"
else
  time_fmt="${secs}s"
fi

# Format lines changed
lines=""
if [ "$lines_added" -gt 0 ] || [ "$lines_removed" -gt 0 ]; then
  lines=" | ${GREEN}+${lines_added}${RESET} ${RED}-${lines_removed}${RESET}"
fi

# Tool call count from transcript
tool_count=0
if [ -n "$transcript_path" ] && [ -f "$transcript_path" ]; then
  tool_count=$(jq -s '[.[] | select(.type == "assistant") | .message.content // [] | .[] | select(.type == "tool_use")] | length' "$transcript_path" 2>/dev/null || echo 0)
fi

# Completed tasks count from transcript (TodoWrite tasks with status "completed")
tasks_done=0
if [ -n "$transcript_path" ] && [ -f "$transcript_path" ]; then
  tasks_done=$(jq -s '
    [ .[]
      | select(.type == "tool_result")
      | .content // []
      | .[]
      | select(type == "object" and .type == "text")
      | .text
    ] as $texts
    | [ .[]
        | select(.type == "assistant")
        | .message.content // []
        | .[]
        | select(.type == "tool_use" and .name == "TodoWrite")
        | .input.todos // []
        | .[]
        | select(.status == "completed")
      ]
    | length
  ' "$transcript_path" 2>/dev/null || echo 0)
fi

# Cache-expiry cost: cache_creation_input_tokens billed at 1.25x base price when a
# 5-min-idle gap forces a rewrite of content that would otherwise be a 0.1x cache read.
# Per-model base prices + verification date live in statusline-pricing.json, not inline,
# so the table can be refreshed without touching script logic.
pricing_file="$HOME/.claude/statusline-pricing.json"
cache_misses=0
cache_miss_cost=0
if [ -n "$transcript_path" ] && [ -f "$transcript_path" ] && [ -f "$pricing_file" ]; then
  cache_stats=$(jq -s --slurpfile pricing "$pricing_file" '
    ($pricing[0].prices | to_entries | sort_by(-(.key | length))) as $sorted_prices
    | def price_per_mtok(m): ([$sorted_prices[] | select(.key as $k | m | test($k))] | .[0].value) // null;
    [ .[] | select(.message.usage != null and .requestId != null) ]
    | unique_by(.requestId)
    | sort_by(.timestamp)
    | reduce .[] as $e (
        {prev: null, misses: 0, cost: 0};
        ($e.timestamp | sub("\\.[0-9]+Z$"; "Z") | fromdateiso8601) as $ts
        | if .prev == null then
            . + {prev: $ts}
          else
            (($ts - .prev) > 300) as $gap
            | ($e.message.usage.cache_creation_input_tokens // 0) as $cw
            | price_per_mtok($e.message.model // "") as $price
            | if ($gap and $cw > 0 and $price != null) then
                {prev: $ts, misses: (.misses + 1), cost: (.cost + ($cw * $price / 1000000 * 1.15))}
              else
                . + {prev: $ts}
              end
          end
      )
    | {misses, cost}
  ' "$transcript_path" 2>/dev/null || echo '{"misses":0,"cost":0}')
  cache_misses=$(echo "$cache_stats" | jq -r '.misses // 0')
  cache_miss_cost=$(echo "$cache_stats" | jq -r '.cost // 0')
fi
cache_miss_cost_fmt=$(printf '$%.2f' "$cache_miss_cost")
cache_suffix=""
if [ "$cache_misses" -gt 0 ] 2>/dev/null; then
  cache_suffix=" ${DIM}(❄️ ${cache_misses} +${cache_miss_cost_fmt})${RESET}"
fi

# Pricing-table staleness warning: nudge for a manual refresh once the table hasn't
# been checked against Anthropic's pricing page in a while (see refresh_hint in the file)
pricing_stale_suffix=""
if [ -f "$pricing_file" ]; then
  verified_on=$(jq -r '.verified_on // empty' "$pricing_file" 2>/dev/null)
  if [ -n "$verified_on" ]; then
    verified_epoch=$(date -j -f '%Y-%m-%d' "$verified_on" +%s 2>/dev/null)
    if [ -n "$verified_epoch" ]; then
      now_epoch=$(date +%s)
      days_stale=$(( (now_epoch - verified_epoch) / 86400 ))
      if [ "$days_stale" -gt 90 ]; then
        pricing_stale_suffix=" ${DIM}⚠️ pricing table not checked in ${days_stale}d, run /statusline-pricing-refresh${RESET}"
      fi
    fi
  fi
fi

# Git repo name and branch from cwd
git_info=""
if [ -n "$cwd" ] && [ -d "$cwd" ]; then
  branch=$(git -C "$cwd" --no-optional-locks rev-parse --abbrev-ref HEAD 2>/dev/null)
  repo=$(git -C "$cwd" --no-optional-locks rev-parse --show-toplevel 2>/dev/null | xargs basename 2>/dev/null)
  if [ -n "$repo" ] && [ -n "$branch" ]; then
    git_info="${repo}${DIM}:${RESET}🌿 ${DEEPSKYBLUE}${branch}${RESET}"
  elif [ -n "$repo" ]; then
    git_info="${repo}"
  fi
fi

# Rate limits (Claude.ai subscribers)
five_hr=$(echo "$input" | jq -r '.rate_limits.five_hour.used_percentage // empty')
seven_day=$(echo "$input" | jq -r '.rate_limits.seven_day.used_percentage // empty')
five_hr_reset=$(echo "$input" | jq -r '.rate_limits.five_hour.resets_at // empty')
seven_day_reset=$(echo "$input" | jq -r '.rate_limits.seven_day.resets_at // empty')

build_bar() {
  local pct_val="${1%.*}"
  local width=15
  local f=$((pct_val * width / 100))
  local e=$((width - f))
  local b=""
  for ((i=0; i<f; i++)); do b+="█"; done
  for ((i=0; i<e; i++)); do b+="░"; done

  if [ "$pct_val" -ge 90 ]; then echo "${RED}${b}${RESET}"
  elif [ "$pct_val" -ge 70 ]; then echo "${YELLOW}${b}${RESET}"
  else echo "${GREEN}${b}${RESET}"; fi
}

format_reset() {
  local reset_epoch="$1"
  if [ -z "$reset_epoch" ]; then echo ""; return; fi
  local now=$(date +%s)
  local diff=$((reset_epoch - now))
  if [ "$diff" -le 0 ]; then echo "now"; return; fi
  local h=$((diff / 3600))
  local m=$(((diff % 3600) / 60))
  if [ "$h" -gt 0 ]; then echo "${h}h ${m}m"
  else echo "${m}m"; fi
}

# Line 1: model, context bar, cost, time, lines changed
echo "${CYAN}${model}${RESET} ${bar} ${pct}% | 💰${YELLOW}${cost_fmt}${RESET}${cache_suffix}${pricing_stale_suffix} | ⏱️ ${time_fmt}${lines}"

# Line 2: git repo/branch
if [ -n "$git_info" ]; then
  echo "$git_info"
fi

# Line 3: tools used and tasks done
printf "${DIM}tools${RESET} ${BOLD}${tool_count}${RESET}  ${DIM}tasks done${RESET} ${BOLD}${tasks_done}${RESET}\n"

# Third line: plan usage
if [ -n "$five_hr" ] || [ -n "$seven_day" ]; then
  plan_line=""
  if [ -n "$five_hr" ]; then
    five_bar=$(build_bar "$five_hr")
    five_reset=$(format_reset "$five_hr_reset")
    five_pct="${five_hr%.*}"
    reset_info=""
    [ -n "$five_reset" ] && reset_info=" ${DIM}resets ${five_reset}${RESET}"
    plan_line="${plan_line}${DIM}5h${RESET} ${five_bar} ${five_pct}%${reset_info}"
  fi
  if [ -n "$seven_day" ]; then
    seven_bar=$(build_bar "$seven_day")
    seven_reset=$(format_reset "$seven_day_reset")
    seven_pct="${seven_day%.*}"
    reset_info=""
    [ -n "$seven_reset" ] && reset_info=" ${DIM}resets ${seven_reset}${RESET}"
    [ -n "$plan_line" ] && plan_line="${plan_line}  ${DIM}|${RESET}  "
    plan_line="${plan_line}${DIM}7d${RESET} ${seven_bar} ${seven_pct}%${reset_info}"
  fi
  echo "$plan_line"
fi