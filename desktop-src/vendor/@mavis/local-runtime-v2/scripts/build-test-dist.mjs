// Emits dist/ for Runtime tests that start the package in a child process. It takes the
// exact file list tsc builds from tsconfig.json and transpiles each file on its own with
// esbuild, which verbatimModuleSyntax makes safe. Vitest runs the in-process tests through
// the same per-file esbuild transform. Types are checked by check:fast:typecheck, and the
// release build still emits with tsc.
import { build } from 'esbuild';
import { dirname, resolve } from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';
import ts from 'typescript';

const packageRoot = resolve(dirname(fileURLToPath(import.meta.url)), '..');

function configError(diagnostics) {
  const text = diagnostics
    .map((diagnostic) => ts.flattenDiagnosticMessageText(diagnostic.messageText, '\n'))
    .join('\n');
  return new Error(`tsconfig.json: ${text}`);
}

/** The files, output layout and target that `tsc --build` uses for this package. */
export function testDistInputs(root = packageRoot) {
  const configPath = resolve(root, 'tsconfig.json');
  const { config, error } = ts.readConfigFile(configPath, ts.sys.readFile);
  if (error) throw configError([error]);
  const parsed = ts.parseJsonConfigFileContent(config, ts.sys, root, undefined, configPath);
  if (parsed.errors.length) throw configError(parsed.errors);
  const { outDir, rootDir, target } = parsed.options;
  if (!outDir || !rootDir || target === undefined)
    throw new Error('tsconfig.json must set outDir, rootDir and target');
  return {
    configPath,
    files: parsed.fileNames.filter((file) => !file.endsWith('.d.ts')),
    outDir,
    rootDir,
    target: ts.ScriptTarget[target].toLowerCase(),
  };
}

export async function buildTestDist(root = packageRoot) {
  const inputs = testDistInputs(root);
  const startedAt = performance.now();
  await build({
    absWorkingDir: root,
    entryPoints: inputs.files,
    outdir: inputs.outDir,
    outbase: inputs.rootDir,
    bundle: false,
    format: 'esm',
    platform: 'node',
    target: inputs.target,
    sourcemap: true,
    tsconfig: inputs.configPath,
    logLevel: 'warning',
  });
  const seconds = ((performance.now() - startedAt) / 1000).toFixed(1);
  console.log(`[build-test-dist] transpiled ${inputs.files.length} files in ${seconds}s`);
}

if (process.argv[1] && pathToFileURL(resolve(process.argv[1])).href === import.meta.url) {
  await buildTestDist();
}
