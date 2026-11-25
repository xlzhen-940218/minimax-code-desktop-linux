// Refreshes the desktop-src tree from an official MiniMax Code desktop build.
//
// The tree is a development view of the shipped application: the renderer
// bundle, the main process bundles, the first party packages that the app
// loads at runtime and the runtime resources. The script copies them from an
// extracted app and rewrites the manifests, because the shipped manifests use
// workspace references and version ranges that npm cannot resolve outside the
// original monorepo.
//
// Usage:
//   node desktop/scripts/sync-desktop-src.mjs \
//     --app <extracted app directory> \
//     --resources <resources directory of the Windows payload> \
//     --target <desktop-src directory>
import {
  cpSync,
  existsSync,
  mkdirSync,
  readFileSync,
  readdirSync,
  rmSync,
  writeFileSync,
} from "node:fs";
import path from "node:path";

const FIRST_PARTY_SCOPES = ["@mavis", "@minimax", "@earendil-works"];

function parseArgs(argv) {
  const args = {};
  for (let i = 0; i < argv.length; i += 2) {
    const key = argv[i];
    const value = argv[i + 1];
    if (!key?.startsWith("--") || value === undefined) {
      throw new Error(`Invalid argument: ${key ?? ""}`);
    }
    args[key.slice(2)] = value;
  }
  return args;
}

const args = parseArgs(process.argv.slice(2));
const appDir = path.resolve(args.app ?? "");
const resourcesDir = path.resolve(args.resources ?? "");
const targetDir = path.resolve(args.target ?? "");

if (!args.app || !args.resources || !args.target) {
  console.error(
    "Usage: sync-desktop-src.mjs --app <app dir> --resources <resources dir> --target <desktop-src dir>",
  );
  process.exit(1);
}
for (const directory of [appDir, resourcesDir, targetDir]) {
  if (!existsSync(directory)) {
    console.error(`Not a directory: ${directory}`);
    process.exit(1);
  }
}

function readJson(file) {
  return JSON.parse(readFileSync(file, "utf8"));
}

function writeJson(file, value) {
  writeFileSync(file, `${JSON.stringify(value, null, 2)}\n`);
}

/** Version of a package as it is installed in the shipped bundle. */
function installedVersion(nodeModules, name) {
  const manifest = path.join(nodeModules, name, "package.json");
  if (!existsSync(manifest)) return undefined;
  try {
    return readJson(manifest).version;
  } catch {
    return undefined;
  }
}

function isFirstParty(name) {
  return FIRST_PARTY_SCOPES.some((scope) => name.startsWith(`${scope}/`));
}

function isForeignBinary(name) {
  return /-(win32|darwin)-/.test(name);
}

/**
 * Rewrites the manifest of a vendored package: workspace references become
 * file references to the other vendored packages, and version ranges become
 * the exact versions the shipped bundle uses.
 */
function rewriteVendoredManifest(file, packageDir, vendorDir, nodeModules) {
  const manifest = readJson(file);
  for (const field of ["dependencies", "devDependencies", "optionalDependencies"]) {
    const entries = manifest[field];
    if (!entries) continue;
    for (const [name, range] of Object.entries(entries)) {
      if (typeof range !== "string") continue;
      if (range.startsWith("workspace:")) {
        const target = path.join(vendorDir, name);
        if (!existsSync(target)) continue;
        let relative = path.relative(packageDir, target).split(path.sep).join("/");
        if (!relative.startsWith(".")) relative = `./${relative}`;
        entries[name] = `file:${relative}`;
        continue;
      }
      const version = installedVersion(nodeModules, name);
      if (version && /^[~^]/.test(range)) entries[name] = version;
    }
  }
  writeJson(file, manifest);
}

console.log(`Syncing ${path.basename(targetDir)} from ${appDir}`);

// The renderer bundle, the static files and the runtime resources.
for (const [from, to] of [
  [path.join(appDir, "out"), path.join(targetDir, "app", "out")],
  [path.join(appDir, "public"), path.join(targetDir, "app", "public")],
]) {
  if (!existsSync(from)) continue;
  rmSync(to, { recursive: true, force: true });
  mkdirSync(path.dirname(to), { recursive: true });
  cpSync(from, to, { recursive: true });
  console.log(`Updated ${path.relative(targetDir, to)}`);
}

