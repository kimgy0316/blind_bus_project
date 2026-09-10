# crop 품질 확인용

from pathlib import Path

import cv2
from ultralytics import YOLO


ROOT = Path(__file__).resolve().parents[1]

MODEL_PATH = ROOT / "outputs" / "route_display" / "weights" / "best.pt"
VIDEO_PATH = ROOT / "sample_videos" / "test" / "night_008.mp4"
OUTPUT_DIR = ROOT / "outputs" / "route_number_crops"

CONFIDENCE = 0.3
FRAME_STRIDE = 5
PADDING_RATIO = 0.15
MAX_CROPS = 100


def expand_box(x1, y1, x2, y2, image_width, image_height, padding_ratio):
    box_width = x2 - x1
    box_height = y2 - y1

    pad_x = int(box_width * padding_ratio)
    pad_y = int(box_height * padding_ratio)

    new_x1 = max(0, x1 - pad_x)
    new_y1 = max(0, y1 - pad_y)
    new_x2 = min(image_width, x2 + pad_x)
    new_y2 = min(image_height, y2 + pad_y)

    return new_x1, new_y1, new_x2, new_y2


def main():
    OUTPUT_DIR.mkdir(parents=True, exist_ok=True)

    model = YOLO(MODEL_PATH)
    capture = cv2.VideoCapture(str(VIDEO_PATH))

    if not capture.isOpened():
        raise FileNotFoundError(f"영상을 열 수 없습니다: {VIDEO_PATH}")

    frame_index = 0
    crop_count = 0

    while True:
        success, frame = capture.read()

        if not success:
            break

        if frame_index % FRAME_STRIDE != 0:
            frame_index += 1
            continue

        height, width = frame.shape[:2]
        results = model.predict(frame, conf=CONFIDENCE, verbose=False)

        for result in results:
            for box in result.boxes:
                x1, y1, x2, y2 = box.xyxy[0].tolist()
                confidence = float(box.conf[0])

                x1, y1, x2, y2 = map(int, [x1, y1, x2, y2])
                x1, y1, x2, y2 = expand_box(
                    x1, y1, x2, y2,
                    width, height,
                    PADDING_RATIO,
                )

                crop = frame[y1:y2, x1:x2]

                if crop.size == 0:
                    continue

                output_path = OUTPUT_DIR / (
                    f"frame_{frame_index:06d}_conf_{confidence:.2f}.jpg"
                )
                cv2.imwrite(str(output_path), crop)
                crop_count += 1

                print(f"저장: {output_path}")

                if crop_count >= MAX_CROPS:
                    capture.release()
                    print(f"crop {crop_count}개 저장 완료: {OUTPUT_DIR}")
                    return

        frame_index += 1

    capture.release()
    print(f"crop {crop_count}개 저장 완료: {OUTPUT_DIR}")


if __name__ == "__main__":
    main()