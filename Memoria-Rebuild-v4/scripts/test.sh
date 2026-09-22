#!/bin/zsh
set -euo pipefail
cd "$(dirname "$0")/.."
# CLT 6.4 intermittently omits the bundled Swift Testing macro search path.
# Explicitly provide the installed toolchain path; do not disable any checks.
swift_binary="$(xcrun --find swiftc)"
plugin_dir="${swift_binary:h:h}/lib/swift/host/plugins/testing"
if [[ -d "$plugin_dir" ]]; then
  swift test -Xswiftc -plugin-path -Xswiftc "$plugin_dir"
else
  swift test
fi
