#!/usr/bin/env python3
"""Load the local credential into process memory and execute the built consumer."""
import os
from pathlib import Path
import re
import sys
import subprocess

root = Path(__file__).resolve().parents[2]
source = Path.home().joinpath('.local/bin/dcc').read_text()
match = re.search(r'ANTHROPIC_AUTH_TOKEN="([^"\n]+)"', source)
if not match:
    sys.exit('No credential found in dcc')
environment = os.environ.copy()
environment['DORA_TEST_DEEPSEEK_KEY'] = match[1]
environment['FX_SOUND'] = '0'
for name in ('FX_DEBUG', 'FX_DEBUG_TRACE', 'FX_DEBUG_RECORD', 'FX_RECORD',
             'FX_TRACE', 'FX_TRACE_LOG', 'FX_TRACE_STDERR', 'FX_RESPONSES_DIAGNOSTICS'):
    environment.pop(name, None)
binary = root / 'swift/consumers/DeepSeek/.build/release/Acceptance'
result = subprocess.run([str(binary), *sys.argv[1:]], env=environment, capture_output=True)
if match[1].encode() in result.stdout or match[1].encode() in result.stderr:
    sys.exit('FAIL: credential found in consumer output; output discarded')
cache = Path.home() / 'Library/Caches/Acceptance'
for cached_file in cache.rglob('*') if cache.exists() else []:
    if cached_file.is_file() and match[1].encode() in cached_file.read_bytes():
        sys.exit('FAIL: credential found in HTTP disk cache')
sys.stdout.buffer.write(result.stdout)
sys.stderr.buffer.write(result.stderr)
print('PASS: credential absent from HTTP disk cache', flush=True)
sys.exit(result.returncode)
