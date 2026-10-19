#!/usr/bin/env python3
"""Install checksum-pinned upstream API-test binaries without Docker or cloud access."""
import json
import platform
import tarfile

from prepare_assets import ARTIFACTS, ROOT, prepare_asset


def main():
    architecture = {'aarch64': 'arm64', 'x86_64': 'amd64'}.get(platform.machine(), platform.machine())
    target = platform.system().lower()+'-'+architecture
    entry = json.loads((ROOT/'config/envtest.lock.json').read_text())[target]
    name = entry['filename']
    ARTIFACTS.mkdir(exist_ok=True)
    prepare_asset(name, entry['sha256'],
                  'https://github.com/kubernetes-sigs/controller-tools/releases/download/envtest-v1.35.0/'+name)
    with tarfile.open(ARTIFACTS/name) as archive:
        archive.extractall(ARTIFACTS/'envtest', filter='data')
    print(ARTIFACTS/'envtest/controller-tools/envtest')


if __name__ == '__main__':
    main()
