"""Cut the ammunition out of stock 1P weapon rigs for physical reloads.

Run with Blender (headless is fine):
  & 'C:\\Program Files\\Blender Foundation\\Blender 5.2\\blender.exe' --background \
      --python tools/generate_reload_props.py -- [rig.psk ...]

For each rig this keeps only the faces skinned to the loaded magazine (or the
loaded shell) and their child bones, and writes build/hand-meshes/
VRAmmo_<rig>.fbx in that bone's own reference frame, origin at the bone. At
runtime VRInteractiveReload draws it with the gun's own material, so the round
or magazine in the hand is the one the gun shows. The ammunition bone is found
by name (the same probe the runtime uses); no per-weapon table.

Also writes VRReloadRing.fbx: a flat, double-sided annulus of unit outer radius
in the YZ plane, for the translucent target highlights.

For the magazine rigs it also writes the reload-hint part shells, AS2-style
part highlights (Arizona Sunshine 2 colours its magazine, grip/magwell and
slide in the gun's shader; KF2 guns share one material, so these are thin
shells of the gun's own faces pushed 0.5 mm out along their normals):
  VRGlowMag_<rig>   the loaded magazine, in the magazine bone frame
  VRGlowSlide_<rig> the slide or bolt subtree (VRReloadCatalog RackBone)
  VRGlowWell_<rig>  the static frame faces around the seated magazine (grip
                    and magwell), in the RW_Weapon bone frame

PSK inputs are derived game assets and stay in ignored extract/ or existing
build/ audit exports; outputs stay in ignored build/. Export settings match
the wristwatch static mesh. --check runs with ordinary Python and verifies the
complete requested set and its source/output hashes without opening Blender.
"""

from __future__ import annotations

import argparse
import hashlib
import re
import json
import math
from pathlib import Path
import struct
import sys

sys.path.insert(0, str(Path(__file__).resolve().parent))
from generate_floating_hands import FACE, HEADER, WEDGE, WEIGHT, Chunk, bone_data  # noqa: E402

REPORT_SCHEMA = 'kf2vr/reload-props/5'


