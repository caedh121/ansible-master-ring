# Tests

This collection ships example playbooks under `playbooks/examples/`. Until full
integration tests are added, validate the collection with syntax checks and a
build/install round-trip.

## Syntax-check the example playbooks

```bash
# From the collection root (this directory's parent):
for p in playbooks/examples/*.yml; do
  ansible-playbook --syntax-check "$p" \
    -i 'windows_targets,' -e 'ansible_connection=local'
done
```

## Build + install round-trip

```bash
ansible-galaxy collection build .
ansible-galaxy collection install master_ring-windows_remote-*.tar.gz -p ./collections --force
```

## Lint (optional)

```bash
ansible-lint roles/ playbooks/
```
