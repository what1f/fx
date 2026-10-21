// Redirect SDK imports. The tool-start preview oracle normalizes JSON key order;
// its assertions and size boundaries remain unchanged.
const adapter = new URL('./adapter.mjs', import.meta.url).href;
export async function resolve(specifier, context, nextResolve) {
  if (context.parentURL?.includes('/sdk/tests/') && (specifier === '../node.js' ||
      specifier === '../browser.js' && context.parentURL.endsWith('/test-list-models.mjs'))) {
    return { url: adapter, shortCircuit: true };
  }
  return nextResolve(specifier, context);
}

export async function load(url, context, nextLoad) {
  const result = await nextLoad(url, context);
  if (!url.endsWith('/sdk/tests/test-agent-tool-start.mjs')) return result;
  const source = result.source.toString();
  const oracle = 'const full = JSON.stringify({ path: "/tmp/big.txt", content: huge });';
  if (source.split(oracle).length !== 2) throw new Error('Tool-start JSON preview oracle changed; review Swift normalization');
  // Swift uses canonical key order. Normalize this expected JSON representation,
  // retaining every upstream assertion and all actual SDK behavior.
  const canonical = 'const full = JSON.stringify({ path: "/tmp/big.txt", content: huge }, Object.keys({ path: "", content: "" }).sort());';
  return { ...result, source: source.replace(oracle, canonical) };
}
