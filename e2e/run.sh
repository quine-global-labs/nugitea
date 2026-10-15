#!/usr/bin/env bash
# Provisions a throwaway nugitea and its web frontend, seeds them from
# e2e/seed.json, and runs the Cypress suite against them. All state (accounts,
# tokens, repos) lives in a temp dir that's removed afterwards, and git ignores
# your own config. Run it with `nix run .#e2e`, which pins every tool; extra
# arguments go to `cypress run`, e.g. `nix run .#e2e -- --headed`.
#
# NUGITEA_E2E_HTTP_PORT, _SSH_PORT and _WEB_PORT override the ports
# (3080, 2223, 3000).
set -euo pipefail

root=$(git rev-parse --show-toplevel)
work=$(mktemp -d "${TMPDIR:-/tmp}/nugitea-e2e.XXXXXX")
http_port=${NUGITEA_E2E_HTTP_PORT:-3080}
web_port=${NUGITEA_E2E_WEB_PORT:-3000}
api_url="http://127.0.0.1:$http_port"
web_url="http://127.0.0.1:$web_port"

# Each server gets its own process group, so cleanup takes down the whole
# tree (mix -> erl, node).
set -m
pids=()
cleanup() {
  for pid in "${pids[@]}"; do kill -- "-$pid" 2>/dev/null || true; done
  wait 2>/dev/null || true
  rm -rf "$work"
}
trap cleanup EXIT

step() { printf '\n==> %s\n' "$*"; }

# Waits for `url` to answer, or prints `log` and fails.
wait_for() {
  local url=$1 log=$2
  for _ in $(seq 120); do
    if curl -sf -o /dev/null "$url"; then return 0; fi
    sleep 0.5
  done
  echo "timed out waiting for $url; its log:" >&2
  cat "$log" >&2
  return 1
}

for url in "$api_url/healthz" "$web_url"; do
  if curl -s -o /dev/null "$url"; then
    echo "something is already listening at $url; stop it or set NUGITEA_E2E_*_PORT" >&2
    exit 1
  fi
done

# The server's git and the spec's git: no user or system config, `main` as
# the default branch, and never a credentials prompt.
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 GIT_TERMINAL_PROMPT=0
export GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=init.defaultBranch GIT_CONFIG_VALUE_0=main

export NUGITEA_STATE_DIR="$work/state"
export NUGITEA_REPO_ROOT="$work/repos"
export NUGITEA_SSH_HOST_KEY_DIR="$work/ssh"
export NUGITEA_HTTP_PORT=$http_port
export NUGITEA_SSH_PORT=${NUGITEA_E2E_SSH_PORT:-2223}

step "Building nugitea"
(
  cd "$root/elixir_nugitea"
  mix local.hex --force --if-missing >/dev/null
  mix deps.get >/dev/null
  mix compile
)

step "Seeding from e2e/seed.json"
(cd "$root/elixir_nugitea" && mix nugitea seed "$root/e2e/seed.json") | tail -n 1 >"$work/seed.json"

step "Starting nugitea on $api_url"
(cd "$root/elixir_nugitea" && exec mix nugitea serve) >"$work/nugitea.log" 2>&1 &
pids+=($!)
wait_for "$api_url/healthz" "$work/nugitea.log"

step "Building the web frontend"
npm --prefix "$root/rust_nugitea/web" ci --no-audit --no-fund
npm --prefix "$root/rust_nugitea/web" run build

step "Starting the web frontend on $web_url"
(
  cd "$root/rust_nugitea/web"
  HOST=127.0.0.1 PORT=$web_port \
    NUXT_GRAPHQL_URL="$api_url/graphql" NUXT_PUBLIC_GRAPHQL_URL="$api_url/graphql" \
    exec node .output/server/index.mjs
) >"$work/web.log" 2>&1 &
pids+=($!)
wait_for "$web_url/repos" "$work/web.log"

step "Running Cypress"
npm --prefix "$root/e2e" ci --no-audit --no-fund
mkdir -p "$work/git"
(
  cd "$root/e2e"
  NUGITEA_E2E_WEB_URL=$web_url NUGITEA_E2E_API_URL=$api_url \
    NUGITEA_E2E_SEED_OUTPUT="$work/seed.json" NUGITEA_E2E_WORK_DIR="$work/git" \
    npx cypress run "$@"
)
