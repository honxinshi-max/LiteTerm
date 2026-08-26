#!/bin/sh
set -eu

project_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$project_root"

swift run \
    --package-path Tests/SSHIntegrationRunner \
    --only-use-versions-from-resolved-file \
    LiteSpaceSSHIntegrationTestRunner
