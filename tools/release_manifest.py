#!/usr/bin/env python3
"""Export build fingerprints and verify an explicit mainnet deployment."""
import argparse
import hashlib
import json
from pathlib import Path
import shutil
import subprocess
import time
import urllib.parse
import urllib.request

ROOT = Path(__file__).resolve().parents[1]
NAMES = {'token': 'ZoruToken', 'ledger': 'ZoruLedger', 'engine': 'ZoruKeccakEngine', 'beacon': 'ZoruDrandBeacon', 'admin': 'ZoruAdminAdapter'}
SLOT = '0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc'
DRAND = '04f1e9062b8a81f848fded9c12306733282b2727ecced50032187751166ec8c3'
NATIVE = 'f9f432b1851b5c179d2091a96f593aaed50ec7466b74f89301f957a83e56ce1f'


def save(path, data):
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(data, indent=2) + '\n')


def sha(data):
    return hashlib.sha256(data).hexdigest()


def command(program, *args, cwd=None):
    executable = shutil.which(program)
    if not executable:
        raise ValueError(f'{program} is required on PATH')
    return subprocess.check_output([executable, *args], text=True, cwd=cwd).strip()


def keccak(data):
    return command('cast', 'keccak', data)


def runtime_artifact(name):
    return json.loads((ROOT / f'contracts/out-runtime/{name}.sol/{name}.json').read_text())['deployedBytecode']


def runtime_code(name, immutable_address=None):
    artifact = runtime_artifact(name)
    code = bytearray.fromhex(artifact['object'].removeprefix('0x'))
    references = artifact.get('immutableReferences', {})
    if references:
        # Each supported runtime has exactly one immutable: the token pointer
        # in the coordinator, or the actual ProxyAdmin in a transparent proxy.
        if immutable_address is None or len(references) != 1:
            raise ValueError(f'{name}: unreviewed immutable layout')
        replacement = int(immutable_address, 16).to_bytes(32, 'big')
        for entries in references.values():
            for item in entries:
                start, length = item['start'], item['length']
                if length != 32 or start < 0 or start + length > len(code):
                    raise ValueError(f'{name}: invalid immutable offset')
                code[start:start+length] = replacement
    elif immutable_address is not None:
        raise ValueError(f'{name}: expected an immutable address')
    return '0x' + code.hex()


def require_runtime(role, actual, expected):
    if actual.lower() != expected.lower():
        raise ValueError(f'{role}: runtime differs from this build')


def build():
    records = {}
    for role, name in NAMES.items():
        artifact = json.loads((ROOT / f'contracts/out-runtime/{name}.sol/{name}.json').read_text())
        ordinary = json.loads((ROOT / f'contracts/out/{name}.sol/{name}.json').read_text())
        for field in ('bytecode', 'deployedBytecode'):
            if artifact[field]['object'] != ordinary[field]['object']:
                raise ValueError(f'{role}: build profiles differ')
        creation = bytes.fromhex(artifact['bytecode']['object'].removeprefix('0x'))
        runtime = bytes.fromhex(artifact['deployedBytecode']['object'].removeprefix('0x'))
        if len(creation) > 49152 or len(runtime) > 24576:
            raise ValueError(f'{role}: EVM code size exceeded')
        layout = json.loads(command('forge', 'inspect', name, 'storage-layout', '--json', '--offline', cwd=ROOT/'contracts'))
        # Compiler-assigned AST IDs differ across build roots; immutable byte offsets do not.
        immutable_offsets = sorted([{'start': item['start'], 'length': item['length']}
                                    for entries in artifact['deployedBytecode'].get('immutableReferences', {}).values()
                                    for item in entries], key=lambda x: (x['start'], x['length']))
        records[role] = {'contract': name, 'creationSha256': sha(creation), 'runtimeTemplateSha256': sha(runtime),
                         'creationBytes': len(creation), 'runtimeBytes': len(runtime),
                         'abiSha256': sha(json.dumps(artifact['abi'], sort_keys=True, separators=(',', ':')).encode()),
                         'storageLayout': layout, 'immutableReferenceOffsets': immutable_offsets}
        save(ROOT / f'release/abi/{name}.json', artifact['abi'])
        save(ROOT / f'release/layout/{name}.json', layout)
        if role == 'token':
            functions = [f['name'].lower() for f in artifact['abi'] if f['type'] == 'function']
            if any(word in name for name in functions for word in ('epoch', 'reward', 'halving', 'beacon', 'engine')):
                raise ValueError('Mining policy must remain outside the token')
    sources = {str(p.relative_to(ROOT)): sha(p.read_bytes()) for p in sorted((ROOT/'contracts').rglob('*.sol'))
               if p.is_file() and not any(part.startswith(('out', 'cache', 'broadcast')) for part in p.relative_to(ROOT/'contracts').parts)}
    for name in ('contracts/foundry.toml', 'package.json', 'package-lock.json',
                 'tools/release_manifest.py', 'tools/test_release_manifest.py'):
        sources[name] = sha((ROOT/name).read_bytes())
    result = {'schema': 'zoru-build-1', 'compiler': '0.8.38', 'evmVersion': 'shanghai', 'openzeppelin': '5.7.0',
              'optimizerRuns': 200, 'viaIR': False, 'cborMetadata': False, 'sourceSha256': sources, 'contracts': records}
    save(ROOT/'release/build-manifest.json', result)
    return result


