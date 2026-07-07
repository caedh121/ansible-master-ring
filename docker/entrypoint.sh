#!/usr/bin/env bash
# Testbox entrypoint: make sure the collection source is present at
# /work/repo (mounted checkout preferred, token/public clone as fallback),
# install it into ~/.ansible/collections so playbooks can reference
# master_ring.windows_remote.* FQCNs, print a tool/version banner, then
# drop to a shell.
set -euo pipefail

REPO_URL="${REPO_URL:-https://github.com/caedh121/ansible-master-ring.git}"

if [ -d /work/repo/.git ]; then
    echo ">> Using mounted repo at /work/repo"
elif [ -n "${GH_TOKEN:-}" ]; then
    echo ">> Cloning ${REPO_URL} (token)"
    git clone "https://x-access-token:${GH_TOKEN}@${REPO_URL#https://}" /work/repo
else
    echo ">> Cloning ${REPO_URL} (public)"
    git clone "$REPO_URL" /work/repo
fi

# Install the collection from the mounted checkout. --force overrides the
# warm ansible.windows / community.general cache baked into the image so
# whatever galaxy.yml declares wins. -p targets the user-level path
# explicitly so ansible-galaxy does NOT default to ./.ansible/ inside the
# mounted repo (which would pollute the host checkout and cause a
# duplicate-install warning from ansible-lint).
ansible-galaxy collection install /work/repo/ansible --force \
    -p /root/.ansible/collections >/dev/null

touch /work/TEST-NOTES.md

cat <<BANNER

=== master-ring-testbox =====================================================
 ansible-core $(ansible --version | head -1 | grep -oE '[0-9.]+' | head -1)  ansible-lint $(ansible-lint --version 2>/dev/null | head -1 | awk '{print $2}')  yamllint $(yamllint --version | awk '{print $2}')
 aws $(aws --version 2>&1 | awk '{print $1}' | cut -d/ -f2)  session-manager-plugin $(session-manager-plugin --version 2>/dev/null | head -1)
 az $(az version --query '"azure-cli"' -o tsv 2>/dev/null)  gcloud $(gcloud version 2>/dev/null | head -1 | awk '{print $4}')

 Repo:        /work/repo
 Collection:  master_ring.windows_remote  (installed from /work/repo/ansible)
 Notes file:  /work/TEST-NOTES.md   <- log failures VERBATIM + evidence here
                                       (lives OUTSIDE the repo; never committed)
 Cred mounts: ~/.aws ~/.azure ~/.config/gcloud (if present on the host)

 Try (shell already cd'd to /work/repo/ansible so configs are picked up):
   tools-check                                    # health-check every CLI
   ansible-lint                                   # what CI runs (picks up .ansible-lint)
   ls roles                                       # available roles
   less roles/aws_ssm_tunnel/README.md            # role docs

 Then wire up an inventory (see playbooks/examples/) and run the quick-start
 playbook for whichever cloud you're testing against.

 Rules: NO commits/pushes from this container. Environment specifics go in
 inventory / env vars, never in committed files.
=============================================================================

BANNER

# Drop the user into the collection root, not /work. This matters because
# ansible-lint searches for .ansible-lint from CWD upward; if you're at
# /work when you run it, the config is missed and the default (basic)
# profile fires ~275 style rules instead of the configured 'min'.
cd /work/repo/ansible
exec "${@:-bash}"
