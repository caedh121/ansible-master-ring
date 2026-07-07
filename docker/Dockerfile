# Testbox: disposable toolchain container for master_ring.windows_remote.
# Contains the full stack the collection expects — ansible-core with the
# required Windows/CredSSP transport, the three cloud CLIs the tunnel
# roles shell out to (AWS CLI v2 + session-manager-plugin for SSM, Azure
# CLI for Bastion, gcloud SDK for IAP), plus the linters CI runs. Tools
# are installed with the same version ranges CI uses, so a run that works
# here should work in CI and vice versa.
#
# Build:  docker build -t master-ring-testbox docker/
# Run:    docker/run.sh   (Linux/macOS)   or   docker/run.cmd (Windows)

FROM ubuntu:22.04

ARG DEBIAN_FRONTEND=noninteractive

SHELL ["/bin/bash", "-o", "pipefail", "-c"]

# Base packages + apt-over-HTTPS prereqs. iproute2 gives us `ss`, used by
# the tunnel-probe tasks; procps gives us `ps` for pid-owner checks.
RUN apt-get update && apt-get install -y --no-install-recommends \
        ca-certificates curl gnupg git jq unzip less vim-tiny \
        python3 python3-pip python3-venv openssh-client apt-transport-https \
        iproute2 procps \
    && rm -rf /var/lib/apt/lists/*

# Microsoft repo: Azure CLI (for Bastion tunnel role)
RUN curl -fsSL https://packages.microsoft.com/keys/microsoft.asc \
        | gpg --dearmor -o /usr/share/keyrings/microsoft.gpg \
    && echo "deb [signed-by=/usr/share/keyrings/microsoft.gpg] https://packages.microsoft.com/repos/azure-cli/ jammy main" \
        > /etc/apt/sources.list.d/azure-cli.list \
    && apt-get update && apt-get install -y --no-install-recommends azure-cli \
    && rm -rf /var/lib/apt/lists/*

# Google Cloud CLI (for IAP tunnel role)
RUN curl -fsSL https://packages.cloud.google.com/apt/doc/apt-key.gpg \
        | gpg --dearmor -o /usr/share/keyrings/cloud.google.gpg \
    && echo "deb [signed-by=/usr/share/keyrings/cloud.google.gpg] https://packages.cloud.google.com/apt cloud-sdk main" \
        > /etc/apt/sources.list.d/google-cloud-sdk.list \
    && apt-get update && apt-get install -y --no-install-recommends google-cloud-cli \
    && rm -rf /var/lib/apt/lists/*

# AWS CLI v2 (for the SSM tunnel role and any AWS-side operations)
RUN curl -fsSL "https://awscli.amazonaws.com/awscli-exe-linux-$(uname -m).zip" -o /tmp/awscli.zip \
    && unzip -q /tmp/awscli.zip -d /tmp \
    && /tmp/aws/install \
    && rm -rf /tmp/aws /tmp/awscli.zip

# AWS Session Manager plugin — REQUIRED by aws_ssm_tunnel.
# `aws ssm start-session` shells out to it to do the actual port-forward.
# AWS publishes the .deb under path segments that DO NOT match the Debian
# arch names (dpkg says `amd64` but the S3 path is `ubuntu_64bit`), so we
# translate here — otherwise the fetch 403s because the object doesn't
# exist at the `ubuntu_amd64` path.
RUN case "$(dpkg --print-architecture)" in \
        amd64) SSM_ARCH="ubuntu_64bit" ;; \
        arm64) SSM_ARCH="ubuntu_arm64" ;; \
        *) echo "unsupported architecture: $(dpkg --print-architecture)" >&2; exit 1 ;; \
    esac \
    && curl -fsSL "https://s3.amazonaws.com/session-manager-downloads/plugin/latest/${SSM_ARCH}/session-manager-plugin.deb" \
        -o /tmp/ssm-plugin.deb \
    && apt-get install -y /tmp/ssm-plugin.deb \
    && rm /tmp/ssm-plugin.deb

# ansible-core + WinRM/CredSSP transport + linters (same version ranges as CI)
RUN pip3 install --no-cache-dir \
        "ansible-core>=2.15,<2.18" \
        "ansible-lint>=6.22" "yamllint>=1.35" \
        "pywinrm>=0.4" requests-credssp

# Warm the collection cache; entrypoint reinstalls from the mounted repo
# so version drift with galaxy.yml is corrected at start-up.
RUN ansible-galaxy collection install \
        "ansible.windows:>=1.5.0" "community.general:>=3.0.0"

WORKDIR /work
COPY entrypoint.sh /usr/local/bin/entrypoint.sh
COPY tools-check.sh /usr/local/bin/tools-check
RUN chmod +x /usr/local/bin/entrypoint.sh /usr/local/bin/tools-check
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
