#!/bin/sh
set -eu

repo_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
host_v=${VGUARD_HOST_V:-"$HOME/dev/v/v"}
default_target_v="$repo_root/../v/v"
if [ -x "$repo_root/../v/v-vguard" ]; then
	default_target_v="$repo_root/../v/v-vguard"
fi
target_v=${VGUARD_TARGET_V:-"$default_target_v"}

example=abort
case "${1-}" in
	--list)
		printf '%s\n' abort deferred_validation rounded_divisor division_overflow
		exit 0
		;;
	--help|-h)
		printf '%s\n' 'Usage: sh run_crash.sh [--example NAME] [--json] [--case FILE]' \
			'Use --list to see the examples. The default is abort.'
		exit 0
		;;
	--example)
		if [ "$#" -lt 2 ]; then
			printf '%s\n' 'Pass an example name after --example. Use --list to see the examples.' >&2
			exit 2
		fi
		example=$2
		shift 2
		;;
esac

case "$example" in
	abort) source="$repo_root/examples/crash.v" ;;
	deferred_validation|rounded_divisor|division_overflow) source="$repo_root/examples/crashes/$example.v" ;;
	*)
		printf 'Unknown example %s. Use --list to see the examples.\n' "$example" >&2
		exit 2
		;;
esac

case "$example" in
	rounded_divisor|division_overflow)
		if ! command -v wasmtime >/dev/null 2>&1; then
			printf '%s\n' 'This example requires wasmtime on PATH.' >&2
			exit 2
		fi
		backend=wasm
		target=wasm32_emscripten/wasm32
		;;
	*)
		case "$(uname -s)/$(uname -m)" in
			Darwin/arm64) backend=arm64; target=macos/arm64 ;;
			Linux/aarch64|Linux/arm64) backend=arm64; target=linux/arm64 ;;
			Linux/x86_64) backend=amd64; target=linux/amd64 ;;
			*)
				printf '%s\n' 'Native examples support macOS/arm64 and Linux/amd64 or arm64.' >&2
				exit 2
				;;
		esac
		;;
esac

work=$(mktemp -d "${TMPDIR:-/tmp}/vguard-crash.XXXXXX")
"$host_v" run "$repo_root" build "$source" \
	--v "$target_v" --backend "$backend" --target "$target" --out "$work/build" \
	--v-arg -gc --v-arg none >&2
exec "$host_v" run "$repo_root" run "$work/build/build.json" "$@"
