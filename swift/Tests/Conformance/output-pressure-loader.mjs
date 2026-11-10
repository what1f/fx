// Run the original pressure assertions against the Swift pull bridge. The final
// JS-addon drainCore injection cannot enter the C ABI used by Swift; omit only
// that block and report this narrower boundary explicitly.
import { load as loadFixture, resolve } from './loader.mjs';
export { resolve };
export async function load(url, context, nextLoad) {
  const result = await loadFixture(url, context, nextLoad);
  if (!url.endsWith('/sdk/tests/test-core-output-pressure.mjs')) return result;
  let source = result.source.toString();
  const begin = '  if (backend === "native") {\n    const addon = createRequire(import.meta.url)(nativeAddon);';
  const end = '  console.log(`${backend} bounded output passed: large frames, slow consumer, cancellation and reuse`);';
  const start = source.indexOf(begin), finish = source.indexOf(end);
  if (start < 0 || finish <= start || source.indexOf(begin, start + 1) !== -1) {
    throw new Error('Original output pressure fixture changed; review supported assertions');
  }
  source = source.slice(0, start) +
    '  console.log("Swift pressure bridge: original assertions passed; JS-addon corruption injection excluded");\n' +
    source.slice(finish + end.length);
  return { ...result, source };
}
