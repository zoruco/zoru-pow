#!/usr/bin/env python3
"""Check beacon recovery after a slow preflight outage on isolated VEX."""
import argparse
import hashlib
import http.client
import http.server
import json
from pathlib import Path
import subprocess
import threading
import time

from native_ram_probe import require
from testnet_miner import MinerExperiment


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ['manifest', 'miner', 'keystore', 'password-file', 'bytecode', 'output']:
        parser.add_argument('--' + name, type=Path, required=True)
    parser.add_argument('--account', required=True)
    parser.add_argument('--cast', default='cast')
    parser.add_argument('--rpc-port', type=int, default=18547)
    parser.add_argument('--read-port', type=int, default=18546)
    parser.add_argument('--native-port', type=int, default=19888)
    args = parser.parse_args()
    require(not args.output.exists(), 'Retain and reconcile an existing run')
    require(args.output.parent.is_dir(), 'Create a private evidence directory first')
    manifest = json.loads(args.manifest.read_text())
    require(manifest['mode'] == 'testnet' and manifest['chainId'] == 46736,
            'Only the isolated testnet manifest is permitted')
    experiment = MinerExperiment(args)
    experiment.verify()
    signer = subprocess.check_output([args.cast, 'wallet', 'address', '--keystore',
        str(args.keystore), '--password-file', str(args.password_file)], text=True).strip()
    require(signer.lower() == args.account.lower(), 'Unexpected test signer')
    args.peer_keystore = args.peer_password_file = args.peer_account = None
    publish = subprocess.check_output([args.cast, 'sig', 'publish(uint48,bytes)'], text=True).strip()
    started = time.monotonic()
    faults = {'outageSeconds': 75, 'preflightDelaySeconds': 3, 'failedPreflights': 0}
    lock = threading.Lock()

    class Gateway(http.server.BaseHTTPRequestHandler):
        def log_message(self, *_):
            pass

        def do_POST(self):
            size = int(self.headers.get('Content-Length', '0'))
            require(0 < size <= 1024 * 1024, 'Oversized test RPC request')
            body = self.rfile.read(size)
            request = json.loads(body)
            call = request.get('params', [{}])[0] if request.get('params') else {}
            if (time.monotonic() - started < faults['outageSeconds']
                    and request.get('method') == 'eth_call' and isinstance(call, dict)
                    and call.get('to', '').lower() == manifest['beacon'].lower()
                    and call.get('data', '').startswith(publish)):
                with lock:
                    faults['failedPreflights'] += 1
                time.sleep(faults['preflightDelaySeconds'])
                raw = json.dumps({'jsonrpc': '2.0', 'id': request['id'],
                    'error': {'code': -32000, 'message': 'Isolated beacon outage'}}).encode()
                status = 200
            else:
                port = args.rpc_port if request.get('method') == 'eth_sendRawTransaction' else args.read_port
                connection = http.client.HTTPConnection('127.0.0.1', port, timeout=20)
                try:
                    connection.request('POST', '/', body, {'Content-Type': 'application/json'})
                    response = connection.getresponse()
                    raw, status = response.read(8 * 1024 * 1024 + 1), response.status
                    require(len(raw) <= 8 * 1024 * 1024, 'Oversized test RPC response')
                finally:
                    connection.close()
            self.send_response(status)
            self.send_header('Content-Type', 'application/json')
            self.send_header('Content-Length', str(len(raw)))
            self.end_headers()
            self.wfile.write(raw)

    experiment.gateway = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Gateway)
    experiment.gateway.daemon_threads = True
    threading.Thread(target=experiment.gateway.serve_forever, daemon=True).start()
    try:
        result = experiment.run_cli('beacon-recovery', args.manifest, seconds=245)
    finally:
        experiment.gateway.shutdown()
        experiment.gateway.server_close()
    epochs = {context['epoch'] for context in result['contexts']}
    require(faults['failedPreflights'] >= 2, 'Missing slow outage witness')
    require(result['accepted'] > 0 and result['autoClaimed'] > 0 and len(epochs) >= 2,
            'Mining and automatic claims did not recover across epochs')
    experiment.result.update(schema='zoru-native-beacon-recovery-1', status='PASS',
        scope='Real isolated VEX; authenticated drand and production Keccak mining',
        binarySha256=hashlib.sha256(args.miner.read_bytes()).hexdigest(),
        faults=faults, miner=result)
    experiment.save()
    print(json.dumps({'status': 'PASS', 'accepted': result['accepted'],
        'autoClaimed': result['autoClaimed'], 'epochs': len(epochs), 'faults': faults}))


if __name__ == '__main__':
    main()
