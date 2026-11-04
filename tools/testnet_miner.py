#!/usr/bin/env python3
"""Real Keccak mining, authenticated drand, recovery and settlement on isolated VEX."""
import argparse
import hashlib
import http.client
import http.server
import json
import os
from pathlib import Path
import selectors
import subprocess
import threading
import time

from native_ram_probe import require
from testnet_migration import MigrationExperiment


class MinerExperiment(MigrationExperiment):
    def run_cli(self, label, manifest, seconds=None, peer=False):
        wallet = self.a.peer_keystore if peer else self.a.keystore
        password = self.a.peer_password_file if peer else self.a.password_file
        account = self.a.peer_account if peer else self.a.account
        state = self.a.output.parent/('peer-miner-state' if peer else 'protocol-miner-state')
        state.mkdir(mode=0o700,exist_ok=True)
        url = f'http://127.0.0.1:{self.gateway.server_port}'
        command = [str(self.a.miner),'mine' if seconds is not None else 'claim','--manifest',str(manifest),
            '--read',url,'--submit',url,'--native',f'http://127.0.0.1:{self.a.native_port}',
            '--wallet',str(wallet),'--password-stdin','--expected-wallet',account,'--state-dir',str(state),
            '--session-budget-wei',str(40_000_000_000_000_000 if peer else 5*10**18)]
        if seconds is not None:
            command += ['--workers','2' if label == 'resumed-mining' else '1','--cpu-budget','0.5',
                        '--seconds',str(seconds),'--auto-claim-after','0' if peer else '2']
            if peer:
                command += ['--max-accepted','1']
        environment = dict(os.environ,ZORU_STATE_ROOT=str(state/'journal-root'))
        stderr = open(state/(label+'.stderr'),'w')
        with open(password,'rb') as secret_input:
            process = subprocess.Popen(command,stdin=secret_input,stdout=subprocess.PIPE,stderr=stderr,
                                       text=True,env=environment)
        selection = selectors.DefaultSelector()
        selection.register(process.stdout,selectors.EVENT_READ)
        deadline = time.monotonic()+(seconds or 60)+150
        peak_rss = 0
        final = None
        with open(state/(label+'.progress.jsonl'),'w') as progress:
            try:
                while process.poll() is None:
                    require(time.monotonic() < deadline,'Native miner did not finish within the bounded test')
                    status = Path(f'/proc/{process.pid}/status')
                    if status.exists():
                        for line in status.read_text().splitlines():
                            if line.startswith('VmRSS:'):
                                peak_rss = max(peak_rss,int(line.split()[1])*1024)
                    for key,_ in selection.select(timeout=1):
                        line = key.fileobj.readline()
                        if not line:
                            continue
                        require(len(line) <= 2*1024*1024,'Miner output exceeded the test limit')
                        message = json.loads(line)
                        if message.get('event') == 'mine-result':
                            final = message['data']
                        elif message.get('event') == 'state':
                            data = message['data']
                            progress.write(json.dumps({k:data.get(k) for k in ['status','accepted','autoClaimed',
                                'hashes','hashesPerSecond','elapsedSeconds','resourcePauses']})+'\n')
                # Drain the final result emitted immediately before process exit.
                for line in process.stdout:
                    message = json.loads(line)
                    if message.get('event') == 'mine-result':
                        final = message['data']
                require(process.returncode == 0,'Native miner exited unsuccessfully; retain logs and nonce journal')
            finally:
                if process.poll() is None:
                    process.terminate()
                    try:
                        process.wait(timeout=20)
                    except subprocess.TimeoutExpired:
                        process.kill()
                        process.wait()
                selection.close()
                stderr.close()
        if seconds is not None:
            require(final is not None,'Native miner did not produce a verifiable final result')
            final['peakRssBytes'] = peak_rss
            (state/(label+'.result.json')).write_text(json.dumps(final,indent=2)+'\n')
            return final

    def run(self):
        require(not self.a.output.exists(),'Retain and reconcile an existing native miner experiment')
        self.verify()
        self.result.update(schema='zoru-native-miner-integration-1',
            scope='Real isolated VEX, production Keccak verifier and authenticated drand; no permissive proof engine')
        launch=int(self.rpc('eth_getBlockByNumber',['latest',False])['timestamp'],16)+120
        genesis=1_727_521_075
        launch=genesis+((launch-genesis+2)//3)*3
        self.deploy('ZoruToken','constructor(address)',self.a.account)
        self.deploy('ZoruAdminAdapter','constructor(address)',self.contracts['ZoruToken'])
        self.deploy('ZoruLedger')
        self.deploy('ZoruKeccakEngine')
        self.deploy('ZoruDrandBeacon')
        deployment='('+','.join([self.contracts['ZoruLedger'],self.contracts['ZoruKeccakEngine'],self.abi('initialize()'),
            self.contracts['ZoruDrandBeacon'],self.abi('initialize(uint256)',launch),str(launch),str((2**256-1)>>19)])+')'
        receipt=self.tx('deploy-authenticated-suite','ZoruAdminAdapter',
            'deploySuite((address,address,bytes,address,bytes,uint256,uint256))',deployment,gas_limit=8_000_000)
        for role in ['ledger','engine','beacon']:
            self.contracts[role]='0x'+self.view('ZoruAdminAdapter',role+'Proxy()')[-40:]
        self.tx('bind-mining-issuer','ZoruToken','setIssuer(address)',self.contracts['ledger'])
        roles={'token':self.contracts['ZoruToken'],'admin':self.contracts['ZoruAdminAdapter'],
               **{role:self.contracts[role] for role in ['ledger','engine','beacon']}}
        def code_hash(address):
            return subprocess.check_output([self.a.cast,'keccak'],
                input=self.rpc('eth_getCode',[address,'latest']),text=True).strip()
        manifest={'schema':'zoru-mainnet-suite-1','mode':'testnet','chainId':46736,'owner':self.a.account,
            'rpcFallbacks':[f'http://127.0.0.1:{self.a.rpc_port}'],
            'launchTime':launch,'epochSeconds':60,'decimals':8,'deploymentBlockNumber':receipt['blockNumber'],
            'drandChainHash':'04f1e9062b8a81f848fded9c12306733282b2727ecced50032187751166ec8c3',**roles,
            'runtimeCodeHashes':{role:code_hash(address) for role,address in roles.items()},
            'approvedImplementationCodeHashes':{role:[code_hash(self.contracts[name])] for role,name in
                [('ledger','ZoruLedger'),('engine','ZoruKeccakEngine'),('beacon','ZoruDrandBeacon')]}}
        manifest['manifestSha256']=hashlib.sha256(json.dumps(manifest,sort_keys=True,separators=(',',':')).encode()).hexdigest()
        manifest_file=self.a.output.parent/'native-miner-deployment.json'
        manifest_file.write_text(json.dumps(manifest,indent=2)+'\n')
        self.result['manifest']=manifest
        self.result['faults']={'droppedSendResponse':False,'httpOutageSeconds':10,'readLatencySeconds':0.25,
                               'httpFailuresInjected':0,'latencyRequestsInjected':0}
        experiment=self
        clock={'started':None}

        class Gateway(http.server.BaseHTTPRequestHandler):
            def log_message(self,*_):pass
            def do_POST(self):
                body=self.rfile.read(int(self.headers['Content-Length']))
                request=json.loads(body)
                elapsed=time.monotonic()-clock['started'] if clock['started'] is not None else -1
                if 50 <= elapsed < 60:
                    experiment.result['faults']['httpFailuresInjected']+=1
                    experiment.save()
                    self.send_response(503);self.end_headers();return
                if 30 <= elapsed < 45:
                    experiment.result['faults']['latencyRequestsInjected']+=1
                    time.sleep(0.25)
                write=request.get('method')=='eth_sendRawTransaction'
                port=experiment.a.rpc_port if write else experiment.a.read_port
                connection=http.client.HTTPConnection('127.0.0.1',port,timeout=20)
                try:
                    connection.request('POST','/',body,{'Content-Type':'application/json'})
                    response=connection.getresponse();raw=response.read(8*1024*1024+1)
                finally:connection.close()
                require(len(raw)<=8*1024*1024,'Gateway response exceeded limit')
                if write and not experiment.result['faults']['droppedSendResponse']:
                    value=json.loads(raw)
                    if value.get('result'):
                        experiment.result['faults'].update(droppedSendResponse=True,droppedResponseTransactionHash=value['result'])
                        experiment.save()
                        self.connection.shutdown(2);self.connection.close();return
                self.send_response(response.status);self.send_header('Content-Type','application/json')
                self.send_header('Content-Length',str(len(raw)));self.end_headers();self.wfile.write(raw)

        self.gateway=http.server.ThreadingHTTPServer(('127.0.0.1',0),Gateway)
        self.gateway.daemon_threads=True
        threading.Thread(target=self.gateway.serve_forever,daemon=True).start()
        try:
            self.wait_until(launch+1)
            clock['started']=time.monotonic()
            first=self.run_cli('initial-mining',manifest_file,seconds=100)
            peer_result={}
            peer_error=[]
            def mine_peer():
                try:
                    deadline=time.monotonic()+100
                    while time.monotonic()<deadline:
                        epoch=self.number('ledger','epochNow()')
                        raw=self.view('ledger','epochInfo(uint48)',epoch)
                        count=int(raw[2+3*64:2+4*64],16)
                        now=int(self.rpc('eth_getBlockByNumber',['latest',False])['timestamp'],16)
                        if count>0 and launch+(epoch+1)*60-now>25:
                            peer_result.update(self.run_cli('concurrent-peer',manifest_file,seconds=45,peer=True))
                            return
                        time.sleep(0.5)
                    raise RuntimeError('Peer miner did not receive a funded inclusion window')
                except Exception as error:
                    peer_error.append(str(error))
            peer_thread=None
            if self.a.peer_account:
                require(self.a.peer_keystore and self.a.peer_password_file,'Peer wallet and protected password file are required')
                peer_thread=threading.Thread(target=mine_peer)
                peer_thread.start()
            second=self.run_cli('resumed-mining',manifest_file,seconds=100)
            if peer_thread:
                peer_thread.join(timeout=60)
                require(not peer_thread.is_alive() and not peer_error and peer_result.get('accepted')==1,
                        'Independent concurrent miner did not complete: '+str(peer_error))
            require(first['accepted']>0 and second['accepted']>0,'Mining did not recover and resume')
            require(first.get('autoClaimed',0)+second.get('autoClaimed',0)>0,'Native automatic claiming did not execute')
            require(self.result['faults']['droppedSendResponse'],'Missing real lost-response witness')
            require(self.result['faults']['httpFailuresInjected']>0 and self.result['faults']['latencyRequestsInjected']>0,
                    'The configured outage and latency were not observed by the real miner')
            require(first.get('rpcFailovers',0)>0,'The native miner did not verify and activate its RPC fallback')
            self.result['minerRuns']=[first,second]
            self.result['peerMiner']=peer_result
            self.save()
            # A real contract pause must prevent hashing and signing.
            self.tx('pause-native-mining','ledger','setAdmissionPaused(bool)','true')
            self.tx('pause-native-claims','ledger','setClaimsPaused(bool)','true')
            nonce_before=self.rpc('eth_getTransactionCount',[self.a.account,'latest'])
            paused=self.run_cli('paused-mining',manifest_file,seconds=5)
            require(paused['accepted']==0 and paused['hashes']==0,'Contract pause still produced work')
            require(self.rpc('eth_getTransactionCount',[self.a.account,'latest'])==nonce_before,'Paused miner consumed a nonce')
            self.tx('resume-native-claims','ledger','setClaimsPaused(bool)','false')
            self.tx('resume-native-mining','ledger','setAdmissionPaused(bool)','false')
            current=self.number('ledger','epochNow()')
            self.wait_until(launch+(current+1)*60+1)
            self.run_cli('final-claim',manifest_file)
            if self.a.peer_account:
                topic=subprocess.check_output([self.a.cast,'keccak','ProofAccepted(uint48,bytes32,address,uint256,uint256)'],text=True).strip()
                logs=self.rpc('eth_getLogs',[{'address':self.contracts['ledger'],'fromBlock':receipt['blockNumber'],
                    'toBlock':'latest','topics':[topic,None,None,'0x'+self.a.peer_account[2:].lower().zfill(64)]}])
                require(len(logs)==1,'Independent miner proof inventory differs from its receipt')
                digest=logs[0]['topics'][2]
                epoch=int(logs[0]['topics'][1],16)
                state=self.view('ledger','epochInfo(uint48)',epoch)
                if int(state[2+6*64:2+7*64],16)==0:
                    self.tx('seal-peer-epoch','ledger','seal(uint48)',epoch)
                self.tx('claim-peer-proof','ledger','claim(bytes32)',digest)
                require(self.number('ZoruToken','balanceOf(address)',self.a.peer_account)>0,'Peer reward did not reach its owner')
        finally:
            self.gateway.shutdown();self.gateway.server_close()
        state=self.snapshot()
        require(state['totalProofs']==first['accepted']+second['accepted']+peer_result.get('accepted',0),
                'Accepted proof inventory does not reconcile')
        require(state['allocatedSupply']==state['fundedSupply']==state['paidSupply']==state['lifetimeMinted'],
                'Native miner rewards do not reconcile')
        require(state['ledgerBalance']==0,'Native miner left a funded reward unclaimed')
        self.result.update(status='PASS_REAL_NATIVE_MINING_RECOVERY_AUTOMATIC_CLAIMS_AND_RESTART',afterSettlement=state,
                           contractPauseStopsWorkAndSigning=True,pausedMiner=paused)
        self.save()
        print(json.dumps({'status':self.result['status'],'accepted':state['totalProofs'],
                          'autoClaimed':sum(r.get('autoClaimed',0) for r in [first,second])}),flush=True)


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    for name in ['cast','account']:parser.add_argument('--'+name,required=True)
    for name in ['keystore','password-file','bytecode','artifacts','output','miner']:
        parser.add_argument('--'+name,type=Path,required=True)
    parser.add_argument('--rpc-port',type=int,default=18547)
    parser.add_argument('--read-port',type=int,default=18546)
    parser.add_argument('--native-port',type=int,default=19888)
    parser.add_argument('--peer-keystore',type=Path)
    parser.add_argument('--peer-password-file',type=Path)
    parser.add_argument('--peer-account')
    MinerExperiment(parser.parse_args()).run()


if __name__=='__main__':main()
