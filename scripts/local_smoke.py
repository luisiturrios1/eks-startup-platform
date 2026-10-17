#!/usr/bin/env python3
"""Exercise both example APIs via a loopback port-forward and assert namespace isolation."""
import json,socket,subprocess,time,urllib.request
from pathlib import Path
ROOT=Path(__file__).resolve().parents[1]
for service in ['payments-service','auth-service']:
    with socket.socket() as sock:sock.bind(('127.0.0.1',0));port=sock.getsockname()[1]
    proc=subprocess.Popen(['kubectl','--context','kind-platform-local','-n',service,'port-forward','svc/'+service,f'{port}:8080'],stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
    try:
        for attempt in range(40):
            try:
                with urllib.request.urlopen(f'http://127.0.0.1:{port}/api/info',timeout=2) as response:
                    assert json.load(response)['service']==service
                break
            except (OSError,AssertionError):time.sleep(.25)
        else:raise RuntimeError('Service did not become reachable: '+service)
        for endpoint in ['demo','cache','object']:
            request=urllib.request.Request(f'http://127.0.0.1:{port}/api/'+endpoint,method='POST',data=b'')
            with urllib.request.urlopen(request,timeout=15) as response:
                assert response.status==200
        print(service+': HTTP, database write, Valkey and S3 passed')
    finally:proc.terminate();proc.wait(timeout=10)
result=subprocess.run(['kubectl','--context','kind-platform-local','-n','payments-service','exec','deployment/payments-service','--','bash','-c','timeout 3 bash -c "echo > /dev/tcp/auth-service.auth-service.svc/8080"'],capture_output=True)
if result.returncode!=124:raise RuntimeError('Expected NetworkPolicy timeout, got '+str(result.returncode))
print('Cross-namespace connection denied by NetworkPolicy')
