// Audits the shared libraries the packaged application needs against the
// dependencies declared in the Debian control file.
//
// A missing dependency only shows up on a machine that does not have the
// library installed, which is exactly where a repackaged desktop client has
// to work. The audit reads the ELF headers of every binary in the package, so
// it also works for a package that was cross built on another host.
import { readFileSync, readdirSync, statSync } from "node:fs";
import path from "node:path";
import { readElf } from "./lib/elf.mjs";

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

// Shared library to Debian package. A package name can list alternatives, the
// way the Debian archive renamed several libraries for the 64 bit time_t
// transition in Ubuntu 24.04.
const SONAME_PACKAGES = {
  "ld-linux-aarch64.so.1": ["libc6"],
  "ld-linux-x86-64.so.2": ["libc6"],
  "libc.so.6": ["libc6"],
  "libm.so.6": ["libc6"],
  "libdl.so.2": ["libc6"],
  "libpthread.so.0": ["libc6"],
  "librt.so.1": ["libc6"],
  "libresolv.so.2": ["libc6"],
  "libgcc_s.so.1": ["libgcc-s1"],
  "libstdc++.so.6": ["libstdc++6"],
  "libatomic.so.1": ["libatomic1"],
  "libffi.so.8": ["libffi8"],
  "libz.so.1": ["zlib1g"],
  "libexpat.so.1": ["libexpat1"],
  "libuuid.so.1": ["libuuid1"],
  "libpcre2-8.so.0": ["libpcre2-8-0"],
  "libbrotlidec.so.1": ["libbrotli1"],
  "libbrotlicommon.so.1": ["libbrotli1"],
  "libbrotlienc.so.1": ["libbrotli1"],
  "libpng16.so.16": ["libpng16-16"],
  "libfreetype.so.6": ["libfreetype6"],
  "libfontconfig.so.1": ["libfontconfig1"],
  "libselinux.so.1": ["libselinux1"],
  "libcap.so.2": ["libcap2"],
  "libgcrypt.so.20": ["libgcrypt20"],
  "libsystemd.so.0": ["libsystemd0"],
  "liblzma.so.5": ["liblzma5"],
  "libzstd.so.1": ["libzstd1"],
  "libgpg-error.so.0": ["libgpg-error0"],
  "libglib-2.0.so.0": ["libglib2.0-0"],
  "libgobject-2.0.so.0": ["libglib2.0-0"],
  "libgio-2.0.so.0": ["libglib2.0-0"],
  "libgmodule-2.0.so.0": ["libglib2.0-0"],
  "libgthread-2.0.so.0": ["libglib2.0-0"],
  "libnspr4.so": ["libnspr4"],
  "libplc4.so": ["libnspr4"],
  "libplds4.so": ["libnspr4"],
  "libnss3.so": ["libnss3"],
  "libnssutil3.so": ["libnss3"],
  "libsmime3.so": ["libnss3"],
  "libssl3.so": ["libnss3"],
  "libatk-1.0.so.0": ["libatk1.0-0"],
  "libatk-bridge-2.0.so.0": ["libatk-bridge2.0-0", "libatk-bridge2.0-0t64"],
  "libatspi.so.0": ["libatspi2.0-0"],
  "libcups.so.2": ["libcups2", "libcups2t64"],
  "libdbus-1.so.3": ["libdbus-1-3"],
  "libcairo.so.2": ["libcairo2"],
  "libcairo-gobject.so.2": ["libcairo2"],
  "libpango-1.0.so.0": ["libpango-1.0-0", "libpango-1.0-0t64"],
  "libpangocairo-1.0.so.0": ["libpango-1.0-0", "libpango-1.0-0t64"],
  "libpangoft2-1.0.so.0": ["libpango-1.0-0", "libpango-1.0-0t64"],
  "libharfbuzz.so.0": ["libharfbuzz0b", "libharfbuzz0bld64"],
  "libgtk-3.so.0": ["libgtk-3-0", "libgtk-3-0t64"],
  "libgdk-3.so.0": ["libgtk-3-0", "libgtk-3-0t64"],
  "libX11.so.6": ["libx11-6"],
  "libX11-xcb.so.1": ["libx11-xcb1"],
  "libXcomposite.so.1": ["libxcomposite1"],
  "libXdamage.so.1": ["libxdamage1"],
  "libXext.so.6": ["libxext6"],
  "libXfixes.so.3": ["libxfixes3"],
  "libXrandr.so.2": ["libxrandr2"],
  "libXrender.so.1": ["libxrender1"],
  "libXi.so.6": ["libxi6"],
  "libXtst.so.6": ["libxtst6"],
  "libXss.so.1": ["libxss1"],
  "libXxf86vm.so.1": ["libxxf86vm1"],
  "libxcb.so.1": ["libxcb1"],
  "libxcb-dri3.so.0": ["libxcb-dri3-0"],
  "libxcb-glx.so.0": ["libxcb-glx0"],
  "libxcb-present.so.0": ["libxcb-present0"],
  "libxcb-randr.so.0": ["libxcb-randr0"],
  "libxcb-shm.so.0": ["libxcb-shm0"],
  "libxcb-sync.so.1": ["libxcb-sync1"],
  "libxcb-xfixes.so.0": ["libxcb-xfixes0"],
  "libxcb-shape.so.0": ["libxcb-shape0"],
  "libxcb-xkb.so.1": ["libxcb-xkb1"],
  "libxkbcommon.so.0": ["libxkbcommon0"],
  "libxkbcommon-x11.so.0": ["libxkbcommon-x11-0"],
  "libgbm.so.1": ["libgbm1"],
  "libdrm.so.2": ["libdrm2"],
  "libudev.so.1": ["libudev1"],
  "libasound.so.2": ["libasound2", "libasound2t64"],
  "libnotify.so.4": ["libnotify4"],
  "libsecret-1.so.0": ["libsecret-1-0"],
  "libvulkan.so.1": ["libvulkan1"],
  "libwayland-client.so.0": ["libwayland-client0"],
  "libwayland-server.so.0": ["libwayland-server0"],
  "libwayland-egl.so.1": ["libwayland-egl1"],
  "libwayland-cursor.so.0": ["libwayland-cursor0"],
  "libGL.so.1": ["libgl1"],
  "libGLX.so.0": ["libglx0"],
  "libEGL.so.1": ["libegl1"],
  "libGLESv2.so.2": ["libgles2"],
};

