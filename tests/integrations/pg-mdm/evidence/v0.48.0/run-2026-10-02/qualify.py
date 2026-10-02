import hashlib
import json
from pathlib import Path
import subprocess
import sys
import time
import uuid

root = Path(sys.argv[1]).resolve()
output = Path(sys.argv[2]).resolve()
output.mkdir(parents=True, exist_ok=False)
image = 'sha256:8cac118a1c52b96607be40a51900fdec0b5a96bd8cb1ecad9a85df920bbd8c47'
container = 'pgreact-pr9-' + uuid.uuid4().hex[:12]
record = {'image_id': image, 'checks': []}

def command(*arguments):
    result = subprocess.run(['rtk', 'proxy', 'docker', *arguments], capture_output=True,
                            text=True, timeout=300)
    if result.returncode:
        raise RuntimeError(' '.join(arguments) + '\n' + result.stdout + result.stderr)
    return result.stdout

def fixture(name, *arguments):
    result = command('exec', container, *arguments)
    path = output / (name + '.log')
    path.write_text(result)
    record['checks'].append({'name': name, 'status': 'passed', 'command':
        ['docker', 'exec', container, *arguments], 'log': path.name,
        'sha256': hashlib.sha256(path.read_bytes()).hexdigest()})
    print(name + ': PASS', flush=True)

try:
    command('run', '--detach', '--name', container, '--network', 'none',
            '--env', 'POSTGRES_HOST_AUTH_METHOD=trust', '--volume', str(root) + ':/work:ro',
            image, 'postgres', '-c', 'shared_preload_libraries=pg_trickle,pg_react',
            '-c', 'pg_trickle.enabled=off', '-c', 'pg_trickle.cdc_mode=trigger',
            '-c', 'pg_trickle.differential_max_change_ratio=1.0')
    for _ in range(60):
        if 'PostgreSQL init process complete' in command('logs', container):
            command('exec', container, 'pg_isready', '-U', 'postgres')
            break
        time.sleep(1)
    else:
        raise RuntimeError('PostgreSQL initialization did not complete')
    for name, file, database in (
        ('mdm-bootstrap', '/tests/e2e.sql', 'postgres'),
        ('mdm-policy-fixtures', '/tests/e2e_policy.sql', 'foundation'),
    ):
        fixture(name, 'psql', '-Xq', '-U', 'postgres', '-d', database,
                '-v', 'ON_ERROR_STOP=1', '-f', file)
    command('exec', container, 'psql', '-Xq', '-U', 'postgres', '-d', 'foundation',
            '-v', 'ON_ERROR_STOP=1', '-c', "CREATE EXTENSION pg_react VERSION '0.46.1';")
    record['runtime'] = json.loads(command('exec', container, 'psql', '-XAtq', '-U', 'postgres',
        '-d', 'foundation', '-c', "SELECT json_build_object('postgresql', current_setting('server_version'), "
        "'extensions', (SELECT json_object_agg(extname, extversion) FROM pg_extension))"))
    assert record['runtime']['extensions']['pg_react'] == '0.46.1'
    record['library_sha256'] = command('exec', container, 'sha256sum',
        '/usr/lib/postgresql/18/lib/pg_react.so', '/usr/lib/postgresql/18/lib/pg_mdm.so',
        '/usr/lib/postgresql/18/lib/pg_trickle.so').splitlines()
    for name in ('v0.47-live-setup', 'v0.47-live', 'v0.48-codec', 'v0.48-live', 'v0.48-security'):
        fixture(name, 'psql', '-Xq', '-U', 'postgres', '-d', 'foundation',
                '-v', 'ON_ERROR_STOP=1', '-f', '/work/tests/integrations/pg-mdm/' + name + '.sql')
    fixture('v0.48-restore', 'env',
            'MDM_HELPER_CONFIG=/workspace/tests/integrations/pg-mdm/pg-mdm-configure-helper.sql',
            'sh', '/work/tests/integrations/pg-mdm/v0.48-restore.sh')
    fixture('v0.48-admission', 'sh', '/work/tests/integrations/pg-mdm/v0.48-admission.sh')
finally:
    command('rm', '--force', '--volumes', container)
    (output / 'observations.json').write_text(json.dumps(record, indent=2) + '\n')
