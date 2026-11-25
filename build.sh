#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"

oxrsys_revision=a87f56f5274b322adc0c7bcc6a9b318be6d3b7f4
vulkan_tag=v1.4.328
mkdir -p .build/runtime

case "${1:-}" in
    ''|--simulator) ;;
    *) echo "Usage: $0 [--simulator]" >&2; exit 2 ;;
esac

if [[ -n "${MIRU_OXRSYS_BUILD:-}" ]]; then
    dependency_build="$(cd "$MIRU_OXRSYS_BUILD" && pwd)"
    if [[ "$(git -C "$dependency_build/oxrsys" rev-parse HEAD)" != "$oxrsys_revision" ]]; then
        echo "MIRU_OXRSYS_BUILD must contain OXRSys revision $oxrsys_revision." >&2
        exit 1
    fi
else
    dependency_build="$PWD/.build/dependencies"
    mkdir -p "$dependency_build"
    if [[ ! -d "$dependency_build/oxrsys/.git" ]]; then
        git init -q "$dependency_build/oxrsys"
        git -C "$dependency_build/oxrsys" remote add origin https://github.com/demonixis/oxrsys.git
    fi
    if [[ "$(git -C "$dependency_build/oxrsys" rev-parse --verify HEAD 2>/dev/null || true)" != "$oxrsys_revision" ]]; then
        git -C "$dependency_build/oxrsys" fetch --depth 1 origin "$oxrsys_revision"
        git -C "$dependency_build/oxrsys" checkout --detach FETCH_HEAD
    fi
    if [[ ! -f "$dependency_build/vulkan-headers/include/vulkan/vulkan.h" ]]; then
        git clone --depth 1 --branch "$vulkan_tag" https://github.com/KhronosGroup/Vulkan-Headers.git "$dependency_build/vulkan-headers"
    fi
    cmake -S "$dependency_build/oxrsys" -B "$dependency_build/runtime" -G Ninja \
        -DCMAKE_BUILD_TYPE=Release -DOXRSYS_VULKAN_INCLUDE_DIR="$dependency_build/vulkan-headers/include"
    cmake --build "$dependency_build/runtime" --target oxrsys_runtime openxr_loader
fi

runtime="$dependency_build/runtime/runtime"
loader="$dependency_build/runtime/_deps/openxr-build/src/loader"
headers="$dependency_build/runtime/_deps/openxr-src/include"
cp "$runtime/liboxrsys-runtime.dylib" "$runtime/oxrsys-runtime.json" "$loader/libopenxr_loader.dylib" .build/runtime/
if [[ ! -f .build/runtime/oxrsys-runtime.toml ]]; then
    sed -e 's/^passthrough_enabled = false$/passthrough_enabled = true/' \
        -e 's/^app_alpha_blend_passthrough = false$/app_alpha_blend_passthrough = true/' \
        "$runtime/oxrsys-runtime.toml" > .build/runtime/oxrsys-runtime.toml
fi

cp Sources/Shaders.metal .build/Shaders.metal
xcrun swiftc -target "$(uname -m)-apple-macosx14.0" -O \
    -module-cache-path .build/swift-cache -I Sources/COpenXR -Xcc -I -Xcc "$headers" \
    -L .build/runtime -lopenxr_loader -Xlinker -rpath -Xlinker '@executable_path/runtime' \
    Sources/*.swift -o .build/miru

if [[ "${1:-}" == --simulator ]]; then
    simulator_source="$PWD/.build/simulator-source"
    mkdir -p "$simulator_source"
    git -C "$dependency_build/oxrsys" archive "$oxrsys_revision" clients/simulator clients/shared config |
        tar -x -C "$simulator_source"
    patch -s -d "$simulator_source" -p1 < Patches/simulator-controller-follow.patch
    xcodebuild -project "$simulator_source/clients/simulator/OXRSys Simulator.xcodeproj" \
        -scheme 'OXRSys Simulator' -configuration Debug -destination 'platform=macOS' \
        -derivedDataPath "$PWD/.build/simulator" CODE_SIGNING_ALLOWED=NO build
    simulator="$PWD/.build/simulator/Build/Products/Debug/OXRSys Simulator.app"
    printf '%s\n' "$simulator" > .build/simulator-path
fi
