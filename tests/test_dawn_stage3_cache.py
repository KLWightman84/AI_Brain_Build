from pathlib import Path


CACHE = (
    Path(__file__).resolve().parents[1] / "cmake" / "dawn-stage3-minimal.cmake"
)


def test_minimal_dawn_stage3_cache_disables_deferred_subsystems() -> None:
    text = CACHE.read_text(encoding="utf-8")

    assert 'set(SERVER_ONLY ON CACHE BOOL "No local audio capture or playback" FORCE)' in text

    for option in (
        "ENABLE_TUI",
        "ENABLE_WEBUI",
        "ENABLE_AEC",
        "ENABLE_SHERPA",
        "ENABLE_VOSK",
        "DAWN_ENABLE_MP3",
        "DAWN_ENABLE_OGG",
    ):
        assert f"set({option} OFF CACHE BOOL" in text


def test_minimal_dawn_stage3_cache_disables_every_legacy_tool() -> None:
    text = CACHE.read_text(encoding="utf-8")

    for option in (
        "DAWN_ENABLE_SHUTDOWN_TOOL",
        "DAWN_ENABLE_MUSIC_TOOL",
        "DAWN_ENABLE_CALCULATOR_TOOL",
        "DAWN_ENABLE_WEATHER_TOOL",
        "DAWN_ENABLE_SEARCH_TOOL",
        "DAWN_ENABLE_URL_TOOL",
        "DAWN_ENABLE_HOMEASSISTANT_TOOL",
        "DAWN_ENABLE_SMARTTHINGS_TOOL",
        "DAWN_ENABLE_MEMORY_TOOL",
        "DAWN_ENABLE_DATETIME_TOOL",
        "DAWN_ENABLE_VOLUME_TOOL",
        "DAWN_ENABLE_LLM_STATUS_TOOL",
        "DAWN_ENABLE_SWITCH_LLM_TOOL",
        "DAWN_ENABLE_RESET_CONVERSATION_TOOL",
        "DAWN_ENABLE_VIEWING_TOOL",
        "DAWN_ENABLE_HUD_TOOLS",
        "DAWN_ENABLE_AUDIO_TOOLS",
        "DAWN_ENABLE_SCHEDULER_TOOL",
        "DAWN_ENABLE_JOB_TOOL",
        "DAWN_ENABLE_TTS_TOOL",
        "DAWN_ENABLE_DOCUMENT_SEARCH_TOOL",
        "DAWN_ENABLE_CALENDAR_TOOL",
        "DAWN_ENABLE_EMAIL_TOOL",
        "DAWN_ENABLE_SFX_TOOL",
        "DAWN_ENABLE_RENDER_VISUAL_TOOL",
        "DAWN_ENABLE_PHONE_TOOL",
        "DAWN_ENABLE_IMAGE_SEARCH_TOOL",
        "DAWN_ENABLE_CONTEXT_EXPAND_TOOL",
        "DAWN_ENABLE_STAT_TOOL",
        "DAWN_ENABLE_SUIT_TOOL",
        "DAWN_ENABLE_MCP_BRIDGE_TOOL",
        "DAWN_ENABLE_CODE_PROJECTS",
    ):
        assert f"set({option} OFF CACHE BOOL" in text
