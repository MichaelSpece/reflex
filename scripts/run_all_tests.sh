#!/usr/bin/env bash
set -euo pipefail

if ! command -v uv >/dev/null 2>&1; then
  echo "Error: uv is required to run the test suite." >&2
  exit 1
fi

export PYTHONUNBUFFERED=1
export APP_HARNESS_HEADLESS="${APP_HARNESS_HEADLESS:-1}"
export REFLEX_TELEMETRY_ENABLED=false

# Install python dependencies from lockfile.
uv sync

# Integration tests rely on a playwright browser.
uv run playwright install chromium --only-shell

# Run every test module under ./tests.
uv run pytest tests -v "$@"
