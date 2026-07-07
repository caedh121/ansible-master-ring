#!/usr/bin/env bash
# Non-interactive smoke test: prove every tool the collection needs
# resolves and runs. Used by CI and available inside the container as
# `tools-check` for a quick health check after proxy/network changes.
set -euo pipefail

fail=0
check() {
    local name="$1"; shift
    local out
    # Capture fully, then trim to the first line — piping to `head` would
    # SIGPIPE tools that print multi-line version output.
    if out=$("$@" 2>&1); then
        printf '  %-22s %s\n' "$name" "${out%%$'\n'*}"
    else
        printf '  %-22s FAILED: %s\n' "$name" "${out%%$'\n'*}"
        fail=1
    fi
}

echo "tool versions:"
check ansible-core          ansible --version
check ansible-lint          ansible-lint --version
check yamllint              yamllint --version
check aws                   aws --version
check session-manager-plugin session-manager-plugin --version
check az                    az version --output tsv --query '"azure-cli"'
check gcloud                gcloud --version
check git                   git --version
check python3               python3 --version
check pywinrm               python3 -c 'import winrm; print(winrm.__version__)'
check collections           ansible-galaxy collection list --format yaml

exit $fail
