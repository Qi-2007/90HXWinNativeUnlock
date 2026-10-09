"""Read ELF objects without loading/executing them; compare the Windows core ABI."""
import argparse
import hashlib
import json
import struct
from pathlib import Path

REQUIRED = (
    "do_permissive_with_handoff", "ga102_booter_open_plm_with_handoff",
    "pcie_find_first_closed_plm", "pcie_run_pre_reset_group",
    "pcie_check_post_reset_gate", "pcie_restore_post_reset_group", "gsp_falcon_reset",
)
IMPORTS = {"ioread32", "iowrite32", "memcpy", "memcpy_toio", "memset"}
RELOCATIONS = {1, 2, 4, 11}
PINNED_HASH = "b533b7b245ed606c151ca336b9a6bacebe935e3ec478246e879c668a4dd98a6a"


def inspect(path):
    data = path.read_bytes()
    def unpack(fmt, offset):
        return struct.unpack_from(fmt, data, offset)
    def region(offset, size):
        if offset < 0 or size < 0 or offset + size > len(data):
            raise ValueError("ELF region outside file")
        return data[offset:offset + size]
    if region(0, 7) != b"\x7fELF\x02\x01\x01" or unpack("<HH", 16) != (1, 62):
        raise ValueError("Expected little-endian AMD64 ET_REL ELF")
    shoff = unpack("<Q", 40)[0]
    entsize, count, strindex = unpack("<HHH", 58)
    if entsize != 64 or not 0 < count < 4096 or strindex >= count:
        raise ValueError("Unsupported ELF section layout")
    region(shoff, count * 64)
    sections = [unpack("<IIQQQQIIQQ", shoff + i * 64) for i in range(count)]
    names = region(sections[strindex][4], sections[strindex][5])
    def string(table, offset):
        return table[offset:table.index(b"\0", offset)].decode("utf-8", errors="replace")
    symbols = []
    relocations = {}
    allocated_relocations = {}
    for section in sections:
        if section[1] != 8:
            region(section[4], section[5])
        if section[1] == 2:
            if section[9] != 24 or section[6] >= count or section[5] % 24:
                raise ValueError("Invalid symbol table")
            st = sections[section[6]]
            strings = region(st[4], st[5])
            for offset in range(section[4], section[4] + section[5], 24):
                name, info, _, index, value, size = unpack("<IBBHQQ", offset)
                if name:
                    symbols.append(dict(name=string(strings, name), binding=info >> 4,
                                        type=info & 15, section=index, value=value, size=size))
        if section[1] == 4:
            if section[9] != 24 or section[7] >= count or section[5] % 24:
                raise ValueError("Invalid relocation table")
            for offset in range(section[4], section[4] + section[5], 24):
                kind = unpack("<Q", offset + 8)[0] & 0xffffffff
                relocations[kind] = relocations.get(kind, 0) + 1
                if sections[section[7]][2] & 2:
                    allocated_relocations[kind] = allocated_relocations.get(kind, 0) + 1
    exports = sorted({s["name"] for s in symbols if s["section"] and s["binding"] in (1, 2)})
    imports = sorted({s["name"] for s in symbols if not s["section"]})
    missing = sorted(set(REQUIRED) - set(exports))
    unknown = sorted(set(imports) - IMPORTS)
    unsupported = sorted(set(relocations) - RELOCATIONS)
    unallocated_targets = [string(names, s[0]) for s in sections
                           if s[1] == 4 and not sections[s[7]][2] & 2]
    digest = hashlib.sha256(data).hexdigest()
    return dict(path=str(path.resolve()), bytes=len(data), sha256=digest,
                format="ELF64 AMD64 ET_REL", section_count=count,
                exports=exports, imports=imports, missing_required_exports=missing,
                unsupported_imports=unknown, relocations=relocations,
                allocated_relocations=allocated_relocations,
                unsupported_relocations=unsupported,
                relocation_sections_targeting_unallocated_sections=unallocated_targets,
                pinned_managed_hash_matches=digest == PINNED_HASH,
                current_loader_accepts=digest == PINNED_HASH and not (
                    missing or unknown or unsupported or unallocated_targets),
                note="Static checks only; no ABI semantics or hardware unlock verification.")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("objects", nargs="+", type=Path)
    parser.add_argument("--out", type=Path)
    args = parser.parse_args()
    report = [inspect(path) for path in args.objects]
    text = json.dumps(report, ensure_ascii=False, indent=2) + "\n"
    if args.out:
        args.out.parent.mkdir(parents=True, exist_ok=True)
        args.out.write_text(text, encoding="utf-8")
    for item in report:
        print(f'{item["path"]}: {item["bytes"]} bytes; '
              f'missing exports={len(item["missing_required_exports"])}; '
              f'unsupported imports={len(item["unsupported_imports"])}; '
              f'loader accepts={item["current_loader_accepts"]}')
    if not args.out:
        print(text)


if __name__ == "__main__":
    main()
