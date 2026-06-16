#!/usr/bin/env bash
# SPDX-License-Identifier: EUPL-1.2
# role: entrypoint
#
# .claude/hooks/router-reminder.sh — inject the request-router reminder.
#
# Wired as a Claude Code `UserPromptSubmit` hook (see .claude/settings.json).
# Whatever this script prints to stdout is added to the model's context for the
# turn, keeping the "tenant vs platform" triage salient so Claude routes work
# through the sanctioned skills instead of drifting into ad-hoc bash.
#
# Checked into the repo so every clone gets identical behaviour — it is referenced
# via $CLAUDE_PROJECT_DIR and contains no machine-specific paths.
#
# Writes: read-only (prints reminder to stdout only)
# Idempotent: yes (pure output, no side effects)
# Requires: bash; invoked by Claude Code with the prompt JSON on stdin (ignored)
#
# Usage:
#   ./.claude/hooks/router-reminder.sh            # prints the reminder block
#   echo '{}' | ./.claude/hooks/router-reminder.sh  # stdin is ignored
#   (configured automatically via .claude/settings.json UserPromptSubmit hook)
set -euo pipefail

cat <<'REMINDER'
[request-router] Before acting, classify this request:
  (A) Add / change a tenant  -> /add-tenant (one) or /batch-add-tenant (many);
      always include secrets via /generate-secrets; deploy with /sync-tenant.
  (B) Platform change (anything outside values/tenants/) -> run /change-guard
      FIRST (sync-window rules), then edit.
  (C) Neither / unclear -> ask which it is; most work here is A or B.
Prefer the skills above and their sanctioned scripts over ad-hoc bash. Bash is
fine only as the script a skill calls, not as a substitute for the skill.
REMINDER
