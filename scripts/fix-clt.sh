#!/bin/bash
# Generates .clt-fix/overlay.yaml, a compiler VFS overlay that masks a stale
# duplicate modulemap left behind by a half-updated Command Line Tools install:
# /Library/Developer/CommandLineTools/usr/include/swift/ contains BOTH
# module.modulemap (old) and bridging.modulemap (new), each defining module
# SwiftBridging. That collision aborts every SDK interface build with a
# misleading "SDK is not supported by the compiler" error. The overlay makes
# the old file appear empty. All swiftc invocations in the Makefile pass
# -vfsoverlay .clt-fix/overlay.yaml.
# Proper fix: reinstall the CLT (sudo rm -rf /Library/Developer/CommandLineTools
# && xcode-select --install), then this overlay becomes a harmless no-op.
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p .clt-fix
printf '// stale duplicate of bridging.modulemap, masked by PDFInk build overlay\n' > .clt-fix/empty.modulemap
cat > .clt-fix/overlay.yaml <<YAML
{
  "version": 0,
  "roots": [
    {
      "name": "/Library/Developer/CommandLineTools/usr/include/swift/module.modulemap",
      "type": "file",
      "external-contents": "$PWD/.clt-fix/empty.modulemap"
    }
  ]
}
YAML
echo "Wrote .clt-fix/overlay.yaml"
