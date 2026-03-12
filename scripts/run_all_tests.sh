#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$script_dir/.." && pwd)"

find_vendored_act_dir() {
  local candidate

  candidate="$(cd "$repo_root/../../../../Utilities/src_and_submodules/utilities/management_of/resources/servers/local/act/act" 2>/dev/null && pwd || true)"
  if [[ -n "$candidate" && -d "$candidate" ]]; then
    printf '%s\n' "$candidate"
    return 0
  fi

  return 1
}

ensure_act() {
  local vendored_act_dir
  local vendored_act_bin
  local install_dir

  if command -v act >/dev/null 2>&1; then
    ACT_BIN="$(command -v act)"
    return 0
  fi

  vendored_act_dir="$(find_vendored_act_dir || true)"
  if [[ -n "$vendored_act_dir" ]]; then
    vendored_act_bin="$vendored_act_dir/dist/local/act"
    if [[ -x "$vendored_act_bin" ]]; then
      ACT_BIN="$vendored_act_bin"
      return 0
    fi

    if command -v make >/dev/null 2>&1; then
      if make -C "$vendored_act_dir" build >/dev/null; then
        if [[ -x "$vendored_act_bin" ]]; then
          ACT_BIN="$vendored_act_bin"
          return 0
        fi
      fi
    fi

    if [[ -f "$vendored_act_dir/install.sh" ]]; then
      mkdir -p "$vendored_act_dir/dist/local"
      sh "$vendored_act_dir/install.sh" -b "$vendored_act_dir/dist/local" >/dev/null
      if [[ -x "$vendored_act_bin" ]]; then
        ACT_BIN="$vendored_act_bin"
        return 0
      fi
    fi
  fi

  if command -v curl >/dev/null 2>&1; then
    install_dir="$repo_root/.tools/act"
    mkdir -p "$install_dir"
    curl --proto '=https' --tlsv1.2 -sSf https://raw.githubusercontent.com/nektos/act/master/install.sh \
      | sh -s -- -b "$install_dir" >/dev/null
    if [[ -x "$install_dir/act" ]]; then
      ACT_BIN="$install_dir/act"
      return 0
    fi
  fi

  echo "Error: could not find or install act." >&2
  exit 1
}

docker_daemon_available() {
  command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1
}

configure_platform_args() {
  local latest_platform
  local ubuntu_2204_platform

  if docker_daemon_available; then
    latest_platform="${REFLEX_ACT_PLATFORM_LATEST:-catthehacker/ubuntu:full-latest}"
    ubuntu_2204_platform="${REFLEX_ACT_PLATFORM_22_04:-catthehacker/ubuntu:full-22.04}"
  else
    latest_platform="${REFLEX_ACT_PLATFORM_LATEST:--self-hosted}"
    ubuntu_2204_platform="${REFLEX_ACT_PLATFORM_22_04:--self-hosted}"
    echo "Warning: Docker daemon unavailable; using self-hosted act platform mapping." >&2
    echo "Warning: service-container and browser-heavy jobs may still require a fuller runner environment." >&2
  fi

  platform_args=(
    -P "ubuntu-latest=${latest_platform}"
    -P "ubuntu-22.04=${ubuntu_2204_platform}"
  )
}

run_job() {
  local workflow="$1"
  local job="$2"
  local label="$3"
  shift 3

  echo "==> ${label}"
  "${ACT_BIN}" \
    "${platform_args[@]}" \
    -W "${repo_root}/.github/workflows/${workflow}" \
    -j "${job}" \
    "$@" \
    "${extra_act_args[@]}" \
    push
}

ACT_BIN=""
extra_act_args=("$@")
platform_args=()

ensure_act
configure_platform_args

run_job \
  "unit_tests.yml" \
  "unit-tests" \
  "unit-tests (ubuntu-latest, python 3.13)" \
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

run_job \
  "performance.yml" \
  "benchmarks" \
  "benchmarks"

for split_index in 1 2; do
  run_job \
    "check_node_latest.yml" \
    "check_latest_node" \
    "check-node-latest (split ${split_index})" \
    --matrix "split_index:${split_index}"
done
