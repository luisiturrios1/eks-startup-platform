#!/usr/bin/env python3
"""Install checksum-pinned validation tools under .artifacts/bin."""
import argparse,hashlib,io,json,platform,tarfile,urllib.request,zipfile
from pathlib import Path
ROOT=Path(__file__).resolve().parents[1]
def main():
    system=platform.system().lower();arch={'aarch64':'arm64','x86_64':'amd64'}.get(platform.machine(),platform.machine())
    entries=json.loads((ROOT/'config/tools.lock.json').read_text())[system+'-'+arch]
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--tool',action='append',choices=sorted(entries),help='Install only the selected tool; repeat to select more than one.')
    args=parser.parse_args()
    if args.tool:entries={name:entries[name] for name in args.tool}
    target=ROOT/'.artifacts/bin';target.mkdir(parents=True,exist_ok=True)
    for tool,entry in entries.items():
        payload=urllib.request.urlopen(entry['url']).read()
        if hashlib.sha256(payload).hexdigest()!=entry['sha256']:raise RuntimeError('Checksum mismatch: '+tool)
        if entry['url'].endswith('.zip'):
            archive=zipfile.ZipFile(io.BytesIO(payload));payload=archive.read(tool)
        elif entry['url'].endswith('.tar.gz'):
            archive=tarfile.open(fileobj=io.BytesIO(payload));payload=archive.extractfile(next(m for m in archive.getmembers() if Path(m.name).name in (tool,f'{tool}-{system}-{arch}'))).read()
        path=target/tool;path.write_bytes(payload);path.chmod(0o755);print(tool+' installed')
if __name__=='__main__':main()
