---
name: Tenant files must be minimal
description: Tenant values files should only contain the tenant-specific config block — do NOT copy the full template content
type: feedback
---

Tenant files are thin, 10-15 line configs. Only the `tenant:` block (and optionally mariadb/nextcloud overrides if truly needed) should be in the file. Everything else (mariadb config, hooks, ingress, resources, podLabels, etc.) is already defined in common.yaml and the env/db values files. Do NOT copy-paste the full template content into the tenant file.

**Why:** The user explicitly corrected this — "je hebt alleen de tenant config nodig. de rest is bepaald door common.yaml en env's"

**How to apply:** When creating a new tenant file, only write the `tenant:` block. Check existing tenant files to confirm the minimal pattern before writing.
