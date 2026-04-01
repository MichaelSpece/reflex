#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$script_dir/.." && pwd)"
PYTHON_BIN="${PYTHON_BIN:-$(command -v python3 || true)}"

REFLEX_ACT_CACHE_ROOT="${REFLEX_ACT_CACHE_ROOT:-${XDG_CACHE_HOME:-$HOME/.cache}/reflex-act}"
ACT_RUNTIME_ROOT="${REFLEX_ACT_CACHE_ROOT}/runtime"
ACT_INSTALL_ROOT="${REFLEX_ACT_CACHE_ROOT}/bin"
ACT_LOCAL_REPOSITORY_ROOT="${REFLEX_ACT_CACHE_ROOT}/repositories"
ACT_RUNNER_NODE_ROOT="${REFLEX_ACT_CACHE_ROOT}/node"

show_help() {
  cat <<'EOF'
Usage: bash scripts/run_all_tests.sh [act args]

Run selected Reflex GitHub Actions jobs locally with `act`.

Examples:
  bash scripts/run_all_tests.sh
  bash scripts/run_all_tests.sh -l

Environment:
  ACT_BIN=/path/to/act                      Override the `act` binary.
  REFLEX_ACT_EVENT=pull_request            Override the event passed to `act`.
  REFLEX_ACT_UNIT_TESTS_PYTHON_VERSION=3.13
  REFLEX_ACT_INTEGRATION_PYTHON_VERSION=3.13
  REFLEX_ACT_INTEGRATION_STATE_MANAGER=memory
  REFLEX_ACT_PLATFORM_LATEST=...
  REFLEX_ACT_PLATFORM_22_04=...
  REFLEX_ACT_ALLOW_SELF_HOSTED=1           Run on the host when Docker is unavailable.
  REFLEX_ACT_SELF_HOSTED_PRESERVE_HOST_ENV=1
                                            Keep host-only env vars in self-hosted mode.
  REFLEX_ACT_CACHE_ROOT=/path/to/cache      Override the cache/bootstrap directory.
  REFLEX_ACT_NODE_MAJOR=22                  Override the self-hosted Node major version.
  REFLEX_ACT_DISABLE_UV_CACHE=1             Disable setup-uv cache for self-hosted act runs.
  REFLEX_ACT_SKIP_BENCHMARKS=1             Skip the benchmark workflow.
EOF
}

has_arg() {
  local needle="$1"
  shift
  local arg

  for arg in "$@"; do
    if [[ "$arg" == "$needle" ]]; then
      return 0
    fi
  done

  return 1
}

is_list_mode() {
  local arg

  for arg in "$@"; do
    case "$arg" in
      -l|--list|--list-options)
        return 0
        ;;
    esac
  done

  return 1
}

require_python() {
  if [[ -n "${PYTHON_BIN}" && -x "${PYTHON_BIN}" ]]; then
    return 0
  fi

  cat >&2 <<'EOF'
Error: python3 is required to bootstrap act and Node for the local CI workflow script.
EOF
  exit 1
}

install_act_with_python() {
  local target_dir="$ACT_INSTALL_ROOT"

  require_python
  mkdir -p "$target_dir"

  "$PYTHON_BIN" - <<'PY' "$target_dir"
from __future__ import annotations

import io
import json
import os
from pathlib import Path, PurePosixPath
import platform
import stat
import tarfile
import urllib.request
import zipfile
import sys


target_dir = Path(sys.argv[1]).resolve()
target_dir.mkdir(parents=True, exist_ok=True)
target = target_dir / ("act.exe" if platform.system() == "Windows" else "act")
if target.exists():
    print(target)
    raise SystemExit(0)

system = platform.system()
machine = platform.machine().lower()

os_name = {
    "Darwin": "Darwin",
    "Linux": "Linux",
    "Windows": "Windows",
}[system]
arch_name = {
    "x86_64": "x86_64",
    "amd64": "x86_64",
    "aarch64": "arm64",
    "arm64": "arm64",
}.get(machine, machine)
asset_name = (
    f"act_{os_name}_{arch_name}.zip"
    if system == "Windows"
    else f"act_{os_name}_{arch_name}.tar.gz"
)

with urllib.request.urlopen("https://api.github.com/repos/nektos/act/releases/latest") as response:
    release = json.load(response)

asset = next((candidate for candidate in release["assets"] if candidate["name"] == asset_name), None)
if asset is None:
    raise RuntimeError(f"Unable to find a compatible act release asset for {asset_name!r}.")

with urllib.request.urlopen(asset["browser_download_url"]) as response:
    blob = response.read()

if asset_name.endswith(".tar.gz"):
    with tarfile.open(fileobj=io.BytesIO(blob), mode="r:gz") as archive:
        member = next(
            candidate
            for candidate in archive.getmembers()
            if PurePosixPath(candidate.name).name == "act"
        )
        extracted = archive.extractfile(member)
        if extracted is None:
            raise RuntimeError("Unable to extract the act binary.")
        target.write_bytes(extracted.read())
else:
    with zipfile.ZipFile(io.BytesIO(blob)) as archive:
        member = next(
            candidate for candidate in archive.namelist() if PurePosixPath(candidate).name == "act.exe"
        )
        target.write_bytes(archive.read(member))

os.chmod(
    target,
    target.stat().st_mode | stat.S_IXUSR | stat.S_IXGRP | stat.S_IXOTH,
)
print(target)
PY

  ACT_BIN="$target_dir/act"
}

