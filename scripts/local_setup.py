#!/usr/bin/env python3
"""Create only MiniStack resources. Refuses non-loopback AWS endpoints."""
import json, time, subprocess, importlib.util
import psycopg, pymysql
from pathlib import Path
import boto3
ROOT=Path(__file__).resolve().parents[1]
def client(name):
    return boto3.client(name,endpoint_url="http://127.0.0.1:4566",region_name="us-east-1",aws_access_key_id="test",aws_secret_access_key="test")
def main():
    rds=client("rds");sm=client("secretsmanager");s3=client("s3")
    state={}
    spec=importlib.util.spec_from_file_location("credential_manager",ROOT/"components/credential-manager/handler.py")
    manager=importlib.util.module_from_spec(spec);spec.loader.exec_module(manager)
    def local_connect(cfg,credentials,database=None):
        if cfg["engine"]=="postgres":
            return psycopg.connect(host="localhost",port=cfg["port"],user=credentials["username"],password=credentials["password"],dbname=database or "postgres",autocommit=True)
        return pymysql.connect(host="localhost",port=int(cfg["port"]),user=credentials["username"],password=credentials["password"],database=database,autocommit=True,ssl={"check_hostname":False,"verify_mode":0})
    manager.connect=local_connect
    for service,engine,port in [("payments-service","postgres",5432),("auth-service","mysql",3306)]:
        name=service.replace("-","_")
        names=subprocess.check_output(["docker","ps","--format","{{.Names}}"]).decode().splitlines()
        if not any(n.startswith("ministack-rds-") and n.endswith("-"+service) for n in names):
            try:rds.delete_db_instance(DBInstanceIdentifier=service,SkipFinalSnapshot=True)
            except rds.exceptions.DBInstanceNotFoundFault:pass
        try:
            rds.create_db_instance(DBInstanceIdentifier=service,Engine=engine,DBInstanceClass="db.t4g.medium",AllocatedStorage=20,MasterUsername="local_admin",MasterUserPassword="local-only-password",DBName=name)
        except rds.exceptions.DBInstanceAlreadyExistsFault: pass
        for attempt in range(60):
            db=rds.describe_db_instances(DBInstanceIdentifier=service)["DBInstances"][0]
            if db.get("DBInstanceStatus")=="available" and db.get("Endpoint"):break
            time.sleep(1)
        else:raise RuntimeError("MiniStack database did not become available")
        endpoint=db["Endpoint"]
        names=subprocess.check_output(["docker","ps","--format","{{.Names}}"]).decode().splitlines()
        container=next(n for n in names if n.startswith("ministack-rds-") and n.endswith("-"+service))
        inspection=json.loads(subprocess.check_output(["docker","inspect",container]))[0]
        endpoint={"Address":"localhost","Port":int(inspection["NetworkSettings"]["Ports"][str(port)+"/tcp"][0]["HostPort"])}
        cfg={"engine":engine,"database":name,"host":"localhost","port":endpoint["Port"]}
        master={"username":"local_admin","password":"local-only-password"}

        value={"engine":engine,"host":endpoint["Address"],"port":endpoint["Port"],"dbname":name,"username":"local_admin","password":"local-only-password"}
        for kind in ["runtime","migration"]:
            value["username"]=manager.user_name(service,kind,"a")
            value["password"]="local-only-"+kind
            manager.provision(cfg,master,service,kind,value)
            secret=f"local/{service}/{kind}"
            try:sm.create_secret(Name=secret,SecretString=json.dumps(value))
            except sm.exceptions.ResourceExistsException:sm.put_secret_value(SecretId=secret,SecretString=json.dumps(value))
        s3.create_bucket(Bucket="local-"+service)
        state[service]={"engine":engine,"host":endpoint["Address"],"port":endpoint["Port"],"database":name}
    cache=client("elasticache")
    try: cache.create_cache_cluster(CacheClusterId="local-api-contract",Engine="redis",CacheNodeType="cache.t4g.small",NumCacheNodes=1)
    except cache.exceptions.CacheClusterAlreadyExistsFault:pass
    (ROOT/"local/generated.json").write_text(json.dumps(state,indent=2))
    print("Created local resources; endpoints written to local/generated.json")
if __name__=="__main__":main()
