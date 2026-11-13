#!/usr/bin/env node
// Will the phone's modules load on a new kernel? Compares the symbol CRCs each
// module recorded at build time (__versions, or __version_ext_crcs/_names)
// with the CRCs the new kernel exports (vmlinux.symvers). The running kernel
// loads every module in loaded.txt, so a module's recorded CRCs are the
// running kernel's; any difference means "disagrees about version of symbol"
// and that module will not load on the new kernel.
//
//   check-module-crcs.mts <vmlinux.symvers> <loaded.txt> <ko-dir>...
//
// loaded.txt: module names, one per line (cut -d' ' -f1 /proc/modules).
// Exit 0: no loaded module imports a vmlinux symbol whose CRC changed.
// Exit 1: at least one does (listed). Exit 2: usage or input error.
import { readFileSync, readdirSync, statSync } from "node:fs";
import { join } from "node:path";

type Section = { name: string; offset: number; size: number; link: number };
type Module = { file: string; name: string; imports: Map<string, number>; exports: string[] };

function sections(buf: Buffer): Section[] {
  if (buf.readUInt32BE(0) !== 0x7f454c46 || buf[4] !== 2 || buf[5] !== 1) {
    throw new Error("not a little-endian ELF64 file");
  }
  const shoff = Number(buf.readBigUInt64LE(0x28));
  const shentsize = buf.readUInt16LE(0x3a);
  const shnum = buf.readUInt16LE(0x3c);
  const shstrndx = buf.readUInt16LE(0x3e);
  const raw = [];
  for (let i = 0; i < shnum; i++) {
    const at = shoff + i * shentsize;
    raw.push({
      nameOff: buf.readUInt32LE(at),
      offset: Number(buf.readBigUInt64LE(at + 24)),
      size: Number(buf.readBigUInt64LE(at + 32)),
      link: buf.readUInt32LE(at + 40),
    });
  }
  const strtab = raw[shstrndx];
  return raw.map((s) => ({
    name: cstr(buf, strtab.offset + s.nameOff),
    offset: s.offset,
    size: s.size,
    link: s.link,
  }));
}

function cstr(buf: Buffer, at: number): string {
  const end = buf.indexOf(0, at);
  return buf.toString("latin1", at, end < 0 ? buf.length : end);
}

