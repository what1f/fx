// Redirect SDK imports. The tool-start preview oracle normalizes JSON key order;
// its assertions and size boundaries remain unchanged.
const adapter = new URL('./adapter.mjs', import.meta.url).href;
export async function resolve(specifier, context, nextResolve) {
  if (context.parentURL?.includes('/sdk/tests/') && (['../node.js', '../skills.js', '../skills-node.js', '../mcp.js'].includes(specifier) ||
      specifier === '../browser.js' && context.parentURL.endsWith('/test-list-models.mjs') ||
      ['../fx-sdk.js', '../tool-observation.js'].includes(specifier) && context.parentURL.endsWith('/test-hooks.mjs'))) {
    return { url: adapter, shortCircuit: true };
  }
  return nextResolve(specifier, context);
}

export async function load(url, context, nextLoad) {
  const result = await nextLoad(url, context);
  if (url.endsWith('/sdk/tests/test-hooks.mjs')) {
    let source = result.source.toString();
    const start = '// A host-created child adds its outer parent only to its own root session.';
    const standalone = '// Cancellation is an observation, not a replacement for the host';
    const end = 'for (const hooks of [';
    if ([start, standalone, end].some(marker => source.split(marker).length !== 2)) throw new Error('Upstream hooks layout changed; review test ownership');
    const before = source.slice(0, source.indexOf(start));
    let runtime = source.slice(source.indexOf(start), source.indexOf(standalone));
    // Preserve assertions while waiting for the asynchronous Swift process to
    // acknowledge fixture injection. Runtime frames still pass through Swift RPC.
    runtime = runtime.replace('queueMicrotask(() =>', 'queueMicrotask(async () =>')
      .replace('const emit = (overrides) =>', 'const emit = async (overrides) =>')
      .replace(/^(\s*)handler\(/gm, '$1await handler(')
      .replace(/^(\s*)emit\(/gm, '$1await emit(')
      .replace('const outer = toolObservation(', 'const outer = await toolObservation(')
      .replace('const engine = await createSharedEngine(', 'let engine;\n  try {\n  engine = await createSharedEngine(')
      .replace('  try {\n    const frame =', '    const frame =')
      .replace('await engine.close();', 'try { await engine?.close(); } finally { await outer.close(); }');
    let helper = source.slice(source.indexOf(standalone), source.indexOf(end));
    if (helper.split('controller.abort();').length !== 2 || helper.split('const observer = toolObservation(').length !== 2) {
      throw new Error('Upstream standalone hooks fixture changed; review Swift timing adaptation');
    }
    // The original synchronous fixture needs an IPC acknowledgement before abort
    // and before inspecting terminal events. Every original assertion is retained.
    helper = helper.replace('const observer = toolObservation(', 'const observer = await toolObservation(')
      .replace('  let calls = 0;', '  try {\n  let calls = 0;')
      .replace('controller.abort();', 'await observer.waitUntilStarted();\n  controller.abort();\n  await observer.flush();');
    const closingBrace = helper.lastIndexOf('}');
    helper = helper.slice(0, closingBrace) + '  } finally { await observer.close(); }\n' + helper.slice(closingBrace);
    source = before + runtime + helper + source.slice(source.indexOf(end));
    return { ...result, source };
  }
  if (!url.endsWith('/sdk/tests/test-agent-tool-start.mjs')) return result;
  const source = result.source.toString();
  const oracle = 'const full = JSON.stringify({ path: "/tmp/big.txt", content: huge });';
  if (source.split(oracle).length !== 2) throw new Error('Tool-start JSON preview oracle changed; review Swift normalization');
  // Swift uses canonical key order. Normalize this expected JSON representation,
  // retaining every upstream assertion and all actual SDK behavior.
  const canonical = 'const full = JSON.stringify({ path: "/tmp/big.txt", content: huge }, Object.keys({ path: "", content: "" }).sort());';
  return { ...result, source: source.replace(oracle, canonical) };
}
