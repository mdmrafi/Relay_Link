#!/usr/bin/env bash
# setup-android-env.sh
# Completes the "critical" Android toolchain setup for RelayLink.
# Idempotent. Re-running is safe.
#
# What this does:
#   1. Persists Flutter / Android SDK / cmdline-tools / platform-tools to PATH in ~/.bashrc
#      (idempotent — won't duplicate entries).
#   2. Sets ANDROID_HOME / ANDROID_SDK_ROOT in ~/.bashrc.
#   3. Accepts all Android SDK licenses non-interactively.
#   4. Re-runs `flutter doctor` so you can verify the critical section is green.
#
# What this does NOT do:
#   - Install new packages
#   - Touch the Flutter project (no `flutter create`, no `pub get`)
#   - Install Chrome / clang / GTK (per your instruction)

set -euo pipefail

# --- Resolve paths (don't hardcode; expand ~) ---
FLUTTER_BIN="$HOME/flutter/bin"
SDK_ROOT="$HOME/Android/Sdk"
CMDLINE_TOOLS_BIN="$SDK_ROOT/cmdline-tools/latest/bin"
PLATFORM_TOOLS_BIN="$SDK_ROOT/platform-tools"

for p in "$FLUTTER_BIN" "$CMDLINE_TOOLS_BIN" "$PLATFORM_TOOLS_BIN"; do
  if [ ! -d "$p" ]; then
    echo "ERROR: expected directory not found: $p" >&2
    echo "       Confirm Flutter / Android SDK / cmdline-tools are at the paths above." >&2
    exit 1
  fi
done

BASHRC="$HOME/.bashrc"
touch "$BASHRC"

# --- 1+2. PATH and ANDROID_HOME blocks, idempotent ---
add_block() {
  local marker="$1"
  local block="$2"
  if grep -Fq "$marker" "$BASHRC"; then
    echo "[setup] PATH/ANDROID_HOME block already present in $BASHRC — skipping."
  else
    printf '\n%s\n%s\n' "# >>> relaylink-android-env ($marker) >>>" "$block" "# <<< relaylink-android-env ($marker) <<<" >> "$BASHRC"
    echo "[setup] Wrote $BASHRC block: $marker"
  fi
}

PATH_BLOCK='export PATH="$HOME/flutter/bin:$HOME/Android/Sdk/cmdline-tools/latest/bin:$HOME/Android/Sdk/platform-tools:$PATH"
export ANDROID_HOME="$HOME/Android/Sdk"
export ANDROID_SDK_ROOT="$HOME/Android/Sdk"'

add_block "path-and-android-home" "$PATH_BLOCK"

# --- 3. Accept Android SDK licenses ---
export PATH="$FLUTTER_BIN:$CMDLINE_TOOLS_BIN:$PLATFORM_TOOLS_BIN:$PATH"
export ANDROID_HOME="$SDK_ROOT"
export ANDROID_SDK_ROOT="$SDK_ROOT"

echo "[setup] Accepting Android SDK licenses (yes-piped, non-interactive)..."
yes | sdkmanager --licenses >/dev/null 2>&1 || true   # 'yes' can exit non-zero on some prompts; license state is what matters

echo "[setup] Accepting licenses via flutter (final step, also non-interactive)..."
yes | flutter doctor --android-licenses >/dev/null 2>&1 || true

# --- 4. Re-verify ---
echo
echo "[setup] Re-running flutter doctor (Android section):"
echo "--------------------------------------------------------"
flutter doctor
echo "--------------------------------------------------------"
echo
echo "[setup] Done. Open a NEW terminal (or: source ~/.bashrc) for the PATH changes to take effect."
