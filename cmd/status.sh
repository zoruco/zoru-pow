#!/usr/bin/env bash
set -euo pipefail
RPC=${ZORU_RPC:-https://api.windcrypto.com/rpc}
CAST=${CAST:-cast}
OWNER=0x0dad2Ad1C030e2e67E7c01a952bab3ce81D4bfFC
echo "chain: $("$CAST" chain-id --rpc-url "$RPC")"
echo "owner: $OWNER"
echo "owner balance VEX: $("$CAST" balance "$OWNER" --ether --rpc-url "$RPC")"
echo "owner nonce: $("$CAST" nonce "$OWNER" --rpc-url "$RPC")"
echo "gas price wei: $("$CAST" gas-price --rpc-url "$RPC")"
