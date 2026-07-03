#!/usr/bin/env python3
import argparse
import json
from pathlib import Path


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--model-json", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--qemu-src", type=Path, required=True)
    parser.add_argument("--library-path", type=Path, required=True)
    return parser.parse_args()


def load_helper_names(model_json: Path) -> list[str]:
    model = json.loads(model_json.read_text(encoding="utf-8"))
    helpers = model.get("helper_defs")
    if not isinstance(helpers, list):
        return []
    names: list[str] = []
    for helper in helpers:
        if not isinstance(helper, dict):
            continue
        raw_name = helper.get("name")
        if not isinstance(raw_name, str) or not raw_name:
            continue
        name = raw_name.removeprefix("helper_")
        if name and name not in names:
            names.append(name)
    return names


def render_helpers(helper_names: list[str], *, qemu_src: Path, library_path: Path) -> str:
    lines = [
        "; ModuleID = 'qemu-v2-libtinycode-helpers'",
        'source_filename = "qemu-v2-libtinycode-helpers"',
        f"; qemu_src = {qemu_src}",
        f"; library_path = {library_path}",
        "; provenance = generated-by-qemu_v2_generate_libtinycode_helpers.py",
        "",
    ]
    if not helper_names:
        lines.extend(
            [
                "; No helper definitions were required by the captured scalar payload.",
                "define void @__qemu_v2_libtinycode_no_helpers_required() {",
                "entry:",
                "  ret void",
                "}",
                "",
            ]
        )
        return "\n".join(lines)
    for name in helper_names:
        safe = "".join(ch if ch.isalnum() or ch == "_" else "_" for ch in name)
        lines.extend(
            [
                f"; helper = {name}",
                f"declare void @{safe}()",
                "",
            ]
        )
    return "\n".join(lines)


def main() -> int:
    args = parse_args()
    helper_names = load_helper_names(args.model_json)
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(
        render_helpers(helper_names, qemu_src=args.qemu_src, library_path=args.library_path),
        encoding="utf-8",
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
