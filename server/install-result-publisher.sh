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

install -d -o root -g root -m 755 \
  /home/hermes/.hermes/hooks/starforge-result-publisher
install -o root -g root -m 644 \
  "${script_dir}/hermes-hook/HOOK.yaml" \
  /home/hermes/.hermes/hooks/starforge-result-publisher/HOOK.yaml
install -o root -g root -m 644 \
  "${script_dir}/hermes-hook/handler.py" \
  /home/hermes/.hermes/hooks/starforge-result-publisher/handler.py
install -d -o hermes -g hermes -m 750 /home/hermes/.hermes/logs

echo "Installed /usr/local/bin/starforge-publish-result"
echo "Installed Hermes gateway hook: starforge-result-publisher"
echo "Restart the Hermes gateway to load the new hook."
