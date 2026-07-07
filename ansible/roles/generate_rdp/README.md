# generate_rdp

Generates RDP access artifacts on the Ansible controller, one per supported
tunneling backend:

- **AWS / SSM** — emits `<name>.rdp` pointing at `localhost:<ansible_port>`,
  the local listener already opened by the SSM port-forwarding tunnel for
  legacy non-workstation SSM flows.
- **AWS / SSM workstation launcher** — emits `<name>-aws-ssm-rdp.ps1`, a
  self-contained PowerShell launcher the user runs on their Windows workstation.
  The launcher verifies AWS CLI authentication, opens its own Session Manager
  port-forward to the target EC2 instance on port 3389, writes a temp `.rdp`,
  launches `mstsc`, and tears the tunnel down when `mstsc` exits.
- **GCP / IAP** — emits `<name>-iap-rdp.ps1`, a self-contained PowerShell
  launcher the user runs on their Windows workstation. The launcher picks a
  free local TCP port, opens its own `gcloud compute start-iap-tunnel` to
  the target VM, writes a temp `.rdp`, launches `mstsc`, and tears the
  tunnel back down when `mstsc` exits.
- **Azure / Bastion** — emits `<name>-azure-bastion-rdp.ps1`, a self-contained
  PowerShell launcher that opens `az network bastion tunnel` to the target VM's
  resource ID before launching `mstsc`.

## Scope: one invocation = one artifact set

Every task in this role is `run_once: true` and `delegate_to: localhost`, so the
role emits **a single artifact set for a single `rdp_target_host`** per run — it
is not a per-host role. Under `run_once`, Ansible executes against the *first*
host in the play batch, so applying the role to a multi-host group still produces
only one set, named after that first host's `rdp_environment_name`. **Set
`rdp_target_host` (and usually `rdp_environment_name`) explicitly** rather than
relying on the `inventory_hostname` defaults. To generate artifacts for several
hosts, invoke the role once per target (e.g. with `loop` over the hosts, passing
`rdp_target_host`/`rdp_environment_name` each time). Each artifact is gated
independently by transport.

---

## Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `platform` | — | **Required.** `aws`, `azure`, or `gcp` — selects which launcher(s) to emit. |
| `domain_admin_user` | — | **Required.** Username written into every artifact (e.g. `EXAMPLE\Administrator`). |
| `rdp_target_host` | `{{ inventory_hostname }}` | Inventory hostname of the VM to connect to. |
| `rdp_environment_name` | `{{ rdp_target_host }}` | Identifier used in artifact filenames and the email subject/body. |
| `rdp_output_dir` | `./rdp_artifacts` | Directory on the controller where artifacts are written. |
| `winrm_via` | _(derived)_ | Explicit transport: `direct`, `ssm`, `iap`, or `bastion` — selects which artifact is emitted (`ssm`+aws → SSM launcher; `ssm`+non-aws → legacy `.rdp`; `iap` → IAP launcher; `bastion` → Bastion launcher). Resolved by the `transport` role; when unset it derives from `platform` + the legacy `use_ssm`/`use_iap`/`use_azure_bastion` flags. |
| `rdp_aws_profile` | `""` | Optional AWS CLI profile embedded as the default `-AwsProfile` for the AWS SSM RDP launcher. Empty means use the workstation's default AWS CLI credential chain or `AWS_PROFILE`. |
| `gcp_project`, `gcp_availability_zone` | — | Required when emitting the IAP launcher (host var on `rdp_target_host` or play var); validated by an assert before rendering. |
| `gcp_iap_configuration` | `default` | Optional gcloud configuration name baked into the IAP launcher. |
| `rdp_validate_domain_prefix` | `false` | When `true`, assert the NetBIOS prefix of `domain_admin_user` equals `rdp_expected_domain_prefix` before writing any artifact. |
| `rdp_expected_domain_prefix` | `""` | Expected NetBIOS domain prefix, used only when the guard above is enabled. |
| `requester` | — | Email address; when set, the artifacts are zipped and mailed. |
| `rdp_email_from` | `ansible@localhost` | From address for the artifact email. |
| `smtp_host` | `localhost` | SMTP relay used to send the artifact email. |
| `rdp_source_project` | `n/a` | Optional free-text label included in the email body. |

For AWS SSM, the launcher uses `ansible_id` and `ansible_aws_ssm_region` from
the target host's inventory. It does **not** embed AWS access keys or secrets.
The workstation user must already have AWS CLI credentials that can call
`sts:GetCallerIdentity` and `ssm:StartSession` for the target instance
(`aws configure`, `AWS_PROFILE`, or `-AwsProfile <name>`).

