#!/usr/bin/env python3
"""Deep-merges the dotfiles Claude Code settings template into the live settings.json.

Structural keys (env, permissions, hooks, statusLine, enabledPlugins,
extraKnownMarketplaces, $schema) are dotfiles-managed and enforced/unioned on every
run. Everything else is seeded once, then left alone -- Claude Code and
`claude plugin install` rewrite scalar preferences (model, effortLevel,
feedbackSurveyState, ...) into this file at runtime, and resyncing dotfiles should
not stomp on that.
"""
import json
import sys

OVERWRITE_KEYS = {"statusLine", "$schema"}


def merge_str_list(existing, template):
    seen = set()
    result = []
    for item in list(template) + list(existing):
        if item not in seen:
            seen.add(item)
            result.append(item)
    return result


def merge_permissions(existing, template):
    result = dict(existing)
    for key, template_list in template.items():
        result[key] = merge_str_list(existing.get(key, []), template_list)
    return result


def merge_hooks(existing, template):
    result = dict(existing)
    for event, template_groups in template.items():
        existing_groups = existing.get(event, [])
        seen = {json.dumps(g, sort_keys=True) for g in existing_groups}
        merged = list(existing_groups)
        for group in template_groups:
            key = json.dumps(group, sort_keys=True)
            if key not in seen:
                seen.add(key)
                merged.append(group)
        result[event] = merged
    return result


def merge_plain_dict(existing, template):
    result = dict(existing)
    result.update(template)
    return result


def main():
    rendered_template_path, target_path = sys.argv[1], sys.argv[2]

    with open(rendered_template_path) as f:
        template = json.load(f)

    try:
        with open(target_path) as f:
            existing = json.load(f)
    except FileNotFoundError:
        existing = {}

    result = dict(existing)
    for key, template_value in template.items():
        if key in OVERWRITE_KEYS:
            result[key] = template_value
        elif key == "env":
            result[key] = merge_plain_dict(existing.get(key, {}), template_value)
        elif key == "permissions":
            result[key] = merge_permissions(existing.get(key, {}), template_value)
        elif key == "hooks":
            result[key] = merge_hooks(existing.get(key, {}), template_value)
        elif key in ("enabledPlugins", "extraKnownMarketplaces"):
            result[key] = merge_plain_dict(existing.get(key, {}), template_value)
        elif key not in existing:
            result[key] = template_value

    with open(target_path, "w") as f:
        json.dump(result, f, indent=2)
        f.write("\n")


if __name__ == "__main__":
    main()
