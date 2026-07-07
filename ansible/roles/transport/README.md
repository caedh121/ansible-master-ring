# transport

Resolves which transport carries a host's WinRM connection into a single fact,
**`winrm_via_resolved`** — the collection's one source of truth for
transport decisions. `win_reboot` (reboot dispatch) and `generate_rdp`
(artifact selection) import this role instead of re-deriving the
platform/`use_*` boolean lattice, which is how transport-mismatch bugs happen
(e.g. rebooting over SSM while the tunnel and RDP artifacts assume IAP).

> **Not to be confused with `ansible_winrm_transport`.** That core Ansible
> connection variable selects the WinRM *authentication* mechanism
> (`ntlm`/`credssp`/`kerberos`/`basic`) inside an already-established
> connection. `winrm_via` selects the *network path* used to
> reach WinRM at all (direct vs. SSM/IAP/Bastion tunnel). The two are
> independent and commonly used together — e.g.
> `ansible_winrm_transport: credssp` over `winrm_via: ssm`.
> The name deliberately avoids the word "transport" so it cannot be confused
> with `ansible_winrm_transport` — or collide with the common inventory
> convention of a bare `winrm_transport` var feeding it.

## Usage

Preferred — declare the transport explicitly (host var, group var, or play var):

```yaml
winrm_via: iap   # one of: direct | ssm | iap | bastion
```

Then anywhere you need to branch:

```yaml
- ansible.builtin.import_role:
    name: master_ring.windows_remote.transport

- ansible.builtin.import_role:
    name: master_ring.windows_remote.aws_ssm_tunnel
  when: winrm_via_resolved == 'ssm'
```

## Variables

| Variable | Default | Description |
|---|---|---|
| `winrm_via` | `""` | Explicit transport: `direct`, `ssm`, `iap`, or `bastion`. Any other non-empty value fails an assert. Empty = derive from legacy flags. |

### Legacy derivation (deprecated fallback)

When `winrm_via` is unset, the transport is derived from `platform` and
the legacy `use_ssm` / `use_iap` / `use_azure_bastion` flags, preserving the
collection's historical priority:

1. `platform: gcp` and `use_iap` (defaults **true** for GCP) → `iap`
2. `platform: azure` and `use_azure_bastion` (defaults false) → `bastion`
3. `use_ssm` (defaults false) → `ssm`
4. otherwise → `direct`

Platform-native tunnels outrank SSM because their controller-side processes
survive guest reboots; on such hosts SSM is a side-channel, not the WinRM
transport. The `use_*` flags remain supported but deprecated — prefer setting
`winrm_via` explicitly per host/group.

## Failure modes

- **Assert failure `winrm_via='...' is not a valid transport`** — a typo
  or unsupported value was set explicitly; use one of the four values or unset.
- **Wrong transport derived** — only possible via the legacy fallback when the
  `use_*` flags disagree with reality (e.g. `use_ssm: true` left set on an IAP
  host derives `iap` by priority, which is correct; but `use_iap: false` on an
  IAP host falls through to `ssm`/`direct`). Diagnose with
  `-e winrm_via=<expected>` to override, then fix the inventory flags —
  or migrate the inventory to explicit `winrm_via` and stop relying on
  the flags.

## Manual fallback

The role only computes a fact. If it's unavailable, set the fact yourself:

```yaml
- ansible.builtin.set_fact:
    winrm_via_resolved: iap
```
