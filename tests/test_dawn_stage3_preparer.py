import sys
from pathlib import Path

import pytest


ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))

from tools.prepare_dawn_stage3_source import (  # noqa: E402
    PIPER_BUILD_BLOCK,
    PIPER_BUILD_GATE,
    RECALL_BLOCK,
    RECALL_GATE,
    TTS_LINK_BLOCK,
    TTS_LINK_GATE,
    TTS_SOURCE_BLOCK,
    TTS_SOURCE_GATE,
    prepare_source,
)


def _write_minimal_reference(reference: Path) -> None:
    tools_cmake = reference / "cmake" / "DawnTools.cmake"
    tools_cmake.parent.mkdir(parents=True)
    tools_cmake.write_text(f"prefix\n{RECALL_BLOCK}suffix\n", encoding="utf-8")

    cmake_lists = reference / "CMakeLists.txt"
    cmake_lists.write_text(
        "\n".join(
            [
                "prefix",
                PIPER_BUILD_BLOCK,
                "set(DAWN_SOURCES",
                TTS_SOURCE_BLOCK,
                ")",
                TTS_LINK_BLOCK,
                "                      suffix)",
            ]
        ),
        encoding="utf-8",
    )
    (reference / "src" / "tts").mkdir(parents=True)


def test_prepare_source_copies_and_gates_minimal_features(tmp_path: Path) -> None:
    reference = tmp_path / "reference"
    _write_minimal_reference(reference)
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

    prepared_cmake = (destination / "CMakeLists.txt").read_text(encoding="utf-8")
    assert PIPER_BUILD_GATE in prepared_cmake
    assert TTS_SOURCE_GATE in prepared_cmake
    assert TTS_LINK_GATE in prepared_cmake
    assert PIPER_BUILD_BLOCK not in prepared_cmake
    assert TTS_SOURCE_BLOCK not in prepared_cmake
    assert TTS_LINK_BLOCK not in prepared_cmake
    stub = (destination / "src" / "tts" / "text_to_speech_stub.c").read_text(
        encoding="utf-8"
    )
    assert "void text_to_speech(const char *text)" in stub
    assert "int text_to_speech_to_pcm(" in stub
    assert "int text_to_speech_to_wav(" in stub

    assert not (destination / "secrets.toml.generated").exists()
    assert not (destination / "old.before-stage3").exists()
    assert not (destination / "dawn_wakeword.py").exists()


def test_prepare_source_rejects_existing_destination(tmp_path: Path) -> None:
    reference = tmp_path / "reference"
    _write_minimal_reference(reference)

    destination = tmp_path / "destination"
    destination.mkdir()

    with pytest.raises(FileExistsError, match="destination already exists"):
        prepare_source(reference, destination)
