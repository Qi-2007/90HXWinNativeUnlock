"""Extract and document the user-supplied EFI's pinned Quadro RMW; never execute it."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import struct
import subprocess
import sys

EFI_SHA256 = '2bf6c06346ccdbdb0deba7ff6e0d423c08991b5f20b588302d0563c158c538e3'

def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('efi', type=Path)
    p.add_argument('--out', type=Path, required=True)
    p.add_argument('--capstone-path', type=Path)
    a = p.parse_args()
    b = a.efi.read_bytes()
    if hashlib.sha256(b).hexdigest() != EFI_SHA256:
        raise ValueError('EFI hash differs; these evidence ranges apply only to the supplied 202610150835 build')
    pe = struct.unpack_from('<I', b, 60)[0]
    n = struct.unpack_from('<H', b, pe+6)[0]
    size = struct.unpack_from('<H', b, pe+20)[0]
    sections = [struct.unpack_from('<8sIIII', b, pe+24+size+i*40) for i in range(n)]
    sec = next(s for s in sections if s[0].rstrip(b'\0') == b'.core')
    core = b[sec[4]:sec[4]+sec[1]]
    if core[:7] != b'\x7fELF\x02\x01\x01':
        raise ValueError('Embedded .core is not AMD64 ELF')
    sh = struct.unpack_from('<Q', core, 40)[0]
    text = struct.unpack_from('<IIQQQQIIQQ', core, sh+64)
    code = core[text[4]:text[4]+text[5]]
    # The complete RMW instruction sequence, including preserved bits and write.
    rmw = bytes.fromhex('4181e544f46ffc4181cd88089003488db0083882004489efe8')
    if code[0x11c00:0x11c00+len(rmw)] != rmw:
        raise ValueError('Pinned Quadro RMW instructions differ')
    a.out.mkdir(parents=True, exist_ok=True)
    obj = a.out/'core-4c32b72.o'
    obj.write_bytes(core)
    report = dict(efi_sha256=EFI_SHA256, embedded_core_sha256=hashlib.sha256(core).hexdigest(),
                  core_pe_file_offset=sec[4], source_register='0x823808', feat_plm='0x823804',
                  mask='0x03900bbb', target='0x03900888',
                  operation='(old & ~0x03900bbb) | 0x03900888',
                  source_verify_text='0x11b10', rmw_text='0x11bc0',
                  rmw_instruction_text='0x11c00', readout_diagnostic='0x823814',
                  baseline='0x00100283 -> 0x03900888', hardware_validated=False)
    (a.out/'evidence.json').write_text(json.dumps(report, indent=2)+'\n', encoding='utf-8')
    if a.capstone_path:
        env = dict(os.environ, PYTHONPATH=str(a.capstone_path.resolve()))
        disasm = Path(__file__).with_name('disassemble-core.py')
        for label, region in [('quadro', '11750:11c90'), ('flow', '12000:15000')]:
            subprocess.run([sys.executable, str(disasm), str(obj), '--range', region,
                            '--out', str(a.out/(label+'.txt'))], env=env, check=True)
    print(json.dumps(report, indent=2))

if __name__ == '__main__':
    main()
