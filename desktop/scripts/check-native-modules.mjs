// Verifies the native modules that were compiled for the target architecture.
//
// The build can run on a host of a different architecture, so a module that was
// built for the wrong target only shows up as a crash at runtime. The script
// reads the ELF headers directly, without executing anything, and reports the
// architecture and the highest C library version each module needs.
import { readdirSync, statSync } from "node:fs";
import path from "node:path";
import { ELF_MACHINE, compareVersions, readElf } from "./lib/elf.mjs";

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
const arch = args.arch;
const maxGlibc = args["max-glibc"] ?? "2.34";

if (!arch) {
  console.error("Usage: check-native-modules.mjs --app <app dir> --arch <arm64|x64> [--max-glibc <version>]");
  process.exit(1);
}

function collect(directory, out = []) {
  for (const entry of readdirSync(directory, { withFileTypes: true })) {
    const full = path.join(directory, entry.name);
    if (entry.isDirectory()) {
      collect(full, out);
    } else if (entry.isFile() && entry.name.endsWith(".node")) {
      out.push(full);
    }
  }
  return out;
}

let stat;
try {
  stat = statSync(appDir);
} catch {
  stat = undefined;
}
if (!stat?.isDirectory()) {
  console.error(`Not a directory: ${appDir}`);
  process.exit(1);
}

const modules = collect(appDir);
const problems = [];
let highest = "0";
let checked = 0;

for (const file of modules) {
  const elf = readElf(file);
  if (!elf) continue; // Not an ELF file, for example a Windows or macOS module.
  const machine = ELF_MACHINE[elf.machine];
  if (!machine) continue;
  checked += 1;

  if (machine.arch !== arch) {
    problems.push(`${file}: built for ${machine.name}, expected ${arch}`);
  }

  for (const version of elf.versions) {
    if (!version.startsWith("GLIBC_")) continue;
    const number = version.slice("GLIBC_".length);
    if (compareVersions(number, highest) > 0) highest = number;
    if (compareVersions(number, maxGlibc) > 0) {
      problems.push(`${file}: needs GLIBC_${number}, above the ${maxGlibc} baseline`);
    }
  }
}

console.log(`Checked ${checked} Linux native module(s); highest C library requirement GLIBC_${highest}.`);

if (problems.length > 0) {
  console.error("Native module check failed:");
  for (const problem of problems) console.error(`  ${problem}`);
  process.exit(1);
}
