"""Compare complete source-built host payloads with pinned static instruction stores."""
import argparse
import hashlib
import importlib.util
import struct
import subprocess
import sys
from pathlib import Path

sys.path.insert(0,str(Path(__file__).resolve().parents[1]/'.build/python-analysis'))
from capstone import Cs, CS_ARCH_X86, CS_MODE_64
from capstone.x86_const import X86_OP_MEM, X86_OP_REG, X86_OP_IMM

def main():
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('--core',type=Path,required=True)
    p.add_argument('--exe',type=Path,required=True)
    p.add_argument('--out',type=Path,required=True)
    a=p.parse_args()
    if hashlib.sha256(a.core.read_bytes()).hexdigest()!='b533b7b245ed606c151ca336b9a6bacebe935e3ec478246e879c668a4dd98a6a':
        raise ValueError('Unpinned reference')
    spec=importlib.util.spec_from_file_location('disassembly',Path(__file__).with_name('disassemble-core.py'))
    m=importlib.util.module_from_spec(spec);spec.loader.exec_module(m)
    data,sections,_=m.load(a.core)
    decoder=Cs(CS_ARCH_X86,CS_MODE_64);decoder.detail=True
    start=sections[1][4]
    ins=list(decoder.disasm(data[start+0xd227:start+0xd2ea],0xd227))
    a.out.mkdir(parents=True,exist_ok=True)
    for target in [0x8200fc,0x8e1b0,0x8e1b4,0x8e1b8,0x8e1bc,0x88fe8,0x88fec,0x88ff0,0x8e1f0]:
        expected=bytearray(b'\x9c\x01\x00\x00'*(0xfa00//4))
        rax=0;stores=0
        for i in ins:
            if i.mnemonic not in ('mov','movabs'): continue
            dest,source=i.operands
            if dest.type==X86_OP_REG and i.reg_name(dest.reg) in ('eax','rax'):
                if source.type==X86_OP_IMM: rax=source.imm
                elif source.type==X86_OP_MEM and source.mem.disp==-0x3b4: rax=target
                else: raise ValueError('Unknown payload register source')
            if dest.type==X86_OP_MEM and i.reg_name(dest.mem.base)=='rdx':
                if source.type==X86_OP_IMM: value=source.imm
                elif source.type==X86_OP_REG and i.reg_name(source.reg) in ('eax','rax'): value=rax
                else: raise ValueError('Unknown payload store')
                size=dest.size;o=dest.mem.disp
                expected[o:o+size]=(value&((1<<(size*8))-1)).to_bytes(size,'little');stores+=1
        if stores!=16: raise ValueError('Pinned payload store count differs: '+str(stores))
        path=a.out/f'payload-{target:x}.bin'
        subprocess.run([str(a.exe.resolve()),hex(target),str(path.resolve())],check=True)
        actual=path.read_bytes()
        if actual!=expected:
            mismatch=next((i for i,(x,y) in enumerate(zip(actual,expected)) if x!=y),None)
            raise ValueError(f'Payload differs for {target:x} at {mismatch}; size={len(actual)}')
    print('REBUILT_PLM_PAYLOAD_DIFFERENTIAL_PASSED: nine complete 64000-byte source payloads match pinned instruction stores byte-for-byte; static firmware evidence only.')

if __name__=='__main__': main()