def sha256(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest().upper()


def read_psk(path):
    """Read-only chunk reader. Unlike the hand cutter, which rewrites the rig and
    must refuse anything it would drop, this only reads points, wedges, faces,
    weights and bones, so extra chunks (EXTRAUVS0 on weapon rigs) are ignored."""
    data = Path(path).read_bytes()
    offset, chunks = 0, {}
    while offset < len(data):
        if len(data) - offset < HEADER.size:
            raise ValueError(f'Truncated PSK chunk header in {path}')
        raw_name, kind, size, count = HEADER.unpack_from(data, offset)
        offset += HEADER.size
        if size < 0 or count < 0 or (count and size == 0) or size * count > len(data) - offset:
            raise ValueError(f'Invalid/truncated PSK chunk in {path}')
        name = raw_name.rstrip(b'\0').decode('ascii')
        if name in chunks:
            raise ValueError(f'Duplicate PSK chunk {name} in {path}')
        chunks[name] = Chunk(name, kind, size, [data[offset + i * size:offset + (i + 1) * size] for i in range(count)])
        offset += size * count
    for name, size in {'PNTS0000':12, 'VTXW0000':16, 'FACE0000':12, 'MATT0000':88, 'REFSKELT':120, 'RAWWEIGHTS':12}.items():
        if name not in chunks or chunks[name].size != size:
            raise ValueError(f'Missing or incompatible {name} in {path}')
    return chunks

# Probed in order, like VRInteractiveReload.LoadedBoneNames and the shell rule.
MAGAZINE_BONES = ('RW_Magazine1', 'RW_Mag', 'RW_Magazine')
SHELL_BONES = ('RW_Shell1', 'RW_Bullet1')
DEFAULT_RIGS = (
    'extract/weapons/WEP_1P_9MM_MESH/SkeletalMesh3/Wep_1stP_9mm_Rig.psk',
    'extract/weapons/WEP_1P_MB500_MESH/SkeletalMesh3/Wep_1stP_MB500_Rig.psk',
    'extract/weapons/WEP_1P_Double_Barrel_MESH/SkeletalMesh3/Wep_1stP_Double_Barrel.psk',
    # Existing local stock exports, audited in reload-expansion-20260927.
    'build/pistol-brace-20260919/pose-audit/export/WEP_1P_M1911_MESH/SkeletalMesh3/Wep_1stP_M1911_Rig.psk',
    'build/pistol-brace-20260919/pose-audit/export/WEP_1P_Deagle_MESH/SkeletalMesh3/Wep_1stP_Deagle_Rig.psk',
    'build/pistol-brace-20260919/pose-audit/export/WEP_1P_Medic_Pistol_MESH/SkeletalMesh3/Wep_1stP_Medic_Pistol_Rig.psk',
    'build/selected-guns-audit/export/WEP_1P_AK12_MESH/SkeletalMesh3/Wep_1stP_AK12_Rig.psk',
    'build/sa80-audit/export/WEP_1P_L85A2_MESH/SkeletalMesh3/Wep_1stP_L85A2_Rig.psk',
    # 2026-09-28 expansion, audited in reload-wave2-audit.
    'build/m14ebr-audit/export/WEP_1P_M14EBR_MESH/SkeletalMesh3/WEP_1stP_M14_EBR.psk',
    'build/aa12-audit/export/Wep_1P_AA12_MESH/SkeletalMesh3/Wep_1stP_AA12_Rig.psk',
    'build/hmtech201-audit/export/WEP_1P_Medic_SMG_MESH/SkeletalMesh3/Wep_1stP_Medic_SMG_Rig.psk',
    'build/ar15-audit/export/WEP_1P_AR15_9mm_MESH/SkeletalMesh3/Wep_1stP_AR15_9mm_Rig.psk',
    'build/scar-audit/export/WEP_1P_SCAR_MESH/SkeletalMesh3/Wep_1stP_SCAR_Rig.psk',
    'build/mp7-audit/export/wep_1p_mp7_mesh/SkeletalMesh3/Wep_1stP_MP7_Rig.psk',
    'build/kriss-audit/export/wep_1p_kriss_mesh/SkeletalMesh3/Wep_1stP_KRISS_Rig.psk',
    'build/p90-audit/export/wep_1p_p90_mesh/SkeletalMesh3/Wep_1stP_P90_Rig.psk',
    # 2026-09-30 straight-pull wave (docs/OPEN_WORK.md roadmap, wave 1).
    'build/tommygun-audit/export/WEP_1P_TommyGun_MESH/SkeletalMesh3/Wep_1stP_TommyGun_Rig.psk',
    'build/mac10-audit/export/WEP_1P_MAC10_MESH/SkeletalMesh3/Wep_1stP_MAC10_Rig.psk',
    'build/g36c-audit/export/WEP_1P_G36C_MESH/SkeletalMesh3/WEP_1stP_G36C_Rig.psk',
    'build/zedmkiii-audit/export/WEP_1P_ZEDMKIII_MESH/SkeletalMesh3/WEP_1stP_ZEDMKIII_Rig.psk',
    'build/stunner-audit/export/Wep_1P_HRG_Stunner_MESH/SkeletalMesh3/Wep_1stP_HRG_Stunner_Rig.psk',
    'build/s12-audit/export/WEP_1P_Saiga12_MESH/SkeletalMesh3/Wep_1stP_Saiga12_Rig.psk',
    'build/ump-audit/export/WEP_1P_HK_UMP_MESH/SkeletalMesh3/Wep_1stP_HK_UMP_Rig.psk',
    'build/mp5ras-audit/export/WEP_1P_MP5RAS_MESH/SkeletalMesh3/Wep_1stP_MP5RAS_Rig.psk',
    # 2026-09-30 two-material medic magazines (roadmap wave 2).
    'build/hmtech301-audit/export/WEP_1P_Medic_Shotgun_MESH/SkeletalMesh3/Wep_1stP_Medic_Shotgun_Rig.psk',
    'build/hmtech401-audit/export/WEP_1P_Medic_Assault_MESH/SkeletalMesh3/Wep_1stP_Medic_Assault_Rig.psk',
    # 2026-09-30 pistols (roadmap wave 6).
    'build/pistol-brace-20260919/pose-audit/export/WEP_1P_G18C_MESH/SkeletalMesh3/Wep_1stP_G18C_Rig.psk',
    'build/pistol-brace-20260919/pose-audit/export/WEP_1P_HRG_93R_Pistol_MESH/SkeletalMesh3/WEP_1P_HRG_93R_Pistol_Rig.psk',
    'build/disrupter-audit/export/WEP_1P_HRG_Energy_MESH/SkeletalMesh3/WEP_1stP_HRG_Energy_Rig.psk',
    # 2026-10-01 Trench Gun (roadmap wave 3), a second pump shotgun.
    'build/trench-audit/export/WEP_1P_DragonsBreath_MESH/SkeletalMesh3/Wep_1stP_DragonsBreath_Rig.psk',
    # 2026-10-01 break-actions (roadmap wave 5).
    'build/m79-audit/export/WEP_1P_M79_MESH/SkeletalMesh3/Wep_1stP_M79_Rig.psk',
    'build/hx25-audit/export/WEP_1P_HX25_Pistol_MESH/SkeletalMesh3/Wep_1stP_HX25_Pistol_Rig.psk',
    'build/dragonsblaze-audit/export/WEP_1P_HRG_MegaDragonsbreath_MESH/SkeletalMesh3/Wep_1stP_HRG_MegaDragonsbreath_Rig.psk',
    # 2026-10-01 MKb.42 (roadmap wave 7).
    'build/mkb42-audit/export/WEP_1P_MKB42_MESH/SkeletalMesh3/Wep_1stP_MKB42_Rig.psk',
    # 2026-10-01 M4 shotgun (roadmap wave 4).
    'build/m4shotgun-audit/export/WEP_1P_M4Shotgun_MESH/SkeletalMesh3/Wep_1stP_M4Shotgun_Rig.psk',
    # 2026-10-01 bolt actions (roadmap wave 8).
    'build/m99-audit/export/WEP_1P_M99_MESH/SkeletalMesh3/Wep_1stP_M99_Rig.psk',
    'build/mosin-audit/export/WEP_1P_Mosin_MESH/SkeletalMesh3/WEP_1stP_Mosin_Rig.psk',
    # 2026-10-01 lever actions (roadmap wave 9).
    'build/winchester-audit/export/WEP_1P_Winchester_MESH/SkeletalMesh3/Wep_1stP_Winchester_Rig.psk',
    'build/spx464-audit/export/WEP_1P_Centerfire_MESH/SkeletalMesh3/Wep_1stP_Centerfire_Rig.psk',
    # 2026-10-01 swing-out revolvers (roadmap wave 10).
    'build/pistol-brace-20260919/pose-audit/export/WEP_1P_SW_500_MESH/SkeletalMesh3/Wep_1stP_SW_500_Rig.psk',
    'build/pistol-brace-20260919/pose-audit/export/WEP_1P_ChiappaRhino_MESH/SkeletalMesh3/Wep_1stP_ChiappaRhino_Rig.psk',
    'build/pistol-brace-20260919/pose-audit/export/WEP_1P_Remington_1858_MESH/SkeletalMesh3/Wep_1stP_Remington_1858_Rig.psk',
    'build/m32-audit/export/WEP_1P_M32_MGL_MESH/SkeletalMesh3/Wep_1stP_M32_MGL_Rig.psk',
    # 2026-10-01 belt-fed guns (roadmap wave 11).
    'build/stoner63a-audit/export/WEP_1P_Stoner63A_MESH/SkeletalMesh3/Wep_1stP_Stoner63A_Rig.psk',
    'build/bastion-audit/export/WEP_1P_HRG_BarrierRifle_MESH/SkeletalMesh3/WEP_1stP_HRG_BarrielRifle_Rig.psk',
    'build/mg3-audit/export/WEP_1P_MG3_MESH/SkeletalMesh3/WEP_1stP_MG3_Rig.psk',
    # 2026-10-01 rifles and the AF2011 (roadmap wave 12).
    'build/reload-wave12-audit/export/WEP_1P_Famas_MESH/SkeletalMesh3/WEP_1stP_Famas_Rig.psk',
    'build/reload-wave12-audit/export/WEP_1P_FNFAL_MESH/SkeletalMesh3/WEP_1stP_FNFAL_Rig.psk',
    'build/reload-wave12-audit/export/WEP_1P_M16_M203_MESH/SkeletalMesh3/Wep_1stP_M16_M203_Rig.psk',
    'build/reload-wave12-audit/export/WEP_1P_AF2001_MESH/SkeletalMesh3/Wep_1stP_AF2001_Rig.psk',
    # 2026-10-01 break-actions and the HRG Buckshot (roadmap wave 13).
    'build/reload-wave13-audit/export/WEP_1P_HRG_Kaboomstick_MESH/SkeletalMesh3/Wep_1stP_HRG_Kaboomstick_Rig.psk',
    'build/reload-wave13-audit/export/WEP_1P_Quad_Barrel_MESH/SkeletalMesh3/Wep_1stP_Quad_Barrel.psk',
    'build/reload-wave13-audit/export/WEP_1P_HRG_SW_500_MESH/SkeletalMesh3/Wep_1stP_HRG_SW_500_Rig.psk',
    'build/reload-wave13-audit/export/WEP_1P_FlareGun_MESH/SkeletalMesh3/Wep_1stP_FlareGun_Rig.psk',
    'build/reload-wave13-audit/export/WEP_1P_Blunderbuss_MESH/SkeletalMesh3/Wep_1stP_Blunderbuss_Rig.psk',
    # 2026-10-01 Winterbite, Scorcher, Cranial Popper, Hemogoblin.
    'build/reload-wave14-audit/export/WEP_1P_HRG_Winterbite_MESH/SkeletalMesh3/Wep_1stP_HRG_Winterbite_Rig.psk',
    'build/reload-wave14-audit/export/WEP_1P_HRGScorcher_Pistol_MESH/SkeletalMesh3/Wep_1stP_HRGScorcher_Pistol_Rig.psk',
    'build/reload-wave14-audit/export/WEP_1P_HRG_CranialPopper_MESH/SkeletalMesh3/WEP_1stP_HRG_CranialPopper_Rig.psk',
    'build/reload-wave14-audit/export/WEP_1P_Bleeder_MESH/SkeletalMesh3/Wep_1stP_Bleeder_Rig.psk',
    # 2026-10-01 cartridges and canisters seated at the ammo moment.
    'build/reload-wave14-audit/export/WEP_1P_CryoGun_MESH/SkeletalMesh3/Wep_1stP_CryoGun_Rig.psk',
    'build/reload-wave14-audit/export/WEP_1P_HRG_Healthrower_MESH/SkeletalMesh3/Wep_1stP_HRG_Healthrower_Rig.psk',
    'build/reload-wave14-audit/export/WEP_1P_HRG_BallisticBouncer_MESH/SkeletalMesh3/Wep_1stP_HRG_BallisticBouncer_Rig.psk',
    'build/reload-wave14-audit/export/WEP_1P_Mine_Reconstructor_MESH/SkeletalMesh3/Wep_1stP_HMTech_Mine_Reconstructor_Rig.psk',
    # 2026-10-02 Pulverizer, Doshinegun, Frost Fang.
    'build/reload-wave14-audit/export/WEP_1P_Pulverizer_MESH/SkeletalMesh3/Wep_1stP_Pulverizer_Rig_New.psk',
    'build/reload-wave14-audit/export/WEP_1P_Doshinegun_MESH/SkeletalMesh3/WEP_1stP_Doshinegun_Rig.psk',
    'build/reload-wave14-audit/export/WEP_1P_Frost_Shotgun_Axe_MESH/SkeletalMesh3/Wep_1stP_Frost_Shotgun_Axe_Rig.psk',
    # 2026-10-01 magazines, batteries, tanks and rockets (roadmap waves 14-16).
    'build/reload-wave14-audit/export/WEP_1P_Nail_Shotgun_MESH/SkeletalMesh3/Wep_1stP_Nail_ShotGun_Rig.psk',
    'build/reload-wave14-audit/export/WEP_1P_HRG_Nailgun_PDW_MESH/SkeletalMesh3/Wep_1stP_HRG_Nailgun_PDW_Rig.psk',
    'build/reload-wave14-audit/export/WEP_1P_HRG_IncendiaryRifle_MESH/SkeletalMesh3/Wep_1stP_HRG_IncendiaryRifle_Rig.psk',
    'build/reload-wave14-audit/export/WEP_1P_HRG_Teslauncher_MESH/SkeletalMesh3/Wep_1stP_HRG_Teslauncher_Rig.psk',
    'build/reload-wave14-audit/export/WEP_1P_Medic_GrenadeLauncher_MESH/SkeletalMesh3/Wep_1stP_Medic_GrenadeLauncher_Rig.psk',
    'build/reload-wave14-audit/export/WEP_1P_HRG_Boomy_MESH/SkeletalMesh3/WEP_1stP_HRG_Boomy_Rig.psk',
    'build/reload-wave14-audit/export/WEP_1P_RiotShield_MESH/SkeletalMesh3/Wep_1P_RiotShield_Rig.psk',
    'build/reload-wave14-audit/export/WEP_1P_Laser_Cutter_MESH/SkeletalMesh3/Wep_1stP_Laser_Cutter_Rig.psk',
    'build/reload-wave14-audit/export/WEP_1P_Microwave_Assault_MESH/SkeletalMesh3/Wep_1stP_Microwave_Assault_Rig.psk',
    'build/reload-wave14-audit/export/WEP_1P_HVStormCannon_MESH/SkeletalMesh3/WEP_1stP_HVStormCannon_Rig.psk',
    'build/reload-wave14-audit/export/WEP_1P_HZ12_MESH/SkeletalMesh3/Wep_1stP_HZ12_Rig.psk',
    'build/reload-wave14-audit/export/WEP_1P_HRG_SonicGun_MESH/SkeletalMesh3/WEP_1stP_HRG_SonicGun_Rig.psk',
    'build/reload-wave14-audit/export/WEP_1P_Seal_Squeal_MESH/SkeletalMesh3/WEP_1stP_Seal_Squeal_Rig.psk',
    'build/reload-wave14-audit/export/WEP_1P_SeekerSix_MESH/SkeletalMesh3/Wep_1stP_SeekerSix_Rig.psk',
    'build/reload-wave14-audit/export/WEP_1P_HRG_Locust_MESH/SkeletalMesh3/Wep_1stP_HRG_Locust_Rig.psk',
    'build/reload-wave14-audit/export/WEP_1P_Thermite_MESH/SkeletalMesh3/WEP_1stP_Thermite_Rig.psk',
    'build/reload-wave14-audit/export/WEP_1P_ShrinkRay_Gun_MESH/SkeletalMesh3/WEP_1stP_ShrinkRay_Gun_Rig.psk',
    'build/reload-wave14-audit/export/WEP_1P_Minigun_MESH/SkeletalMesh3/Wep_1stP_Minigun_Rig.psk',
    'build/reload-wave14-audit/export/WEP_1P_CaulkBurn_MESH/SkeletalMesh3/Wep_1stP_CaulkBurn_Rig.psk',
    'build/reload-wave14-audit/export/WEP_1P_Flamethrower_MESH/SkeletalMesh3/Wep_1stP_Flamethrower_Rig.psk',
    'build/reload-wave14-audit/export/WEP_1P_Microwave_Gun_MESH/SkeletalMesh3/Wep_1stP_Microwave_Gun_Rig.psk',
    'build/reload-wave14-audit/export/WEP_1P_HRG_ArcGenerator_MESH/SkeletalMesh3/Wep_1stP_HRG_ArcGenerator_Rig.psk',
    'build/reload-wave14-audit/export/WEP_1P_Medic_Bat_MESH/SkeletalMesh3/Wep_1stP_Medic_Bat_Rig.psk',
    'build/reload-wave14-audit/export/WEP_1P_Gravity_Imploder_MESH/SkeletalMesh3/Wep_1stP_Gravity_Imploder_Rig.psk',
    'build/reload-wave14-audit/export/WEP_1P_BladedPistol_MESH/SkeletalMesh3/WEP_1stP_BladedPistol_Rig.psk',
    'build/reload-wave14-audit/export/WEP_1P_RPG7_MESH/SkeletalMesh3/Wep_1stP_RPG7_Rig.psk',
    'build/reload-wave14-audit/export/WEP_1P_HRG_MedicMissile_MESH/SkeletalMesh3/Wep_1stP_HRG_MedicMissile_Rig.psk',
    'build/reload-wave14-audit/export/WEP_1P_ParasiteImplanter_MESH/SkeletalMesh3/Wep_1stP_ParasiteImplanter_Rig.psk',
)
RING_OUTER, RING_INNER, RING_SEGMENTS = 1.0, 0.8, 48
# Hint shells: action bone per magazine rig, matching VRReloadCatalog.RackBone.
GLOW_ACTION_BONES = {
    'Wep_1stP_9mm_Rig': 'RW_Bolt', 'Wep_1stP_M1911_Rig': 'RW_Bolt',
    'Wep_1stP_Deagle_Rig': 'RW_Slide', 'Wep_1stP_Medic_Pistol_Rig': 'RW_Bolt',
    'Wep_1stP_AK12_Rig': 'RW_Bolt', 'Wep_1stP_L85A2_Rig': 'RW_Bolt',
    'WEP_1stP_M14_EBR': 'RW_Bolt', 'Wep_1stP_AA12_Rig': 'RW_ChargingHandle',
    'Wep_1stP_Medic_SMG_Rig': 'RW_Bolt', 'Wep_1stP_AR15_9mm_Rig': 'RW_Charging_Handle',
    'Wep_1stP_SCAR_Rig': 'RW_Charging_Handle', 'Wep_1stP_MP7_Rig': 'RW_Charging_Handle',
    'Wep_1stP_KRISS_Rig': 'RW_Charging_Handle', 'Wep_1stP_P90_Rig': 'RW_Charging_Handle',
    'Wep_1stP_TommyGun_Rig': 'RW_Charging_Handle', 'Wep_1stP_MAC10_Rig': 'RW_Charging_Handle',
    'WEP_1stP_G36C_Rig': 'RW_Charging_Handle', 'WEP_1stP_ZEDMKIII_Rig': 'RW_Charging_Handle',
    'Wep_1stP_HRG_Stunner_Rig': 'RW_ChargingHandle', 'Wep_1stP_Saiga12_Rig': 'RW_Bolt',
    'Wep_1stP_HK_UMP_Rig': 'RW_Charging_Handle', 'Wep_1stP_MP5RAS_Rig': 'RW_Charging_Handle',
    'Wep_1stP_Medic_Shotgun_Rig': 'RW_Bolt', 'Wep_1stP_Medic_Assault_Rig': 'RW_Bolt',
    'Wep_1stP_G18C_Rig': 'RW_Bolt', 'WEP_1P_HRG_93R_Pistol_Rig': 'RW_Bolt', 'WEP_1stP_HRG_Energy_Rig': None,
    'Wep_1stP_MKB42_Rig': 'RW_Bolt',
    'WEP_1stP_Famas_Rig': 'RW_Charging_Rod', 'WEP_1stP_FNFAL_Rig': 'RW_Charging_Handle',
    'Wep_1stP_M16_M203_Rig': 'RW_Charging_Handle', 'Wep_1stP_AF2001_Rig': 'RW_Bolt',
    'Wep_1stP_Blunderbuss_Rig': None,
    'Wep_1stP_Pulverizer_Rig_New': None,
    'Wep_1stP_CryoGun_Rig': None,
    'Wep_1stP_HRG_Healthrower_Rig': None,
    'Wep_1stP_HRG_BallisticBouncer_Rig': None,
    'Wep_1stP_HMTech_Mine_Reconstructor_Rig': None,
    'Wep_1stP_Nail_ShotGun_Rig': None,
    'Wep_1stP_HRG_Nailgun_PDW_Rig': None,
    'Wep_1stP_HRG_IncendiaryRifle_Rig': 'RW_Charging_Handle',
    'Wep_1stP_HRG_Teslauncher_Rig': 'RW_Charging_Handle',
    'Wep_1stP_Medic_GrenadeLauncher_Rig': 'RW_Charging_Handle',
    'WEP_1stP_HRG_Boomy_Rig': 'RW_Charging_Handle',
    'Wep_1P_RiotShield_Rig': 'RW_Bolt',
    'Wep_1stP_Laser_Cutter_Rig': None,
    'Wep_1stP_Microwave_Assault_Rig': None,
    'WEP_1stP_HVStormCannon_Rig': None,
    'Wep_1stP_HZ12_Rig': 'RW_Pump',
    'WEP_1stP_HRG_SonicGun_Rig': 'RW_ChargingHandle',
    'WEP_1stP_Seal_Squeal_Rig': 'RW_ChargingHandle',
    'Wep_1stP_SeekerSix_Rig': None,
    'Wep_1stP_HRG_Locust_Rig': None,
    'WEP_1stP_Thermite_Rig': None,
    'WEP_1stP_ShrinkRay_Gun_Rig': None,
    'Wep_1stP_Minigun_Rig': None,
    'Wep_1stP_CaulkBurn_Rig': None,
    'Wep_1stP_Flamethrower_Rig': None,
    'Wep_1stP_Microwave_Gun_Rig': None,
    'Wep_1stP_HRG_ArcGenerator_Rig': None,
    'Wep_1stP_Medic_Bat_Rig': None,
    'Wep_1stP_Gravity_Imploder_Rig': None,
    'WEP_1stP_BladedPistol_Rig': None,
    'Wep_1stP_RPG7_Rig': None,
    'Wep_1stP_HRG_MedicMissile_Rig': None,
    'Wep_1stP_ParasiteImplanter_Rig': None,
}
# The S12 skins its receiver to RW_Body, a child of RW_Weapon.
GLOW_FRAME_BONES = ('Root', 'RW_Weapon', 'RW_Body')
# Rigs whose part seats into a turning chamber, not a fixed well (the Freeze
# Thrower's and Healthrower's cartridge): no well shell; the part's own shows.
NO_WELL_SHELL = ('Wep_1stP_CryoGun_Rig', 'Wep_1stP_HRG_Healthrower_Rig')
# Hint shells cut from named bones, as AS2 paints them: only the pump fore-end
# on its pump shotgun (slide band) and only the breech face with both chamber
# mouths on its break-actions (grip band). Kind -> (the bone, or bones, that
# must own every corner, the first being the shell's frame; optional forward
# range in RW_Weapon's bone frame). Strap, shell and ejector bones animate on
# their own and stay out. VRInteractiveReload.WellGlowBones names the frame of
# a well shell that is not RW_Weapon's or RW_Barrel's.
GLOW_BONE_PARTS = {
    'Wep_1stP_MB500_Rig': {'Slide': ('RW_Pump', None)},
    'Wep_1stP_DragonsBreath_Rig': {'Slide': ('RW_Pump', None)},
    # Breech bands follow the hunting shotgun's: from 0.1 behind the chambered
    # shell's base to 1.0 ahead of it (the barrel's rear face where the bind
    # pose holds the shell outside the gun, as on the M79).
    'Wep_1stP_M79_Rig': {'Well': ('RW_Barrel', (6.6, 7.7))},
    'Wep_1stP_HX25_Pistol_Rig': {'Well': ('RW_Barrel', (6.8, 7.9))},
    'Wep_1stP_HRGScorcher_Pistol_Rig': {'Well': ('RW_Barrel', (6.8, 7.9))},
    'Wep_1stP_HRG_MegaDragonsbreath_Rig': {'Well': ('RW_Barrel', (12.8, 13.9))},
    'Wep_1stP_Double_Barrel': {'Well': ('RW_Barrel', (12.5, 13.6))},
    # Same rule from each rig's measured shell base (12.52 and 12.88).
    'Wep_1stP_HRG_Kaboomstick_Rig': {'Well': ('RW_Barrel', (12.4, 13.5))},
    'Wep_1stP_Quad_Barrel': {'Well': ('RW_Barrel', (12.8, 13.9))},
    # AS2's cylinder strategy lights the cylinder (grip band) once it is open.
    # The Cranial Popper and Hemogoblin keep theirs and take a speedloader; the
    # Flare Gun and Winterbite swap theirs, so the seat lights: the barrel's
    # rear face that the cylinder's rounds enter.
    'WEP_1stP_HRG_CranialPopper_Rig': {'Well': ('RW_Cylinder', None)},
    'Wep_1stP_Bleeder_Rig': {'Well': ('RW_Cylinder', None)},
    'Wep_1stP_FlareGun_Rig': {'Well': ('RW_Barrel', (12.3, 14.2))},
    'Wep_1stP_HRG_Winterbite_Rig': {'Well': ('RW_Barrel', (12.3, 14.2))},
    # The Frost Fang loads shell by shell through its side gate (no pump).
    'Wep_1stP_Frost_Shotgun_Axe_Rig': {'Well': ('RW_Breech_Cover', None)},
    # The Doshinegun's wad drops into its container; its wad rests off the gun
    # outside a reload and leaves nothing to eject, so it has no magazine shell.
    'WEP_1stP_Doshinegun_Rig': {'Well': (('RW_Container', 'RW_Lid'), None)},
}
# Magwell region: the magazine's reference-pose box in the RW_Weapon bone frame
# (X along the bore, Y across, Z up; the AR-15 rig alone is not axis-aligned in
# rig space), widened across and along, reaching below the base plate, stopping
# short of its top where the frame meets the action.
WELL_MARGIN_ACROSS, WELL_MARGIN_ALONG, WELL_MARGIN_BELOW, WELL_TOP_INSET = 1.0, 0.8, 0.8, 0.5
SHELL_OFFSET = 0.05


def bind_frames(bones):
    """Reference world position and rotation of every bone (ActorX composition)."""
    from mathutils import Quaternion, Vector
    positions, rotations = [], []
    for i, bone in enumerate(bones):
        x, y, z, w = bone[4:8]
        q = Quaternion((w, x, y, z))
        p = Vector(bone[8:11])
        if i:
            parent = bone[3]
            p = positions[parent] + rotations[parent] @ p
            q = rotations[parent] @ q.conjugated()
        positions.append(p)
        rotations.append(q)
    return positions, rotations


# What the hand brings when it is not a magazine or a single shell.
# Rounds that are separate meshes, not rig geometry: the prop is the whole mesh.
WHOLE_MESH_PROPS = {
    'Wep_1stP_M32_MGL_Rig': 'build/m32-audit/export/WEP_1P_M32_MGL_MESH/SkeletalMesh3/Wep_1stP_M32_MGL_Shell.psk',
}
AMMO_OVERRIDES = {'WEP_1stP_Mosin_Rig': ('clip', 'RW_StripMag'),
                  'Wep_1stP_SW_500_Rig': ('clip', 'RW_Speedloader'),
                  'Wep_1stP_ChiappaRhino_Rig': ('clip', 'RW_Speedloader'),
                  'Wep_1stP_HRG_SW_500_Rig': ('clip', 'RW_Speedloader'),
                  'Wep_1stP_FlareGun_Rig': ('clip', 'RW_Cylinder'),
                  'Wep_1stP_HRG_Winterbite_Rig': ('clip', 'RW_Cylinder'),
                  'WEP_1stP_HRG_CranialPopper_Rig': ('clip', 'RW_Speedloader'),
                  'Wep_1stP_Bleeder_Rig': ('clip', 'RW_Speedloader'),
                  'Wep_1stP_Blunderbuss_Rig': ('magazine', 'RW_Cylinder'),
                  'Wep_1stP_Pulverizer_Rig_New': ('magazine', 'RW_Mag1'),
                  'WEP_1stP_Doshinegun_Rig': ('magazine', 'RW_Notes2'),
                  'Wep_1stP_Frost_Shotgun_Axe_Rig': ('shell', 'RW_Shell_01'),
                  'Wep_1stP_Flamethrower_Rig': ('magazine', 'RW_GasTank1'),
                  'WEP_1stP_BladedPistol_Rig': ('magazine', 'RW_Container'),
                  'Wep_1stP_RPG7_Rig': ('magazine', 'RW_Grenade1'),
                  'Wep_1stP_HRG_MedicMissile_Rig': ('magazine', 'RW_Grenade1'),
                  'Wep_1stP_Stoner63A_Rig': ('clip', 'RW_Magazine1'),
                  'WEP_1stP_HRG_BarrielRifle_Rig': ('clip', 'RW_Magazine1'),
                  'WEP_1stP_MG3_Rig': ('clip', 'RW_Magazine'),
                  'Wep_1stP_Remington_1858_Rig': ('clip', 'RW_Cylinder')}


# A speedloader carries its rounds: the stock reload clip moves the cylinder's
# round bones with the loader between these frames (read from each PSA,
# 2026-10-01: the .500's Reload_Half 70-91, the Rhino's Reload_Empty 84-112),
# so the prop adds them at that riding pose. The Rhino's rounds are rig
# geometry; the .500's are separate meshes on RW_Bullet_FX sockets (roll only,
# from the package's socket table) drawn with that mesh's own material.
RIDING_ROUNDS = {
    'Wep_1stP_SW_500_Rig': {
        'psa': 'build/pistol-brace-20260919/pose-audit/export/WEP_1P_SW_500_ANIM/AnimSet/WEP_1stP_SW_500_Anim.psa',
        'clip': 'Reload_Half', 'frame': 84,
        'mesh': 'build/reload-sound-audit/export/WEP_1P_SW_500_MESH/SkeletalMesh3/Wep_1stP_SW_500_Bullet.psk',
        'material': 'WEP_1P_SW_500_MESH.Wep_1stP_SW_500_Bullet',
        'sockets': {'RW_Bullets1': 52428, 'RW_Bullets2': 39321, 'RW_Bullets3': 26214,
                    'RW_Bullets4': 13107, 'RW_Bullets5': 0},
    },
    'Wep_1stP_ChiappaRhino_Rig': {
        'psa': 'build/pistol-brace-20260919/pose-audit/export/WEP_1P_ChiappaRhino_ANIM/AnimSet/WEP_1stP_ChiappaRhino_Anim.psa',
        'clip': 'Reload_Empty', 'frame': 98,
    },
    # The Cranial Popper's and Hemogoblin's seven darts ride their loader at
    # 18.2 UU from its origin between Reload_Empty frames 3 and 57.
    'WEP_1stP_HRG_CranialPopper_Rig': {
        'psa': 'build/reload-wave14-audit/export/WEP_1P_HRG_CranialPopper_ANIM/AnimSet/Wep_1stP_HRG_CranialPopper_Anim.psa',
        'clip': 'Reload_Empty', 'frame': 45, 'max_offset': 25.0,
    },
    'Wep_1stP_Bleeder_Rig': {
        'psa': 'build/reload-wave14-audit/export/WEP_1P_Bleeder_ANIM/AnimSet/Wep_1stP_Bleeder_Anim.psa',
        'clip': 'Reload_Empty', 'frame': 45, 'max_offset': 25.0,
    },
    # The Pulverizer's four shells and spring plate hang from the gun but ride
    # its clip between Reload_Empty frames 74 and 121.
    'Wep_1stP_Pulverizer_Rig_New': {
        'psa': 'build/reload-wave14-audit/export/WEP_1P_Pulverizer_ANIM/AnimSet/Wep_1stP_Pulverizer_Anim.psa',
        'clip': 'Reload_Empty', 'frame': 100,
        'bones': ['RW_Shell1', 'RW_Shell2', 'RW_Shell3', 'RW_Shell4', 'RW_MagSpringPlate1'],
    },
    # The HRG Buckshot rides the same loader with its shotshells (3P mesh, the
    # class's UnusedBulletMeshTemplate) between Reload_Half frames 64 and 92.
    'Wep_1stP_HRG_SW_500_Rig': {
        'psa': 'build/reload-wave13-audit/export/WEP_1P_HRG_SW_500_ANIM/AnimSet/WEP_1stP_HRG_SW_500_Anim.psa',
        'clip': 'Reload_Half', 'frame': 76,
        'mesh': 'build/reload-wave13-audit/export/WEP_3P_HRG_SW_500_MESH/SkeletalMesh3/Wep_3rdP_HRG_SW_500_Bullet.psk',
        'material': 'wep_3p_hrg_sw_500_mesh.Wep_3rdP_HRG_SW_500_Bullet',
        'sockets': {'RW_Bullets1': 52428, 'RW_Bullets2': 39321, 'RW_Bullets3': 26214,
                    'RW_Bullets4': 13107, 'RW_Bullets5': 0},
    },
}


def riding_rounds(psk_path, chunks, bones, names, root, points, wedges, faces, slot):
    """The rounds a loader carries, as extra points, wedges and faces placed in
    the loader's bind frame at their stock riding pose."""
    from mathutils import Quaternion, Vector
    from reload_sound_map import Motion
    top = Path(__file__).resolve().parents[1]
    spec = RIDING_ROUNDS[Path(psk_path).stem]
    motion = Motion(Path(psk_path), top / spec['psa'])
    frames = motion.infos[spec['clip']][11]
    if spec['frame'] >= frames:
        raise ValueError(f"{spec['clip']} has {frames} frames, not {spec['frame'] + 1}")
    pos, rot = motion.world(spec['clip'], spec['frame'], frames - 1)
    pos = [Vector(p) for p in pos]
    rot = [Quaternion((q[3], q[0], q[1], q[2])) for q in rot]
    bind_p, bind_q = bind_frames(bones)
    loader = names[root]

    def riding(bone):
        # The round bone in the loader's riding frame, placed on the loader's bind pose.
        s, b = motion.index[loader], motion.index[bone]
        inv = rot[s].conjugated()
        at, turn = inv @ (pos[b] - pos[s]), inv @ rot[b]
        if at.length > spec.get('max_offset', 15.0):
            raise ValueError(f'{bone} is {at.length:.1f} UU from {loader}; not riding it')
        return lambda v: bind_p[root] + bind_q[root] @ (at + turn @ v)
    out_points, out_wedges, out_faces = [], [], []

    def add(transform, src_points, src_wedges, src_faces, material):
        index = {}
        for face in src_faces:
            row = []
            for w in face[:3]:
                wedge = src_wedges[w]
                if wedge[0] not in index:
                    index[wedge[0]] = len(points) + len(out_points)
                    out_points.append(tuple(transform(Vector(src_points[wedge[0]]))))
                out_wedges.append((index[wedge[0]],) + tuple(wedge[1:]))
                row.append(len(wedges) + len(out_wedges) - 1)
            out_faces.append(tuple(row) + (material,) + tuple(face[4:]))

    if 'mesh' in spec:
        bullet = read_psk(top / spec['mesh'])
        b_points = [struct.unpack('<3f', row) for row in bullet['PNTS0000'].rows]
        b_wedges = [WEDGE.unpack(row) for row in bullet['VTXW0000'].rows]
        b_faces = [FACE.unpack(row) for row in bullet['FACE0000'].rows]
        for bone, roll in spec['sockets'].items():
            place = riding(bone)
            turn = Quaternion((1, 0, 0), roll / 65536.0 * 2 * math.pi)
            add(lambda v, place=place, turn=turn: place(turn @ v), b_points, b_wedges, b_faces, slot)
        return out_points, out_wedges, out_faces
    dominant = [(0.0, -1)] * len(points)
    for row in chunks['RAWWEIGHTS'].rows:
        weight, point, bone = WEIGHT.unpack(row)
        if weight > dominant[point][0]:
            dominant[point] = (weight, bone)
    for i, name in enumerate(names):
        if name not in spec.get('bones', ()) and (
                'bones' in spec or not ROUND_BONE.match(name) or not name.startswith('RW_Bullets')):
            continue
        own = [f for f in faces if all(dominant[wedges[w][0]][1] == i for w in f[:3])]
        if any(f not in own and any(dominant[wedges[w][0]][1] == i for w in f[:3]) for f in faces):
            raise ValueError(f'{name} has faces crossing other bones; refusing an incomplete round')
        if not own:
            continue
        place = riding(name)
        inverse = bind_q[i].conjugated()
        add(lambda v, place=place, inverse=inverse, i=i: place(inverse @ (v - bind_p[i])), points, wedges, own, own[0][3])
    if not out_faces:
        raise ValueError(f'{Path(psk_path).stem} has no round geometry for its loader')
    return out_points, out_wedges, out_faces


def ammo_bone(names, stem=''):
    if stem in AMMO_OVERRIDES:
        kind, bone = AMMO_OVERRIDES[stem]
        return kind, names.index(bone)
    for kind, candidates in (('magazine', MAGAZINE_BONES), ('shell', SHELL_BONES)):
        for name in candidates:
            if name in names:
                return kind, names.index(name)
    raise ValueError('Rig has no magazine or shell bone')


# The rounds riding in a magazine (RW_Bullets1, RW_Bullet...), not its follower
# tray: an empty reload ejects the magazine without them, as the stock clip
# hides them on the outgoing magazine.
ROUND_BONE = re.compile(r'RW_(Bullets?|Famas_Shell)\d*$')


def cut_ammo(psk_path, spent=False):
    """Faces whose every point is dominated by the ammunition bone or its children.
    A spent cut also leaves out every face touching a round. A rig listed in
    WHOLE_MESH_PROPS is cut from that round mesh whole."""
    if Path(psk_path).stem in WHOLE_MESH_PROPS:
        return cut_whole(Path(__file__).resolve().parents[1] / WHOLE_MESH_PROPS[Path(psk_path).stem])
    chunks = read_psk(psk_path)
    bones, names = bone_data(chunks)
    kind, root = ammo_bone(names, Path(psk_path).stem)
    keep = {root}
    for i in range(root + 1, len(bones)):
        if bones[i][3] in keep:
            keep.add(i)
    rounds = {i for i in keep if ROUND_BONE.match(names[i])}
    points = [struct.unpack('<3f', row) for row in chunks['PNTS0000'].rows]
    wedges = [WEDGE.unpack(row) for row in chunks['VTXW0000'].rows]
    faces = [FACE.unpack(row) for row in chunks['FACE0000'].rows]
    dominant = [(0.0, -1)] * len(points)
    for row in chunks['RAWWEIGHTS'].rows:
        weight, point, bone = WEIGHT.unpack(row)
        if weight > dominant[point][0]:
            dominant[point] = (weight, bone)
    kept = [f for f in faces if all(dominant[wedges[w][0]][1] in keep for w in f[:3])]
    mixed = sum(1 for f in faces if f not in kept and any(dominant[wedges[w][0]][1] in keep for w in f[:3]))
    full_indices = sorted({f[3] for f in kept})
    if spent:
        kept = [f for f in kept if not any(dominant[wedges[w][0]][1] in rounds for w in f[:3])]
    if not kept:
        raise ValueError(f'No faces skinned to {names[root]}')
    if mixed:
        raise ValueError(f'{names[root]} has {mixed} faces crossing the ammunition cut; refusing an incomplete prop')
    # A separate round mesh draws in a slot after the gun's own.
    extra_slot = len(chunks['MATT0000'].rows)
    if Path(psk_path).stem in RIDING_ROUNDS and not spent:
        more_points, more_wedges, more_faces = riding_rounds(
            psk_path, chunks, bones, names, root, points, wedges, faces, extra_slot)
        points, wedges, kept = points + more_points, wedges + more_wedges, kept + more_faces
        full_indices = sorted({f[3] for f in kept})
    # Up to two of the gun's material slots, as mesh sections in ascending
    # slot order (VRReloadCatalog MaterialIndex, then Section1MaterialIndex):
    # the HMTech-301/401 rounds use a different slot from their magazine body.
    material_indices = sorted({f[3] for f in kept})
    if len(material_indices) > 3:
        raise ValueError(f'{names[root]} spans material slots {material_indices}; the runtime draws three at most')
    if material_indices[-1] > extra_slot or (material_indices[-1] == extra_slot
                                              and 'material' not in RIDING_ROUNDS.get(Path(psk_path).stem, {})):
        raise ValueError(f'{names[root]} references missing material slot {material_indices[-1]}')
    material_names = [chunks['MATT0000'].rows[i][:64].split(b'\0', 1)[0].decode('ascii') if i < extra_slot
                      else RIDING_ROUNDS[Path(psk_path).stem]['material'] for i in material_indices]
    positions, rotations = bind_frames(bones)
    return {
        'kind': kind, 'bone': names[root], 'bones': sorted(names[i] for i in keep),
        'full_material_indices': full_indices,
        'points': points, 'wedges': wedges, 'faces': kept, 'mixed_faces': mixed,
        'material_indices': material_indices, 'material_names': material_names,
        'origin': positions[root], 'rotation': rotations[root],
    }


def cut_whole(psk_path):
    """Every face of a one-bone round mesh, in its own frame."""
    from mathutils import Quaternion, Vector
    chunks = read_psk(psk_path)
    points = [struct.unpack('<3f', row) for row in chunks['PNTS0000'].rows]
    wedges = [WEDGE.unpack(row) for row in chunks['VTXW0000'].rows]
    faces = [FACE.unpack(row) for row in chunks['FACE0000'].rows]
    slots = sorted({f[3] for f in faces})
    return {
        'kind': 'round', 'bone': 'Root', 'bones': ['Root'], 'full_material_indices': slots,
        'points': points, 'wedges': wedges, 'faces': faces, 'mixed_faces': 0,
        'material_indices': slots, 'material_names': ['material_%d' % i for i in slots],
        'origin': Vector((0, 0, 0)), 'rotation': Quaternion((1, 0, 0, 0)),
    }


def rig_geometry(psk_path):
    chunks = read_psk(psk_path)
    bones, names = bone_data(chunks)
    points = [struct.unpack('<3f', row) for row in chunks['PNTS0000'].rows]
    wedges = [WEDGE.unpack(row) for row in chunks['VTXW0000'].rows]
    faces = [FACE.unpack(row) for row in chunks['FACE0000'].rows]
    dominant = [(0.0, -1)] * len(points)
    for row in chunks['RAWWEIGHTS'].rows:
        weight, point, bone = WEIGHT.unpack(row)
        if weight > dominant[point][0]:
            dominant[point] = (weight, bone)
    return bones, names, points, wedges, faces, [d[1] for d in dominant]


def subtree(bones, root):
    keep = {root}
    for i in range(root + 1, len(bones)):
        if bones[i][3] in keep:
            keep.add(i)
    return keep


def cut_glow_parts(psk_path):
    """The three hint shells of one magazine rig. Faces are whole: a face belongs
    to a part only when every corner is dominated by that part's bones."""
    stem = Path(psk_path).stem
    bones, names, points, wedges, faces, owner = rig_geometry(psk_path)
    positions, rotations = bind_frames(bones)
    mag_bone = ammo_bone(names, stem)[1]
    magazine = subtree(bones, mag_bone)
    # A gun with no visible action (the Disrupter) gets no slide shell.
    action = subtree(bones, names.index(GLOW_ACTION_BONES[stem])) if GLOW_ACTION_BONES[stem] else set()
    frame = {names.index(n) for n in GLOW_FRAME_BONES if n in names}
    weapon = names.index('RW_Weapon')
    to_weapon = rotations[weapon].conjugated()
    from mathutils import Vector

    def owned(face, bones_set):
        return all(owner[wedges[w][0]] in bones_set for w in face[:3])

    def in_weapon(p):
        return to_weapon @ (Vector(points[p]) - positions[weapon])

    mag_faces = [f for f in faces if owned(f, magazine)]
    mag_points = [in_weapon(wedges[w][0]) for f in mag_faces for w in f[:3]]
    lo = [min(p[i] for p in mag_points) for i in range(3)]
    hi = [max(p[i] for p in mag_points) for i in range(3)]

    def in_well(point):
        return (lo[0] - WELL_MARGIN_ALONG <= point[0] <= hi[0] + WELL_MARGIN_ALONG
                and lo[1] - WELL_MARGIN_ACROSS <= point[1] <= hi[1] + WELL_MARGIN_ACROSS
                and lo[2] - WELL_MARGIN_BELOW <= point[2] <= hi[2] - WELL_TOP_INSET)

    well_faces = [f for f in faces if owned(f, frame) and all(in_well(in_weapon(wedges[w][0])) for w in f[:3])]
    parts = {}
    for kind, part_faces, bone in (('Mag', mag_faces, mag_bone),
                                   ('Slide', [f for f in faces if owned(f, action)],
                                    names.index(GLOW_ACTION_BONES[stem]) if GLOW_ACTION_BONES[stem] else weapon),
                                   ('Well', well_faces, weapon)):
        if kind == 'Slide' and not GLOW_ACTION_BONES[stem]:
            continue
        if kind == 'Well' and stem in NO_WELL_SHELL:
            continue
        if not part_faces:
            raise ValueError(f'{stem} has no {kind} faces for its hint shell')
        parts[kind] = {'kind': kind, 'bone': names[bone], 'points': points, 'wedges': wedges,
                       'faces': part_faces, 'origin': positions[bone], 'rotation': rotations[bone]}
    return parts


def cut_bone_glow(psk_path):
    """The AS2 hint shells cut from named bones (see GLOW_BONE_PARTS)."""
    stem = Path(psk_path).stem
    bones, names, points, wedges, faces, owner = rig_geometry(psk_path)
    positions, rotations = bind_frames(bones)
    weapon = names.index('RW_Weapon')
    to_weapon = rotations[weapon].conjugated()
    from mathutils import Vector

    def forward(p):
        return (to_weapon @ (Vector(points[p]) - positions[weapon])).x

    parts = {}
    for kind, (bone_names, span) in GLOW_BONE_PARTS[stem].items():
        bone_names = (bone_names,) if isinstance(bone_names, str) else bone_names
        bone_name = bone_names[0]
        bone = names.index(bone_name)
        owners = {names.index(n) for n in bone_names}
        part_faces = [f for f in faces if all(owner[wedges[w][0]] in owners for w in f[:3])
                      and (span is None or all(span[0] <= forward(wedges[w][0]) <= span[1] for w in f[:3]))]
        if not part_faces:
            raise ValueError(f'{stem} has no {kind} faces for its hint shell')
        parts[kind] = {'kind': kind, 'bone': bone_name, 'points': points, 'wedges': wedges,
                       'faces': part_faces, 'origin': positions[bone], 'rotation': rotations[bone]}
    return parts


def build_ammo_object(name, cut, shell_offset=0.0):
    """Blender mesh in the bone frame. Like the PSK importer: reversed winding, V flipped.
    A shell offset makes a two-way shell: one copy pushed along the normals and
    one pushed against them, wound the other way round. Whichever way the
    fragment was modelled (the Flare Gun's barrel faces inward), one copy sits
    outside the gun facing out and the other hides inside it. An open fragment's
    signed volume cannot tell which (a magwell's faces are concave)."""
    import bmesh
    import bpy
    inverse = cut['rotation'].conjugated()
    origin = cut['origin']
    from mathutils import Vector
    index_of = {}
    verts = []
    for face in cut['faces']:
        for w in face[:3]:
            p = cut['wedges'][w][0]
            if p not in index_of:
                index_of[p] = len(verts)
                verts.append(inverse @ (Vector(cut['points'][p]) - origin))
    mesh = bpy.data.meshes.new(name)
    obj = bpy.data.objects.new(name, mesh)
    bpy.context.scene.collection.objects.link(obj)
    # One section per source material slot, in ascending slot order; hint
    # shells draw one glow material and stay a single section.
    slots = sorted({f[3] for f in cut['faces']}) if not shell_offset else [None]
    for i in range(len(slots)):
        mesh.materials.append(bpy.data.materials.new(f'AmmoSurface{i}'))
    bm = bmesh.new()
    bm_verts = [bm.verts.new(v) for v in verts]
    uv = bm.loops.layers.uv.new('UVMap')
    for face in cut['faces']:
        order = (face[2], face[1], face[0])
        corners = [bm_verts[index_of[cut['wedges'][w][0]]] for w in order]
        if len(set(corners)) < 3:
            raise ValueError(f'{name} has a degenerate ammunition face; refusing to omit it')
        try:
            f = bm.faces.new(corners)
        except ValueError:
            # A double-sided triangle (the Parasite Implanter's magazine has
            # two): its other side gets its own copies of the same points.
            f = bm.faces.new([bm.verts.new(v.co) for v in corners])
        f.material_index = slots.index(face[3]) if len(slots) > 1 else 0
        for loop, w in zip(f.loops, order):
            loop[uv].uv = (cut['wedges'][w][1], 1.0 - cut['wedges'][w][2])
    for f in bm.faces:
        f.smooth = True
    for e in bm.edges:
        e.smooth = len(e.link_faces) == 2 and e.calc_face_angle(math.pi) < math.radians(35)
    if shell_offset:
        bm.normal_update()
        normals = {v: v.normal.copy() for v in bm.verts}
        inner = bmesh.ops.duplicate(bm, geom=list(bm.verts) + list(bm.edges) + list(bm.faces))
        for v, normal in normals.items():
            v.co += normal * shell_offset
            inner['vert_map'][v].co -= normal * shell_offset
        bmesh.ops.reverse_faces(bm, faces=[f for f in inner['geom'] if isinstance(f, bmesh.types.BMFace)])
    bm.to_mesh(mesh)
    bm.free()
    mesh.update()
    return obj


def build_ring_object(name='VRReloadRing'):
    """Unit annulus facing +X and -X (two opposite-wound layers)."""
    import bmesh
    import bpy
    mesh = bpy.data.meshes.new(name)
    obj = bpy.data.objects.new(name, mesh)
    bpy.context.scene.collection.objects.link(obj)
    mesh.materials.append(bpy.data.materials.new('RingSurface'))
    bm = bmesh.new()
    uv = bm.loops.layers.uv.new('UVMap')
    # bmesh refuses a second face over the same vertices, so each side of the
    # ring gets its own copy of them.
    for side in (1, -1):
        outer, inner = [], []
        for i in range(RING_SEGMENTS):
            a = 2 * math.pi * i / RING_SEGMENTS
            outer.append(bm.verts.new((0.0, RING_OUTER * math.cos(a), RING_OUTER * math.sin(a))))
            inner.append(bm.verts.new((0.0, RING_INNER * math.cos(a), RING_INNER * math.sin(a))))
        for i in range(RING_SEGMENTS):
            j = (i + 1) % RING_SEGMENTS
            quad = [outer[i], outer[j], inner[j], inner[i]]
            f = bm.faces.new(quad if side > 0 else list(reversed(quad)))
            for loop in f.loops:
                loop[uv].uv = (0.5, 0.5)
    bm.to_mesh(mesh)
    bm.free()
    mesh.update()
    return obj


def export_static(obj, fbx_path):
    import bpy
    scene = bpy.context.scene
    scene.unit_settings.system = 'METRIC'
    scene.unit_settings.scale_length = 0.01
    scene.unit_settings.length_unit = 'CENTIMETERS'
    fbx_path.parent.mkdir(parents=True, exist_ok=True)
    # A freshly linked object is not in the view layer until it updates, and
    # use_selection then writes an empty FBX without complaint.
    bpy.context.view_layer.update()
    if obj.name not in bpy.context.view_layer.objects:
        raise RuntimeError(f'{obj.name} is not in the view layer')
    for o in bpy.context.view_layer.objects:
        o.select_set(o == obj)
    bpy.context.view_layer.objects.active = obj
    result = bpy.ops.export_scene.fbx(
        filepath=str(fbx_path), use_selection=True, global_scale=1.0,
        axis_forward='-X', axis_up='Z', apply_unit_scale=True,
        apply_scale_options='FBX_SCALE_UNITS', bake_space_transform=False,
        mesh_smooth_type='EDGE', add_leaf_bones=False, bake_anim=False,
        use_mesh_modifiers=False, object_types={'MESH'})
    if result != {'FINISHED'}:
        raise RuntimeError(f'FBX export failed: {fbx_path}')
    mesh = obj.data
    co = [v.co for v in mesh.vertices]
    return {
        'output_fbx': str(fbx_path),
        'fbx_sha256': sha256(fbx_path),
        'vertices': len(mesh.vertices),
        'triangles': sum(len(p.vertices) - 2 for p in mesh.polygons),
        'bounds_min': [round(min(v[i] for v in co), 3) for i in range(3)],
        'bounds_max': [round(max(v[i] for v in co), 3) for i in range(3)],
    }


def report_is_current(root, out, rigs):
    """Validate the entire requested prop set without Blender or writing assets."""
    try:
        report = json.loads((out / 'VRReloadProps.json').read_text(encoding='utf-8'))
        if report.get('schema') != REPORT_SCHEMA or report.get('generator_sha256') != sha256(__file__):
            return False
        if report.get('psk_reader_sha256') != sha256(root / 'tools/generate_floating_hands.py'):
            return False
        expected = {'VRAmmo_' + rig.stem: rig for rig in rigs}
        for rig in rigs:
            if rig.stem in GLOW_ACTION_BONES:
                for kind in [k for k in (('Mag', 'Slide', 'Well') if GLOW_ACTION_BONES[rig.stem] else ('Mag', 'Well'))
                             if not (k == 'Well' and rig.stem in NO_WELL_SHELL)]:
                    expected['VRGlow' + kind + '_' + rig.stem] = rig
            for kind in GLOW_BONE_PARTS.get(rig.stem, {}):
                expected['VRGlow' + kind + '_' + rig.stem] = rig
        props = report['props']
        # Spent magazines exist only for rigs whose magazine carries rounds;
        # deciding that needs the cut, so any requested rig's may be present.
        optional = {}
        for rig in rigs:
            optional['VRAmmoEmpty_' + rig.stem] = rig
            optional['VRAmmoEmpty1_' + rig.stem] = rig
        if not set(expected) | {'VRReloadRing'} <= set(props) or not set(props) <= set(expected) | set(optional) | {'VRReloadRing'}:
            return False
        expected.update({k: v for k, v in optional.items() if k in props})
        for name, prop in props.items():
            output = out / (name + '.fbx')
            if Path(prop['output_fbx']).resolve() != output.resolve() or prop['fbx_sha256'] != sha256(output):
                return False
            if name in expected:
                rig = expected[name]
                if Path(prop['source_psk']).resolve() != rig.resolve() or prop['source_psk_sha256'] != sha256(rig):
                    return False
        return True
    except (OSError, ValueError, KeyError, TypeError):
        return False


def main():
    parser = argparse.ArgumentParser(description='Generate physical reload prop FBX files.')
    parser.add_argument('rigs', nargs='*')
    parser.add_argument('--out', default='build/hand-meshes')
    parser.add_argument('--check', action='store_true', help='Check all input/output hashes without running Blender.')
    argv = sys.argv[sys.argv.index('--') + 1:] if '--' in sys.argv else (
        sys.argv[1:] if Path(sys.argv[0]).suffix.lower() == '.py' else [])
    args = parser.parse_args(argv)
    root = Path(__file__).resolve().parents[1]
    out = (root / args.out).resolve()
    rigs = [(root / r).resolve() for r in (args.rigs or DEFAULT_RIGS)]
    if len({r.stem.casefold() for r in rigs}) != len(rigs):
        raise ValueError('Requested rigs have duplicate prop names')
    if args.check:
        current = report_is_current(root, out, rigs)
        print('Physical reload props are current.' if current else 'Physical reload prop inputs or outputs need regeneration.')
        return 0 if current else 1
    # Validate every cut before writing any output. An unsupported new rig must
    # not leave a successful-looking partial set of fresh props.
    cuts = [(rig, sha256(rig), cut_ammo(rig)) for rig in rigs]
    spent = []
    for rig, source_hash, cut in cuts:
        # A speedloader that carries its rounds leaves the gun empty.
        if cut['kind'] != 'magazine' and rig.stem not in RIDING_ROUNDS:
            continue
        empty = cut_ammo(rig, spent=True)
        if len(empty['faces']) == len(cut['faces']):
            continue
        if len(empty['material_indices']) != 1:
            raise ValueError(f'{rig.stem} spent magazine spans {empty["material_indices"]}; expected the body slot alone')
        section = cut['material_indices'].index(empty['material_indices'][0])
        spent.append((rig, source_hash, empty, ('VRAmmoEmpty_' if section == 0 else 'VRAmmoEmpty1_') + rig.stem))
    glows = [(rig, sha256(rig), cut_glow_parts(rig)) for rig in rigs if rig.stem in GLOW_ACTION_BONES]
    glows += [(rig, sha256(rig), cut_bone_glow(rig)) for rig in rigs if rig.stem in GLOW_BONE_PARTS]
    import bpy
    bpy.ops.wm.read_factory_settings(use_empty=True)
    report = {'schema': REPORT_SCHEMA, 'generator': 'tools/generate_reload_props.py', 'props': {},
              'generator_sha256': sha256(__file__),
              'psk_reader_sha256': sha256(root / 'tools/generate_floating_hands.py')}
    for rig, source_hash, cut in cuts:
        name = 'VRAmmo_' + rig.stem
        summary = export_static(build_ammo_object(name, cut), out / (name + '.fbx'))
        summary.update({'source_psk': str(rig), 'source_psk_sha256': source_hash,
                        'provenance': 'stock KF2 weapon rig; ammunition faces in the loaded bone reference frame',
                        'kind': cut['kind'], 'bone': cut['bone'],
                        'bones': cut['bones'], 'mixed_faces_dropped': cut['mixed_faces'],
                        'material_indices': cut['material_indices'], 'material_names': cut['material_names']})
        report['props'][name] = summary
        print(f"{name}: {cut['kind']} {cut['bone']} {summary['triangles']} tris "
              f"bounds {summary['bounds_min']}..{summary['bounds_max']}")
    for rig, source_hash, cut, name in spent:
        summary = export_static(build_ammo_object(name, cut), out / (name + '.fbx'))
        summary.update({'source_psk': str(rig), 'source_psk_sha256': source_hash,
                        'provenance': 'stock KF2 weapon rig; magazine without its rounds, in the loaded bone frame',
                        'kind': 'spent-magazine', 'bone': cut['bone'],
                        'material_indices': cut['material_indices']})
        report['props'][name] = summary
        print(f"{name}: spent {cut['bone']} {summary['triangles']} tris")
    for rig, source_hash, parts in glows:
        for kind, cut in parts.items():
            name = 'VRGlow' + kind + '_' + rig.stem
            summary = export_static(build_ammo_object(name, cut, SHELL_OFFSET), out / (name + '.fbx'))
            summary.update({'source_psk': str(rig), 'source_psk_sha256': source_hash,
                            'provenance': 'stock KF2 weapon rig; reload-hint shell in the ' + cut['bone'] + ' reference frame',
                            'kind': 'glow-' + kind.lower(), 'bone': cut['bone'], 'shell_offset': SHELL_OFFSET})
            report['props'][name] = summary
            print(f"{name}: {cut['bone']} {summary['triangles']} tris "
                  f"bounds {summary['bounds_min']}..{summary['bounds_max']}")
    report['props']['VRReloadRing'] = export_static(build_ring_object(), out / 'VRReloadRing.fbx')
    # A report is the completeness receipt. Publish it only after all props and
    # the original ring have exported; a partial run cannot certify the set.
    report_path = out / 'VRReloadProps.json'
    pending_report = report_path.with_suffix('.json.tmp')
    pending_report.write_text(json.dumps(report, indent=2), encoding='utf-8')
    pending_report.replace(report_path)
    return 0


if __name__ == '__main__':
    result = main()
    # Blender owns the successful script lifecycle. Let it shut down normally
    # instead of raising SystemExit into its --python-exit-code wrapper.
    if result:
        raise SystemExit(result)