ensure_act() {
  local resolved_act_bin=""

  if [[ -n "$ACT_BIN" ]]; then
    # Resolve bare command names through PATH before validating executability.
    resolved_act_bin="$(command -v "$ACT_BIN" 2>/dev/null || true)"

    if [[ -n "$resolved_act_bin" && -x "$resolved_act_bin" ]]; then
      ACT_BIN="$resolved_act_bin"
      return 0
    fi

    if [[ -x "$ACT_BIN" ]]; then
      return 0
    fi
  fi

  resolved_act_bin="$(command -v act 2>/dev/null || true)"
  if [[ -n "$resolved_act_bin" && -x "$resolved_act_bin" ]]; then
    ACT_BIN="$resolved_act_bin"
    return 0
  fi

  install_act_with_python
}

docker_daemon_available() {
  command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1
}

self_hosted_mode_enabled() {
  [[ "${REFLEX_ACT_ALLOW_SELF_HOSTED:-0}" == "1" ]]
}

require_runner_support() {
  if is_list_mode "${extra_act_args[@]+"${extra_act_args[@]}"}"; then
    return 0
  fi

  if docker_daemon_available || self_hosted_mode_enabled; then
    return 0
  fi

  cat >&2 <<'EOF'
Error: Docker is required to run Reflex GitHub Actions locally with act.

Use `bash scripts/run_all_tests.sh -l` to list the selected jobs without running them,
or set REFLEX_ACT_ALLOW_SELF_HOSTED=1 to execute directly on the host with lower CI parity.
EOF
  exit 1
}

configure_platform_args() {
  local latest_platform
  local ubuntu_2204_platform

  if self_hosted_mode_enabled; then
    latest_platform="${REFLEX_ACT_PLATFORM_LATEST:--self-hosted}"
    ubuntu_2204_platform="${REFLEX_ACT_PLATFORM_22_04:--self-hosted}"
    echo "Warning: Docker unavailable or bypassed; using self-hosted act platform mapping." >&2
  else
    latest_platform="${REFLEX_ACT_PLATFORM_LATEST:-catthehacker/ubuntu:full-latest}"
    ubuntu_2204_platform="${REFLEX_ACT_PLATFORM_22_04:-catthehacker/ubuntu:full-22.04}"
  fi

  platform_args=(
    -P "ubuntu-latest=${latest_platform}"
    -P "ubuntu-22.04=${ubuntu_2204_platform}"
  )
}

