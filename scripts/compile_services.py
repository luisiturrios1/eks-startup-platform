#!/usr/bin/env python3
"""Validate contracts and emit deterministic non-secret inputs; never contacts AWS."""
import argparse, json
from pathlib import Path
import yaml
from jsonschema import Draft202012Validator
ROOT = Path(__file__).resolve().parents[1]
def compile_config(environment, services=None, config=None):
    schema = json.loads((ROOT / "schemas/service.schema.json").read_text())
    config = config or json.loads((ROOT / f"config/{environment}.json").read_text())
    services = services if services is not None else [yaml.safe_load(p.read_text()) for p in sorted((ROOT / "services").glob("*.yaml"))]
    groups = config["database_groups"]
    result, instances, used_databases = {}, {}, set()
    for name, group in groups.items():
        if group["engine"] not in ("postgres", "mysql"):
            raise ValueError(f"Invalid engine in group {name}")
    for service in services:
        Draft202012Validator(schema).validate(service)
        name, database = service["name"], service["database"]
        if any("/database/" in ref for ref in service.get("secretReferences",[])):
            raise ValueError("Database credential references are reserved for generated identities")
        if environment == "prod" and service["scaling"]["minReplicas"] < 2:
            raise ValueError("Production requires at least two replicas")
        def cpu(value):return int(value[:-1]) if value.endswith("m") else int(value)*1000
        def memory(value):return int(value[:-2]) * (1024 if value.endswith("Gi") else 1)
        for resource,convert in [("cpu",cpu),("memory",memory)]:
            if convert(service["resources"]["requests"][resource]) > convert(service["resources"]["limits"][resource]):
                raise ValueError("Resource requests cannot exceed limits")
        if name in result: raise ValueError(f"Duplicate service {name}")
        if service["scaling"]["minReplicas"] > service["scaling"]["maxReplicas"]:
            raise ValueError(f"Invalid scaling bounds for {name}")
        if database["placement"] == "shared":
            group = groups[database["group"]]
            if group["domain"] != service["domain"]: raise ValueError("Cross-domain database group reference")
            key = "shared-" + database["group"]
        else:
            key = "dedicated-" + name
            group = {k: database[k] for k in ("engine", "engine_version", "instance_class", "storage_gb")}
            group.update(domain=service["domain"], multi_az=environment == "prod")
        if environment == "prod" and not group["multi_az"]: raise ValueError("Production RDS requires Multi-AZ")
        pair = (key, database["name"])
        if pair in used_databases: raise ValueError("Each service requires a unique database")
        used_databases.add(pair)
        instances[key] = group
        result[name] = dict(service, database_key=key, engine=group["engine"])
    for name, service in result.items():
        if any(d not in result or d == name for d in service["dependencies"]):
            raise ValueError(f"Invalid dependency in {name}")
    return {"services": result, "database_instances": instances}
def main():
    p = argparse.ArgumentParser();p.add_argument("--environment", choices=["dev","staging","prod"], required=True);p.add_argument("--check", action="store_true")
    args = p.parse_args(); result = compile_config(args.environment)
    if args.check: print(f"{args.environment}: validated {len(result['services'])} services"); return
    output = ROOT / "environments" / args.environment / "services.auto.tfvars.json"
    output.write_text(json.dumps(result, indent=2) + "\n")
    print(output)
if __name__ == "__main__": main()
