#!/bin/sh
set -eu

repo_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
host_v=${VGUARD_HOST_V:-"$HOME/dev/v/v"}
default_target_v="$repo_root/../v/v"
if [ -x "$repo_root/../v/v-vguard" ]; then
	default_target_v="$repo_root/../v/v-vguard"
fi
target_v=${VGUARD_TARGET_V:-"$default_target_v"}

case "$(uname -s)/$(uname -m)" in
	Darwin/arm64) backend=arm64; target=macos/arm64 ;;
	Linux/aarch64|Linux/arm64) backend=arm64; target=linux/arm64 ;;
	Linux/x86_64) backend=amd64; target=linux/amd64 ;;
	*)
		printf '%s\n' 'The crash example supports macOS/arm64 and Linux/amd64 or arm64.' >&2
		exit 2
		;;
esac

work=$(mktemp -d "${TMPDIR:-/tmp}/vguard-crash.XXXXXX")
"$host_v" run "$repo_root" build "$repo_root/examples/crash.v" \
	--v "$target_v" --backend "$backend" --target "$target" --out "$work/build" \
	--v-arg -gc --v-arg none >&2
exec "$host_v" run "$repo_root" run "$work/build/build.json" "$@"
