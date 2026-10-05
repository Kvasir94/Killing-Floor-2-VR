"""Read installed KF2 avatar controls and 9mm sockets without running the SDK.

Print JSON to stdout. No game/SDK processes, asset exports or file writes.
Reports serialized properties, not inherited defaults or evaluated bone poses.
Uses the project's existing reader for the installed uncompressed KF2 packages.
"""
from pathlib import Path
import argparse
import hashlib
import json
import struct
import sys

sys.path.insert(0, str(Path(__file__).resolve().parents[2]))
from tools.audit_source_assets import read_package, properties
from tools.ue3.upkg import Reader


def inspect(path, include_animation_graph=False):
    data, names, imports, objects = read_package(path)
    tree_indices = {i for i, obj in enumerate(objects, 1)
                    if obj["cls"] == "AnimTree" and obj["name"] == "CHR_Human_AnimTree"}

    def reference(index):
        if index == 0:
            return "None"
        obj = imports[-index - 1] if index < 0 else objects[index - 1]
        prefix = reference(obj["outer"]) + "." if obj["outer"] else ""
        return prefix + obj["name"]

    def decode(field):
        kind, raw = field["kind"], field["value"]
        if kind in ("NameProperty", "ByteProperty") and len(raw) == 8:
            return Reader(raw).fname(names)
        if kind == "StrProperty":
            return Reader(raw).fstring()
        if kind == "ObjectProperty":
            return reference(struct.unpack("<i", raw)[0])
        if kind == "IntProperty":
            return struct.unpack("<i", raw)[0]
        if kind == "FloatProperty":
            return struct.unpack("<f", raw)[0]
        if kind == "BoolProperty":
            return field["extra"]
        if kind == "StructProperty" and field["extra"] == "Vector":
            return struct.unpack("<3f", raw)
        if kind == "StructProperty" and field["extra"] == "Rotator":
            return struct.unpack("<3i", raw)
        if kind == "StructProperty" and field["extra"] == "Vector2D":
            return struct.unpack("<2f", raw)
        return {"type": kind, "struct": field["extra"], "hex": raw.hex()}

    def tagged_array(raw):
        reader = Reader(raw)
        count = reader.i32()
        assert 0 <= count <= 1024, "Unexpected tagged array size"
        entries = []
        for _ in range(count):
            entry, size = properties(raw[reader.p:], names)
            reader.p += size
            entries.append(entry)
        assert reader.p == len(raw), "Incomplete tagged-array decode"
        return entries

    def graph_field(key, field):
        if key == "Profiles":
            return [{"ProfileName": decode(entry["ProfileName"])}
                    for entry in tagged_array(field["value"])]
        if key in ("Children", "MaskList", "BranchList", "WeightRuleList", "AnimGroups"):
            return [{k: graph_field(k, v) for k, v in entry.items()
                     if k not in ("DrawY", "PerBoneWeights", "TransformReqBone")}
                    for entry in tagged_array(field["value"])]
        if key in ("FirstNode", "SecondNode"):
            entry, size = properties(field["value"], names)
            assert size == len(field["value"])
            return {k: decode(v) for k, v in entry.items()}
        return decode(field)

    selected = []
    for index, obj in enumerate(objects, 1):
        cls = obj["cls"]
        graph_node = (include_animation_graph and obj["outer"] in tree_indices
                      and "Anim" in cls and cls != "AnimNodeFrame")
        if not graph_node and cls not in ("AnimTree", "KFCharacterInfo_Human", "SkeletalMeshSocket") and "SkelControl" not in cls:
            continue
        fields, _ = properties(data[obj["offset"] + 4:obj["offset"] + obj["size"]], names)
        if graph_node:
            keys = {"NodeName", "Children", "MaskList", "RotationBlendType", "BlendType",
                    "PropertyName", "BlendTime", "AnimSeqName", "SynchGroupName", "Rate",
                    "BaseSpeed", "TransitionThresholdAngle", "Profiles", "RootRotationOption",
                    "bForceLocalSpaceBlend", "IgnoreAtOrAboveLOD"}
            decoded = {k: graph_field(k, v) for k, v in fields.items() if k in keys}
        elif cls == "AnimTree":
            if obj["name"] != "CHR_Human_AnimTree":
                continue
            raw = fields["SkelControlLists"]["value"]
            reader = Reader(raw)
            count = reader.i32()
            assert 0 <= count <= 128, "Unexpected number of control chains"
            chains = []
            for _ in range(count):
                entry, size = properties(raw[reader.p:], names)
                reader.p += size
                chains.append({key: decode(value) for key, value in entry.items() if key != "DrawY"})
            assert reader.p == len(raw), "Incomplete control-list decode"
            decoded = {"SkelControlLists": chains}
            if include_animation_graph:
                decoded.update({k: graph_field(k, fields[k]) for k in ("Children", "AnimGroups") if k in fields})
        elif cls == "KFCharacterInfo_Human":
            decoded = {key: decode(value) for key, value in fields.items() if key == "AnimTreeTemplate"}
            if not decoded:
                continue
        else:
            decoded = {key: decode(value) for key, value in fields.items()
                       if key not in ("DrawWidth", "NodePosX", "NodePosY", "TargetLocation")}
        selected.append({"export_index": index, "object": reference(index), "class": cls,
                         "serialized_properties": decoded})
    return {"path": str(path), "sha256": hashlib.sha256(data).hexdigest(),
            "export_count": len(objects), "selected_objects": selected}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--packages", type=Path,
                        default=Path("D:/SteamLibrary/steamapps/common/killingfloor2/KFGame/BrewedPC/Packages"))
    parser.add_argument("--animation-graph", action="store_true",
                        help="Also report the human tree's blend nodes, masks, slots and profile names.")
    args = parser.parse_args()
    paths = ("Characters/BaseMale/CHR_BaseMale_ARCH.upk",
             "Characters/CHR_Playable_ARCH.upk", "Weapons/9mm/WEP_3P_9MM_MESH.upk")
    packages = [inspect(args.packages / path, args.animation_graph) for path in paths]
    tree = next(obj for obj in packages[0]["selected_objects"] if obj["class"] == "AnimTree")
    characters = packages[1]["selected_objects"]
    summary = {"human_tree": tree["object"],
               "control_bones": [item["BoneName"] for item in tree["serialized_properties"]["SkelControlLists"]],
               "character_info_entries": len(characters),
               "character_tree_references": sorted({obj["serialized_properties"]["AnimTreeTemplate"] for obj in characters}),
               "weapon_sockets": [obj["serialized_properties"].get("SocketName") for obj in packages[2]["selected_objects"]]}
    if args.animation_graph:
        graph_nodes = [obj for obj in packages[0]["selected_objects"]
                       if "Anim" in obj["class"] and obj["class"] != "AnimTree"]
        summary["animation_node_counts"] = {cls: sum(obj["class"] == cls for obj in graph_nodes)
                                             for cls in sorted({obj["class"] for obj in graph_nodes})}
        summary["action_slots"] = [obj["serialized_properties"].get("NodeName") for obj in graph_nodes
                                    if obj["class"] == "AnimNodeSlot"]
        # The graph receipt needs only the human tree package, not another copy
        # of the 111 character mappings and weapon sockets in the asset receipt.
        packages = packages[:1]
    print(json.dumps({"scope": "Offline serialized asset metadata only; no runtime or visual acceptance.",
                      "limitations": "Selected serialized properties only; absence from this filtered report does not establish an inherited/default value. No bone hierarchy, grip fit, live control insertion or final animation evaluation is measured.",
                      "audit_script_sha256": hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),
                      "summary": summary, "packages": packages}, indent=2))


if __name__ == "__main__":
    main()
