# master_ring.windows_remote

[![CI](https://github.com/caedh121/ansible-master-ring/actions/workflows/ci.yml/badge.svg)](https://github.com/caedh121/ansible-master-ring/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)
[![ansible-core](https://img.shields.io/badge/ansible--core-%E2%89%A5%202.15-black?logo=ansible)](https://docs.ansible.com/)

**Manage Windows VMs over WinRM from a Linux Ansible controller across AWS, Azure, and GCP — without a VPN.**

Each cloud already ships an authenticated, audited, identity-based tunnel to
private instances (AWS SSM, Azure Bastion, GCP IAP). This collection wraps
them so a single inventory and play reaches Windows over WinRM through
whichever tunnel the target's cloud provides.

## Architecture

```mermaid
flowchart LR
    subgraph CTRL ["<b>Controller</b> — Linux + Ansible"]
        direction LR
        C["Ansible play"]
        L(("localhost:PORT"))
        C -- "WinRM" --> L
    end

    L -- "aws ssm start-session" --> A["AWS SSM<br/>Session Manager"]
    L -- "az network bastion tunnel" --> B["Azure<br/>Bastion"]
    L -- "gcloud start-iap-tunnel" --> G["GCP<br/>IAP"]

    subgraph PRIV ["<b>Private network</b> — no inbound internet path"]
        W["<b>Windows VM</b><br/>WinRM 5986"]
    end

    A -- "tunneled WinRM" --> W
    B -- "tunneled WinRM" --> W
    G -- "tunneled WinRM" --> W

    classDef ansible fill:#dbeafe,stroke:#1d4ed8,stroke-width:2px,color:#0b3a91
    classDef cloud fill:#fef3c7,stroke:#b45309,color:#7c2d12
    classDef local fill:#dcfce7,stroke:#15803d,color:#14532d
    classDef target fill:#fce7f3,stroke:#be185d,color:#831843

    class C ansible
    class A,B,G cloud
    class L local
    class W target

    style CTRL fill:#f0f9ff,stroke:#0284c7,stroke-width:2px
    style PRIV fill:#fef2f2,stroke:#dc2626,stroke-width:2px,stroke-dasharray: 6 4
```

The tunnel role opens a background listener on the controller and rewrites
`ansible_host` / `ansible_port` to `localhost:PORT` so every subsequent task
in the play talks WinRM transparently through the tunnel — no other role
needs to know a tunnel exists.

## Why this exists

Site-to-site VPNs across three clouds are slow, risky, and often not
permitted. Exposing WinRM to the internet is worse. The cloud-native
tunnels are already deployed, already audited, already authenticated with
IAM — this collection puts them behind a single Ansible interface so
`platform: aws` and `platform: gcp` targets look identical to your
playbooks.

## Install

**Option A — Testbox (no local toolchain required).** A disposable Docker
container ships every CLI the collection expects (ansible-core, pywinrm,
AWS CLI v2 + `session-manager-plugin`, Azure CLI, gcloud SDK), installed with
the same version ranges CI uses. Clone the repo, run one script, get an
interactive shell
with the collection already installed:

```bash
git clone https://github.com/caedh121/ansible-master-ring.git
cd ansible-master-ring
docker/run.sh          # Linux/macOS
.\docker\run.cmd       # Windows (Docker Desktop, Linux containers / WSL2)
```

See [`docker/README.md`](docker/README.md) for the full flow, credential
mounts, and troubleshooting.

**Option B — Install into your own controller.** Straight from GitHub:

```bash
ansible-galaxy collection install \
  git+https://github.com/caedh121/ansible-master-ring.git#/ansible/,main
```

Or from Ansible Galaxy (once published):

```bash
ansible-galaxy collection install master_ring.windows_remote
```

## Quick start

```yaml
- hosts: windows_targets
  gather_facts: false
  vars:
    platform: aws
    winrm_via: ssm
  pre_tasks:
    - import_role: { name: master_ring.windows_remote.aws_ssm_tunnel }
    - import_role: { name: master_ring.windows_remote.win_readiness }
  tasks:
    - ansible.windows.win_ping:
  post_tasks:
    - import_role: { name: master_ring.windows_remote.win_reboot }
      when: reboot_needed | default(false)
```

Full Azure and GCP quick starts live in
[`ansible/playbooks/examples/`](ansible/playbooks/examples/).

## Docs

- **Collection README** — [`ansible/README.md`](ansible/README.md) (roles reference, tunnel behavior on reboot, troubleshooting)
- **Per-role docs** — [`ansible/roles/`](ansible/roles/)

## Contact

**Adrian Estrada**
[![Email](https://img.shields.io/badge/email-caedh121%40gmail.com-red?logo=gmail&logoColor=white)](mailto:caedh121@gmail.com)
[![LinkedIn](https://img.shields.io/badge/LinkedIn-Adrian%20Estrada-0A66C2?logo=linkedin&logoColor=white)](https://www.linkedin.com/in/adrian-e-264a6948/)

Feel free to reach out about this
collection, hybrid-cloud Windows automation, or opportunities.

## License

MIT — see [LICENSE](LICENSE).
