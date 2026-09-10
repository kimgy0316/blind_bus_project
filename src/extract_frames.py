from pathlib import Path

import cv2


ROOT = Path(__file__).resolve().parents[1]

VIDEO_ROOT = ROOT / "sample_videos"
DATASET_ROOT = ROOT / "datasets" / "route_display"

SECONDS_BETWEEN_IMAGES = 0.5
MAX_FRAMES_PER_VIDEO = 30

SPLITS = ["train", "valid", "test"]


def extract_frames_from_video(video_path, output_dir):
    capture = cv2.VideoCapture(str(video_path))

    if not capture.isOpened():
        print(f"영상을 열 수 없어 건너뜁니다: {video_path}")
        return 0

    fps = capture.get(cv2.CAP_PROP_FPS)
    interval = max(1, round(fps * SECONDS_BETWEEN_IMAGES))

    frame_index = 0
    saved_count = 0

    while True:
        success, frame = capture.read()

        if not success:
            break

        if frame_index % interval == 0:
            output_path = output_dir / (
                f"{video_path.stem}_frame_{saved_count:05d}.jpg"
            )
            cv2.imwrite(str(output_path), frame)
            saved_count += 1

            if saved_count >= MAX_FRAMES_PER_VIDEO:
                break

        frame_index += 1

    capture.release()
    return saved_count


def main():
    total_saved = 0

    for split in SPLITS:
        video_dir = VIDEO_ROOT / split
        image_output_dir = DATASET_ROOT / split / "images"
        image_output_dir.mkdir(parents=True, exist_ok=True)

        if not video_dir.exists():
            print(f"{split}: 영상 폴더가 없습니다. 건너뜁니다.")
            continue

        split_saved = 0

        for video_path in sorted(video_dir.glob("*.mp4")):
            saved_count = extract_frames_from_video(video_path, image_output_dir)
            split_saved += saved_count
            print(f"{split} / {video_path.name}: {saved_count}개 저장")

        total_saved += split_saved
        print(f"{split}: 총 {split_saved}개 저장")

    print(f"전체 {total_saved}개 프레임 저장 완료")


if __name__ == "__main__":
    main()