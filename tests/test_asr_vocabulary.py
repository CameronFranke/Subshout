"""Request-local boosting uses the upstream decoder on the MLX thread."""

from __future__ import annotations

import threading
from types import SimpleNamespace
from unittest.mock import Mock

import numpy as np
import pytest
from parakeet_mlx import boost
from parakeet_mlx.parakeet import Beam, ParakeetRNNT, ParakeetTDT, ParakeetTDTCTC

from shout_daemon import asr as asr_module
from shout_daemon.asr import ParakeetASR, UnsupportedVocabularyError


@pytest.fixture
def engine(monkeypatch):
    engine = ParakeetASR()
    monkeypatch.setattr(asr_module, "get_logmel", lambda audio, config: audio)
    yield engine
    engine._executor.shutdown(wait=True)


def fake_model(model_type=ParakeetTDT):
    model = Mock(spec=model_type)
    model.preprocessor_config = object()
    model.vocabulary = ["▁", "h", "e", "l", "o", "H", "E", "L", "O"]
    model.generate.return_value = [SimpleNamespace(text="hello")]
    return model


@pytest.mark.parametrize("model_type", [ParakeetTDT, ParakeetRNNT, ParakeetTDTCTC])
def test_booster_wiring_and_next_request_greedy(engine, model_type):
    engine.model = fake_model(model_type)
    audio = np.zeros(160, dtype=np.float32)
    assert engine.transcribe_array(audio, vocabulary=["Hello"]).text == "hello"
    config = engine.model.generate.call_args.kwargs["decoding_config"]
    assert isinstance(config.decoding, Beam)
    assert config.decoding.beam_size == 2
    machine = config.decoding.booster
    for tokens in ([0, 1, 2, 3, 3, 4], [0, 5, 6, 7, 7, 8]):
        state = machine.start
        weight = 0.0
        for token in tokens:
            state, delta = boost.advance(machine, state, token)
            weight += delta
        assert weight + boost.settle(machine, state) == pytest.approx(1.5)
    engine.transcribe_array(audio)
    assert engine.model.generate.call_args.kwargs == {}
    engine.transcribe_array(audio, vocabulary=[])
    assert engine.model.generate.call_args.kwargs == {}


def test_boost_build_and_generate_share_mlx_thread(engine, monkeypatch):
    engine.model = fake_model()
    threads = []
    original_words = boost.words

    def words(weights):
        threads.append(threading.get_ident())
        return original_words(weights)

    def generate(mel, **kwargs):
        threads.append(threading.get_ident())
        return []

    monkeypatch.setattr(boost, "words", words)
    engine.model.generate.side_effect = generate
    errors = []

    def transcribe():
        try:
            engine.transcribe_array(np.zeros(160), vocabulary=["hello"])
        except Exception as error:
            errors.append(error)

    caller = threading.Thread(target=transcribe)
    caller.start()
    caller.join(timeout=10)
    assert not caller.is_alive()
    assert errors == []
    assert threads == [engine._run(threading.get_ident)] * 2
    assert threads[0] != caller.ident


def test_unsupported_model_is_not_silently_ignored(engine):
    engine.model = Mock()
    with pytest.raises(UnsupportedVocabularyError):
        engine.transcribe_array(np.zeros(160), vocabulary=["hello"])
    engine.model.generate.assert_not_called()


def test_missing_token_vocabulary_is_not_silently_ignored(engine):
    engine.model = fake_model()
    engine.model.vocabulary = []
    with pytest.raises(UnsupportedVocabularyError):
        engine.transcribe_array(np.zeros(160), vocabulary=["hello"])
    engine.model.generate.assert_not_called()


@pytest.mark.integration
@pytest.mark.parametrize("model_id", [
    "mlx-community/parakeet-tdt_ctc-110m",
    "mlx-community/parakeet-tdt-1.1b",
])
def test_cached_models_boost_then_greedy(model_id):
    """Smoke the hybrid default and selected 1.1B without downloading weights."""
    from huggingface_hub import snapshot_download
    from huggingface_hub.errors import LocalEntryNotFoundError

    try:
        model_path = snapshot_download(model_id, local_files_only=True)
    except LocalEntryNotFoundError:
        pytest.skip("model is not cached locally")
    engine = ParakeetASR()
    try:
        engine.load(model_path)
        audio = np.zeros(4_000, dtype=np.float32)
        boosted = engine.transcribe_array(audio, vocabulary=["Subshout"])
        greedy = engine.transcribe_array(audio)
        assert isinstance(boosted.text, str)
        assert isinstance(greedy.text, str)
        assert boosted.audio_seconds == greedy.audio_seconds == 0.25
    finally:
        engine._run(lambda: setattr(engine, "model", None))
        engine._run(asr_module.mx.clear_cache)
        engine._executor.shutdown(wait=True)


def test_failed_boost_request_does_not_change_next_request(engine):
    engine.model = fake_model()
    def fail_with_cached_booster(mel, *, decoding_config):
        machine = decoding_config.decoding.booster
        deltas = boost.tabulate(machine, len(engine.model.vocabulary))
        asr_module.mx.eval(deltas(machine.start))
        assert boost.tabulate.cache_info().currsize > 0
        raise RuntimeError("decoder failed")

    engine.model.generate.side_effect = fail_with_cached_booster
    with pytest.raises(RuntimeError, match="decoder failed"):
        engine.transcribe_array(np.zeros(160), vocabulary=["hello"])
    assert boost.tabulate.cache_info().currsize == 0
    engine.model.generate.side_effect = None
    engine.transcribe_array(np.zeros(160))
    assert engine.model.generate.call_args.kwargs == {}
