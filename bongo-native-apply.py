from __future__ import annotations

import argparse
import copy
import hashlib
import json
import os
import pathlib
import shutil
import struct
import sys
from dataclasses import dataclass
from typing import Any


GAME_VERSION = "6000.3.0f1"


@dataclass(frozen=True)
class Slot:
    group: str
    type_id: int
    proxy_id: int
    required: bool = False


SLOTS = (
    Slot("Corpo", 100, 200, True),
    Slot("Partes íntimas", 101, 400, True),
    # O jogo não oferece um item gratuito desta categoria. O ID 1004 é um
    # cabelo já presente no inventário local e funciona como slot visual
    # reservado; o identificador e o inventário dele não são alterados.
    Slot("Pelos, genitais e marcas", 102, 1004),
    Slot("Cabelos", 1, 1002),
    Slot("Peças de cima", 3, 3006),
    Slot("Saias", 4, 4106),
    Slot("Sutiãs e biquínis", 5, 5109),
    Slot("Meias", 8, 8000),
    Slot("Calçados", 9, 9209),
    Slot("Brinquedos", 0, 1, True),
)

# Campos que determinam a aparência e o posicionamento, sem copiar campos de
# desbloqueio/DLC para o slot-proxy.
VISUAL_FIELDS = (
    "type",
    "skinName",
    "texture",
    "icon",
    "overrideDickBottomPos",
    "dickBottomOverrideLocalPos",
)
IDENTITY_FIELDS = (
    "name",
    "isNeedUnlock",
    "achievement",
    "creatorPageUnlock",
    "dlcType",
)


def arguments() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Aplicador visual nativo do Bongo Waifu")
    parser.add_argument("action", choices=("build", "inspect"))
    parser.add_argument("--asset", required=True)
    parser.add_argument("--output")
    parser.add_argument("--selection", help="JSON com IDs por grupo")
    parser.add_argument("--manifest")
    parser.add_argument("--unitypy", required=True)
    parser.add_argument("--managed", required=True)
    parser.add_argument("--assembly")
    parser.add_argument("--assembly-output")
    parser.add_argument("--dncil")
    return parser.parse_args()