const args = parseArgs(process.argv.slice(2));
const packageDir = path.resolve(args.pkg ?? "");
const controlFile = path.resolve(args.control ?? "");

if (!args.pkg || !args.control) {
  console.error("Usage: check-package-deps.mjs --pkg <package dir> --control <control file>");
  process.exit(1);
}

function collectElfFiles(directory, out = []) {
  for (const entry of readdirSync(directory, { withFileTypes: true })) {
    const full = path.join(directory, entry.name);
    if (entry.isDirectory()) {
      collectElfFiles(full, out);
    } else if (entry.isFile()) {
      out.push(full);
    }
  }
  return out;
}

function declaredPackages(control) {
  // The control file folds a long field over several lines.
  const lines = control.split("\n").reduce((folded, line) => {
    if (/^[ \t]/.test(line) && folded.length > 0) {
      folded[folded.length - 1] += ` ${line.trim()}`;
    } else {
      folded.push(line);
    }
    return folded;
  }, []);
  const depends = lines.find((line) => line.startsWith("Depends:"));
  if (!depends) return new Set();
  const names = new Set();
  for (const clause of depends.slice("Depends:".length).split(",")) {
    for (const alternative of clause.split("|")) {
      const name = alternative.trim().split(/[\s(]/)[0];
      if (name) names.add(name);
    }
  }
  return names;
}

const control = readFileSync(controlFile, "utf8");
const declared = declaredPackages(control);
const sonames = new Map();
const files = collectElfFiles(packageDir);

for (const file of files) {
  const elf = readElf(file);
  if (!elf) continue;
  for (const library of elf.needed) {
    if (!sonames.has(library)) sonames.set(library, file);
  }
}

const missing = [];
const unmapped = [];
for (const [library, file] of sonames) {
  const packages = SONAME_PACKAGES[library];
  if (!packages) {
    unmapped.push(`${library} (${path.relative(packageDir, file)})`);
    continue;
  }
  if (!packages.some((name) => declared.has(name))) {
    missing.push(`${library} needs ${packages.join(" or ")}`);
  }
}

console.log(
  `Audited ${files.length} file(s) in the package; ${sonames.size} distinct shared librar${sonames.size === 1 ? "y" : "ies"}.`,
);

if (unmapped.length > 0) {
  console.log("Libraries without a Debian package mapping:");
  for (const entry of unmapped) console.log(`  ${entry}`);
}

if (missing.length > 0) {
  console.error("Shared libraries that the control file does not cover:");
  for (const entry of missing) console.error(`  ${entry}`);
  process.exit(1);
}

console.log("Every shared library is covered by the declared dependencies.");
