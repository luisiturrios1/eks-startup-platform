"""Real SQL grants/rotation tests against only the disposable MiniStack setup."""
import importlib.util,json,os
from pathlib import Path
import boto3,psycopg,pymysql,pytest
ROOT=Path(__file__).resolve().parents[2]
pytestmark=pytest.mark.skipif(os.environ.get('PLATFORM_LOCAL_INTEGRATION')!='1',reason='Requires explicit disposable local setup')

def client():
    return boto3.client('secretsmanager',endpoint_url='http://127.0.0.1:4566',region_name='us-east-1',aws_access_key_id='test',aws_secret_access_key='test')
def local_connect(cfg,credentials,database=None):
    if cfg['engine']=='postgres':return psycopg.connect(host='localhost',port=cfg['port'],user=credentials['username'],password=credentials['password'],dbname=database or 'postgres',autocommit=True)
    return pymysql.connect(host='localhost',port=int(cfg['port']),user=credentials['username'],password=credentials['password'],database=database,autocommit=True,ssl={'check_hostname':False,'verify_mode':0})
def execute(conn,statement):
    with conn.cursor() as cur:cur.execute(statement)
@pytest.mark.parametrize('service',['payments-service','auth-service'])
def test_grants_and_rotation(service,monkeypatch):
    state=json.loads((ROOT/'local/generated.json').read_text())[service]
    cfg=dict(state)
    sm=client();master={'username':'local_admin','password':'local-only-password'}
    spec=importlib.util.spec_from_file_location('manager',ROOT/'components/credential-manager/handler.py');m=importlib.util.module_from_spec(spec);spec.loader.exec_module(m)
    monkeypatch.setattr(m,'connect',local_connect)
    runtime=json.loads(sm.get_secret_value(SecretId=f'local/{service}/runtime')['SecretString'])
    migration=json.loads(sm.get_secret_value(SecretId=f'local/{service}/migration')['SecretString'])
    with local_connect(cfg,migration,cfg['database']) as c:execute(c,'CREATE TABLE IF NOT EXISTS grant_probe (id INTEGER PRIMARY KEY)')
    with local_connect(cfg,runtime,cfg['database']) as c:
        execute(c,'SELECT * FROM grant_probe')
        with pytest.raises(Exception):execute(c,'CREATE TABLE forbidden_table (id INTEGER)')
    peer=dict(cfg,database='peer_database')
    peer_user={'username':m.user_name('peer-'+service,'runtime','a'),'password':'local-peer-password'}
    m.provision(peer,master,'peer-'+service,'runtime',peer_user)
    with pytest.raises(Exception):
        with local_connect(peer,runtime,peer['database']) as c:execute(c,'SELECT 1')
    master_id=f'local/{service}/master'
    try:sm.create_secret(Name=master_id,SecretString=json.dumps(master))
    except sm.exceptions.ResourceExistsException:pass
    cfg.update(master=master_id,runtime=f'local/{service}/runtime',migration=f'local/{service}/migration')
    monkeypatch.setenv('CONFIG',json.dumps({service:cfg}));monkeypatch.setattr(m.boto3,'client',lambda name:sm)
    m.handler({'action':'rotate'},None)
    updated=json.loads(sm.get_secret_value(SecretId=cfg['runtime'])['SecretString'])
    assert updated['username']!=runtime['username']
    with local_connect(cfg,updated,cfg['database']) as c:
        execute(c,'SELECT * FROM grant_probe')
        with pytest.raises(Exception):execute(c,'CREATE TABLE forbidden_after_rotation (id INTEGER)')
    # Previous credentials survive the overlap window; next rotation replaces the older slot.
    with local_connect(cfg,runtime,cfg['database']) as c:execute(c,'SELECT * FROM grant_probe')

    active_migration=json.loads(sm.get_secret_value(SecretId=cfg['migration'])['SecretString'])
    with local_connect(cfg,active_migration,cfg['database']) as c:execute(c,'DROP TABLE grant_probe')

def test_valkey_key_prefix_isolation():
    import subprocess
    def command(*args):
        return subprocess.run(['docker','compose','exec','-T','valkey','valkey-cli','-e','--no-auth-warning','--user','payments-service','--pass','local-payments-only',*args],cwd=ROOT,capture_output=True,text=True)
    assert command('SET','payments-service:probe','ok').returncode==0
    assert command('GET','payments-service:probe').stdout.strip()=='ok'
    denied=command('GET','auth-service:probe')
    assert denied.returncode!=0 and 'NOPERM' in denied.stdout+denied.stderr
