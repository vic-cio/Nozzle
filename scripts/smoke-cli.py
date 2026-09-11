#!/usr/bin/env python3
"""Exercise the built executable; no printer or GUI needed."""
import json
from pathlib import Path
import subprocess
import sys
import tempfile

binary = str(Path(sys.argv[1]).resolve())
checks = 0


def run(*args, code=0, error=False):
    global checks
    result = subprocess.run([binary, *args], capture_output=True, text=True, timeout=20)
    assert result.returncode == code, (args, result.returncode, result.stderr)
    assert not (result.stdout if error else result.stderr), (args, result)
    document = json.loads(result.stderr if error else result.stdout)
    assert document['schemaVersion'] == 1
    checks += 1
    return document['error' if error else 'data']


with tempfile.TemporaryDirectory(prefix='nozzle-cli-') as directory:
    fixture = Path(directory) / 'part with spaces.gcode'
    fixture.write_text(';FLAVOR:Marlin\n;MAXX:230\n;MAXY:10\n;MAXZ:2\nG28 ; home\nG1 X20\n')
    profile = Path(directory) / 'profile.json'
    profile.write_text('{"maxX":250}')
    assert 'file validate' in run('--help', '--json')['help']
    assert run('--version')['version'] == '1.0.0'
    assert isinstance(run('ports'), list)
    assert isinstance(run('ports', '--include-dialin'), list)
    assert run('profile', 'show')['maxX'] == 220
    assert run('profile', 'show', '--profile', str(profile))['maxX'] == 250
    assert run('file', 'inspect', str(fixture))['hasBlockingWarnings']
    assert run('file', 'validate', str(fixture), code=3)['hasBlockingWarnings']
    assert not run('file', 'validate', str(fixture), '--profile', str(profile))['hasBlockingWarnings']
    page = run('file', 'commands', str(fixture), '--limit', '1')
    assert page['commands'] == [{'index': 0, 'sourceLine': 5, 'command': 'G28'}]
    assert page['nextOffset'] == 1
    assert run('file', 'commands', str(fixture), '--offset', '99')['commands'] == []
    assert run('command', 'assess', 'M502')['requiresConfirmation']
    assert not run('command', 'assess', 'M105')['requiresConfirmation']
    assert run('file', 'inspect', str(fixture) + '.missing', code=1, error=True)['code'] == 'gcode_input'
    assert run('ports', '--limit', '1', code=2, error=True)['code'] == 'usage'
    assert run('command', 'assess', 'G28\nM112', code=2, error=True)['code'] == 'usage'
    result = subprocess.run([binary, '--help'], capture_output=True, text=True, timeout=20)
    assert result.returncode == 0 and 'Usage:' in result.stdout and not result.stderr
    checks += 1
print(f'Passed {checks} real CLI smoke checks.')