def sha256_file(path: pathlib.Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def load_unitypy(module_root: pathlib.Path):
    sys.path.insert(0, str(module_root))
    import UnityPy  # type: ignore
    from UnityPy.helpers.TypeTreeGenerator import TypeTreeGenerator  # type: ignore

    return UnityPy, TypeTreeGenerator


def locate_setting(
    asset: pathlib.Path,
    unitypy_root: pathlib.Path,
    managed_root: pathlib.Path,
):
    unitypy, generator_type = load_unitypy(unitypy_root)
    global_managers = managed_root.parent / "globalgamemanagers.assets"
    if not global_managers.is_file():
        raise RuntimeError(f"globalgamemanagers.assets não encontrado em {global_managers}")
    environment = unitypy.load(str(asset), str(global_managers))
    generator = generator_type(GAME_VERSION)
    generator.load_local_dll_folder(str(managed_root))
    environment.typetree_generator = generator
    for obj in environment.objects:
        if obj.type.name != "MonoBehaviour":
            continue
        try:
            head = obj.parse_monobehaviour_head()
            script = head.m_Script.read()
        except Exception:
            continue
        if str(getattr(script, "m_ClassName", "")) == "SpineSkinSetting":
            node = obj.generate_monobehaviour_node()
            return environment, obj, node, obj.read_typetree(nodes=node)
    raise RuntimeError("SpineSkinSetting não foi encontrado no asset informado.")


def item_index(tree: dict[str, Any]) -> dict[int, tuple[str, int, dict[str, Any]]]:
    result: dict[int, tuple[str, int, dict[str, Any]]] = {}
    for list_name in ("SpineSkinDatas", "CollabSkinDatas"):
        for index, item in enumerate(tree.get(list_name, [])):
            item_id = int(item["name"])
            if item_id in result:
                raise RuntimeError(f"ID visual duplicado no asset: {item_id}")
            result[item_id] = (list_name, index, item)
    return result


def read_selection(path: pathlib.Path) -> dict[str, int]:
    payload = json.loads(path.read_text(encoding="utf-8-sig"))
    if not isinstance(payload, dict):
        raise RuntimeError("A seleção precisa ser um objeto JSON.")
    allowed = {slot.group for slot in SLOTS}
    unknown = sorted(set(map(str, payload)) - allowed)
    if unknown:
        raise RuntimeError(f"Grupos desconhecidos: {', '.join(unknown)}")
    selection: dict[str, int] = {}
    for slot in SLOTS:
        raw = payload.get(slot.group, 0)
        if isinstance(raw, bool):
            raise RuntimeError(f"ID inválido em {slot.group}.")
        try:
            target_id = int(raw or 0)
        except (TypeError, ValueError) as error:
            raise RuntimeError(f"ID inválido em {slot.group}.") from error
        if target_id < 0:
            raise RuntimeError(f"ID inválido em {slot.group}.")
        if slot.required and target_id == 0:
            raise RuntimeError(f"O grupo obrigatório {slot.group} não pode ficar vazio.")
        selection[slot.group] = target_id
    return selection


def validate_and_snapshot(
    tree: dict[str, Any], selection: dict[str, int]
) -> tuple[dict[int, tuple[str, int, dict[str, Any]]], dict[str, dict[str, Any]]]:
    indexed = item_index(tree)
    snapshots: dict[str, dict[str, Any]] = {}
    for slot in SLOTS:
        target_id = selection[slot.group]
        if target_id == 0:
            continue
        if target_id not in indexed:
            raise RuntimeError(f"O ID {target_id} de {slot.group} não existe nesta versão do jogo.")
        target = indexed[target_id][2]
        if int(target["type"]) != slot.type_id:
            raise RuntimeError(
                f"O ID {target_id} não pertence a {slot.group} "
                f"(tipo {target['type']}, esperado {slot.type_id})."
            )
        if slot.proxy_id not in indexed:
            raise RuntimeError(f"O slot-proxy {slot.proxy_id} de {slot.group} não existe.")
        snapshots[slot.group] = {
            "target_id": target_id,
            "proxy_id": slot.proxy_id,
            "visual": {field: copy.deepcopy(target[field]) for field in VISUAL_FIELDS},
            "proxy_identity": {
                field: copy.deepcopy(indexed[slot.proxy_id][2][field]) for field in IDENTITY_FIELDS
            },
        }
    return indexed, snapshots


def patch_tree(
    tree: dict[str, Any], selection: dict[str, int]
) -> tuple[list[dict[str, Any]], dict[str, dict[str, Any]]]:
    indexed, snapshots = validate_and_snapshot(tree, selection)
    changes: list[dict[str, Any]] = []
    for slot in SLOTS:
        snapshot = snapshots.get(slot.group)
        if snapshot is None:
            continue
        proxy = indexed[slot.proxy_id][2]
        changed_fields: list[str] = []
        for field, value in snapshot["visual"].items():
            if proxy[field] != value:
                changed_fields.append(field)
                proxy[field] = copy.deepcopy(value)
        changes.append(
            {
                "group": slot.group,
                "proxy_id": slot.proxy_id,
                "target_id": snapshot["target_id"],
                "changed_fields": changed_fields,
            }
        )
    return changes, snapshots


def verify_expected(
    asset: pathlib.Path,
    unitypy_root: pathlib.Path,
    managed_root: pathlib.Path,
    expected: dict[str, dict[str, Any]],
) -> dict[str, Any]:
    _, obj, _, tree = locate_setting(asset, unitypy_root, managed_root)
    indexed = item_index(tree)
    checks: list[dict[str, Any]] = []
    for group, snapshot in expected.items():
        proxy = indexed[int(snapshot["proxy_id"])][2]
        visual_ok = all(proxy[field] == value for field, value in snapshot["visual"].items())
        identity_ok = all(
            proxy[field] == value for field, value in snapshot["proxy_identity"].items()
        )
        checks.append(
            {
                "group": group,
                "proxy_id": snapshot["proxy_id"],
                "target_id": snapshot["target_id"],
                "visual_ok": visual_ok,
                "identity_ok": identity_ok,
            }
        )
    return {
        "asset": str(asset),
        "sha256": sha256_file(asset),
        "setting_path_id": obj.path_id,
        "setting_byte_start": obj.byte_start,
        "setting_byte_size": obj.byte_size,
        "checks": checks,
        "verified": bool(checks) and all(
            check["visual_ok"] and check["identity_ok"] for check in checks
        ),
    }


def inspect_asset(
    asset: pathlib.Path, unitypy_root: pathlib.Path, managed_root: pathlib.Path
) -> dict[str, Any]:
    _, obj, _, tree = locate_setting(asset, unitypy_root, managed_root)
    indexed = item_index(tree)
    counts: dict[str, int] = {}
    for _, _, item in indexed.values():
        key = str(item["type"])
        counts[key] = counts.get(key, 0) + 1
    return {
        "asset": str(asset),
        "sha256": sha256_file(asset),
        "setting_path_id": obj.path_id,
        "setting_byte_start": obj.byte_start,
        "setting_byte_size": obj.byte_size,
        "item_count": len(indexed),
        "type_counts": counts,
        "proxies": {slot.group: slot.proxy_id for slot in SLOTS},
    }


def runtime_operands(
    assembly: pathlib.Path, unitypy_root: pathlib.Path, dncil_root: pathlib.Path
) -> tuple[list[dict[str, int]], Any]:
    sys.path[:0] = [str(unitypy_root), str(dncil_root)]
    import dnfile  # type: ignore
    from dncil.cil.body.reader import read_method_body_from_bytes  # type: ignore

    pe = dnfile.dnPE(str(assembly))
    method = None
    for typedef in pe.net.mdtables.TypeDef:
        if str(typedef.TypeName) != "bd":
            continue
        for method_ref in typedef.MethodList:
            if str(method_ref.row.Name) == "qx":
                method = method_ref.row
                break
    if method is None or not int(method.Rva or 0):
        raise RuntimeError("O método nativo bd::qx não foi encontrado em Assembly-CSharp.dll.")
    method_rva = int(method.Rva)
    method_file_offset = int(pe.get_offset_from_rva(method_rva))
    body = read_method_body_from_bytes(pe.get_data(method_rva, 65536))
    matches: list[dict[str, int]] = []
    for instruction in body.instructions:
        if instruction.mnemonic != "ldc.i4" or instruction.operand not in (600, 601):
            continue
        operand_offset = (
            method_file_offset
            + int(instruction.offset)
            + len(instruction.opcode_bytes)
        )
        matches.append(
            {
                "value": int(instruction.operand),
                "file_offset": operand_offset,
                "method_offset": int(instruction.offset),
            }
        )
    values = [entry["value"] for entry in matches]
    if values != [600, 601]:
        raise RuntimeError(
            f"A assinatura visual de bd::qx mudou (encontrado {values}, esperado [600, 601])."
        )
    return matches, pe


def build_runtime(
    assembly: pathlib.Path,
    output: pathlib.Path,
    pubic_target_id: int,
    pubic_proxy_id: int,
    unitypy_root: pathlib.Path,
    dncil_root: pathlib.Path,
) -> dict[str, Any]:
    matches, _ = runtime_operands(assembly, unitypy_root, dncil_root)
    replacement = pubic_proxy_id if pubic_target_id in (600, 601) else None
    output.parent.mkdir(parents=True, exist_ok=True)
    temporary = output.with_name(f".{output.name}.{os.getpid()}.tmp")
    try:
        shutil.copy2(assembly, temporary)
        if replacement is not None:
            with temporary.open("r+b") as stream:
                for entry in matches:
                    stream.seek(entry["file_offset"])
                    found = stream.read(4)
                    expected = struct.pack("<i", entry["value"])
                    if found != expected:
                        raise RuntimeError(
                            f"O operando IL em 0x{entry['file_offset']:X} não corresponde à fonte."
                        )
                    stream.seek(entry["file_offset"])
                    stream.write(struct.pack("<i", replacement))
                stream.flush()
                os.fsync(stream.fileno())
        os.replace(temporary, output)
    finally:
        if temporary.exists():
            temporary.unlink()

    if replacement is None:
        verified_values = [entry["value"] for entry in runtime_operands(output, unitypy_root, dncil_root)[0]]
    else:
        # O leitor de assinatura procura 600/601; para a versão remapeada,
        # verificamos diretamente os dois operandos nos offsets já validados.
        with output.open("rb") as stream:
            verified_values = []
            for entry in matches:
                stream.seek(entry["file_offset"])
                verified_values.append(struct.unpack("<i", stream.read(4))[0])
    expected_values = [600, 601] if replacement is None else [replacement, replacement]
    if verified_values != expected_values:
        raise RuntimeError(
            f"A verificação do ajuste nativo falhou ({verified_values} != {expected_values})."
        )
    return {
        "source_assembly": str(assembly),
        "output_assembly": str(output),
        "source_sha256": sha256_file(assembly),
        "patched_sha256": sha256_file(output),
        "pubic_target_id": pubic_target_id,
        "futa_position_proxy_id": replacement,
        "operand_offsets": [entry["file_offset"] for entry in matches],
        "operand_values": verified_values,
        "verified": True,
    }


def build(
    asset: pathlib.Path,
    output: pathlib.Path,
    selection_path: pathlib.Path,
    manifest_path: pathlib.Path | None,
    unitypy_root: pathlib.Path,
    managed_root: pathlib.Path,
    assembly: pathlib.Path | None = None,
    assembly_output: pathlib.Path | None = None,
    dncil_root: pathlib.Path | None = None,
) -> dict[str, Any]:
    if asset.resolve() == output.resolve():
        raise RuntimeError("O arquivo de saída não pode sobrescrever diretamente a fonte.")
    selection = read_selection(selection_path)
    _, obj, node, tree = locate_setting(asset, unitypy_root, managed_root)
    original_raw = obj.get_raw_data()
    changes, expected = patch_tree(tree, selection)
    patched_raw = obj.save_typetree(tree, nodes=node)
    if len(original_raw) != len(patched_raw) or len(original_raw) != obj.byte_size:
        raise RuntimeError(
            f"O bloco serializado mudou de tamanho ({len(original_raw)} -> "
            f"{len(patched_raw)}); operação cancelada."
        )

    output.parent.mkdir(parents=True, exist_ok=True)
    temporary = output.with_name(f".{output.name}.{os.getpid()}.tmp")
    try:
        shutil.copy2(asset, temporary)
        with temporary.open("r+b") as stream:
            stream.seek(obj.byte_start)
            if stream.read(obj.byte_size) != original_raw:
                raise RuntimeError("Os bytes no offset calculado não correspondem ao objeto lido.")
            stream.seek(obj.byte_start)
            stream.write(patched_raw)
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temporary, output)
    finally:
        if temporary.exists():
            temporary.unlink()

    verification = verify_expected(output, unitypy_root, managed_root, expected)
    if not verification["verified"]:
        raise RuntimeError("A verificação estrutural do asset gerado falhou.")
    result = {
        "format": "bongo-waifu-native-look-v2",
        "source_asset": str(asset),
        "output_asset": str(output),
        "source_sha256": sha256_file(asset),
        "patched_sha256": verification["sha256"],
        "setting_path_id": obj.path_id,
        "setting_byte_start": obj.byte_start,
        "setting_byte_size": obj.byte_size,
        "selection": selection,
        "proxy_ids": {slot.group: slot.proxy_id for slot in SLOTS},
        "changes": changes,
        "verified": True,
    }
    runtime_args = (assembly, assembly_output, dncil_root)
    if any(value is not None for value in runtime_args):
        if not all(value is not None for value in runtime_args):
            raise RuntimeError("--assembly, --assembly-output e --dncil precisam ser usados juntos.")
        result["runtime"] = build_runtime(
            assembly,
            assembly_output,
            selection["Pelos, genitais e marcas"],
            next(slot.proxy_id for slot in SLOTS if slot.group == "Pelos, genitais e marcas"),
            unitypy_root,
            dncil_root,
        )
    if manifest_path:
        manifest_path.parent.mkdir(parents=True, exist_ok=True)
        manifest_path.write_text(
            json.dumps(result, ensure_ascii=False, indent=2), encoding="utf-8"
        )
    return result


def main() -> int:
    args = arguments()
    asset = pathlib.Path(args.asset).resolve()
    unitypy_root = pathlib.Path(args.unitypy).resolve()
    managed_root = pathlib.Path(args.managed).resolve()
    if args.action == "inspect":
        result = inspect_asset(asset, unitypy_root, managed_root)
    else:
        if not args.output or not args.selection:
            raise RuntimeError("--output e --selection são obrigatórios para build.")
        manifest = pathlib.Path(args.manifest).resolve() if args.manifest else None
        result = build(
            asset,
            pathlib.Path(args.output).resolve(),
            pathlib.Path(args.selection).resolve(),
            manifest,
            unitypy_root,
            managed_root,
            pathlib.Path(args.assembly).resolve() if args.assembly else None,
            pathlib.Path(args.assembly_output).resolve() if args.assembly_output else None,
            pathlib.Path(args.dncil).resolve() if args.dncil else None,
        )
    print(json.dumps(result, ensure_ascii=False, indent=2))
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except Exception as error:
        print(str(error), file=sys.stderr)
        raise SystemExit(1)
