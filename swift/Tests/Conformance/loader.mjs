// Redirect SDK imports only. Upstream fixtures and assertions remain unchanged.
const adapter = new URL('./adapter.mjs', import.meta.url).href;
export async function resolve(specifier, context, nextResolve) {
  if (context.parentURL?.includes('/sdk/tests/') && specifier === '../node.js') {
    return { url: adapter, shortCircuit: true };
  }
  return nextResolve(specifier, context);
}
