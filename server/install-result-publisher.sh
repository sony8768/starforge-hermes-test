#!/usr/bin/env bash
set -euo pipefail

if [[ "${EUID}" -ne 0 ]]; then
  echo "Run this installer with sudo." >&2
  exit 1
fi

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

install -d -o root -g root -m 755 /usr/local/lib/starforge
install -o root -g root -m 755 \
  "${script_dir}/publish_hermes_result.py" \
  /usr/local/lib/starforge/publish_hermes_result.py

ln -sfn \
  /usr/local/lib/starforge/publish_hermes_result.py \
  /usr/local/bin/starforge-publish-result

cat >/etc/sudoers.d/starforge-publish-result <<'EOF'
hermes ALL=(root) NOPASSWD: /usr/local/bin/starforge-publish-result SF-*
EOF

chown root:root /etc/sudoers.d/starforge-publish-result
chmod 440 /etc/sudoers.d/starforge-publish-result
visudo -cf /etc/sudoers.d/starforge-publish-result

echo "Installed /usr/local/bin/starforge-publish-result"