function parseModule(file: string): Module {
  const buf = readFileSync(file);
  const secs = sections(buf);
  const byName = new Map(secs.map((s) => [s.name, s]));
  const imports = new Map<string, number>();

  const versions = byName.get("__versions");
  if (versions) {
    // struct modversion_info { unsigned long crc; char name[56]; }
    for (let at = versions.offset; at + 64 <= versions.offset + versions.size; at += 64) {
      imports.set(cstr(buf, at + 8), Number(buf.readBigUInt64LE(at) & 0xffffffffn));
    }
  }
  const extCrcs = byName.get("__version_ext_crcs");
  const extNames = byName.get("__version_ext_names");
  if (extCrcs && extNames) {
    const names = buf
      .toString("latin1", extNames.offset, extNames.offset + extNames.size)
      .split("\0")
      .filter((n) => n.length > 0);
    names.forEach((n, i) => imports.set(n, buf.readUInt32LE(extCrcs.offset + i * 4)));
  }

  let name = "";
  const modinfo = byName.get(".modinfo");
  if (modinfo) {
    for (const kv of buf.toString("latin1", modinfo.offset, modinfo.offset + modinfo.size).split("\0")) {
      if (kv.startsWith("name=")) name = kv.slice(5);
    }
  }
  if (!name) name = file.replace(/^.*\//, "").replace(/\.ko$/, "").replace(/-/g, "_");

  const exports: string[] = [];
  const symtab = byName.get(".symtab");
  if (symtab) {
    const strtab = secs[symtab.link];
    for (let at = symtab.offset; at + 24 <= symtab.offset + symtab.size; at += 24) {
      const sym = cstr(buf, strtab.offset + buf.readUInt32LE(at));
      if (sym.startsWith("__ksymtab_")) exports.push(sym.slice("__ksymtab_".length));
    }
  }
  return { file, name, imports, exports };
}

function koFiles(dir: string): string[] {
  const out: string[] = [];
  for (const entry of readdirSync(dir)) {
    const p = join(dir, entry);
    if (statSync(p).isDirectory()) out.push(...koFiles(p));
    else if (entry.endsWith(".ko")) out.push(p);
  }
  return out;
}

function readLoaded(path: string): Set<string> {
  return new Set(
    readFileSync(path, "utf8").split("\n").map((l) => l.trim()).filter((l) => l.length > 0),
  );
}

// --derive: print the running kernel's CRCs as the loaded modules recorded
// them, in vmlinux.symvers form. Loaded modules that disagree about a symbol
// go to stderr (and exit 1): the parse is wrong or a module did not load.
if (process.argv[2] === "--derive") {
  const [loadedPath, ...dirs] = process.argv.slice(3);
  if (!loadedPath || dirs.length === 0) {
    console.error("usage: check-module-crcs.mts --derive <loaded.txt> <ko-dir>...");
    process.exit(2);
  }
  const loaded = readLoaded(loadedPath);
  const modules = dirs.flatMap(koFiles).map(parseModule).filter((m) => loaded.has(m.name));
  const moduleExports = new Set(modules.flatMap((m) => m.exports));
  const crcs = new Map<string, { crc: number; from: string }>();
  let conflicts = 0;
  for (const m of modules) {
    for (const [sym, crc] of m.imports) {
      if (moduleExports.has(sym)) continue;
      const seen = crcs.get(sym);
      if (!seen) crcs.set(sym, { crc, from: m.name });
      else if (seen.crc !== crc) {
        conflicts++;
        console.error(`conflict ${sym}: ${seen.from}=0x${seen.crc.toString(16)} ${m.name}=0x${crc.toString(16)}`);
      }
    }
  }
  for (const [sym, { crc }] of crcs) {
    console.log(`0x${crc.toString(16).padStart(8, "0")}\t${sym}\tvmlinux\tEXPORT_SYMBOL\t`);
  }
  console.error(`derived ${crcs.size} kernel symbol CRCs from ${modules.length} loaded module files; conflicts: ${conflicts}`);
  process.exit(conflicts === 0 ? 0 : 1);
}

const [symversPath, loadedPath, ...dirs] = process.argv.slice(2);
if (!symversPath || !loadedPath || dirs.length === 0) {
  console.error("usage: check-module-crcs.mts <vmlinux.symvers> <loaded.txt> <ko-dir>...");
  console.error("       check-module-crcs.mts --derive <loaded.txt> <ko-dir>...");
  process.exit(2);
}

const kernel = new Map<string, number>();
for (const line of readFileSync(symversPath, "utf8").split("\n")) {
  const [crc, sym] = line.split("\t");
  if (crc && sym) kernel.set(sym, Number.parseInt(crc, 16) >>> 0);
}
if (kernel.size === 0) {
  console.error(`no symbols read from ${symversPath}`);
  process.exit(2);
}

const loaded = readLoaded(loadedPath);
const modules = dirs.flatMap(koFiles).map(parseModule);
const moduleExports = new Set(modules.flatMap((m) => m.exports));
const found = new Set(modules.map((m) => m.name));

let broken = 0;
let checked = 0;
let compared = 0;
const unresolved = new Map<string, string[]>();
const notLoadedBroken: string[] = [];
for (const m of modules) {
  const bad: string[] = [];
  for (const [sym, crc] of m.imports) {
    const want = kernel.get(sym);
    if (want === undefined) {
      if (!moduleExports.has(sym)) unresolved.set(sym, [...(unresolved.get(sym) ?? []), m.name]);
      continue;
    }
    compared++;
    if (want !== crc) {
      bad.push(`${sym} module=0x${crc.toString(16).padStart(8, "0")} kernel=0x${want.toString(16).padStart(8, "0")}`);
    }
  }
  if (loaded.has(m.name)) checked++;
  if (bad.length === 0) continue;
  if (loaded.has(m.name)) {
    broken++;
    console.log(`BROKEN (loaded now) ${m.name}  ${m.file}`);
    for (const b of bad) console.log(`    ${b}`);
  } else {
    notLoadedBroken.push(`${m.name} (${bad.length} symbols)`);
  }
}

const missing = [...loaded].filter((n) => !found.has(n));
console.log(`\nkernel symbols: ${kernel.size}; module files: ${modules.length}; CRCs compared: ${compared}`);
console.log(`loaded modules: ${loaded.size}; with a .ko here: ${loaded.size - missing.length}`);
if (missing.length > 0) console.log(`loaded but no .ko found (not checked): ${missing.join(" ")}`);
if (notLoadedBroken.length > 0) {
  console.log(`CRC mismatches in modules not loaded now (were they ever?): ${notLoadedBroken.join(", ")}`);
}
if (unresolved.size > 0) {
  console.log(`imports found in neither the kernel nor any module: ${unresolved.size}`);
  for (const [sym, who] of [...unresolved].slice(0, 20)) console.log(`    ${sym}  <- ${who.slice(0, 3).join(" ")}`);
}
console.log(broken === 0 ? `\nPASS: no loaded module would fail its CRC check` : `\nFAIL: ${broken} loaded modules would not load`);
process.exit(broken === 0 ? 0 : 1);
