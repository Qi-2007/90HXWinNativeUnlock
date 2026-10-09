"""Extract pinned GPU data assets and build a non-executable ELF data object."""
import argparse
import hashlib
import json
import struct
from pathlib import Path

PINNED = 'b533b7b245ed606c151ca336b9a6bacebe935e3ec478246e879c668a4dd98a6a'
ASSETS = [('firmware_plm_image',0x37ea0,0x6000),('firmware_plm_signature',0x3dea0,0x2168),
          ('firmware_feature_image',0x41180,0x6000),('firmware_feature_signature',0x49300,0x2168),
          ('firmware_booter_image',0x18ae0,0xec00),('firmware_booter_signatures',0x187e0,768)]

EXPECTED_HASHES = {'firmware_plm_image': '3df651acb174fd5f5561a1996965b192f50c5d763168446ed0d4ead19d895768', 'firmware_plm_signature': '966512cef7f9ce3f4052b1bf33df7b509c97c405fdcf264df4ea2b1366c37372', 'firmware_feature_image': '3df651acb174fd5f5561a1996965b192f50c5d763168446ed0d4ead19d895768', 'firmware_feature_signature': '966512cef7f9ce3f4052b1bf33df7b509c97c405fdcf264df4ea2b1366c37372', 'firmware_booter_image': '6803188fef6bd352f7ab47b2cf13e18175ac3f12243fa6afae7c4e2872f246f0', 'firmware_booter_signatures': '4db5a10949e475df7ecc011e34229895b296653cd401f6d88396ae00412cf0ea'}

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--original', type=Path, required=True)
    parser.add_argument('--assets', type=Path, required=True)
    parser.add_argument('--out', type=Path, required=True)
    args = parser.parse_args()
    # The original is needed only to create the asset bundle the first time.
    manifest_path = args.assets/'manifest.json'
    if not manifest_path.exists():
        original = args.original.read_bytes()
        if hashlib.sha256(original).hexdigest() != PINNED:
            raise ValueError('Only pinned 469dc0c firmware can be extracted')
        shoff = struct.unpack_from('<Q', original, 40)[0]
        section = struct.unpack_from('<IIQQQQIIQQ', original, shoff+5*64)
        args.assets.mkdir(parents=True, exist_ok=True)
        records = []
        for name, offset, size in ASSETS:
            if offset+size > section[5]:
                raise ValueError('Firmware section is too short')
            data = original[section[4]+offset:section[4]+offset+size]
            path = args.assets/(name+'.bin')
            if path.exists() and path.read_bytes() != data:
                raise ValueError('Existing firmware asset differs: '+str(path))
            path.write_bytes(data)
            records.append(dict(name=name, offset=offset, size=size, sha256=hashlib.sha256(data).hexdigest()))
        manifest_path.write_text(json.dumps(dict(original_sha256=PINNED, assets=records),indent=2)+'\n')
    manifest = json.loads(manifest_path.read_text())
    if manifest['original_sha256'] != PINNED or [(a['name'],a['offset'],a['size']) for a in manifest['assets']] != ASSETS:
        raise ValueError('Firmware manifest layout differs')
    payload = bytearray(); strings = bytearray(b'\0'); symbols = bytearray(24)
    for item in manifest['assets']:
        data = (args.assets/(item['name']+'.bin')).read_bytes()
        if item['sha256'] != EXPECTED_HASHES[item['name']] or len(data) != item['size'] or hashlib.sha256(data).hexdigest() != item['sha256']:
            raise ValueError('Firmware checksum differs: '+item['name'])
        payload.extend(b'\0'*(-len(payload)%32))
        symbols.extend(struct.pack('<IBBHQQ',len(strings),0x11,0,1,len(payload),len(data)))
        strings.extend(item['name'].encode()+b'\0');payload.extend(data)
    names = b'\0.rodata\0.symtab\0.strtab\0.shstrtab\0'
    blob = bytearray(64); sections = [(0,0,0,0,0,0,0,0,0,0)]
    for name, typ, flags, data, link, info, align, entry in [
        (1,1,2,payload,0,0,32,0),(9,2,0,symbols,3,1,8,24),
        (17,3,0,strings,0,0,1,0),(25,3,0,names,0,0,1,0)]:
        blob.extend(b'\0'*(-len(blob)%align));offset=len(blob);blob.extend(data)
        sections.append((name,typ,flags,0,offset,len(data),link,info,align,entry))
    blob.extend(b'\0'*(-len(blob)%8));shoff=len(blob)
    for s in sections:blob.extend(struct.pack('<IIQQQQIIQQ',*s))
    blob[:64] = struct.pack('<16sHHIQQQIHHHHHH',b'\x7fELF\x02\x01\x01'+b'\0'*9,1,62,1,0,0,shoff,0,64,0,0,64,5,4)
    args.out.parent.mkdir(parents=True,exist_ok=True);args.out.write_bytes(blob)
    print('REBUILT_FIRMWARE_DATA_ONLY: six verified assets; no executable sections or relocations')

if __name__ == '__main__':main()
