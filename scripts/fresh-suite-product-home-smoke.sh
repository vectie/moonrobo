#!/bin/zsh

set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
moon_bin="${MOON_BIN:-/Users/kq/.moon/bin/moon}"
tmp_parent="${TMPDIR:-/tmp}"
tmp_parent="${tmp_parent%/}"
suite_root="$(mktemp -d "$tmp_parent/moonrobo-fresh-suite-product-home.XXXXXX")"
suite_root="$(cd "$suite_root" && pwd)"

cleanup() {
  rm -rf "$suite_root"
}
trap cleanup EXIT

book_root="$suite_root/books/noetix-e1-smoke"
product_home="$suite_root/.moonsuite/products/moonrobo"

mkdir -p "$suite_root/.moonsuite" "$suite_root/.tmp" "$suite_root/books"
cp -R "$repo_root/examples/noetix-e1" "$book_root"

run_moonrobo() {
  "$moon_bin" run cmd/main --target native -- "$@"
}

assert_file() {
  local path="$1"
  if [[ ! -f "$path" ]]; then
    echo "expected file missing: $path" >&2
    exit 1
  fi
}

assert_dir() {
  local path="$1"
  if [[ ! -d "$path" ]]; then
    echo "expected directory missing: $path" >&2
    exit 1
  fi
}

assert_absent() {
  local path="$1"
  if [[ -e "$path" ]]; then
    echo "legacy path should not exist: $path" >&2
    exit 1
  fi
}

assert_contains() {
  local path="$1"
  local needle="$2"
  if ! /usr/bin/grep -Fq "$needle" "$path"; then
    echo "expected $path to contain: $needle" >&2
    exit 1
  fi
}

cd "$repo_root"

run_moonrobo bootstrap "$book_root" >/dev/null
run_moonrobo gateway-command "$book_root" "walk forward when ready" 1783001 >/dev/null
run_moonrobo prove-loop "$book_root" "walk forward when ready" 1783002 >/dev/null
run_moonrobo proof-session "$book_root" "walk forward when ready" 1783003 1 >/dev/null
run_moonrobo turn "$book_root" "walk forward when ready" 1783004 >/dev/null
run_moonrobo loop "$book_root" "walk forward when ready" 1783005 >/dev/null

assert_dir "$product_home"
assert_dir "$product_home/gateway-commands"
assert_dir "$product_home/prove-loop"
assert_dir "$product_home/proof-sessions"
assert_dir "$product_home/robo-turns"
assert_dir "$product_home/robo-loops"
assert_dir "$product_home/dry-runs"
assert_dir "$product_home/approvals"
assert_dir "$product_home/runtime-validation"
assert_dir "$product_home/runtime-calibration"
assert_dir "$product_home/runtime-health"
assert_dir "$product_home/bridge-dispatches"
assert_dir "$product_home/bridge-contracts"
assert_dir "$product_home/live-exercises"

assert_file "$product_home/gateway-commands/cli-gateway-command-1783001.json"
assert_file "$product_home/prove-loop/prove-loop-cli-prove-loop-1783002-1783002.json"
assert_file "$product_home/proof-sessions/cli-proof-session-1783003.json"
assert_file "$product_home/robo-turns/robo-turn-message-cli-turn-1783004-1783004.json"
assert_file "$product_home/robo-loops/cli-loop-1783005.json"
assert_file "$book_root/agents/tool-registry.json"
assert_file "$book_root/moonbook/task-messages/message-bootstrap-first-task.json"
assert_file "$book_root/moonbook/memory/moonbook-memory-noetix-e1-lab-01-0.json"

assert_contains "$product_home/gateway-commands/cli-gateway-command-1783001.json" "\"command_id\": \"cli-gateway-command-1783001\""
assert_contains "$product_home/prove-loop/prove-loop-cli-prove-loop-1783002-1783002.json" "\"proof_id\": \"prove-loop-cli-prove-loop-1783002-1783002\""
assert_contains "$product_home/proof-sessions/cli-proof-session-1783003.json" "\"session_id\": \"cli-proof-session-1783003\""
assert_contains "$product_home/robo-turns/robo-turn-message-cli-turn-1783004-1783004.json" "\"turn_id\": \"robo-turn-message-cli-turn-1783004-1783004\""
assert_contains "$product_home/robo-loops/cli-loop-1783005.json" "\"loop_id\": \"cli-loop-1783005\""

assert_absent "$suite_root/.moonrobo"
assert_absent "$suite_root/runs/gateway-commands"
assert_absent "$suite_root/runs/robo-loops"
assert_absent "$suite_root/runs/proof-sessions"
assert_absent "$book_root/.moonrobo"
assert_absent "$book_root/.moonsuite/products/moonrobo"

echo "MoonRobo fresh-suite product-home smoke passed on $suite_root"
