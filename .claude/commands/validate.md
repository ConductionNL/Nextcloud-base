Run the full local validation suite for this repository and report the results clearly.

## Steps

1. Run the values validator:
   ```
   ./scripts/validate-values.sh
   ```
   Report: pass or fail, and if fail, which tenant files have issues and what is missing.

2. Run the smoke checks (Helm template rendering + schema validation):
   ```
   ./scripts/smoke-checks.sh
   ```
   Report: pass or fail, and if fail, the exact error output.

3. Summarize the overall result:
   - If both pass: confirm it is safe to push. Remind the user to run `/change-guard` to verify the change classification and office hours rules before pushing.
   - If either fails: list the failures clearly, state what needs to be fixed, and do not suggest pushing until issues are resolved.

Do not skip or abbreviate any step. Run the commands and report actual output, not assumptions.
