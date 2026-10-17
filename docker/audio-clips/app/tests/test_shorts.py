import math
import shutil
import subprocess

import pytest

from shorts import clip_bounds, export_clip, fit_candidate, materialize, probe, sentences_from_words, sentences_from_segments


@pytest.fixture
def transcript():
    words = [{"word":"Hello.","start":1.,"end":2.},
             {"word":"A","start":2.1,"end":2.5},
             {"word":"complete","start":2.6,"end":3.},
             {"word":"thought.","start":3.1,"end":4.},
             {"word":"Trailing","start":5.,"end":6.}]
    return {"words":words,"sentences":sentences_from_words(words),"duration":7.}


def test_sentences_keep_every_word_and_trailing_fragment(transcript):
    rows = transcript["sentences"]
    assert [r["text"] for r in rows] == ["Hello.","A complete thought.","Trailing"]
    assert [r["sentence_end"] for r in rows] == [True, True, False]
    assert rows[-1]["last_word"] == 4


def test_padding_does_not_include_neighboring_words(transcript):
    start,end = clip_bounds(transcript,1,1)
    assert 2. < start <= 2.1
    assert 4. <= end < 5.
    first,last = clip_bounds(transcript,0,2)
    assert 0 <= first < 1
    assert 6 < last <= 7


@pytest.mark.parametrize("first,last", [(-1,0),(2,1),(0,99)])
def test_invalid_model_sentence_ids_rejected(transcript,first,last):
    with pytest.raises(ValueError):
        clip_bounds(transcript,first,last)


def test_out_of_range_model_duration_rejected(transcript):
    with pytest.raises(ValueError,match="outside"):
        materialize(transcript,{"first_sentence":0,"last_sentence":1,"title":"Bad duration"},30,90)


def test_segment_punctuation_and_zero_duration_words_preserved():
    words = [{"word":"A","start":0.,"end":0.}, {"word":"complete","start":0.,"end":1.},
             {"word":"sentence","start":1.,"end":2.}, {"word":"ends","start":2.,"end":2.}]
    segments = [{"text":"A complete", "start":0.,"end":1.},
                {"text":"sentence ends.","start":1.,"end":2.}]
    rows = sentences_from_segments(segments,words)
    assert len(rows) == 1
    assert rows[0]["text"] == "A complete sentence ends."
    assert rows[0]["first_word"] == 0 and rows[0]["last_word"] == 3
    assert rows[0]["sentence_end"]


def test_incomplete_sentence_end_rejected(transcript):
    with pytest.raises(ValueError,match="incomplete"):
        materialize(transcript,{"first_sentence":0,"last_sentence":2,"title":"Dangling"},1,10)


def test_short_candidate_gets_whole_sentence_context(transcript):
    result = fit_candidate(transcript,{"first_sentence":1,"last_sentence":1,"title":"Thought"},3,5,[])
    assert result["first_sentence"] == 0
    assert result["last_sentence"] == 1
    assert result["text"] == "Hello. A complete thought."
    assert "boundary_note" in result
    with pytest.raises(ValueError,match="non-overlapping"):
        fit_candidate(transcript,{"first_sentence":1,"last_sentence":1,"title":"Thought"},3,5,[result])


@pytest.mark.skipif(not shutil.which("ffmpeg"),reason="FFmpeg required")
def test_real_mp3_export_and_invalid_boundaries(tmp_path):
    source = tmp_path / "original.wav"
    subprocess.run(["ffmpeg","-v","error","-f","lavfi","-i","sine=frequency=440:duration=5",
                    "-c:a","pcm_s16le",str(source)],check=True)
    clip = export_clip(source,1.25,3.75,"A / safe title",tmp_path/"exports")
    assert abs(probe(clip)["duration"]-2.5) < .1
    assert clip.parent == tmp_path/"exports"
    assert source.exists()
    for start,end in [(3,2),(-1,2),(1,6),(math.nan,2),(1,math.inf)]:
        with pytest.raises(ValueError):
            export_clip(source,start,end,"invalid",tmp_path/"exports")
