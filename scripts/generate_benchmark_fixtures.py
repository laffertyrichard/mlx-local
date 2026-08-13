#!/usr/bin/env python3
from pathlib import Path
import subprocess
from PIL import Image, ImageDraw

root = Path(__file__).resolve().parents[1] / "Benchmarks" / "fixtures"
root.mkdir(parents=True, exist_ok=True)
image = Image.new("RGB", (1000, 700), "white")
draw = ImageDraw.Draw(image)
draw.rectangle((100, 100, 900, 600), outline="black", width=8)
draw.text((250, 260), "ROOM A", fill="black", font_size=72)
draw.text((180, 380), "12'-6\" x 10'-0\"", fill="black", font_size=58)
image.save(root / "room.png")
image.save(root / "scanned-plan.pdf", "PDF", resolution=150)
second = Image.new("RGB", (1000, 700), "white")
d = ImageDraw.Draw(second); d.rectangle((80, 80, 920, 620), outline="black", width=8)
d.text((250, 260), "ROOM B", fill="black", font_size=72); d.text((180, 380), "9'-0\" x 11'-0\"", fill="black", font_size=58)
second.save(root / "room-b.png")
aiff = root / "meeting.aiff"; wav = root / "meeting.wav"
subprocess.run(["say", "-v", "Samantha", "-o", str(aiff), "Project Apollo launches on Tuesday. The budget is forty two thousand dollars. Alice will prepare the final report."], check=True)
subprocess.run(["ffmpeg", "-y", "-loglevel", "error", "-i", str(aiff), "-ar", "16000", "-ac", "1", str(wav)], check=True)
aiff.unlink(missing_ok=True)
(root / "sample.py").write_text("def divide(a, b):\n    return a / b\n\nprint(divide(1, 0))\n")
print(root)
