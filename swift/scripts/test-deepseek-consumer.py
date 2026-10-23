#!/usr/bin/env python3
"""Load the local credential into process memory and execute the built consumer."""
import os
from pathlib import Path
import re
import sys

root = Path(__file__).resolve().parents[2]
source = Path.home().joinpath('.local/bin/dcc').read_text()
match = re.search(r'ANTHROPIC_AUTH_TOKEN="([^"\n]+)"', source)
if not match:
    sys.exit('No credential found in dcc')
environment = os.environ.copy()
environment['DEEPSEEK_API_KEY'] = match[1]
environment['FX_SOUND'] = '0'
for name in ('FX_DEBUG', 'FX_DEBUG_TRACE', 'FX_DEBUG_RECORD', 'FX_RECORD'):
    environment.pop(name, None)
binary = root / 'swift/consumers/DeepSeek/.build/release/Acceptance'
os.execve(binary, [str(binary), *sys.argv[1:]], environment)