ensure_runner_node() {
  local desired_major="${REFLEX_ACT_NODE_MAJOR:-22}"
  local current_node_bin=""
  local current_node_major=""

  if ! self_hosted_mode_enabled || is_list_mode "${extra_act_args[@]+"${extra_act_args[@]}"}"; then
    return 0
  fi

  if current_node_bin="$(command -v node 2>/dev/null || true)"; then
    current_node_major="$("$current_node_bin" -p 'process.versions.node.split(".")[0]' 2>/dev/null || true)"
  fi

  if [[ -n "$current_node_major" && "$current_node_major" =~ ^[0-9]+$ && "$current_node_major" -ge 20 ]]; then
    return 0
  fi

  require_python
  mkdir -p "$ACT_RUNNER_NODE_ROOT"

  "$PYTHON_BIN" - <<'PY' "$ACT_RUNNER_NODE_ROOT" "$desired_major"
from __future__ import annotations

import io
import json
import os
from pathlib import Path, PurePosixPath
import platform
import stat
import tarfile
import urllib.request
import zipfile
import sys


install_root = Path(sys.argv[1]).resolve()
desired_major = int(sys.argv[2])
install_root.mkdir(parents=True, exist_ok=True)

system = platform.system()
machine = platform.machine().lower()

os_name = {
    "Darwin": "darwin",
    "Linux": "linux",
    "Windows": "win",
}[system]
arch_name = {
    "x86_64": "x64",
    "amd64": "x64",
    "aarch64": "arm64",
    "arm64": "arm64",
}.get(machine, machine)

with urllib.request.urlopen("https://nodejs.org/dist/index.json") as response:
    versions = json.load(response)

entry = next(
    (candidate for candidate in versions if candidate["version"].startswith(f"v{desired_major}.")),
    None,
)
if entry is None:
    raise RuntimeError(f"Unable to find a Node.js release for major version {desired_major}.")

version = entry["version"]
target_dir = install_root / version
node_binary = target_dir / ("node.exe" if system == "Windows" else "bin/node")
if node_binary.exists():
    print(target_dir)
    raise SystemExit(0)

asset_name = (
    f"node-{version}-win-{arch_name}.zip"
    if system == "Windows"
    else f"node-{version}-{os_name}-{arch_name}.tar.xz"
)
url = f"https://nodejs.org/dist/{version}/{asset_name}"

with urllib.request.urlopen(url) as response:
    blob = response.read()

target_dir.mkdir(parents=True, exist_ok=True)

if asset_name.endswith(".tar.xz"):
    with tarfile.open(fileobj=io.BytesIO(blob), mode="r:xz") as archive:
        members = archive.getmembers()
        root_prefix = members[0].name.split("/", maxsplit=1)[0]
        for member in members:
            relative = PurePosixPath(member.name).relative_to(root_prefix)
            if not relative.parts:
                continue
            destination = target_dir / Path(*relative.parts)
            if member.isdir():
                destination.mkdir(parents=True, exist_ok=True)
                continue
            if not member.isfile():
                continue
            destination.parent.mkdir(parents=True, exist_ok=True)
            extracted = archive.extractfile(member)
            if extracted is None:
                continue
            destination.write_bytes(extracted.read())
            os.chmod(destination, member.mode | stat.S_IRUSR | stat.S_IWUSR)
else:
    with zipfile.ZipFile(io.BytesIO(blob)) as archive:
        root_prefix = PurePosixPath(archive.namelist()[0]).parts[0]
        for member in archive.namelist():
            relative = PurePosixPath(member).relative_to(root_prefix)
            if not relative.parts:
                continue
            destination = target_dir / Path(*relative.parts)
            if member.endswith("/"):
                destination.mkdir(parents=True, exist_ok=True)
                continue
            destination.parent.mkdir(parents=True, exist_ok=True)
            destination.write_bytes(archive.read(member))

print(target_dir)
PY

  local node_root=""
  node_root="$(find "$ACT_RUNNER_NODE_ROOT" -mindepth 1 -maxdepth 1 -type d | sort | tail -n 1)"
  if [[ -z "$node_root" || ! -x "$node_root/bin/node" ]]; then
    cat >&2 <<'EOF'
Error: failed to provision a modern Node.js runtime for self-hosted act execution.
EOF
    exit 1
  fi

  export PATH="$node_root/bin:$PATH"
}

configure_local_action_sources() {
  local action_specs=()

  local_repository_args=()
  common_act_args=(
    --action-cache-path "$ACT_RUNTIME_ROOT"
  )

  mkdir -p "$ACT_RUNTIME_ROOT"

  if is_list_mode "${extra_act_args[@]+"${extra_act_args[@]}"}"; then
    return 0
  fi

  require_python
  mkdir -p "$ACT_LOCAL_REPOSITORY_ROOT"

  action_specs+=("actions/checkout@v4=$ACT_LOCAL_REPOSITORY_ROOT/actions-checkout@v4")
  action_specs+=("astral-sh/setup-uv@v6=$ACT_LOCAL_REPOSITORY_ROOT/astral-sh-setup-uv@v6")
  action_specs+=("actions/setup-node@v4=$ACT_LOCAL_REPOSITORY_ROOT/actions-setup-node@v4")
  action_specs+=("actions/setup-python@v5=$ACT_LOCAL_REPOSITORY_ROOT/actions-setup-python@v5")

  if [[ "${REFLEX_ACT_SKIP_BENCHMARKS:-0}" != "1" ]]; then
    action_specs+=("CodSpeedHQ/action@v4=$ACT_LOCAL_REPOSITORY_ROOT/CodSpeedHQ-action@v4")
  fi

  "$PYTHON_BIN" - <<'PY' "${action_specs[@]}"
from __future__ import annotations

import io
from pathlib import Path, PurePosixPath
import tarfile
import urllib.request
import sys


for spec in sys.argv[1:]:
    repo_ref, target_dir_raw = spec.split("=", maxsplit=1)
    repo_name, ref = repo_ref.split("@", maxsplit=1)
    target_dir = Path(target_dir_raw).resolve()
    action_yml = target_dir / "action.yml"
    action_yaml = target_dir / "action.yaml"
    if action_yml.exists() or action_yaml.exists():
        continue

    target_dir.mkdir(parents=True, exist_ok=True)
    request = urllib.request.Request(
        f"https://api.github.com/repos/{repo_name}/tarball/{ref}",
        headers={"Accept": "application/vnd.github+json"},
    )
    with urllib.request.urlopen(request) as response:
        blob = response.read()

    with tarfile.open(fileobj=io.BytesIO(blob), mode="r:gz") as archive:
        members = archive.getmembers()
        root_prefix = members[0].name.split("/", maxsplit=1)[0]
        for member in members:
            relative = PurePosixPath(member.name).relative_to(root_prefix)
            if not relative.parts:
                continue
            destination = target_dir / Path(*relative.parts)
            if member.isdir():
                destination.mkdir(parents=True, exist_ok=True)
                continue
            if not member.isfile():
                continue
            destination.parent.mkdir(parents=True, exist_ok=True)
            extracted = archive.extractfile(member)
            if extracted is None:
                continue
            destination.write_bytes(extracted.read())
PY

  common_act_args+=(--action-offline-mode)
  for spec in "${action_specs[@]}"; do
    local_repository_args+=(--local-repository "$spec")
  done
}

