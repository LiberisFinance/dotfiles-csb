---
name: statusline-pricing-refresh
description: Refresh the per-model Anthropic pricing table used by statusline.sh's cold-cache-cost calculation, stored in ~/.claude/statusline-pricing.json. Use when the statusline shows a "⚠️ pricing table not checked in Nd" warning, or when the user asks to update/refresh/check the statusline pricing table.
---

# Refresh statusline pricing table

`~/.claude/statusline.sh` estimates the extra cost of cold-cache-expiry events using a per-model base-input-price table stored in `~/.claude/statusline-pricing.json`. That file has no automated update mechanism (cron jobs here aren't reliable background daemons — see the plan at `~/.claude/plans/anthropic-has-cheaper-prices-swirling-sprout.md` for why that was ruled out). Instead, the statusline shows a staleness warning once `verified_on` is more than 90 days old, and this skill is how you act on that warning.

## Steps

1. Fetch `https://platform.claude.com/docs/en/about-claude/pricing` and extract the "Model pricing" table's **Base Input Tokens** column for every model row (ignore 5m/1h cache write and cache read columns — `statusline.sh` derives those as fixed multipliers of base input price: 1.25x for 5m write, 0.1x for cache read).
2. Read the current `~/.claude/statusline-pricing.json`. Its `prices` map is keyed by short substrings matched against the model id string from the transcript (e.g. `"sonnet-5"`, `"opus-4-8"`, `"haiku-3-5"`) — `statusline.sh` does longest-key-wins substring matching, so key naming just needs to uniquely identify each model family; exact key spelling doesn't need to match Anthropic's display names.
3. Diff the fetched base input prices against the existing `prices` map:
   - If a price changed for an existing key, update its value.
   - If a new model family appears that isn't covered by any existing key, add a new key (using the same short-substring convention, most-specific string that appears in that model's id).
   - Leave retired models in place unless the user asks to prune them (harmless — they just won't match any current model id).
4. Update `verified_on` to today's date (`YYYY-MM-DD`) and `source` if the URL changed.
5. Write the updated JSON back to `~/.claude/statusline-pricing.json`, preserving the existing structure (`verified_on`, `source`, `refresh_hint`, `prices`).
6. Report to the user what changed (old price → new price per model, or "no changes, still current as of today").

## Verification

Run `bash ~/.claude/statusline.sh` with a synthetic stdin payload (no `transcript_path` needed) and confirm the `⚠️ pricing table not checked in Nd` warning is gone:

```sh
echo '{"model":{"display_name":"Sonnet 5"},"cost":{"total_cost_usd":0.10,"total_duration_ms":1000},"context_window":{"used_percentage":10}}' | bash ~/.claude/statusline.sh
```
