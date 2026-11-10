#!/usr/bin/env python3
"""Prove duplicate discovery rejection with real Responses requests, without disk credentials."""
import json
import os
from pathlib import Path
import re
import urllib.error
import urllib.request


def main():
    match = re.search(r'ANTHROPIC_AUTH_TOKEN\s*=\s*[\x22\x27]([^\x22\x27\n]+)',
                      Path.home().joinpath('.local/bin/dcc').read_text())
    if not match:
        raise SystemExit('Credential assignment not found')
    os.environ['DORA_TEST_DEEPSEEK_KEY'] = match[1]
    key = os.environ['DORA_TEST_DEEPSEEK_KEY']
    definitions = [
        {'type': 'function', 'name': name, 'description': description,
         'parameters': {'type': 'object', 'properties': {}}, 'defer_loading': True}
        for name, description in [('notes_read', 'Read notes'), ('notes_write', 'Write notes')]
    ]
    for duplicate in (True, False):
        items = [{'role': 'user', 'content': 'Find tools for notes twice, then say OK.'}]
        for number in (1, 2):
            items.extend([
                {'type': 'tool_search_call', 'execution': 'client', 'call_id': f'search-{number}',
                 'arguments': {'query': 'notes'}},
                {'type': 'tool_search_output', 'execution': 'client', 'status': 'completed',
                 'call_id': f'search-{number}', 'tools': definitions if duplicate or number == 1 else []},
            ])
        payload = {'model': 'deepseek-flash', 'input': items, 'stream': False,
                   'tools': [{'type': 'tool_search', 'execution': 'client', 'description': 'Search tools',
                              'parameters': {'type': 'object', 'properties': {'query': {'type': 'string'}}, 'required': ['query']}}],
                   'max_output_tokens': 1024, 'reasoning': {'effort': 'none'}}
        request = urllib.request.Request('https://api.deepseek.com/v1/responses',
                                         data=json.dumps(payload).encode(),
                                         headers={'Authorization': 'Bearer ' + key, 'Content-Type': 'application/json'})
        try:
            with urllib.request.urlopen(request, timeout=120) as response:
                status, body = response.status, response.read()
        except urllib.error.HTTPError as error:
            status, body = error.code, error.read()
        if key.encode() in body:
            raise SystemExit('Credential detected in response; discarded')
        value = json.loads(body)
        if duplicate:
            assert status == 400 and 'unique' in str(value).lower(), f'Unexpected duplicate status: {status}: {value}'
            print('PASS: duplicate broad-search definitions rejected (HTTP 400)')
        else:
            assert status == 200, f'Unique definitions rejected: {status}: {value}'
            print('PASS: repeated broad search with unique definitions accepted (HTTP 200)')


if __name__ == '__main__':
    main()