configure_self_hosted_env() {
  local disable_uv_cache="${REFLEX_ACT_DISABLE_UV_CACHE:-1}"

  if ! self_hosted_mode_enabled; then
    return 0
  fi

  if [[ "${REFLEX_ACT_SELF_HOSTED_PRESERVE_HOST_ENV:-0}" == "1" ]]; then
    act_env_prefix=(
      env
      "REFLEX_ACT_DISABLE_UV_CACHE=${disable_uv_cache}"
    )
    echo "Warning: preserving host environment in self-hosted mode." >&2
    return 0
  fi

  # Keep host-specific shell state from leaking into workflow behavior.
  act_env_prefix=(
    env
    -u CODESPACE_NAME
    -u GITHUB_CODESPACES_PORT_FORWARDING_DOMAIN
    -u GITHUB_CODESPACE_TOKEN
    -u PYTHONSAFEPATH
    "REFLEX_ACT_DISABLE_UV_CACHE=${disable_uv_cache}"
  )

  echo "Warning: self-hosted mode scrubs Codespaces and PYTHONSAFEPATH env vars for better CI parity." >&2

  if [[ "$(id -u)" == "0" ]]; then
    cat >&2 <<'EOF'
Warning: browser-based workflows may still fail as root.
Use a non-root environment for best parity. If you stay on root, try APP_HARNESS_DRIVER_ARGS=--no-sandbox as a local-only fallback.
EOF
  fi
}

run_job() {
  local workflow="$1"
  local job="$2"
  local label="$3"
  shift 3

  echo "==> ${label}"
  "${act_env_prefix[@]+"${act_env_prefix[@]}"}" "${ACT_BIN}" \
    "${ACT_EVENT}" \
    "${platform_args[@]}" \
    "${common_act_args[@]}" \
    "${local_repository_args[@]+"${local_repository_args[@]}"}" \
    -W ".github/workflows/${workflow}" \
    -j "${job}" \
    "$@" \
    "${extra_act_args[@]+"${extra_act_args[@]}"}"
}

if has_arg "-h" "$@" || has_arg "--help" "$@"; then
  show_help
  exit 0
fi

ACT_BIN="${ACT_BIN:-$(command -v act || true)}"
ACT_EVENT="${REFLEX_ACT_EVENT:-pull_request}"
extra_act_args=("$@")
act_env_prefix=()
common_act_args=()
local_repository_args=()
platform_args=()

ensure_act
require_runner_support
configure_platform_args
ensure_runner_node
configure_local_action_sources
configure_self_hosted_env

cd "$repo_root"

run_job \
  "unit_tests.yml" \
  "unit-tests" \
  "unit-tests (ubuntu-latest, python ${REFLEX_ACT_UNIT_TESTS_PYTHON_VERSION:-3.13})" \
  --matrix "os:ubuntu-latest" \
  --matrix "python-version:${REFLEX_ACT_UNIT_TESTS_PYTHON_VERSION:-3.13}"

for split_index in 1 2; do
  run_job \
    "integration_app_harness.yml" \
    "integration-app-harness" \
    "integration-app-harness (python ${REFLEX_ACT_INTEGRATION_PYTHON_VERSION:-3.13}, ${REFLEX_ACT_INTEGRATION_STATE_MANAGER:-memory}, split ${split_index})" \
    --matrix "python-version:${REFLEX_ACT_INTEGRATION_PYTHON_VERSION:-3.13}" \
    --matrix "state_manager:${REFLEX_ACT_INTEGRATION_STATE_MANAGER:-memory}" \
    --matrix "split_index:${split_index}"
done

if [[ "${REFLEX_ACT_SKIP_BENCHMARKS:-0}" != "1" ]]; then
  run_job \
    "performance.yml" \
    "benchmarks" \
    "benchmarks"
fi

for split_index in 1 2; do
  run_job \
    "check_node_latest.yml" \
    "check_latest_node" \
    "check-node-latest (split ${split_index})" \
    --matrix "split_index:${split_index}"
done
