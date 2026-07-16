#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."

for required in README.md scripts/test.sh scripts/build.sh; do
  if [[ ! -f "$required" ]]; then
    echo "PR-07 scope validation failed: missing $required"
    exit 1
  fi
done

for forbidden in ServerDeployment StagingDeploy ProductionDeploy ManualDeploy ServerProbe ReachabilityProbe; do
  if grep -R "$forbidden" Sources Tests Package.swift README.md >/dev/null 2>&1; then
    echo "PR-07 scope violation: found out-of-scope symbol '$forbidden'"
    exit 1
  fi
done

swift test
swift build
