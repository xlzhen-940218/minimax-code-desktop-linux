// Minimal ELF reader. It only extracts what the packaging checks need: the
// machine architecture, the needed shared libraries and the symbol version
// requirements. Reading the headers directly keeps the checks independent of
// the host architecture, so they also work for a cross built package.
import { readFileSync } from "node:fs";

export const ELF_MACHINE = {
  0x3e: { name: "x86-64", arch: "x64" },
  0xb7: { name: "aarch64", arch: "arm64" },
};

export function compareVersions(left, right) {
  const a = left.split(".").map(Number);
  const b = right.split(".").map(Number);
  for (let i = 0; i < Math.max(a.length, b.length); i += 1) {
    const diff = (a[i] ?? 0) - (b[i] ?? 0);
    if (diff !== 0) return diff;
  }
  return 0;
}

function readCString(table, offset) {
  let end = offset;
  while (end < table.length && table[end] !== 0) end += 1;
  return table.toString("utf8", offset, end);
}

/**
 * @returns {undefined | {machine: number, needed: string[], versions: string[]}}
 *   undefined when the file is not a 64 bit little endian ELF file.
 */
export function readElf(file) {
  const buffer = readFileSync(file);
  if (buffer.length < 64 || buffer.readUInt32BE(0) !== 0x7f454c46) return undefined;
  if (buffer[4] !== 2 || buffer[5] !== 1) return undefined;

  const machine = buffer.readUInt16LE(18);
  const sectionHeaderOffset = Number(buffer.readBigUInt64LE(40));
  const sectionHeaderEntrySize = buffer.readUInt16LE(58);
  const sectionHeaderCount = buffer.readUInt16LE(60);

  const sections = [];
  for (let i = 0; i < sectionHeaderCount; i += 1) {
    const offset = sectionHeaderOffset + i * sectionHeaderEntrySize;
    if (offset + 64 > buffer.length) break;
    sections.push({
      type: buffer.readUInt32LE(offset + 4),
      offset: Number(buffer.readBigUInt64LE(offset + 24)),
      size: Number(buffer.readBigUInt64LE(offset + 32)),
      link: buffer.readUInt32LE(offset + 40),
    });
  }

  const dynamic = sections.find((section) => section.type === 6); // SHT_DYNAMIC
  const dynstr = sections.find((section) => section.type === 3); // SHT_STRTAB
  const needed = [];
  if (dynamic && dynstr && dynamic.offset + dynamic.size <= buffer.length) {
    const strtab = buffer.subarray(dynstr.offset, dynstr.offset + dynstr.size);
    for (let offset = dynamic.offset; offset + 16 <= dynamic.offset + dynamic.size; offset += 16) {
      const tag = Number(buffer.readBigInt64LE(offset));
      const value = Number(buffer.readBigInt64LE(offset + 8));
      if (tag === 0) break;
      if (tag === 1 && value >= 0 && value < strtab.length) {
        const name = readCString(strtab, value);
        if (name) needed.push(name);
      }
    }
  }

  // SHT_GNU_VERNEED lists the symbol versions a file requires, for example
  // GLIBC_2.34 for the C library and GLIBCXX_3.4.29 for the C++ runtime.
  const versionNeed = sections.find((section) => section.type === 0x6ffffffe);
  const versions = [];
  if (versionNeed) {
    const strtabSection = sections[versionNeed.link];
    if (strtabSection) {
      const strtab = buffer.subarray(strtabSection.offset, strtabSection.offset + strtabSection.size);
      // Elf64_Verneed: vn_version, vn_cnt, vn_file, vn_aux, vn_next.
      let offset = versionNeed.offset;
      while (offset + 16 <= versionNeed.offset + versionNeed.size) {
        const vnAux = buffer.readUInt32LE(offset + 8);
        const vnNext = buffer.readUInt32LE(offset + 12);
        // Elf64_Vernaux: vna_hash, vna_flags, vna_other, vna_name, vna_next.
        let auxOffset = offset + vnAux;
        while (auxOffset + 16 <= versionNeed.offset + versionNeed.size) {
          const vnaName = buffer.readUInt32LE(auxOffset + 8);
          const vnaNext = buffer.readUInt32LE(auxOffset + 12);
          versions.push(readCString(strtab, vnaName));
          if (vnaNext === 0) break;
          auxOffset += vnaNext;
        }
        if (vnNext === 0) break;
        offset += vnNext;
      }
    }
  }

  return { machine, needed, versions };
}
