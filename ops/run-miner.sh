#!/usr/bin/env bash
set -euo pipefail
: "${CREDENTIALS_DIRECTORY:?Service credentials are unavailable}"
: "${ZORU_MINER_ACCOUNT:?Expected mining account is required}"
wallet="$CREDENTIALS_DIRECTORY/zevo-keystore"
password_file="$CREDENTIALS_DIRECTORY/zevo-password"
test -r "$wallet" && test -r "$password_file"
exec /opt/zoru-mainnet/bin/zoru-miner-cli mine \
  --manifest /opt/zoru-mainnet/release/deployment.json \
  --read https://vexascan.com/rpc \
  --submit https://api.windcrypto.com/rpc \
  --native https://vexascan.com:8443 \
  --wallet "$wallet" --password-stdin \
  --expected-wallet "$ZORU_MINER_ACCOUNT" \
  --state-dir /var/lib/zoru-mainnet-zevo \
  --workers 2 --cpu-budget 1.0 \
  --seconds 0 --max-accepted 0 \
  --auto-claim-after "${ZORU_AUTO_CLAIM_AFTER:-10}" < "$password_file"
