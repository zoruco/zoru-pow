"""Deployment attestation policy tests; no node, wallet or compiler required."""
import contextlib
import hashlib
import io
import json
from pathlib import Path
from types import SimpleNamespace
import tempfile
import unittest
from unittest.mock import patch

import release_manifest as release


def address(n):
    return '0x' + f'{n:040x}'


def fingerprint(data):
    # Deterministic fixture IDs only. Production uses cast's Keccak implementation.
    return '0x' + hashlib.sha256(bytes.fromhex(data.removeprefix('0x'))).hexdigest()


class DeploymentAttestationTest(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.root = Path(self.directory.name)
        self.roles = dict(zip(release.NAMES, map(address, range(1, 6))))
        self.owner = address(9)
        self.admins = {p: '0x' + fingerprint('0xd694' + p[2:] + '01')[-40:]
                       for p in (self.roles[r] for r in ('ledger', 'engine', 'beacon'))}
        self.impl = {self.roles[r]: address(n) for r, n in zip(('ledger', 'engine', 'beacon'), (6, 7, 8))}
        for n, name in enumerate(('ZoruToken', 'ZoruAdminAdapter', 'TransparentUpgradeableProxy',
                                  'ProxyAdmin', 'ZoruLedger', 'ZoruKeccakEngine', 'ZoruDrandBeacon')):
            immutable = name in ('ZoruAdminAdapter', 'TransparentUpgradeableProxy')
            code = ('00' * 32 if immutable else '') + f'60{n:02x}'
            artifact = {'deployedBytecode': {'object': '0x' + code, 'immutableReferences':
                        {'1': [{'start': 0, 'length': 32}]} if immutable else {}}}
            filename = name + '.sol'
            p = self.root / 'contracts/out-runtime' / filename / (name + '.json')
            p.parent.mkdir(parents=True, exist_ok=True)
            p.write_text(json.dumps(artifact))
        (self.root / 'release').mkdir()
        (self.root / 'release/build-manifest.json').write_text('{}')
        self.data = {**self.roles, 'owner': self.owner, 'chainId': 6736, 'mode': 'mainnet',
                     'deploymentBlockNumber': 1, 'launchTime': 1}
        self.config = self.root / 'deployment.json'
        self.args = SimpleNamespace(deployment=str(self.config), read='http://127.0.0.1:1',
                                    native=None, output=str(self.root / 'manifest.json'))
        root_patch = patch.object(release, 'ROOT', self.root)
        root_patch.start()
        self.addCleanup(root_patch.stop)
        self.codes = {self.roles['token']: release.runtime_code('ZoruToken'),
                      self.roles['admin']: release.runtime_code('ZoruAdminAdapter', self.roles['token'])}
        for role in ('ledger', 'engine', 'beacon'):
            proxy = self.roles[role]
            self.codes[proxy] = release.runtime_code('TransparentUpgradeableProxy', self.admins[proxy])
            self.codes[self.admins[proxy]] = release.runtime_code('ProxyAdmin')
            name = release.NAMES[role]
            p = self.root / 'contracts/out-runtime' / (name + '.sol') / (name + '.json')
            self.codes[self.impl[proxy]] = json.loads(p.read_text())['deployedBytecode']['object']
        self.proxy_admin_owner = self.roles['admin']
        self.launch_times = {'ledger': 1, 'beacon': 1, 'admin': 1}

    def run_export(self):
        fixture = self

        class Rpc:
            def __init__(self, _): pass

            def request(self, method, params):
                if method == 'eth_chainId': return hex(6736)
                if method == 'web3_clientVersion': return 'anvil'
                if method == 'eth_getCode': return fixture.codes[params[0]]
                if method == 'eth_getStorageAt': return '0x' + fixture.impl[params[0]][2:].zfill(64)
                if method == 'eth_call':
                    proxy = params[0]['data'].split('|')[1]
                    return '0x' + fixture.admins[proxy][2:].zfill(64)
                raise AssertionError(method)

            def call(self, target, signature):
                r = fixture.roles
                values = {(r['ledger'], 'token()'): r['token'], (r['ledger'], 'engine()'): r['engine'],
                          (r['ledger'], 'beacon()'): r['beacon'], (r['ledger'], 'protocolAdmin()'): r['admin'],
                          (r['token'], 'issuer()'): r['ledger'], (r['token'], 'owner()'): fixture.owner,
                          (r['token'], 'MAX_SUPPLY()'): hex(21_000_000 * 10**8), (r['token'], 'decimals()'): hex(8),
                          (r['admin'], 'token()'): r['token']}
                values.update({(r['admin'], role + 'Proxy()'): r[role] for role in ('ledger', 'engine', 'beacon')})
                values.update({(r[role], 'launchTime()'): hex(fixture.launch_times[role])
                               for role in ('ledger', 'beacon', 'admin')})
                values.update({(a, 'owner()'): fixture.proxy_admin_owner for a in fixture.admins.values()})
                return '0x' + values[(target, signature)][2:].zfill(64)

        self.config.write_text(json.dumps(self.data))
        with patch.object(release, 'Rpc', Rpc), patch.object(release, 'keccak', fingerprint), \
                patch.object(release, 'command', lambda _, op, sig, addr: sig + '|' + addr), \
                contextlib.redirect_stdout(io.StringIO()):
            release.deployment(self.args, {'sourceSha256': {}})

    def test_exact_runtimes_and_authorities_are_accepted(self):
        self.run_export()
        self.assertTrue(Path(self.args.output).is_file())

    def test_token_runtime_cannot_be_self_attested(self):
        self.codes[self.roles['token']] += '00'
        with self.assertRaisesRegex(ValueError, 'token: runtime differs'):
            self.run_export()

    def test_coordinator_runtime_cannot_be_self_attested(self):
        self.codes[self.roles['admin']] += '00'
        with self.assertRaisesRegex(ValueError, 'admin: runtime differs'):
            self.run_export()

    def test_proxy_immutable_admin_must_match_the_factory(self):
        self.codes[self.roles['engine']] = release.runtime_code('TransparentUpgradeableProxy', address(42))
        with self.assertRaisesRegex(ValueError, 'engine proxy: runtime differs'):
            self.run_export()

    def test_declared_owner_must_match_token_state(self):
        self.data['owner'] = address(42)
        with self.assertRaisesRegex(ValueError, 'Token owner differs'):
            self.run_export()

    def test_proxy_admin_authority_must_match_coordinator(self):
        self.proxy_admin_owner = address(42)
        with self.assertRaisesRegex(ValueError, 'ProxyAdmin authority mismatch'):
            self.run_export()

    def test_declared_launch_time_must_match_chain(self):
        self.data['launchTime'] = 2
        with self.assertRaisesRegex(ValueError, 'ledger: launch time differs'):
            self.run_export()

    def test_beacon_launch_time_must_match_ledger(self):
        self.launch_times['beacon'] = 2
        with self.assertRaisesRegex(ValueError, 'beacon: launch time differs'):
            self.run_export()


if __name__ == '__main__':
    unittest.main()
