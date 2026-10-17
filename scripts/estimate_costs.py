#!/usr/bin/env python3
"""Estimate all infrastructure environments from HCL without AWS credentials or plans."""
import argparse
import json
import os
from pathlib import Path
import shutil
import subprocess
from decimal import Decimal

from compile_services import compile_config

ROOT = Path(__file__).resolve().parents[1]
ENVIRONMENTS = ("dev", "staging", "prod")
VERSION = "0.10.46"


def cost_components(resources):
    for resource in resources:
        yield from resource.get("costComponents", [])
        yield from cost_components(resource.get("subresources", []))


def validate_estimate(data):
    projects = data.get("projects", [])
    if sorted(project.get("name") for project in projects) != sorted(ENVIRONMENTS):
        raise ValueError("Expected exactly one estimate for dev, staging and prod")
    for project in projects:
        for warning in project.get("metadata", {}).get("warnings", []):
            if warning.get("isError") or warning.get("code") == 105:
                raise ValueError(f"Unresolved inputs in {project['name']}: {warning.get('message')}")
        if project.get("breakdown", {}).get("totalMonthlyCost") is None:
            raise ValueError(f"No monthly estimate for {project['name']}")


def render_summary(data, input_label):
    validate_estimate(data)
    lines = [
        "## Infrastructure cost estimate",
        "",
        f"Inputs: {input_label}. Infracost {VERSION}; currency: {data.get('currency', 'USD')}.",
        "",
        "These are partial monthly estimates for provisioned capacity, using Infracost's defaults.",
        "Unspecified usage and missing prices are unknown, not zero. This is not an AWS bill or spending limit.",
        "",
        "| Environment | Unadjusted monthly estimate | Supported resources | Unsupported resources | Usage components without quantities | Missing prices |",
        "|---|---:|---:|---:|---:|---:|",
    ]
    order = {name: i for i, name in enumerate(ENVIRONMENTS)}
    for project in sorted(data["projects"], key=lambda project: order[project["name"]]):
        breakdown = project["breakdown"]
        summary = project.get("summary", {})
        components = list(cost_components(breakdown.get("resources", [])))
        unknown_usage = sum(c.get("usageBased", False) and c.get("monthlyQuantity") is None for c in components)
        missing_prices = sum(bool(c.get("priceNotFound")) for c in components)
        amount = Decimal(breakdown["totalMonthlyCost"])
        lines.append(
            f"| {project['name']} | ${amount:,.2f} | {summary.get('totalSupportedResources', 0)} | "
            f"{summary.get('totalUnsupportedResources', 0)} | {unknown_usage} | {missing_prices} |"
        )
    lines.extend([
        "",
        "Scope: environments/dev, environments/staging and environments/prod, including their local Terraform modules.",
        "Bootstrap account resources, Kubernetes workload capacity beyond the system node group (including Karpenter),",
        "unmodeled AWS charges, discounts, taxes and unspecified traffic/storage/telemetry usage need separate review.",
        "The checked-in usage files contain no measured usage. Review JSON coverage and CLI warnings before budgeting.",
        "Known CLI model limitation: MySQL 8.4 can inherit MySQL 8 extended-support charges; verify those components",
        "against AWS engine support dates before using these unadjusted tool totals for a budget.",
        "No AWS credentials, Terraform plan, apply, destroy or state access are used.",
        "",
    ])
    return "\n".join(lines)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--vars-dir", type=Path, help="Use ENV.tfvars.json files from this private directory instead of repository examples")
    args = parser.parse_args()
    binary = ROOT / ".artifacts/bin/infracost"
    executable = str(binary) if binary.is_file() else shutil.which("infracost")
    if not executable:
        raise SystemExit("Install the pinned CLI: python scripts/install_tools.py --tool infracost")
    environment = dict(os.environ, INFRACOST_ENABLE_CLOUD="false", INFRACOST_SKIP_UPDATE_CHECK="true")
    version = subprocess.check_output([executable, "--version"], env=environment, text=True)
    if version.splitlines()[0] != f"Infracost v{VERSION}":
        raise SystemExit(f"Expected Infracost {VERSION}; run scripts/install_tools.py --tool infracost")
    output = ROOT / "build/infracost"
    output.mkdir(parents=True, exist_ok=True)
    report = output / "costs.json"
    report.unlink(missing_ok=True)
    (output / "summary.md").unlink(missing_ok=True)
    # Restrict generated inputs/reports even when operators supply private tfvars.
    os.umask(0o077)
    for name in ENVIRONMENTS:
        source = args.vars_dir / f"{name}.tfvars.json" if args.vars_dir else ROOT / f"environments/{name}/terraform.tfvars.json.example"
        values = json.loads(source.read_text())
        if values.get("environment") != name:
            raise SystemExit(f"Environment mismatch in inputs for {name}")
        # Read JSON examples ourselves: the CLI treats .json.example as HCL and silently misses inputs.
        values.update(compile_config(name))
        target = output / f"{name}.tfvars.json"
        target.write_text(json.dumps(values, indent=2) + "\n")
        target.chmod(0o600)
    subprocess.run([
        executable, "breakdown", "--config-file", "infracost.yml", "--format", "json",
        "--out-file", str(report), "--no-color",
    ], cwd=ROOT, env=environment, check=True)
    label = "explicit operator tfvars" if args.vars_dir else "repository example sizing; default region us-east-1"
    summary = render_summary(json.loads(report.read_text()), label)
    (output / "summary.md").write_text(summary)
    print(summary)
    print("Reports: build/infracost/costs.json and build/infracost/summary.md")


if __name__ == "__main__":
    main()
