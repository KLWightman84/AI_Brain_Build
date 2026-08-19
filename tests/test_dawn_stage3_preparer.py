import sys
from pathlib import Path

import pytest


ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))

from tools.prepare_dawn_stage3_source import (  # noqa: E402
    PIPER_BUILD_BLOCK,
    PIPER_BUILD_GATE,
    ONNX_EMBED_SOURCE,
    ONNX_EMBED_STUB_SOURCE,
    DAWN_SOURCES_WITH_STAGE3_SUPPORT,
    TEXT_CLEANUP_STUB,
    VAD_STUB,
    PIPER_INCLUDE_BLOCK,
    PIPER_INCLUDE_GATE,
    RECALL_BLOCK,
    RECALL_GATE,
    TTS_LINK_BLOCK,
    TTS_LINK_GATE,
    TTS_SOURCE_BLOCK,
    TTS_SOURCE_LIST,
    TTS_SOURCE_VARIABLES,
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
                "# Base source files (always compiled)",
                "set(DAWN_SOURCES",
                TTS_SOURCE_BLOCK,
                ONNX_EMBED_SOURCE,
                ")",
                TTS_LINK_BLOCK,
                "                      suffix)",
                PIPER_INCLUDE_BLOCK,
            ]
        ),
        encoding="utf-8",
    )
    (reference / "src" / "tts").mkdir(parents=True)
    (reference / "src" / "memory").mkdir(parents=True)
    (reference / "src" / "asr").mkdir(parents=True)
    (reference / "src" / "core" / "attention").mkdir(parents=True)
    (reference / "src" / "tools").mkdir(parents=True)
    (reference / "src" / "tools" / "tools_init.c").write_text(
        '#include "tools/recall_tool.h"\n'
        '   /* Unified cross-source recall — aggregates whatever focus adapters are\n'
        '    * registered (memory/notes/documents/calendar).  Registered unconditionally;\n'
        '    * recall_is_available() gates at runtime on the embedding engine. */\n'
        '   if (recall_tool_register() != 0) {\n'
        '      OLOG_WARNING("Failed to register recall tool");\n'
        '   }\n\n',
        encoding="utf-8",
    )
    (reference / "src" / "llm").mkdir(parents=True)
    (reference / "src" / "llm" / "llm_tool_loop.c").write_text(
        "session_get_for_reconnect(0);\n", encoding="utf-8"
    )
    (reference / "src" / "core" / "attention" / "attention_core.c").write_text(
        "      session_broadcast_system_message(note);\n", encoding="utf-8"
    )


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
    assert TTS_SOURCE_VARIABLES in prepared_cmake
    assert DAWN_SOURCES_WITH_STAGE3_SUPPORT in prepared_cmake
    assert TTS_SOURCE_LIST in prepared_cmake
    assert TTS_LINK_GATE in prepared_cmake
    assert PIPER_INCLUDE_GATE in prepared_cmake
    assert PIPER_BUILD_BLOCK not in prepared_cmake
    assert TTS_SOURCE_BLOCK not in prepared_cmake
    assert TTS_LINK_BLOCK not in prepared_cmake
    assert PIPER_INCLUDE_BLOCK not in prepared_cmake
    assert ONNX_EMBED_STUB_SOURCE in prepared_cmake
    assert ONNX_EMBED_SOURCE not in prepared_cmake
    embedding_stub = (
        destination / "src" / "memory" / "memory_embed_onnx_stub.c"
    ).read_text(encoding="utf-8")
    assert "const embedding_provider_t embedding_provider_onnx" in embedding_stub
    stub = (destination / "src" / "tts" / "text_to_speech_stub.c").read_text(
        encoding="utf-8"
    )
    assert "void text_to_speech(const char *text)" in stub
    assert "int text_to_speech_to_pcm(" in stub
    assert "int text_to_speech_to_wav(" in stub
    assert "pthread_cond_t tts_cond =" not in stub
    assert "pthread_mutex_t tts_mutex =" not in stub
    assert (destination / "src" / "asr" / "vad_silero_stub.c").read_text(
        encoding="utf-8"
    ) == VAD_STUB
    assert (destination / "src" / "core" / "stage3_text_cleanup_stub.c").read_text(
        encoding="utf-8"
    ) == TEXT_CLEANUP_STUB
    prepared_tools_init = (destination / "src" / "tools" / "tools_init.c").read_text(
        encoding="utf-8"
    )
    assert "#ifdef DAWN_ENABLE_RECALL_TOOL" in prepared_tools_init
    assert "session_get_for_reconnect(" not in (
        destination / "src" / "llm" / "llm_tool_loop.c"
    ).read_text(encoding="utf-8")

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
