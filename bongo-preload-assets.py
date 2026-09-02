"""Pre-extract full item texture pages so the preview never reloads Unity assets per click."""

from __future__ import annotations

import argparse
import json
import pathlib

import UnityPy  # noqa: E402


SUPPORTED_TYPES = {
    "Dick",
    "SkinTone",
    "IntimateParts",
    "PubicAndGenital",
    "Hair",
    "Top",
    "Bottom",
    "Underwear",
    "Socks",
    "Shoes",
}
ICON_TYPES = {"Dick", "IntimateParts", "PubicAndGenital"}
PACKAGE_ROOT = pathlib.Path(__file__).resolve().parent
MAPPING_PATH = PACKAGE_ROOT / "runtime" / "bongo-spine-skin-mapping.json"


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--game-data", required=True)
    parser.add_argument("--output", required=True)
    parser.add_argument("--icon-output", required=True)
    parser.add_argument("--ids", help="IDs separados por vírgula para teste")
    parser.add_argument("--force", action="store_true")
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    game_data = pathlib.Path(args.game_data).resolve()
    source = game_data / "sharedassets0.assets"
    if not source.is_file():
        raise RuntimeError(f"Assets do jogo não encontrados: {source}")

    output = pathlib.Path(args.output).resolve()
    icon_output = pathlib.Path(args.icon_output).resolve()
    output.mkdir(parents=True, exist_ok=True)
    icon_output.mkdir(parents=True, exist_ok=True)
    marker_path = output / "preload-manifest.json"

    mapping = json.loads(MAPPING_PATH.read_text(encoding="utf-8"))
    supported = [entry for entry in mapping if entry.get("type") in SUPPORTED_TYPES]
    if args.ids:
        wanted = {int(value) for value in args.ids.split(",") if value.strip()}
        supported = [entry for entry in supported if entry["id"] in wanted]
    supported.sort(key=lambda entry: entry["id"])
    selected = [entry for entry in supported if entry.get("texture_path_id")]
    icon_entries = [entry for entry in supported if entry["type"] in ICON_TYPES and entry.get("icon_path_id")]

    source_stat = source.stat()
    signature = {
        "source": str(source),
        "source_size": source_stat.st_size,
        "source_mtime_ns": source_stat.st_mtime_ns,
        "texture_ids": [entry["id"] for entry in selected],
        "icon_ids": [entry["id"] for entry in icon_entries],
        "format": "png-v2-all-game-categories",
    }
    missing = [entry for entry in selected if not (output / f"{entry['id']}.png").is_file()]
    missing_icons = [
        entry for entry in icon_entries
        if not (icon_output / f"{entry['id']}.png").is_file()
    ]
    signature_matches = False
    if marker_path.is_file():
        try:
            signature_matches = json.loads(marker_path.read_text(encoding="utf-8")) == signature
        except Exception:
            pass
    if not args.force and signature_matches and not missing and not missing_icons:
        print(json.dumps({"ready": True, "cached": True, "textures": len(selected), "icons": len(icon_entries)}))
        return 0

    refresh_all = args.force or not signature_matches

    environment = UnityPy.load(str(source))
    objects = {obj.path_id: obj for obj in environment.objects}
    total = len(selected)
    for index, entry in enumerate(selected, start=1):
        texture_path = output / f"{entry['id']}.png"
        if refresh_all or not texture_path.is_file():
            texture_object = objects.get(entry["texture_path_id"])
            if texture_object is None:
                raise RuntimeError(f"Textura ausente para o ID {entry['id']}")
            image = texture_object.read().image.convert("RGBA")
            image.save(texture_path, "PNG", compress_level=1)

        if index % 25 == 0 or index == total:
            print(f"PRELOAD\t{index}\t{total}", flush=True)

    for entry in icon_entries:
        icon_path = icon_output / f"{entry['id']}.png"
        if refresh_all or not icon_path.is_file():
            icon_object = objects.get(entry["icon_path_id"])
            if icon_object is None:
                raise RuntimeError(f"Ícone ausente para o item {entry['id']}")
            icon_object.read().image.convert("RGBA").save(icon_path, "PNG")

    marker_path.write_text(json.dumps(signature, ensure_ascii=False, indent=2), encoding="utf-8")
    print(json.dumps({"ready": True, "cached": False, "textures": total, "icons": len(icon_entries)}))
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except Exception as error:
        print(str(error), file=sys.stderr)
        raise SystemExit(1)
