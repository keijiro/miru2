#!/bin/bash
set -euo pipefail
project_dir="$(cd "$(dirname "$0")" && pwd)"
build_dir="$project_dir/.build"
if [[ ! -x "$build_dir/miru" || ! -f "$build_dir/runtime/oxrsys-runtime.json" ]]; then
    echo "Run $project_dir/build.sh first." >&2
    exit 1
fi
simulator=false
for option in "$@"; do
    case "$option" in
        --simulator) simulator=true ;;
        -h|--help) simulator=false; break ;;
    esac
done
if [[ "$simulator" == true ]]; then
    if [[ ! -f "$build_dir/simulator-path" ]]; then
        echo "Run $project_dir/build.sh --simulator first." >&2
        exit 1
    fi
    open "$(cat "$build_dir/simulator-path")"
fi
export XR_RUNTIME_JSON="$build_dir/runtime/oxrsys-runtime.json"
exec "$build_dir/miru" "$@"
