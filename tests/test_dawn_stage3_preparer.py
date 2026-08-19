import sys
from pathlib import Path

import pytest


ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))

from tools.prepare_dawn_stage3_source import (  # noqa: E402
    RECALL_BLOCK,
    RECALL_GATE,
    prepare_source,
)


def test_prepare_source_copies_and_gates_recall(tmp_path: Path) -> None:
    reference = tmp_path / "reference"
    tools_cmake = reference / "cmake" / "DawnTools.cmake"
    tools_cmake.parent.mkdir(parents=True)
    tools_cmake.write_text(f"prefix\n{RECALL_BLOCK}suffix\n", encoding="utf-8")
    (reference / "tracked.txt").write_text("keep\n", encoding="utf-8")
    (reference / "secrets.toml.generated").write_text("omit\n", encoding="utf-8")
    (reference / "old.before-stage3").write_text("omit\n", encoding="utf-8")
    (reference / "dawn_wakeword.py").write_text("omit\n", encoding="utf-8")

    destination = tmp_path / "destination"
    prepare_source(reference, destination)

    assert (destination / "tracked.txt").read_text(encoding="utf-8") == "keep\n"
    assert RECALL_GATE in (destination / "cmake" / "DawnTools.cmake").read_text(
        encoding="utf-8"
    )
    assert not (destination / "secrets.toml.generated").exists()
    assert not (destination / "old.before-stage3").exists()
    assert not (destination / "dawn_wakeword.py").exists()


def test_prepare_source_rejects_existing_destination(tmp_path: Path) -> None:
    reference = tmp_path / "reference"
    tools_cmake = reference / "cmake" / "DawnTools.cmake"
    tools_cmake.parent.mkdir(parents=True)
    tools_cmake.write_text(RECALL_BLOCK, encoding="utf-8")

    destination = tmp_path / "destination"
    destination.mkdir()

    with pytest.raises(FileExistsError, match="destination already exists"):
        prepare_source(reference, destination)
