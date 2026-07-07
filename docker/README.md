# Testbox — containerized toolchain for master_ring.windows_remote

A disposable Docker container with everything the collection expects
(ansible-core, `ansible.windows`, `community.general`, pywinrm/CredSSP,
AWS CLI v2 + session-manager-plugin, Azure CLI, gcloud SDK), so any Docker
host — Linux server or Windows workstation — becomes a consistent place to
clone and run the collection against real infrastructure. Tools are
installed with the same version ranges CI uses, so a run that works here
should work in CI, and vice versa.

## Quick start

Linux / macOS:

```bash
git clone https://github.com/caedh121/ansible-master-ring.git
cd ansible-master-ring
docker/run.sh              # builds the image on first use, then drops to a shell
```

Windows (Docker Desktop with Linux containers / WSL2):

```powershell
git clone https://github.com/caedh121/ansible-master-ring.git
cd ansible-master-ring
.\docker\run.ps1
```

Inside the container:

- The repo is at `/work/repo`.
- The collection is already installed from `/work/repo/ansible` — you can
  reference `master_ring.windows_remote.<role>` FQCNs directly.
- A persistent work directory (host: `~/testbox-work`, override with
  `TESTBOX_WORK_DIR`) is at `/work`.
- `/work/TEST-NOTES.md` is pre-created for logging failures and evidence —
  deliberately *outside* the repo so it can never be committed.

Host credential directories (`~/.aws`, `~/.azure`, `~/.config/gcloud`) are
mounted automatically when they exist. Proxy vars (`HTTP_PROXY`,
`HTTPS_PROXY`, `NO_PROXY`) and Ansible auth env vars (`ANSIBLE_USER`,
`ANSIBLE_PASSWORD`, `ANSIBLE_VAULT_PASSWORD_FILE`) pass through from the
host environment when set.

No local clone? Set `GH_TOKEN` to a read-only fine-grained PAT and the
entrypoint clones the repo itself (override the source with `REPO_URL`).

## What to run, in order

1. `tools-check` — verify every CLI resolves and prints a version.
2. `ansible-lint /work/repo/ansible` — the same check CI runs.
3. Point an inventory at your test host and run one of the quick-start
   playbooks under `/work/repo/ansible/playbooks/examples/`:
   - `aws_ssm_connect.yml` (AWS, requires `session-manager-plugin` — bundled)
   - `azure_bastion_connect.yml`
   - `gcp_iap_connect.yml`

Record evidence (session IDs, tunnel ports, apply summaries) in
`/work/TEST-NOTES.md`.

## Limitations

- **You still need to be authenticated to each cloud.** The container
  mounts your `~/.aws`, `~/.azure`, `~/.config/gcloud` if they exist; if
  they don't, run `aws configure`, `az login --use-device-code`, and
  `gcloud auth login` inside the container. Tokens persist on the mount.
- **Container must have network reach to the target's WinRM port**
  (5985/5986) — check routing/firewall from the *Docker host*, and
  remember NAT: the target sees the host's IP, not the container's.

## How it fails / troubleshooting

| Symptom | Cause / fix |
|---|---|
| `docker daemon not reachable` | Docker not running, or your user lacks the `docker` group (Linux) / Docker Desktop stopped (Windows). |
| Image build fails fetching apt repos | Corporate proxy: `export HTTP_PROXY=... HTTPS_PROXY=...` before `run.sh` (passed through), and configure Docker's own proxy for the build (`~/.docker/config.json` → `proxies`). |
| WinRM connect fails from container | Container must have L3 reach to the target on 5985/5986. Check host firewall / routing; verify from the Docker host with `nc -vz <target> 5986` first. |
| `az` / `gcloud` token errors | Re-run `az login` / `gcloud auth login` inside the container; ensure `~/.azure` / `~/.config/gcloud` are mounted read-write (default). |
| `session-manager-plugin` not found when the SSM tunnel role runs | The image bundles it; if `tools-check` reports it missing, rebuild the image with `docker/run.sh --rebuild`. |
| Clone fails with 404 | The repo is private: `GH_TOKEN` missing/expired, or the PAT isn't scoped to this repo. |

## Manual fallback

If Docker is unavailable, install the toolchain natively and run the same
commands:

```bash
pip install "ansible-core>=2.15,<2.18" "pywinrm>=0.4" requests-credssp \
            ansible-lint yamllint
ansible-galaxy collection install ansible.windows community.general
# Then whichever cloud CLIs you need:
#   AWS:   awscli v2 + session-manager-plugin
#   Azure: azure-cli
#   GCP:   google-cloud-cli
ansible-galaxy collection install ./ansible --force
```

The CI workflow (`.github/workflows/ci.yml`) shows the exact validation
commands.
