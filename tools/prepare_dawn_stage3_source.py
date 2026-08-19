"""Prepare an isolated, minimal DAWN source derivative for stage 3 testing."""

from __future__ import annotations

import argparse
import shutil
from pathlib import Path


RECALL_BLOCK = """# Unified cross-source recall tool — aggregates the focus adapters
# (memory/notes/documents/calendar) via focus_compose_ex.  Always compiled;
# recall_is_available() gates at runtime on the embedding engine.
list(APPEND TOOL_SOURCES
    src/tools/recall_tool.c
    src/tools/recall_format.c)
message(STATUS "DAWN: Recall tool ENABLED")
"""

RECALL_GATE = """# Unified cross-source recall tool — aggregates the focus adapters
# (memory/notes/documents/calendar) via focus_compose_ex.
option(DAWN_ENABLE_RECALL_TOOL "Enable unified cross-source recall tool" ON)
if(DAWN_ENABLE_RECALL_TOOL)
    add_definitions(-DDAWN_ENABLE_RECALL_TOOL)
    list(APPEND TOOL_SOURCES
        src/tools/recall_tool.c
        src/tools/recall_format.c)
    message(STATUS "DAWN: Recall tool ENABLED")
else()
    message(STATUS "DAWN: Recall tool DISABLED")
endif()
"""


def _ignore_archive_residue(_: str, names: list[str]) -> set[str]:
    ignored: set[str] = set()
    for name in names:
        if (
            name == ".claude"
            or name in {"131", "The"}
            or name.startswith("secrets.toml")
            or ".before-" in name
            or name.endswith(".orig")
            or ".poc-pass-" in name
            or name.startswith("apply_dawn_acoustic_history_handoff")
            or name.startswith("create_dawn_known_good_backup")
            or name.startswith("dawn_wake_probe")
            or name.startswith("dawn_wakeword")
        ):
            ignored.add(name)
    return ignored


def gate_recall_tool(source_root: Path) -> None:
    tools_cmake = source_root / "cmake" / "DawnTools.cmake"
    text = tools_cmake.read_text(encoding="utf-8")
    if RECALL_GATE in text:
        return
    if RECALL_BLOCK not in text:
        raise ValueError(
            f"unexpected Recall block in {tools_cmake}; refusing to patch it"
        )
    tools_cmake.write_text(text.replace(RECALL_BLOCK, RECALL_GATE), encoding="utf-8")


def prepare_source(reference: Path, destination: Path) -> None:
    if not reference.is_dir():
        raise ValueError(f"reference source does not exist: {reference}")
    if destination.exists():
        raise FileExistsError(f"destination already exists: {destination}")

    shutil.copytree(reference, destination, ignore=_ignore_archive_residue)
    gate_recall_tool(destination)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Create a minimal stage-3 DAWN test source from the archive."
    )
    parser.add_argument("--reference", type=Path, required=True)
    parser.add_argument("--destination", type=Path, required=True)
    return parser.parse_args()


def main() -> None:
    args = parse_args()
    prepare_source(args.reference, args.destination)
    print(f"Prepared minimal DAWN stage-3 source: {args.destination}")


if __name__ == "__main__":
    main()
