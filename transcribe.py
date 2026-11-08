"""Speech-to-text for the Watch Video app (used when a video has no captions).
Usage: python transcribe.py audio.wav transcript.txt [start_offset_seconds]
Needs: pip install faster-whisper   (the app's Settings has an Install button)
"""
import sys

from faster_whisper import WhisperModel


def stamp(sec):
    sec = int(sec)
    return f"{sec // 3600:02d}:{sec % 3600 // 60:02d}:{sec % 60:02d}"


def main():
    audio, out = sys.argv[1], sys.argv[2]
    offset = float(sys.argv[3]) if len(sys.argv) > 3 else 0.0
    model = WhisperModel("base", device="cpu", compute_type="int8")
    segments, _ = model.transcribe(audio, vad_filter=True)
    blocks = {}
    for seg in segments:
        b = int((seg.start + offset) // 30)
        blocks.setdefault(b, []).append(seg.text.strip())
    with open(out, "w", encoding="utf-8") as f:
        f.write("(transcribed by speech-to-text, may contain mistakes)\n")
        for b in sorted(blocks):
            f.write(f"[{stamp(b * 30)}] {' '.join(blocks[b])}\n")


if __name__ == "__main__":
    main()
