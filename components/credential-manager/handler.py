"""Operator bootstrap and scheduled alternating-user rotation. Never logs secrets."""
import hashlib
import json
import os
import re
import secrets
import uuid
import boto3
import psycopg
from psycopg import sql
import pymysql


def identifier(value):
    if not re.fullmatch(r"[a-z][a-z0-9_]{1,40}", value):
        raise ValueError("Invalid database identifier")
    return value


def user_name(service, kind, slot):
    return "s_" + hashlib.sha256(service.encode()).hexdigest()[:16] + "_" + kind[0] + "_" + slot


def connect(cfg, credentials, database=None):
    tls = os.environ.get("RDS_CA_BUNDLE", "/var/task/global-bundle.pem")
    if cfg["engine"] == "postgres":
        return psycopg.connect(host=cfg["host"], port=cfg["port"], user=credentials["username"],
                              password=credentials["password"], dbname=database or "postgres",
                              sslmode="verify-full", sslrootcert=tls, connect_timeout=10, autocommit=True)
    return pymysql.connect(host=cfg["host"], port=int(cfg["port"]), user=credentials["username"],
                           password=credentials["password"], database=database,
                           ssl_ca=tls, ssl_verify_cert=True, ssl_verify_identity=True,
                           connect_timeout=10, autocommit=True)


def provision(cfg, master, service, kind, credentials):
    db = identifier(cfg["database"])
    user = credentials["username"]
    if cfg["engine"] == "postgres":
        with connect(cfg, master) as conn:
            if not conn.execute("SELECT 1 FROM pg_database WHERE datname=%s", (db,)).fetchone():
                conn.execute(sql.SQL("CREATE DATABASE {}").format(sql.Identifier(db)))
            conn.execute(sql.SQL("REVOKE ALL ON DATABASE {} FROM PUBLIC").format(sql.Identifier(db)))
            if not conn.execute("SELECT 1 FROM pg_roles WHERE rolname=%s", (user,)).fetchone():
                conn.execute(sql.SQL("CREATE ROLE {} LOGIN").format(sql.Identifier(user)))
            conn.execute(sql.SQL("ALTER ROLE {} PASSWORD {}").format(sql.Identifier(user), sql.Literal(credentials["password"])))
            conn.execute(sql.SQL("GRANT CONNECT ON DATABASE {} TO {}").format(sql.Identifier(db),sql.Identifier(user)))
        with connect(cfg, master, db) as conn:
            conn.execute("REVOKE ALL ON SCHEMA public FROM PUBLIC")
            conn.execute(sql.SQL("GRANT USAGE ON SCHEMA public TO {}").format(sql.Identifier(user)))
            # Stable, non-login owner role allows alternating migration users to alter old objects.
            owner = "o_" + hashlib.sha256(service.encode()).hexdigest()[:16]
            if not conn.execute("SELECT 1 FROM pg_roles WHERE rolname=%s", (owner,)).fetchone():
                conn.execute(sql.SQL("CREATE ROLE {} NOLOGIN").format(sql.Identifier(owner)))
            conn.execute(sql.SQL("GRANT {} TO {}").format(sql.Identifier(owner),sql.Identifier(master["username"])))
            conn.execute(sql.SQL("GRANT USAGE, CREATE ON SCHEMA public TO {}").format(sql.Identifier(owner)))
            if kind == "migration":
                conn.execute(sql.SQL("GRANT {} TO {}").format(sql.Identifier(owner),sql.Identifier(user)))
                conn.execute(sql.SQL("ALTER ROLE {} IN DATABASE {} SET role TO {}").format(sql.Identifier(user),sql.Identifier(db),sql.Literal(owner)))
            else:
                conn.execute(sql.SQL("GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA public TO {}").format(sql.Identifier(user)))
                conn.execute(sql.SQL("GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA public TO {}").format(sql.Identifier(user)))
                conn.execute(sql.SQL("ALTER DEFAULT PRIVILEGES FOR ROLE {} IN SCHEMA public GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO {}").format(sql.Identifier(owner),sql.Identifier(user)))
                conn.execute(sql.SQL("ALTER DEFAULT PRIVILEGES FOR ROLE {} IN SCHEMA public GRANT USAGE, SELECT ON SEQUENCES TO {}").format(sql.Identifier(owner),sql.Identifier(user)))
    else:
        with connect(cfg, master) as conn, conn.cursor() as cur:
            cur.execute(f"CREATE DATABASE IF NOT EXISTS `{db}`")
            cur.execute("CREATE USER IF NOT EXISTS %s@'%%' IDENTIFIED BY %s REQUIRE SSL", (user,credentials["password"]))
            cur.execute("ALTER USER %s@'%%' IDENTIFIED BY %s REQUIRE SSL", (user,credentials["password"]))
            privileges = "SELECT, INSERT, UPDATE, DELETE" if kind == "runtime" else "ALL PRIVILEGES"
            cur.execute(f"GRANT {privileges} ON `{db}`.* TO %s@'%%'", (user,))
    with connect(cfg, credentials, db) as conn:
        if cfg["engine"] == "postgres": conn.execute("SELECT 1")
        else:
            with conn.cursor() as cur: cur.execute("SELECT 1")


def handler(event, context):
    if event.get("action") not in ("bootstrap", "rotate"):
        raise ValueError("Expected explicit bootstrap or rotate action")
    config = json.loads(os.environ["CONFIG"])
    sm = boto3.client("secretsmanager")
    completed = []
    for service, cfg in config.items():
        master = json.loads(sm.get_secret_value(SecretId=cfg["master"])["SecretString"])
        # Runtime first establishes grants before migrations run.
        for kind in ("runtime", "migration"):
            arn = cfg[kind]
            current = None
            try:
                current = json.loads(sm.get_secret_value(SecretId=arn)["SecretString"])
            except sm.exceptions.ResourceNotFoundException:
                pass
            if current and event["action"] == "bootstrap":
                continue
            metadata = sm.describe_secret(SecretId=arn)
            pending = next((v for v, stages in metadata.get("VersionIdsToStages",{}).items()
                            if "AWSPENDING" in stages and "AWSCURRENT" not in stages), None)
            if pending:
                token = pending
                value = json.loads(sm.get_secret_value(SecretId=arn,VersionId=token)["SecretString"])
            else:
                slot = "b" if current and current["username"].endswith("_a") else "a"
                value = {"engine":cfg["engine"],"host":cfg["host"],"port":cfg["port"],"dbname":cfg["database"],
                         "username":user_name(service,kind,slot),"password":secrets.token_urlsafe(36)}
                token = str(uuid.uuid4())
                sm.put_secret_value(SecretId=arn,ClientRequestToken=token,SecretString=json.dumps(value),VersionStages=["AWSPENDING"])
            provision(cfg,master,service,kind,value)
            previous = next((v for v, stages in metadata.get("VersionIdsToStages",{}).items() if "AWSCURRENT" in stages),None)
            args = dict(SecretId=arn,VersionStage="AWSCURRENT",MoveToVersionId=token)
            if previous: args["RemoveFromVersionId"] = previous
            sm.update_secret_version_stage(**args)
            sm.update_secret_version_stage(SecretId=arn,VersionStage="AWSPENDING",RemoveFromVersionId=token)
        completed.append(service)
    return {"completed":completed}
