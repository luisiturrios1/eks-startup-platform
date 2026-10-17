"""Prevent incomplete cost estimates from being presented as complete results."""
import importlib.util
from pathlib import Path
import sys

import pytest

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts"))
spec = importlib.util.spec_from_file_location("estimate_costs", ROOT / "scripts/estimate_costs.py")
costs = importlib.util.module_from_spec(spec)
spec.loader.exec_module(costs)


def estimate():
    return {"projects": [
        {"name": name, "metadata": {}, "breakdown": {"totalMonthlyCost": "10.5", "resources": []}}
        for name in costs.ENVIRONMENTS
    ]}


def test_missing_environment_cannot_produce_summary():
    data = estimate()
    data["projects"].pop()
    with pytest.raises(ValueError, match="exactly one estimate"):
        costs.render_summary(data, "test inputs")


def test_missing_terraform_inputs_fail_even_when_cli_exits_successfully():
    data = estimate()
    data["projects"][0]["metadata"]["warnings"] = [{"code": 105, "message": "Missing Terraform vars", "isError": False}]
    with pytest.raises(ValueError, match="Unresolved inputs"):
        costs.validate_estimate(data)


def test_unknown_usage_and_missing_prices_are_visible_in_summary():
    data = estimate()
    data["projects"][0]["breakdown"]["resources"] = [{"subresources": [{"costComponents": [
        {"usageBased": True, "monthlyQuantity": None},
        {"priceNotFound": True},
    ]}]}]
    summary = costs.render_summary(data, "test inputs")
    assert "| dev | $10.50 | 0 | 0 | 1 | 1 |" in summary
    assert "unknown, not zero" in summary
