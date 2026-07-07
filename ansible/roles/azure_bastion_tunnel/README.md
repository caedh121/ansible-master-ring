# azure_bastion_tunnel

Opens an Azure Bastion TCP tunnel from the Ansible controller to an Azure VM,
then repoints the host's WinRM connection to `localhost:<local_port>` so all
subsequent tasks reach the VM through the tunnel.

The role uses `az network bastion tunnel --target-resource-id`, which requires a
**Standard SKU** Bastion host with native-client tunneling enabled.

## Variables

Each input resolves in order: role var → hostvar on the target host → legacy bare
var. All of bastion name / resource group / subscription / target resource ID,
plus a local port, are required (the role asserts this and fails fast).

| Variable | Default | Description |
|---|---|---|
| `target_host` | `inventory_hostname` | Host to tunnel to. Override to tunnel to a different host without hijacking this host's WinRM connection. |
| `target_resource_id` / hostvar `azure_vm_resource_id` | — | Full ARM resource ID of the target VM. |
| `azure_bastion_name` / hostvar / `bastion_name` | — | Bastion host name. |
| `azure_bastion_resource_group_name` / hostvar / `bastion_resource_group_name` | — | Bastion resource group. |
| `azure_bastion_subscription_id` / hostvar | — | Subscription ID. |
| `remote_port` | `5986` | Target WinRM port (5985 HTTP / 5986 HTTPS). |
| `local_port` (or hostvar `azure_bastion_local_port`, or `ansible_port`) | _(unset)_ | Local listener port on the controller. |
| `use_azure_bastion` | `false` | Gate flag consumed by callers. |
| `tunnel_state_dir` | `{{ ssm_tunnel_state_dir \| default('/tmp/ansible_tunnels') }}` | Directory for `.pid` / `.port` state files (keyed per `target_host` + `remote_port`). |

## Idempotency & stale tunnel handling

The role reuses an existing tunnel only when the recorded PID is **alive**, is
genuinely an `az ... bastion tunnel` process (verified via `/proc/<pid>/cmdline`),
**and owns** the `127.0.0.1:<local_port>` listener (verified via `ss -ltnp`).

A naive "is the port open?" check is unsafe: an interrupted previous run can leave
an **orphaned** `az` tunnel that keeps the local listener open but no longer
forwards, so the port accepts TCP while WinRM rides a dead pipe and times out. To
prevent this, before starting a fresh tunnel the role **kills any orphaned
`bastion tunnel` process bound to the target local port**, then waits for an
`az ... bastion tunnel` process to actually own the port (not merely for the port
to accept TCP). It records the PID that owns the listener — which may differ from
the launched `az` PID if `az` forks its worker. This makes the role self-healing
across interrupted runs even when `teardown` never ran.

## Behavior during reboot

The Bastion tunnel process runs on the **controller** and reconnects when the VM
returns, so it **survives a guest reboot** — `win_reboot` uses a plain reboot for
Azure rather than a tunnel rebuild. Use `teardown` only for explicit end-of-play
cleanup.

## Requirements

- Azure CLI (`az`) on the controller, logged in (`az login`) with rights over the
  Bastion host and target VM.
- A **Standard SKU** Bastion with native-client tunneling enabled.
- `ss` (from `iproute2`) and Linux `/proc` on the controller — used to verify port
  ownership and reclaim orphaned tunnels. The role asserts `az` and `ss` are present.

## Teardown

```yaml
- ansible.builtin.import_role:
    name: master_ring.windows_remote.azure_bastion_tunnel
    tasks_from: teardown
```

Kills every recorded tunnel for the target host and removes its pid/port state
files — including tunnels opened on non-default ports, so nothing leaks when
`remote_port` is not re-passed at teardown time. Set `teardown_remote_port` to
scope the teardown to a single port.
