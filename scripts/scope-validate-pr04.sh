#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."

for forbidden in RdpSessionEngine CredentialStore Keychain ServerDeployment StagingDeploy ProductionDeploy ManualDeploy; do
  if grep -R "$forbidden" Sources Tests Package.swift >/dev/null 2>&1; then
    echo "PR-04 scope violation: found future-scope symbol '$forbidden'"
    exit 1
  fi
done

swift test