const mcodeTools = path.join(resourcesDir, "mcode-tools");
if (existsSync(mcodeTools)) {
  const to = path.join(targetDir, "resources", "mcode-tools");
  rmSync(to, { recursive: true, force: true });
  mkdirSync(path.dirname(to), { recursive: true });
  cpSync(mcodeTools, to, { recursive: true });
  console.log(`Updated ${path.relative(targetDir, to)}`);
}

// The first party packages the main process loads at runtime.
const vendorDir = path.join(targetDir, "vendor");
const nodeModules = path.join(appDir, "node_modules");
for (const scope of FIRST_PARTY_SCOPES) {
  const from = path.join(nodeModules, scope);
  if (!existsSync(from)) continue;
  const to = path.join(vendorDir, scope);
  rmSync(to, { recursive: true, force: true });
  mkdirSync(path.dirname(to), { recursive: true });
  cpSync(from, to, { recursive: true });
  console.log(`Updated ${path.relative(targetDir, to)}`);
}

// Rewrite the manifests of the vendored packages.
for (const scope of FIRST_PARTY_SCOPES) {
  const scopeDir = path.join(vendorDir, scope);
  if (!existsSync(scopeDir)) continue;
  for (const entry of readdirSync(scopeDir)) {
    const packageDir = path.join(scopeDir, entry);
    const manifest = path.join(packageDir, "package.json");
    if (!existsSync(manifest)) continue;
    rewriteVendoredManifest(manifest, packageDir, vendorDir, nodeModules);
  }
}

// The application manifest. The shipped manifest uses workspace references for
// the first party packages and version ranges for everything else.
const shipped = readJson(path.join(appDir, "package.json"));
const dependencies = {};
const optionalDependencies = {};

function addDependency(name, range) {
  if (isForeignBinary(name)) {
    optionalDependencies[name] = range;
    return;
  }
  if (isFirstParty(name)) {
    if (!existsSync(path.join(vendorDir, name))) {
      // Some first party packages are compiled into the application bundle
      // instead of being shipped as a package, so there is nothing to install.
      console.log(`Skipped ${name}: it is part of the application bundle`);
      return;
    }
    dependencies[name] = `file:../vendor/${name}`;
    return;
  }
  const version = installedVersion(nodeModules, name);
  dependencies[name] = version ?? range;
}

for (const [name, range] of Object.entries(shipped.dependencies ?? {})) {
  addDependency(name, range);
}
for (const [name, range] of Object.entries(shipped.optionalDependencies ?? {})) {
  addDependency(name, range);
}

// The vendored packages depend on more of the application dependencies than
// the shipped manifest lists, because the shipped manifest only records the
// direct imports of the main process.
for (const scope of FIRST_PARTY_SCOPES) {
  const scopeDir = path.join(vendorDir, scope);
  if (!existsSync(scopeDir)) continue;
  for (const entry of readdirSync(scopeDir)) {
    const manifestPath = path.join(scopeDir, entry, "package.json");
    if (!existsSync(manifestPath)) continue;
    const manifest = readJson(manifestPath);
    for (const [name, range] of Object.entries(manifest.dependencies ?? {})) {
      if (isFirstParty(name) || dependencies[name] || optionalDependencies[name]) continue;
      if (isForeignBinary(name)) continue;
      const version = installedVersion(nodeModules, name);
      if (version) dependencies[name] = version;
    }
  }
}

const appManifest = {
  name: shipped.name,
  version: shipped.version,
  description: shipped.description,
  author: shipped.author,
  private: true,
  engines: shipped.engines,
  main: shipped.main,
  dependencies: Object.fromEntries(Object.entries(dependencies).sort(([a], [b]) => a.localeCompare(b))),
  optionalDependencies: Object.fromEntries(
    Object.entries(optionalDependencies).sort(([a], [b]) => a.localeCompare(b)),
  ),
};
writeJson(path.join(targetDir, "app", "package.json"), appManifest);
console.log(`Updated app/package.json (${Object.keys(dependencies).length} dependencies)`);

// The workspace root carries the version of the application.
const rootManifestPath = path.join(targetDir, "package.json");
const rootManifest = readJson(rootManifestPath);
rootManifest.version = shipped.version;
writeJson(rootManifestPath, rootManifest);
console.log(`Updated package.json (version ${shipped.version})`);
