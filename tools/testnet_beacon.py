#!/usr/bin/env python3
"""Real authenticated publication, bounded cache reuse and historical cleanup on private VEX."""
import argparse
import hashlib
import http.client
import json
from pathlib import Path
import subprocess
from native_ram_probe import require
from testnet_migration import MigrationExperiment

CHAIN_HASH = '04f1e9062b8a81f848fded9c12306733282b2727ecced50032187751166ec8c3'


class BeaconExperiment(MigrationExperiment):
    def scheduled_signature(self):
        start = self.number('authenticatedBeacon', 'launchTime()')
        now = int(self.rpc('eth_getBlockByNumber', ['latest', False])['timestamp'], 16)
        epoch = (now-start)//60
        if start+(epoch+1)*60-now < 10:
            self.wait_until(start+(epoch+1)*60+1)
            epoch += 1
        expected = self.number('authenticatedBeacon', 'expectedRound(uint48)', epoch)
        for host in ['api.drand.sh', 'api2.drand.sh', 'api3.drand.sh']:
            conn = http.client.HTTPSConnection(host, timeout=8)
            try:
                conn.request('GET', '/'+CHAIN_HASH+'/public/'+str(expected))
                response = conn.getresponse()
                if response.status != 200: continue
                value = json.loads(response.read(16385))
                sig = bytes.fromhex(value['signature'])
                require(value['round'] == expected and len(sig) == 64
                        and hashlib.sha256(sig).hexdigest() == value['randomness'], 'Invalid drand encoding')
                return epoch, '0x'+sig.hex(), '0x'+value['randomness']
            except (OSError, ValueError, KeyError):
                continue
            finally:
                conn.close()
        raise RuntimeError('Scheduled drand round unavailable; no publication signed')

    def run(self):
        require(not self.a.output.exists(), 'Reconcile the existing beacon run before retrying')
        self.verify()
        public = subprocess.check_output([self.a.cast, 'wallet', 'address', '--keystore', str(self.a.keystore),
                                         '--password-file', str(self.a.password_file)], text=True).strip()
        require(public.lower() == self.a.account.lower(), 'Test signer mismatch')
        self.result['schema'] = 'zoru-testnet-beacon-1'
        self.result['scope'] = 'Real drand signatures and native RAM; isolated VEX chain 46736'
        self.contracts = json.loads(self.a.previous.read_text())['contracts']
        vectors = json.loads(self.a.vectors.read_text())
        original = self.deploy('ZoruDrandBeaconOriginal')
        migration = self.deploy('ZoruDrandBeaconMigration')
        final = self.deploy('ZoruDrandBeacon')
        start = 1_727_521_075+(vectors[0]['round']-1)*3
        receipt = self.tx('deploy-original-authenticated-beacon', 'ZoruAdminAdapter', 'deployProxy(address,bytes)', original,
                          self.abi('initialize(uint256)', start), gas_limit=4_000_000)
        registration = [l for l in receipt['logs'] if l['address'].lower() == self.contracts['ZoruAdminAdapter'].lower()
                        and len(l['topics']) == 3]
        require(len(registration) == 1, 'Beacon proxy registration missing')
        self.contracts['authenticatedBeacon'] = '0x'+registration[0]['topics'][1][-40:]
        self.result['contracts'] = self.contracts
        epochs = []
        config = self.view('authenticatedBeacon', 'verificationConfigId()')
        for vector in vectors:
            epoch = (vector['round']-vectors[0]['round'])//20
            require(vectors[0]['round']+epoch*20 == vector['round'], 'Unscheduled vector')
            epochs.append(epoch)
            self.tx('original-publish-round-'+str(vector['round']), 'authenticatedBeacon', 'publish(uint48,bytes)', epoch, vector['signature'])
            require(self.view('authenticatedBeacon', 'verifiedSeed(uint48)', epoch).lower() == vector['seed'].lower(),
                    'Original authenticated randomness differs from independent vector')
        self.tx('activate-bounded-cache-migration', 'ZoruAdminAdapter', 'upgrade(address,address,bytes)',
                self.contracts['authenticatedBeacon'], migration, '0x')
        require(self.view('authenticatedBeacon', 'verificationConfigId()') == config, 'Drand schedule or key changed')
        batch = '['+','.join(map(str,epochs))+']'
        self.tx('clear-historical-cache', 'authenticatedBeacon', 'clearHistoricalCache(uint48[])', batch)
        self.tx('retry-historical-cache-cleanup', 'authenticatedBeacon', 'clearHistoricalCache(uint48[])', batch)
        for epoch in epochs:
            for slot in [0,3]:
                key = subprocess.check_output([self.a.cast, 'index', 'uint48', str(epoch), str(slot)], text=True).strip()
                require(int(self.rpc('eth_getStorageAt', [self.contracts['authenticatedBeacon'], key, 'latest']),16) == 0,
                        'Historical native-backed cache row retained')
        epoch, signature, seed = self.scheduled_signature()
        forged = '0x'+f'{1:064x}{2:064x}'
        response = self.http(self.a.rpc_port, '/', {'jsonrpc': '2.0', 'id': 1, 'method': 'eth_call', 'params': [
            {'to': self.contracts['authenticatedBeacon'], 'data': self.abi('publish(uint48,bytes)', epoch, forged)}, 'latest']})
        require('error' in response and self.number('authenticatedBeacon','verifiedSeed(uint48)',epoch) == 0,
                'On-curve forged signature accepted')
        self.tx('publish-current-authenticated-round', 'authenticatedBeacon', 'publish(uint48,bytes)', epoch, signature)
        require(self.view('authenticatedBeacon', 'verifiedSeed(uint48)', epoch).lower() == seed.lower(), 'Current authentication failed')
        self.wait_until(start+(epoch+1)*60+1)
        next_epoch, next_signature, next_seed = self.scheduled_signature()
        self.tx('reuse-cache-next-epoch', 'authenticatedBeacon', 'publish(uint48,bytes)', next_epoch, next_signature)
        require(self.number('authenticatedBeacon','verifiedSeed(uint48)',epoch) == 0, 'Expired cache retained')
        require(self.view('authenticatedBeacon','verifiedSeed(uint48)',next_epoch).lower() == next_seed.lower(), 'Next authentication failed')
        self.tx('activate-final-authenticated-beacon', 'ZoruAdminAdapter', 'upgrade(address,address,bytes)',
                self.contracts['authenticatedBeacon'], final, '0x')
        require(self.number('authenticatedBeacon','verifiedSeed(uint48)',next_epoch) == 0, 'Implementation trust did not reset')
        epoch, signature, seed = self.scheduled_signature()
        self.tx('authenticate-final-current-round', 'authenticatedBeacon', 'publish(uint48,bytes)', epoch, signature)
        require(self.view('authenticatedBeacon','verifiedSeed(uint48)',epoch).lower() == seed.lower(), 'Final authentication failed')
        require(self.view('authenticatedBeacon','verificationConfigId()') == config, 'Final key or schedule changed')
        self.result['status'] = 'PASS_REAL_DRAND_UPGRADE_CLEANUP_AND_BOUNDED_CACHE'
        self.result['onCurveForgeryRejected'] = True
        self.save()
        print(self.result['status'], flush=True)


def main():
    p = argparse.ArgumentParser(description=__doc__)
    for arg in ['cast', 'account']: p.add_argument('--'+arg, required=True)
    for arg in ['keystore', 'password-file', 'bytecode', 'artifacts', 'output', 'previous', 'vectors']:
        p.add_argument('--'+arg, type=Path, required=True)
    p.add_argument('--rpc-port', type=int, default=18547)
    p.add_argument('--native-port', type=int, default=19888)
    BeaconExperiment(p.parse_args()).run()


if __name__ == '__main__': main()