class Rpc:
    def __init__(self, url):
        parsed = urllib.parse.urlsplit(url)
        if parsed.scheme != 'https' and not (parsed.scheme == 'http' and parsed.hostname == '127.0.0.1'):
            raise ValueError('Use HTTPS or a local RPC connection')
        self.url = url

    def post(self, data, suffix=''):
        request = urllib.request.Request(self.url.rstrip('/') + suffix, json.dumps(data).encode(),
                                         {'Content-Type': 'application/json', 'Accept': 'application/json',
                                          'User-Agent': 'ZoruMainnetManifest/1.0'})
        with urllib.request.urlopen(request, timeout=12) as response:
            body = response.read(8*1024*1024+1)
        if len(body) > 8*1024*1024:
            raise ValueError('RPC response too large')
        time.sleep(0.08)
        return json.loads(body)

    def request(self, method, params):
        reply = self.post({'jsonrpc': '2.0', 'id': 1, 'method': method, 'params': params})
        if 'error' in reply:
            raise ValueError(f'{method}: RPC rejected the request')
        return reply['result']

    def call(self, address, signature):
        return self.request('eth_call', [{'to': address, 'data': command('cast', 'sig', signature)}, 'latest'])


def deployment(args, baseline):
    data = json.loads(Path(args.deployment).read_text())
    rpc = Rpc(args.read)
    if data['chainId'] != 6736 or int(rpc.request('eth_chainId', []), 16) != 6736:
        raise ValueError('Only mainnet chain 6736 is enabled')
    if data['mode'] != 'mainnet':
        raise ValueError('Only mainnet deployment mode is supported')
    if args.native and Rpc(args.native).post({}, '/v1/chain/get_info').get('chain_id') != NATIVE:
        raise ValueError('Wrong native network')
    roles = {k: data[k].lower() for k in NAMES}
    if len(set(roles.values())) != 5 or any(len(v) != 42 or int(v, 16) == 0 for v in roles.values()):
        raise ValueError('Invalid deployment addresses')
    owner = data['owner'].lower()
    if len(owner) != 42 or int(owner, 16) == 0:
        raise ValueError('Invalid deployment owner')
    result = {**data, **roles, 'schema': 'zoru-mainnet-suite-1', 'decimals': 8, 'epochSeconds': 60,
              'drandChainHash': DRAND, 'buildManifestSha256': sha((ROOT/'release/build-manifest.json').read_bytes()),
              'sourceSha256': baseline['sourceSha256'], 'runtimeCodeHashes': {}, 'approvedImplementationCodeHashes': {}, 'implementations': {}}
    height = data['deploymentBlockNumber']
    result['deploymentBlockNumber'] = hex(height) if isinstance(height, int) else height
    for role, address in roles.items():
        code = rpc.request('eth_getCode', [address, 'latest'])
        if code == '0x':
            raise ValueError(f'Missing {role} code')
        if role == 'token':
            require_runtime(role, code, runtime_code('ZoruToken'))
        elif role == 'admin':
            require_runtime(role, code, runtime_code('ZoruAdminAdapter', roles['token']))
        else:
            actual_admin = '0x' + keccak('0xd694' + address[2:] + '01')[-40:]
            require_runtime(role + ' proxy', code, runtime_code('TransparentUpgradeableProxy', actual_admin))
            require_runtime(role + ' ProxyAdmin', rpc.request('eth_getCode', [actual_admin, 'latest']), runtime_code('ProxyAdmin'))
            admin_word = command('cast', 'calldata', 'adminOf(address)', address)
            recorded = rpc.request('eth_call', [{'to': roles['admin'], 'data': admin_word}, 'latest'])
            if ('0x' + recorded[-40:]).lower() != actual_admin:
                raise ValueError('ProxyAdmin registration mismatch')
            if ('0x' + rpc.call(actual_admin, 'owner()')[-40:]).lower() != roles['admin']:
                raise ValueError('ProxyAdmin authority mismatch')
            if ('0x' + rpc.call(roles['admin'], role + 'Proxy()')[-40:]).lower() != address:
                raise ValueError('Coordinator proxy mismatch')
        result['runtimeCodeHashes'][role] = keccak(code)
        if role in ('ledger', 'engine', 'beacon'):
            implementation = '0x' + rpc.request('eth_getStorageAt', [address, SLOT, 'latest'])[-40:]
            artifact = ROOT/f'contracts/out-runtime/{NAMES[role]}.sol/{NAMES[role]}.json'
            expected = json.loads(artifact.read_text())['deployedBytecode']['object']
            actual = rpc.request('eth_getCode', [implementation, 'latest'])
            if actual.removeprefix('0x') != expected.removeprefix('0x'):
                raise ValueError(f'{role}: implementation differs from this build')
            result['implementations'][role] = implementation
            result['approvedImplementationCodeHashes'][role] = [keccak(actual)]
    for signature, expected in [('token()', roles['token']), ('engine()', roles['engine']), ('beacon()', roles['beacon']), ('protocolAdmin()', roles['admin'])]:
        if ('0x'+rpc.call(roles['ledger'], signature)[-40:]).lower() != expected:
            raise ValueError('Ledger pointer mismatch')
    declared_launch = int(data['launchTime'])
    for role in ('ledger', 'beacon', 'admin'):
        if int(rpc.call(roles[role], 'launchTime()'), 16) != declared_launch:
            raise ValueError(f'{role}: launch time differs from deployment')
    if ('0x'+rpc.call(roles['token'], 'issuer()')[-40:]).lower() != roles['ledger']:
        raise ValueError('Issuer must be Ledger Proxy')
    if ('0x' + rpc.call(roles['token'], 'owner()')[-40:]).lower() != owner:
        raise ValueError('Token owner differs from the requested deployment owner')
    if ('0x' + rpc.call(roles['admin'], 'token()')[-40:]).lower() != roles['token']:
        raise ValueError('Coordinator token mismatch')
    if int(rpc.call(roles['token'], 'MAX_SUPPLY()'), 16) != 21_000_000*10**8 or int(rpc.call(roles['token'], 'decimals()'), 16) != 8:
        raise ValueError('Token precision or cap differs')
    result.pop('manifestSha256', None)
    result['manifestSha256'] = sha(json.dumps(result, sort_keys=True, separators=(',', ':')).encode())
    save(args.output, result)
    print(json.dumps({'status': 'PASS', 'manifestSha256': result['manifestSha256']}))


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--deployment'); parser.add_argument('--read'); parser.add_argument('--native'); parser.add_argument('--output')
    args = parser.parse_args()
    baseline = build()
    if args.deployment:
        if not args.read or not args.output:
            parser.error('--deployment requires --read and --output')
        deployment(args, baseline)
    else:
        print(json.dumps({'status': 'PASS', 'contracts': len(baseline['contracts'])}))


if __name__ == '__main__':
    main()
