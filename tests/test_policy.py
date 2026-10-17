import importlib.util
from pathlib import Path
ROOT=Path(__file__).resolve().parents[1]
spec=importlib.util.spec_from_file_location('policy',ROOT/'scripts/check_policy.py');p=importlib.util.module_from_spec(spec);spec.loader.exec_module(p)
def test_security_baseline():
    assert p.evaluate(p.resources(ROOT/'modules/platform'),p.resources(ROOT/'modules/networking'))==[]
def test_public_control_plane_rejected():
    platform=p.resources(ROOT/'modules/platform');platform['aws_eks_cluster.this']['vpc_config'][0]['endpoint_public_access']=True
    assert 'EKS API must be private' in p.evaluate(platform,p.resources(ROOT/'modules/networking'))
def test_private_subnet_internet_route_rejected():
    network=p.resources(ROOT/'modules/networking');network['aws_route.internet']['route_table_id']='${aws_route_table.application.id}'
    assert 'Internet route outside ingress subnets' in p.evaluate(p.resources(ROOT/'modules/platform'),network)
