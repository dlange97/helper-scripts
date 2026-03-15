# Copilot Instructions - Helper Scripts

Scope: This repository only (my-dashboard-backend/helper-scripts).

## Rules
- Scripts must be deterministic, CI-friendly, and idempotent where possible.
- Fail fast with clear error messages and non-zero exit codes.
- Prefer portable shell and minimal external dependencies.
- Keep smoke and verification scripts aligned with current API routes.

## Quality
- After script updates, execute the updated script or scripts locally.
- If behavior changes, update local README docs in this repository.
