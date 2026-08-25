#!/bin/bash
#
# Builds libmarkdown_core.a for the architectures Xcode asked for and merges them
# into a single static library the app target links against.
#
# On macOS it also builds the vendored solomd-mcp binary and drops it into the app
# bundle's Resources, so the MCP server ships with the app instead of being a separate
# install. See vendor/solomd-mcp/PROVENANCE.md.
#
# Invoked from the "Build Rust core" run script phase of the Markdown target, and
# usable standalone: `./build-xcode.sh` builds a Debug slice for the host machine.
#
set -euo pipefail

cd "$(dirname "$0")"

# Xcode's build environment has a minimal PATH.
export PATH="$HOME/.cargo/bin:$HOME/.bun/bin:/opt/homebrew/bin:/usr/local/bin:$PATH"

if ! command -v cargo >/dev/null 2>&1; then
  echo "error: cargo not found. Install Rust from https://rustup.rs" >&2
  exit 1
fi

CONFIGURATION="${CONFIGURATION:-Debug}"
PLATFORM_NAME="${PLATFORM_NAME:-macosx}"
ARCHS="${ARCHS:-$(uname -m)}"

if [ "$CONFIGURATION" = "Debug" ]; then
  CARGO_PROFILE="dev"
  PROFILE_DIR="debug"
else
  CARGO_PROFILE="release"
  PROFILE_DIR="release"
fi

rust_target_for() {
  local arch="$1"
  case "$PLATFORM_NAME" in
    macosx)
      case "$arch" in
        arm64|arm64e) echo "aarch64-apple-darwin" ;;
        x86_64) echo "x86_64-apple-darwin" ;;
        *) return 1 ;;
      esac
      ;;
    iphoneos)
      [ "$arch" = "arm64" ] && echo "aarch64-apple-ios" || return 1
      ;;
    iphonesimulator)
      case "$arch" in
        arm64) echo "aarch64-apple-ios-sim" ;;
        x86_64) echo "x86_64-apple-ios" ;;
        *) return 1 ;;
      esac
      ;;
    *) return 1 ;;
  esac
}

TARGETS=()
for arch in $ARCHS; do
  if ! target="$(rust_target_for "$arch")"; then
    echo "error: no Rust target for arch '$arch' on platform '$PLATFORM_NAME'" >&2
    exit 1
  fi
  TARGETS+=("$target")
done

INSTALLED="$(rustup target list --installed 2>/dev/null || true)"
SLICES=()
for target in "${TARGETS[@]}"; do
  if [ -n "$INSTALLED" ] && ! grep -qx "$target" <<<"$INSTALLED"; then
    echo "note: installing Rust target $target"
    rustup target add "$target"
  fi

  # Keep Xcode's include/library paths away from the Rust build; the target triple already
  # pins the platform and stale values break cross-arch builds.
  #
  # SDKROOT is *set* rather than unset: dependencies that compile C (libgit2 and zlib, via
  # git2) need a sysroot, and clearing it leaves them unable to find even <sys/types.h>.
  # Pointing it at the SDK for the platform being built satisfies both concerns.
  SDK_PATH="$(xcrun --sdk "$PLATFORM_NAME" --show-sdk-path)"
  env -u CPATH -u LIBRARY_PATH -u RUSTFLAGS SDKROOT="$SDK_PATH" \
    cargo build \
      --manifest-path markdown_core/Cargo.toml \
      --target "$target" \
      --profile "$CARGO_PROFILE"

  SLICES+=("target/$target/$PROFILE_DIR/libmarkdown_core.a")
done

OUTPUT_DIR="target/apple/$PLATFORM_NAME-$CONFIGURATION"
mkdir -p "$OUTPUT_DIR"
OUTPUT="$OUTPUT_DIR/libmarkdown_core.a"

if [ "${#SLICES[@]}" -eq 1 ]; then
  cp -f "${SLICES[0]}" "$OUTPUT"
else
  lipo -create "${SLICES[@]}" -output "$OUTPUT"
fi

echo "note: built $OUTPUT ($(printf '%s ' "${TARGETS[@]}"))"

# The MCP server is a macOS-only sidecar: Claude Desktop and Claude Code launch it as a
# process, which has no meaning on iOS or visionOS.
if [ "$PLATFORM_NAME" = "macosx" ]; then
  MCP_SLICES=()
  for target in "${TARGETS[@]}"; do
    SDK_PATH="$(xcrun --sdk "$PLATFORM_NAME" --show-sdk-path)"
    env -u CPATH -u LIBRARY_PATH -u RUSTFLAGS SDKROOT="$SDK_PATH" \
      cargo build \
        --manifest-path vendor/solomd-mcp/Cargo.toml \
        --target "$target" \
        --profile "$CARGO_PROFILE"
    MCP_SLICES+=("target/$target/$PROFILE_DIR/solomd-mcp")
  done

  MCP_OUTPUT="$OUTPUT_DIR/solomd-mcp"
  if [ "${#MCP_SLICES[@]}" -eq 1 ]; then
    cp -f "${MCP_SLICES[0]}" "$MCP_OUTPUT"
  else
    lipo -create "${MCP_SLICES[@]}" -output "$MCP_OUTPUT"
  fi

  # Copy straight into the bundle rather than adding a Copy Files phase, so the whole
  # sidecar story lives in this one script.
  #
  # It must go in Contents/MacOS, not Contents/Resources: macOS refuses to execute a Mach-O
  # from Resources inside a signed bundle (the process dies on SIGKILL with no diagnostic).
  if [ -n "${BUILT_PRODUCTS_DIR:-}" ] && [ -n "${EXECUTABLE_FOLDER_PATH:-}" ]; then
    EXEC_DIR="$BUILT_PRODUCTS_DIR/$EXECUTABLE_FOLDER_PATH"
    mkdir -p "$EXEC_DIR"
    cp -f "$MCP_OUTPUT" "$EXEC_DIR/solomd-mcp"

    # Sign it here. Cargo leaves a "linker-signed" ad-hoc signature, which taskgated
    # rejects once the binary sits inside a properly signed bundle — the process dies on
    # SIGKILL with "Code Signature Invalid" and no other diagnostic. Xcode's own signing
    # phase seals the bundle afterwards and does not re-sign nested executables for us.
    if [ "${CODE_SIGNING_ALLOWED:-YES}" = "YES" ] && [ -n "${EXPANDED_CODE_SIGN_IDENTITY:-}" ]; then
      codesign --force --sign "$EXPANDED_CODE_SIGN_IDENTITY" \
        --options runtime --timestamp=none \
        "$EXEC_DIR/solomd-mcp"
      echo "note: signed solomd-mcp with $EXPANDED_CODE_SIGN_IDENTITY_NAME"
    fi
    echo "note: bundled solomd-mcp into $EXEC_DIR"
  fi
  echo "note: built $MCP_OUTPUT"
fi
