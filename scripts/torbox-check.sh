#!/usr/bin/env bash
# Asks TorBox what plan the account behind a key has. The key is read from the environment and never printed.
#   TORBOX_KEY=... scripts/torbox-check.sh
set -euo pipefail
: "${TORBOX_KEY:?set TORBOX_KEY to your TorBox API key}"
curl -sS -m 20 -H "Authorization: Bearer $TORBOX_KEY" https://api.torbox.app/v1/api/user/me \
  | jq '{success, error, plan: .data.plan, premium_expires_at: .data.premium_expires_at, is_subscribed: .data.is_subscribed}'
