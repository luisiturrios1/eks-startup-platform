import copy, importlib.util, json
from pathlib import Path
import pytest
ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("compiler", ROOT / "scripts/compile_services.py")
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
def fixtures():
    return [json.loads(p.read_text()) for p in sorted((ROOT / "services").glob("*.yaml"))]
def test_environments():
    for env in ("dev", "staging", "prod"):
        assert len(m.compile_config(env)["database_instances"]) == 2
def test_shared_and_dedicated():
    services = fixtures(); extra = copy.deepcopy(services[0]);extra["name"] = "another-auth";extra["database"]["name"] = "another_auth";services.append(extra)
    assert len(m.compile_config("dev", services)["database_instances"]) == 2
    extra["database"] = dict(placement="dedicated", name="another_auth",engine="postgres",engine_version="17",instance_class="db.t4g.medium",storage_gb=20)
    assert len(m.compile_config("dev", services)["database_instances"]) == 3
@pytest.mark.parametrize("mutation", ["unknown_group","engine_override","database_collision","cross_domain","scaling","permission"])
def test_rejections(mutation):
    services=fixtures(); s=services[0]
    if mutation=="unknown_group": s["database"]["group"]="missing"
    if mutation=="engine_override": s["database"]["engine"]="postgres"
    if mutation=="database_collision":
        extra=copy.deepcopy(s);extra["name"]="collision";services.append(extra)
    if mutation=="cross_domain": s["domain"]="other"
    if mutation=="scaling": s["scaling"]["minReplicas"]=20
    if mutation=="permission": s["permissions"]["s3"]=["*"]
    with pytest.raises(Exception): m.compile_config("dev",services)

@pytest.mark.parametrize("resource,value", [("cpu", "2000m"), ("memory", "2Gi")])
def test_requests_cannot_exceed_limits(resource, value):
    services = fixtures()
    services[0]["resources"]["requests"][resource] = value
    with pytest.raises(ValueError, match="requests cannot exceed"):
        m.compile_config("dev", services)

def test_runtime_cannot_request_database_secret():
    services = fixtures()
    services[0]["secretReferences"] = ["arn:aws:secretsmanager:us-east-1:111111111111:secret:platform-dev/auth-service/database/migration-abcdef"]
    with pytest.raises(ValueError):
        m.compile_config("dev", services)

def test_production_requires_multiple_replicas():
    services = fixtures()
    services[0]["scaling"]["minReplicas"] = 1
    with pytest.raises(ValueError):
        m.compile_config("prod", services)
