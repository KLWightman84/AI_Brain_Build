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

PIPER_BUILD_BLOCK = """# Text to Speech - check if target already exists (may be created by common/)
if(NOT TARGET piper)
    add_library(piper STATIC src/tts/piper.cpp)
    target_link_libraries(piper onnxruntime)
endif()
"""

PIPER_BUILD_GATE = """# Text-to-speech is deliberately absent from the minimal stage-3 build.
# Only build the native Piper library when the TTS tool is explicitly enabled.
if(DAWN_ENABLE_TTS_TOOL AND NOT TARGET piper)
    add_library(piper STATIC src/tts/piper.cpp)
    target_link_libraries(piper onnxruntime)
elseif(NOT DAWN_ENABLE_TTS_TOOL)
    message(STATUS "Piper: DISABLED (minimal stage-3 build)")
endif()
"""

TTS_SOURCE_BLOCK = """    # TTS subsystem
    src/tts/text_to_speech.cpp
    common/src/tts/tts_preprocessing.cpp
    common/src/tts/number_to_words.c

"""

TTS_SOURCE_GATE = """    # TTS subsystem
    # The minimal stage uses a no-op implementation so it does not acquire
    # Piper, eSpeak, piper-phonemize, or ONNX Runtime as a build dependency.
    if(DAWN_ENABLE_TTS_TOOL)
        list(APPEND DAWN_SOURCES
            src/tts/text_to_speech.cpp
            common/src/tts/tts_preprocessing.cpp
            common/src/tts/number_to_words.c)
    else()
        list(APPEND DAWN_SOURCES src/tts/text_to_speech_stub.c)
    endif()

"""

TTS_LINK_BLOCK = """target_link_libraries(dawn
                      dawn_common
                      dawn_common_vad
                      dawn_common_asr
                      piper
                      piper_phonemize
                      espeak-ng
                      onnxruntime
                      pthread
"""

TTS_LINK_GATE = """set(DAWN_TTS_LIBRARIES)
if(DAWN_ENABLE_TTS_TOOL)
    list(APPEND DAWN_TTS_LIBRARIES
        piper
        piper_phonemize
        espeak-ng
        onnxruntime)
endif()

target_link_libraries(dawn
                      dawn_common
                      dawn_common_vad
                      dawn_common_asr
                      ${DAWN_TTS_LIBRARIES}
                      pthread
"""

PIPER_INCLUDE_BLOCK = """target_include_directories(piper PUBLIC
                           /usr/local/include/piper-phonemize
                           ${SPDLOG_INCLUDE_DIRS}
                           /usr/local/include/onnxruntime/)
"""

PIPER_INCLUDE_GATE = """if(TARGET piper)
    target_include_directories(piper PUBLIC
                               /usr/local/include/piper-phonemize
                               ${SPDLOG_INCLUDE_DIRS}
                               /usr/local/include/onnxruntime/)
endif()
"""

TTS_STUB = """/*
 * Stage-3 server-only TTS stub.
 *
 * This generated source is used only while DAWN_ENABLE_TTS_TOOL=OFF.  It keeps
 * DAWN's required interface linkable without pulling Piper, piper-phonemize,
 * eSpeak, or ONNX Runtime into the minimal DAWN → RKLLM acceptance build.
 */
#include "tts/text_to_speech.h"

#include <stddef.h>

pthread_cond_t tts_cond = PTHREAD_COND_INITIALIZER;
pthread_mutex_t tts_mutex = PTHREAD_MUTEX_INITIALIZER;
int tts_playback_state = TTS_PLAYBACK_IDLE;

void initialize_text_to_speech(char *pcm_device) {
    (void)pcm_device;
}

void text_to_speech(const char *text) {
    (void)text;
}

int text_to_speech_to_pcm(const char *text,
                          int16_t **pcm_data_out,
                          size_t *pcm_samples_out,
                          uint32_t *sample_rate_out) {
    (void)text;
    if (pcm_data_out != NULL) {
        *pcm_data_out = NULL;
    }
    if (pcm_samples_out != NULL) {
        *pcm_samples_out = 0;
    }
    if (sample_rate_out != NULL) {
        *sample_rate_out = 0;
    }
    return 1;
}

int text_to_speech_to_wav(const char *text,
                          uint8_t **wav_data_out,
                          size_t *wav_size_out) {
    (void)text;
    if (wav_data_out != NULL) {
        *wav_data_out = NULL;
    }
    if (wav_size_out != NULL) {
        *wav_size_out = 0;
    }
    return 1;
}

void tts_speak_greeting_with_calibration(const char *greeting) {
    (void)greeting;
}

int tts_wait_for_completion(int timeout_ms) {
    (void)timeout_ms;
    return 0;
}

void cleanup_text_to_speech(void) {
}
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


def _replace_once(path: Path, original: str, replacement: str, label: str) -> None:
    text = path.read_text(encoding="utf-8")
    if replacement in text:
        return
    if original not in text:
        raise ValueError(f"unexpected {label} in {path}; refusing to patch it")
    path.write_text(text.replace(original, replacement, 1), encoding="utf-8")


def gate_recall_tool(source_root: Path) -> None:
    tools_cmake = source_root / "cmake" / "DawnTools.cmake"
    _replace_once(tools_cmake, RECALL_BLOCK, RECALL_GATE, "Recall block")


def gate_native_tts(source_root: Path) -> None:
    cmake_lists = source_root / "CMakeLists.txt"
    _replace_once(cmake_lists, PIPER_BUILD_BLOCK, PIPER_BUILD_GATE, "Piper build block")
    _replace_once(cmake_lists, TTS_SOURCE_BLOCK, TTS_SOURCE_GATE, "TTS source block")
    _replace_once(cmake_lists, TTS_LINK_BLOCK, TTS_LINK_GATE, "TTS link block")
    _replace_once(
        cmake_lists, PIPER_INCLUDE_BLOCK, PIPER_INCLUDE_GATE, "Piper include block"
    )

    stub_path = source_root / "src" / "tts" / "text_to_speech_stub.c"
    stub_path.write_text(TTS_STUB, encoding="utf-8")


def prepare_source(reference: Path, destination: Path) -> None:
    if not reference.is_dir():
        raise ValueError(f"reference source does not exist: {reference}")
    if destination.exists():
        raise FileExistsError(f"destination already exists: {destination}")

    shutil.copytree(reference, destination, ignore=_ignore_archive_residue)
    gate_recall_tool(destination)
    gate_native_tts(destination)


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
