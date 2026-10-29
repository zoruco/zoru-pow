#!/usr/bin/env bash
set -euo pipefail
HASH="${1:?Usage: ./cmd/receipt.sh TX_HASH}"
exec "${CAST:-cast}" receipt "$HASH" \
  --rpc-url "${ZORU_RPC:-https://vexascan.com/rpc}" --json
