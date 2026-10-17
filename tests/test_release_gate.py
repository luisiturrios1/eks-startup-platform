import json,os,subprocess
from pathlib import Path
ROOT=Path(__file__).resolve().parents[1]
def test_failed_migration_blocks_application_upgrade(tmp_path):
    commands=tmp_path/'commands'
    for name,body in {
        'kubectl':'if [ "$1" = config ]; then echo test-context; fi\n',
        'helm':'echo "$*" >> "$COMMAND_LOG"\nif [ "$1" = status ]; then exit 0; fi\ncase "$*" in *migrationOnly=true*) exit 1;; esac\n'
    }.items():
        path=tmp_path/name;path.write_text('#!/bin/sh\n'+body);path.chmod(0o755)
    values=tmp_path/'values.json';values.write_text(json.dumps({'name':'payments-service'}))
    result=subprocess.run(['bash',str(ROOT/'scripts/deploy-service.sh'),'--approved',str(values),'test-context'],cwd=ROOT,env=dict(os.environ,PATH=str(tmp_path)+os.pathsep+os.environ['PATH'],COMMAND_LOG=str(commands)),capture_output=True)
    assert result.returncode!=0
    calls=commands.read_text()
    assert 'migrationOnly=true' in calls
    assert 'upgrade --install payments-service charts/service' not in calls