The `ansible_port` value for the target host is read from `hostvars` only for
the legacy SSM `.rdp` artifact — it must already be populated by the SSM
inventory.

---

## Requirements

- For AWS SSM launcher: the end user running the `.ps1` needs valid AWS
  credentials/profile for the target account, plus a one-time elevated setup:
  `winget install Amazon.AWSCLI Amazon.SessionManagerPlugin`. The launcher
  checks the prerequisites and fails with that hint — it does not install
  anything itself. `mstsc` must be available as the Windows Remote Desktop
  client.
- For legacy SSM `.rdp`: the SSM tunnel must already be open and the SSM
  inventory loaded.
- For IAP: the target host must have `gcp_project`, `gcp_availability_zone`,
  and `gcp_iap_configuration` set. The end user running the `.ps1` needs
  Google Cloud SDK (`gcloud`) and `mstsc` on `PATH`.
- For Azure Bastion: the inventory must include `azure_vm_resource_id` and
  Bastion metadata. The end user running the `.ps1` needs Azure CLI (`az`) and
  `mstsc` on `PATH`.
- The `rdp_output_dir` directory is created by the role.

---

## Example play

```yaml
- hosts: localhost
  gather_facts: false
  tasks:
    - import_role:
        name: master_ring.windows_remote.generate_rdp
      vars:
        platform: aws
        winrm_via: ssm
        rdp_target_host: "{{ groups['windows_targets'][0] }}"
        rdp_environment_name: prod-pool4
        domain_admin_user: 'EXAMPLE\Administrator'
```

The role selects which artifacts to emit from the resolved transport
(`winrm_via` or the legacy flags) plus `platform`. Artifacts can coexist in the same
`rdp_output_dir` directory when their transports are enabled.

---

## Verification

After the role runs:

```bash
ls "$rdp_output_dir"/
# <name>.rdp           (legacy non-AWS SSM artifact)
# <name>-aws-ssm-rdp.ps1 (when platform == aws and use_ssm)
# <name>-iap-rdp.ps1   (when platform == gcp and use_iap)
# <name>-azure-bastion-rdp.ps1 (when platform == azure and use_azure_bastion)
# <name>-rdp.zip       (bundle of whichever artifacts were emitted)
```

The zip is what gets emailed to `requester` (raw `.ps1` attachments are
commonly stripped or quarantined by mail gateways; zipping sidesteps that).

For the AWS SSM launcher, run:

```powershell
powershell -ExecutionPolicy Bypass -File .\<name>-aws-ssm-rdp.ps1 -AwsProfile <profile>
```

If `-AwsProfile` is omitted, the script uses the normal AWS CLI credential
chain, including `AWS_PROFILE` if set. For the IAP launcher, double-click the
`.ps1` (or `powershell -File <name>-iap-rdp.ps1`) on a workstation that has
`gcloud` configured against the right project. Launchers print the chosen local
port and tunnel log path before starting `mstsc`.


---

## Troubleshooting

Role-side (on the controller):

| Symptom | Cause / fix |
|---|---|
| Assert failure naming missing metadata (`ansible_id`, `azure_vm_resource_id`, `gcp_project`, …) | The transport's required host vars aren't set for `rdp_target_host` — populate the inventory or pass them as play vars |
| No artifact emitted at all | The resolved transport (`winrm_via`) doesn't match any emit condition — check `platform` + `winrm_via` (or legacy `use_*` flags) |
| Email never sent | `requester` unset, or no artifacts were emitted. Note the inverse too: the email is (re)sent on **every** run while `requester` is set — there is no changed-only gating |
| Mail task fails | `smtp_host` unreachable from the controller, or the relay rejects `rdp_email_from` |

Launcher-side (on the end user's workstation — each launcher prints its tunnel
log paths at startup; read those first):

| Symptom | Cause / fix |
|---|---|
| AWS: `AWS authentication failed` | Missing/expired credentials — run `aws configure`, set `AWS_PROFILE`, or rerun with `-AwsProfile <name>`; the identity must be able to call `sts:GetCallerIdentity` and `ssm:StartSession` |
| AWS: `<tool> not found` | AWS CLI / Session Manager plugin not installed — one-time elevated setup: `winget install Amazon.AWSCLI Amazon.SessionManagerPlugin` |
| Tunnel process exits before the port opens | No permission on the target (IAP role, Bastion rights, SSM policy) or target offline — the printed tunnel log has the provider error |
| `mstsc.exe not found` | Not a full Windows workstation (e.g. Server Core) — install the RDP client or run from another machine |
| Emailed `.ps1` blocked/quarantined | Mail gateways strip raw scripts; use the `.zip` bundle the role emails (that's why it zips) |
