"""Assert source objects call only the source-owned dependency boundary."""
import argparse
import importlib
import json
from pathlib import Path

inspect = importlib.import_module('inspect-core-compatibility').inspect
ALLOWED = set('''ioread32 iowrite32 memset
rebuilt_gr_power rebuilt_media_probe rebuilt_session_identity
rebuilt_booter_target firmware_booter_image firmware_booter_signatures rebuilt_fwsec_execute rebuilt_reset_managed
rebuilt_inputs_prepare rebuilt_inputs_release rebuilt_inputs_metadata
rebuilt_inputs_metadata_feature rebuilt_vbios_acquire rebuilt_vbios_fwsec
rebuilt_vbios_release firmware_plm_image firmware_plm_signature
firmware_feature_image firmware_feature_signature
rebuilt_find_signature rebuilt_fwsec_free rebuilt_local_memory_size
rebuilt_pmu_devinit rebuilt_vbios_vde rebuilt_sec2_accessible rebuilt_meta_signature
rebuilt_feature_stage rebuilt_fwsec_stage rebuilt_plm_transaction
rebuilt_session_cleanup rebuilt_frts_interface'''.split())

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('objects', nargs='+', type=Path)
    parser.add_argument('--out', required=True, type=Path)
    args = parser.parse_args()
    report = []
    for path in args.objects:
        imports = inspect(path)['imports']
        unknown = sorted(set(imports) - ALLOWED)
        if unknown:
            raise ValueError(f'{path}: undeclared backend imports: {unknown}')
        report.append({'object': str(path.resolve()), 'imports': imports})
    args.out.write_text(json.dumps(report, indent=2)+'\n', encoding='utf-8')
    print('REBUILT_SOURCE_BOUNDARY_PASSED: no original executable backend imports.')

if __name__ == '__main__':
    main()
