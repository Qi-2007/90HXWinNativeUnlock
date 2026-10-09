"""Rename exports and expose pinned stage aliases; preserves original code/data."""
import argparse
import hashlib
import json
import struct
from pathlib import Path
from importlib.util import spec_from_file_location, module_from_spec

PINNED = 'b533b7b245ed606c151ca336b9a6bacebe935e3ec478246e879c668a4dd98a6a'
RENAME = (
    'do_permissive_with_handoff', 'ga102_booter_open_plm_with_handoff',
    'pcie_find_first_closed_plm', 'pcie_run_pre_reset_group',
    'pcie_check_post_reset_gate', 'pcie_restore_post_reset_group', 'gsp_falcon_reset',
)
ALIASES = {
    'backend_booter_target': ('nvperm_booter_execute_target_managed', 0x4540),
}


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('original', type=Path)
    p.add_argument('output', type=Path)
    a = p.parse_args()
    data = bytearray(a.original.read_bytes())
    if hashlib.sha256(data).hexdigest() != PINNED:
        raise ValueError('Only pinned 469dc0c is supported')
    shoff = struct.unpack_from('<Q', data, 40)[0]
    ss = [struct.unpack_from('<IIQQQQIIQQ', data, shoff+i*64)
          for i in range(struct.unpack_from('<H', data, 60)[0])]
    sym = next(s for s in ss if s[1] == 2)
    st = ss[sym[6]]
    table = bytearray(data[st[4]:st[4]+st[5]])
    changed = []
    entries = {}
    for off in range(sym[4], sym[4]+sym[5], 24):
        nameoff = struct.unpack_from('<I', data, off)[0]
        name = table[nameoff:table.index(0, nameoff)].decode()
        entries[name] = bytes(data[off:off+24])
        if name in RENAME:
            new = 'reference_'+name
            struct.pack_into('<I', data, off, len(table))
            table.extend(new.encode()+b'\0')
            changed.append(name)
    if sorted(changed) != sorted(RENAME):
        raise ValueError('Expected exactly seven core exports')
    symbols = bytearray(data[sym[4]:sym[4]+sym[5]])
    for alias, (name, expected) in ALIASES.items():
        entry = bytearray(entries[name])
        _, info, _, section, value, _ = struct.unpack('<IBBHQQ', entry)
        if section != 1 or value != expected or info & 15 != 2:
            raise ValueError('Pinned backend helper layout differs: '+name)
        struct.pack_into('<I', entry, 0, len(table))
        entry[4] = 0x12  # append global FUNC; original local indexes unchanged
        symbols.extend(entry)
        table.extend(alias.encode()+b'\0')
    for name, offset, size in [('firmware_plm_image',0x37ea0,0x6000),('firmware_plm_signature',0x3dea0,0x2168),
                               ('firmware_feature_image',0x41180,0x6000),('firmware_feature_signature',0x49300,0x2168),('firmware_booter_image',0x18ae0,0xec00),('firmware_booter_signatures',0x187e0,768)]:
        if offset+size > ss[5][5]:
            raise ValueError('Pinned firmware section too short')
        symbols.extend(struct.pack('<IBBHQQ',len(table),0x11,0,5,offset,size))
        table.extend(name.encode()+b'\0')
    # Point the existing string-table section at an appended replacement.
    # No symbol indexes, relocation indexes or original instruction bytes move.
    offset = len(data)
    data.extend(table)
    struct.pack_into('<QQ', data, shoff+sym[6]*64+24, offset, len(table))
    sym_offset = len(data)
    data.extend(symbols)
    sym_index = next(i for i, s in enumerate(ss) if s[1] == 2)
    struct.pack_into('<QQ', data, shoff+sym_index*64+24, sym_offset, len(symbols))
    original = a.original.read_bytes()
    for section in ss:
        if section[2] & 2 and section[1] != 8:
            start, size = section[4], section[5]
            if data[start:start+size] != original[start:start+size]:
                raise ValueError('Allocated section changed during symbol preparation')
    a.output.parent.mkdir(parents=True, exist_ok=True)
    a.output.write_bytes(data)
    a.output.with_suffix('.renames.json').write_text(json.dumps(dict(
        input_sha256=PINNED, output_sha256=hashlib.sha256(data).hexdigest(),
        renamed=changed, backend_aliases=list(ALIASES),
        mode='symbol names/aliases only; original .text/.rodata unchanged'),
        indent=2)+'\n', encoding='utf-8')


if __name__ == '__main__':
    main()
