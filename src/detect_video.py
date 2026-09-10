from pathlib import Path

from ultralytics import YOLO


ROOT = Path(__file__).resolve().parents[1]
MODEL_PATH = ROOT / "outputs" / "route_display" / "weights" / "best.pt"
VIDEO_PATH = ROOT / "sample_videos" / "test" / "night_008.mp4"

model = YOLO(MODEL_PATH)

model.predict(
    source=VIDEO_PATH,
    conf=0.4,
    save=True,
    project=ROOT / "outputs",
    name="video_test",
)