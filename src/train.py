from pathlib import Path

from ultralytics import YOLO


ROOT = Path(__file__).resolve().parents[1]
DATA_YAML = ROOT / "datasets" / "route_display" / "data.yaml"

model = YOLO("yolov8n.pt")

model.train(
    data=DATA_YAML,
    epochs=50,
    imgsz=640,
    batch=8,
    project=ROOT / "outputs",
    name="route_display",
)