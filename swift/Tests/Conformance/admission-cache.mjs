import assert from 'node:assert/strict';
import { createFxEngine } from './adapter.mjs';

const texts = [], requests = [];
const png = Buffer.from('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNkYAAAAAYAAjCB0C8AAAAASUVORK5CYII=', 'base64');
const engine = await createFxEngine({ apiKey: 'test-key', model: 'swift/admission',
  fetch(_url, init) {
    if (init.method === 'GET') return Response.json({ data: [{ id: 'swift/admission', type: 'language', tags: ['vision', 'file-input'] }] });
    const payload = JSON.parse(Buffer.from(init.body).toString());
    requests.push(payload);
    const input = payload.prompt.filter(message => message.role === 'user').at(-1);
    texts.push(typeof input.content === 'string' ? input.content : input.content.filter(part => part.type === 'text').map(part => part.text).join(''));
    return new Response('data: {"type":"text-delta","delta":"OK"}\n\ndata: {"type":"finish","finishReason":{"unified":"stop","raw":"stop"}}\n\ndata: [DONE]\n\n', {
      headers: { 'content-type': 'text/event-stream' },
    });
  },
});
async function prompt(input) {
  const turn = engine.prompt(input);
  let text = '';
  for await (const event of turn) if (event.type === 'text_delta') text += event.delta;
  assert.equal((await turn.result).stopReason, 'end_turn');
  assert.equal(text, 'OK');
}
try {
  await prompt('look 0');
  await prompt('read 1');
  assert.deepEqual(texts, ['look 0', 'read 1'], 'cached admission must preserve each actual prompt');
  const width = 4 * 1024 * 1024;
  await prompt('a'.repeat(width));
  for (const character of ['"', '\\', 'é']) {
    assert.throws(() => engine.prompt(character.repeat(width)), /Prompt exceeds frame limit/,
      'equal character counts with escaping or multibyte UTF-8 must not reuse ASCII admission');
  }
  await prompt([{ type: 'text', text: 'look 2' }, { type: 'image', data: png, mimeType: 'image/png' }]);
  const malformed = Buffer.from(png);
  malformed[0] = 0;
  assert.throws(() => engine.prompt([{ type: 'text', text: 'look 3' }, { type: 'image', data: malformed, mimeType: 'image/png' }]), /not a PNG, JPEG, GIF or WebP/,
    'equal image sizes must still distinguish image signatures');
  assert.equal(requests.length, 4, 'rejected inputs must not reach the model');
  console.log('Swift admission cache passed: original content, escaping, UTF-8 bounds and image signatures');
} finally { await engine.close(); }
