"""Static symbol/relocation-aware disassembly of an ELF core; never executes it."""
import argparse
import re
import struct
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / '.build/python-analysis'))


def load(path):
    b = path.read_bytes()
    if b[:7] != b'\x7fELF\x02\x01\x01' or struct.unpack_from('<HH', b, 16) != (1, 62):
        raise ValueError('Not an AMD64 relocatable ELF')
    sh = struct.unpack_from('<Q', b, 40)[0]
    ss = [struct.unpack_from('<IIQQQQIIQQ', b, sh + i*64)
          for i in range(struct.unpack_from('<H', b, 60)[0])]
    sym = next(s for s in ss if s[1] == 2)
    st = ss[sym[6]]
    names = b[st[4]:st[4]+st[5]]
    sy = []
    for o in range(sym[4], sym[4]+sym[5], 24):
        n, info, _, sec, value, size = struct.unpack_from('<IBBHQQ', b, o)
        sy.append((names[n:names.index(b'\0', n)].decode(), info, sec, value, size))
    return b, ss, sy


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('core', type=Path)
    p.add_argument('--symbol', default='.*')
    p.add_argument('--list', action='store_true')
    p.add_argument('--out', type=Path)
    p.add_argument('--range', dest='code_range', help='Hex .text START:END')
    a = p.parse_args()
    b, ss, sy = load(a.core)
    if a.code_range:
        start, end = [int(n, 16) for n in a.code_range.split(':')]
        if not 0 <= start < end <= ss[1][5]:
            raise ValueError('Invalid .text range')
        sy.append(('STATIC_RANGE', 2, 1, start, end-start))
        a.symbol = '^STATIC_RANGE$'
    lines = []
    if not a.list:
        from capstone import Cs, CS_ARCH_X86, CS_MODE_64
        decoder = Cs(CS_ARCH_X86, CS_MODE_64)
    rels = {}
    for s in ss:
        if s[1] == 4:
            for o in range(s[4], s[4]+s[5], 24):
                target, info, addend = struct.unpack_from('<QQq', b, o)
                sym = sy[info >> 32]
                description = sym[0]
                if not description and sym[2] and ss[sym[2]][1] != 8:
                    description = f'section{sym[2]}'
                    offset = ss[sym[2]][4]+sym[3]+addend
                    if 0 <= offset < len(b):
                        text = b[offset:offset+200].split(b'\0')[0]
                        if text and all(c in (9, 10, 13) or 32 <= c < 127 for c in text):
                            description += ' '+repr(text.decode())
                rels[s[7], target] = (description, addend, info & 0xffffffff)
    for name, info, sec, value, size in sy:
        if not name or not re.search(a.symbol, name):
            continue
        lines.append(f'{name} section={sec} offset={value:#x} size={size} info={info}')
        if a.list or not sec:
            continue
        s = ss[sec]
        data = b[s[4]+value:s[4]+value+size]
        if info & 15 != 2:
            lines.append(data[:256].hex(' '))
            continue
        for ins in decoder.disasm(data, value):
            refs = [f'{name}{addend:+#x} (reloc {kind})'
                    for (section, target), (name, addend, kind) in rels.items()
                    if section == sec and ins.address <= target < ins.address + ins.size]
            lines.append(f'{ins.address:08x}: {ins.mnemonic:8s} {ins.op_str:48s} {"; ".join(refs)}')
    text = '\n'.join(lines)+'\n'
    if a.out:
        a.out.parent.mkdir(parents=True, exist_ok=True)
        a.out.write_text(text, encoding='utf-8')
    else:
        print(text)


if __name__ == '__main__':
    main()
