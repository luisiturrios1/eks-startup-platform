# Local development and testing

The Java integration suite wraps MiniStack's documented module with scoped cleanup: version 0.1.5 otherwise reaps all containers carrying its global label. Our tests remove only their own emulator container and use independently owned database fixtures. Do not add real-infrastructure mode to this wrapper without implementing ownership-scoped sidecar cleanup.

```bash
examples/apps/mvnw -B -f examples/apps/pom.xml verify
docker compose up -d --wait
.venv/bin/python scripts/local_setup.py
PLATFORM_LOCAL_INTEGRATION=1 .venv/bin/pytest -q tests/integration
scripts/local_kind.sh
.venv/bin/python scripts/local_smoke.py
```

MiniStack provisions real PostgreSQL/MySQL containers through its RDS API and exercises its ElastiCache API. A separate pinned Valkey container tests the actual selected cache engine. `local_setup.py` uses only a fixed loopback AWS endpoint and test credentials; it creates separate runtime/migration users using the same provisioning code as AWS. The explicit local adapter permits local connections without production certificate verification. AWS code always verifies certificates and requires TLS.

MiniStack's real-infrastructure mode mounts the Docker socket and creates sidecars whose host ports may bind beyond loopback. Use a trusted development machine or isolated CI runner, not a shared Docker daemon. No real credentials or production data belong here. kind's pod CIDR must not overlap Docker Desktop's host-gateway addresses.

The local kind cluster uses Calico NetworkPolicy. Its app profile uses HTTP on port 8080 and direct addresses on kind's Docker network for MiniStack, database sidecars and Valkey; this works on Docker Desktop and Linux. AWS Helm deployment uses HTTPS, private endpoints and Pod Identity. Local mode is never selected by the AWS chart.

Access the demos through port-forwarding:

```bash
kubectl --context kind-platform-local -n payments-service port-forward svc/payments-service 8081:8080
# In another terminal:
curl http://localhost:8081/api/info
curl -X POST http://localhost:8081/api/demo
curl -X POST http://localhost:8081/api/cache
curl -X POST http://localhost:8081/api/object
```

For auth-service use its namespace/service and another local port. Re-running local_kind replaces only disposable migration Jobs; it does not delete databases. Example apps use the same shared image with different service identities.

Local tests verify SQL grants, migration behavior, secret refresh, S3 operations and cache ACLs. They do not prove AWS IAM authorization, VPC packet paths, WAF enforcement, VPN authentication, EKS/Karpenter behavior, or managed failover. See [MiniStack limitations](https://ministack.org/docs/limitations).

Cleanup is explicit: `kind delete cluster --name platform-local` removes only this local test cluster; `docker compose down` stops this project's containers. MiniStack-managed RDS/cache sidecars are separate: delete the known local RDS/cache resources through MiniStack first. Do not use global Docker pruning.
