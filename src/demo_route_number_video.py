from collections import deque
from pathlib import Path
import argparse
import math
import os
import re
import time

import cv2
import easyocr
from ultralytics import YOLO


ROOT = Path(__file__).resolve().parents[1]

MODEL_PATH = ROOT / "outputs" / "route_display" / "weights" / "best.pt"
VIDEO_PATH = ROOT / "sample_videos" / "test" / "day_012.mp4"
OUTPUT_VIDEO_PATH = ROOT / "outputs" / "demo_route_number_result.mp4"

EXPECTED_BUS_NUMBERS = ["30-1"]

# Presentation defaults: sparse inference, stable overlay, and predictable progress.
YOLO_CONFIDENCE = 0.3
DEFAULT_MODE = "cpu"
YOLO_FRAME_STRIDE = 15
OCR_FRAME_STRIDE = 30
WRITE_FRAME_STRIDE = 4
YOLO_IMAGE_SIZE = 416
OUTPUT_SCALE = 0.75
CPU_THREADS = 4

MODE_PRESETS = {
    "cpu": {
        "yolo_stride": 15,
        "ocr_stride": 30,
        "write_stride": 4,
        "imgsz": 416,
        "output_scale": 0.75,
    },
    "balanced": {
        "yolo_stride": 8,
        "ocr_stride": 16,
        "write_stride": 2,
        "imgsz": 512,
        "output_scale": 0.9,
    },
    "quality": {
        "yolo_stride": 4,
        "ocr_stride": 8,
        "write_stride": 1,
        "imgsz": 640,
        "output_scale": 1.0,
    },
}

OCR_HISTORY_SIZE = 8
CONFIRM_SCORE = 4
NO_MATCH_RESET_COUNT = 999

OCR_ALLOWLIST = "0123456789-"
DASH_CODEPOINTS = (
    "\u2010",
    "\u2011",
    "\u2012",
    "\u2013",
    "\u2014",
    "\u2212",
    "\uff0d",
)


def parse_args():
    parser = argparse.ArgumentParser(
        description="Create a fast presentation video for route-number OCR."
    )
    parser.add_argument(
        "--mode",
        choices=sorted(MODE_PRESETS),
        default=DEFAULT_MODE,
        help="cpu is fastest. Use balanced or quality only when recognition is weak.",
    )
    parser.add_argument("--video", type=Path, default=VIDEO_PATH)
    parser.add_argument("--output", type=Path, default=OUTPUT_VIDEO_PATH)
    parser.add_argument("--model", type=Path, default=MODEL_PATH)
    parser.add_argument(
        "--expected",
        default=",".join(EXPECTED_BUS_NUMBERS),
        help="Comma-separated expected bus numbers, e.g. 30-1,31.",
    )
    parser.add_argument("--yolo-stride", type=int, default=None)
    parser.add_argument("--ocr-stride", type=int, default=None)
    parser.add_argument("--write-stride", type=int, default=None)
    parser.add_argument("--conf", type=float, default=YOLO_CONFIDENCE)
    parser.add_argument("--imgsz", type=int, default=None)
    parser.add_argument("--output-scale", type=float, default=None)
    parser.add_argument(
        "--cpu-threads",
        type=int,
        default=CPU_THREADS,
        help="Limit CPU threads so the computer stays responsive. Use 0 for default.",
    )
    parser.add_argument(
        "--max-seconds",
        type=float,
        default=None,
        help="Process only the first N seconds. Defaults to the full video.",
    )
    parser.add_argument(
        "--keep-searching-after-match",
        action="store_true",
        help="Keep running OCR after a stable route number is confirmed.",
    )
    parser.add_argument(
        "--keep-detecting-after-match",
        action="store_true",
        help="Keep running YOLO after a stable route number is confirmed.",
    )
    return parser.parse_args()


def normalize_number(text):
    text = "" if text is None else str(text)
    text = text.replace(" ", "")
    text = text.replace("_", "-")

    for dash in DASH_CODEPOINTS:
        text = text.replace(dash, "-")

    text = re.sub(r"[^0-9-]", "", text)

    if "-" in text:
        parts = [part for part in text.split("-") if part]
        if len(parts) >= 2:
            return f"{parts[0]}-{parts[1]}"

    return text


def compact_number(text):
    return normalize_number(text).replace("-", "")


def extract_route_number(ocr_texts, expected_numbers):
    candidates = []

    for text in ocr_texts:
        normalized = normalize_number(text)

        if not normalized:
            continue

        if re.fullmatch(r"\d{1,4}(-\d{1,2})?", normalized):
            candidates.append(normalized)

    if not candidates:
        return None

    expected_compact = {compact_number(number): number for number in expected_numbers}

    for candidate in candidates:
        candidate_compact = compact_number(candidate)
        if candidate_compact in expected_compact:
            return expected_compact[candidate_compact]

    candidates.sort(key=len, reverse=True)
    return candidates[0]


def score_candidate(candidate, expected):
    if not candidate:
        return 0

    candidate_clean = compact_number(candidate)
    expected_clean = compact_number(expected)

    if not candidate_clean or not expected_clean:
        return 0

    if candidate == expected:
        return 4

    if candidate_clean == expected_clean:
        return 4

    if len(candidate_clean) >= 2 and expected_clean.startswith(candidate_clean):
        return 1

    if len(expected_clean) >= 2 and candidate_clean.startswith(expected_clean):
        return 1

    return 0


def choose_confirmed_number(history, expected_numbers):
    best_number = None
    best_score = 0

    for expected in expected_numbers:
        score = 0

        for candidate in history:
            score += score_candidate(candidate, expected)

        if score > best_score:
            best_score = score
            best_number = expected

    if best_score >= CONFIRM_SCORE:
        return best_number, best_score

    return None, best_score


def expand_box(x1, y1, x2, y2, frame_width, frame_height):
    box_width = x2 - x1
    box_height = y2 - y1

    pad_left = int(box_width * 0.4)
    pad_right = int(box_width * 0.8)
    pad_top = int(box_height * 0.5)
    pad_bottom = int(box_height * 0.5)

    new_x1 = max(0, x1 - pad_left)
    new_y1 = max(0, y1 - pad_top)
    new_x2 = min(frame_width, x2 + pad_right)
    new_y2 = min(frame_height, y2 + pad_bottom)

    return new_x1, new_y1, new_x2, new_y2


def resize_for_ocr(gray):
    height, width = gray.shape[:2]
    target_height = 96
    scale = target_height / max(1, height)
    scale = min(5.0, max(1.5, scale))

    resized = cv2.resize(
        gray,
        None,
        fx=scale,
        fy=scale,
        interpolation=cv2.INTER_CUBIC,
    )

    if resized.shape[1] > 900:
        ratio = 900 / resized.shape[1]
        resized = cv2.resize(
            resized,
            None,
            fx=ratio,
            fy=ratio,
            interpolation=cv2.INTER_AREA,
        )

    return resized


def make_ocr_images(crop):
    gray = cv2.cvtColor(crop, cv2.COLOR_BGR2GRAY)
    resized = resize_for_ocr(gray)

    clahe = cv2.createCLAHE(clipLimit=3.0, tileGridSize=(8, 8))
    contrast = clahe.apply(resized)
    blur = cv2.GaussianBlur(contrast, (3, 3), 0)

    _, binary = cv2.threshold(
        blur,
        0,
        255,
        cv2.THRESH_BINARY + cv2.THRESH_OTSU,
    )

    # LED signs often become dotted in daylight. Make the lit segments touch.
    white_on_black = binary if binary.mean() < 127 else cv2.bitwise_not(binary)
    horizontal_kernel = cv2.getStructuringElement(cv2.MORPH_RECT, (5, 2))
    vertical_kernel = cv2.getStructuringElement(cv2.MORPH_RECT, (2, 3))
    close_kernel = cv2.getStructuringElement(cv2.MORPH_RECT, (4, 3))

    connected = cv2.dilate(white_on_black, horizontal_kernel, iterations=1)
    connected = cv2.dilate(connected, vertical_kernel, iterations=1)
    connected = cv2.morphologyEx(connected, cv2.MORPH_CLOSE, close_kernel)

    return [
        ("connected", connected),
        ("connected_inverted", cv2.bitwise_not(connected)),
    ]


def readtext_fast(reader, image):
    return reader.readtext(
        image,
        allowlist=OCR_ALLOWLIST,
        detail=1,
        paragraph=False,
        decoder="greedy",
        beamWidth=1,
        batch_size=1,
        workers=0,
        canvas_size=640,
        mag_ratio=1.0,
    )


def run_best_ocr(reader, crop, expected_numbers):
    best_method = "none"
    best_texts = []
    best_confidence = 0.0
    best_match_score = 0

    for method_name, image in make_ocr_images(crop):
        results = readtext_fast(reader, image)

        texts = []
        confidences = []

        for item in results:
            text = item[1]
            confidence = float(item[2])

            texts.append(text)
            confidences.append(confidence)

        parsed = extract_route_number(texts, expected_numbers)
        match_score = max(
            [score_candidate(parsed, expected) for expected in expected_numbers],
            default=0,
        )
        confidence = max(confidences) if confidences else 0.0

        if (match_score, confidence) > (best_match_score, best_confidence):
            best_match_score = match_score
            best_confidence = confidence
            best_texts = texts
            best_method = method_name

        if best_match_score >= 4 and best_confidence >= 0.2:
            break

    return best_texts, best_confidence, best_method


def pick_best_box(results):
    best_box = None
    best_confidence = 0.0

    for result in results:
        for box in result.boxes:
            confidence = float(box.conf[0])

            if confidence > best_confidence:
                best_confidence = confidence
                best_box = box

    return best_box, best_confidence


def shorten_text(text, max_length=40):
    text = str(text)

    if len(text) <= max_length:
        return text

    return text[: max_length - 3] + "..."


def draw_boxes(frame, model_box, crop_box, yolo_confidence):
    if crop_box:
        crop_x1, crop_y1, crop_x2, crop_y2 = crop_box
        cv2.rectangle(frame, (crop_x1, crop_y1), (crop_x2, crop_y2), (255, 160, 0), 2)
        cv2.putText(
            frame,
            "OCR crop",
            (crop_x1, max(28, crop_y1 - 8)),
            cv2.FONT_HERSHEY_SIMPLEX,
            0.7,
            (255, 160, 0),
            2,
            cv2.LINE_AA,
        )

    if model_box:
        x1, y1, x2, y2 = model_box
        cv2.rectangle(frame, (x1, y1), (x2, y2), (0, 255, 0), 3)
        cv2.putText(
            frame,
            f"YOLO {yolo_confidence:.2f}",
            (x1, max(28, y1 - 8)),
            cv2.FONT_HERSHEY_SIMPLEX,
            0.75,
            (0, 255, 0),
            2,
            cv2.LINE_AA,
        )


def draw_overlay(
    frame,
    expected_numbers,
    yolo_confidence,
    ocr_texts,
    ocr_confidence,
    ocr_method,
    parsed_number,
    confirmed_number,
    stable_score,
    frame_index,
    total_frames,
):
    height, width = frame.shape[:2]
    overlay_height = min(height - 20, 245)

    overlay = frame.copy()
    cv2.rectangle(overlay, (20, 20), (width - 20, overlay_height), (0, 0, 0), -1)
    frame = cv2.addWeighted(overlay, 0.68, frame, 0.32, 0)

    status = "MATCH" if confirmed_number else "SEARCHING"
    progress = "unknown"

    if total_frames > 0:
        progress = f"{min(100.0, frame_index / total_frames * 100.0):.1f}%"

    lines = [
        f"Expected bus: {', '.join(expected_numbers)}",
        f"YOLO conf: {yolo_confidence:.2f}",
        f"OCR: {shorten_text(ocr_texts)}",
        f"OCR conf/method: {ocr_confidence:.2f} / {ocr_method}",
        f"Current OCR: {parsed_number or 'None'}",
        f"Stable result: {confirmed_number or 'None'}",
        f"Stable score: {stable_score}",
        f"Status: {status} | Progress: {progress}",
    ]

    y = 52

    for line in lines:
        color = (255, 255, 255)

        if line.startswith("Current OCR") and parsed_number:
            color = (0, 255, 255)

        if line.startswith("Stable result") and confirmed_number:
            color = (0, 255, 255)

        if line.startswith("Status") and confirmed_number:
            color = (0, 255, 0)

        cv2.putText(
            frame,
            line,
            (40, y),
            cv2.FONT_HERSHEY_SIMPLEX,
            0.72,
            color,
            2,
            cv2.LINE_AA,
        )

        y += 24

    return frame


def positive_stride(value, fallback):
    if value is None or value < 1:
        return fallback

    return value


def build_runtime_options(args):
    preset = MODE_PRESETS[args.mode].copy()

    if args.yolo_stride is not None:
        preset["yolo_stride"] = args.yolo_stride

    if args.ocr_stride is not None:
        preset["ocr_stride"] = args.ocr_stride

    if args.write_stride is not None:
        preset["write_stride"] = args.write_stride

    if args.imgsz is not None:
        preset["imgsz"] = args.imgsz

    if args.output_scale is not None:
        preset["output_scale"] = args.output_scale

    preset["yolo_stride"] = positive_stride(
        preset["yolo_stride"],
        YOLO_FRAME_STRIDE,
    )
    preset["ocr_stride"] = positive_stride(
        preset["ocr_stride"],
        OCR_FRAME_STRIDE,
    )
    preset["write_stride"] = positive_stride(
        preset["write_stride"],
        WRITE_FRAME_STRIDE,
    )
    preset["imgsz"] = max(160, int(preset["imgsz"] or YOLO_IMAGE_SIZE))
    preset["output_scale"] = min(1.0, max(0.25, float(preset["output_scale"])))

    return preset


def configure_cpu(cpu_threads):
    cv2.setUseOptimized(True)

    if cpu_threads is None or cpu_threads <= 0:
        return

    threads = min(cpu_threads, os.cpu_count() or cpu_threads)
    cv2.setNumThreads(threads)

    try:
        import torch

        torch.set_num_threads(threads)
        torch.set_num_interop_threads(max(1, min(2, threads)))
    except Exception:
        pass


def scaled_dimensions(width, height, scale):
    output_width = max(2, int(width * scale))
    output_height = max(2, int(height * scale))

    if output_width % 2:
        output_width -= 1

    if output_height % 2:
        output_height -= 1

    return output_width, output_height


def resize_for_output(frame, output_size):
    output_width, output_height = output_size

    if frame.shape[1] == output_width and frame.shape[0] == output_height:
        return frame

    return cv2.resize(
        frame,
        (output_width, output_height),
        interpolation=cv2.INTER_AREA,
    )


def print_progress(
    frame_index,
    total_frames,
    current_candidate,
    confirmed_number,
    start_time,
):
    elapsed = time.time() - start_time
    progress_text = "unknown"

    if total_frames > 0:
        progress_text = f"{min(100.0, frame_index / total_frames * 100.0):.1f}%"

    print(
        f"frame {frame_index}"
        f" | progress={progress_text}"
        f" | ocr={current_candidate or 'None'}"
        f" | stable={confirmed_number or 'None'}"
        f" | elapsed={elapsed:.1f}s"
    )


def main():
    args = parse_args()
    runtime_options = build_runtime_options(args)
    configure_cpu(args.cpu_threads)

    expected_numbers = [
        number.strip()
        for number in args.expected.split(",")
        if number.strip()
    ]

    if not expected_numbers:
        expected_numbers = EXPECTED_BUS_NUMBERS

    yolo_stride = runtime_options["yolo_stride"]
    ocr_stride = runtime_options["ocr_stride"]
    write_stride = runtime_options["write_stride"]
    yolo_image_size = runtime_options["imgsz"]
    output_scale = runtime_options["output_scale"]

    if not args.model.exists():
        raise FileNotFoundError(f"Model file not found: {args.model}")

    if not args.video.exists():
        raise FileNotFoundError(f"Video file not found: {args.video}")

    args.output.parent.mkdir(parents=True, exist_ok=True)

    model = YOLO(str(args.model))
    reader = easyocr.Reader(["en"], gpu=False)

    capture = cv2.VideoCapture(str(args.video))

    if not capture.isOpened():
        raise FileNotFoundError(f"Could not open video: {args.video}")

    fps = capture.get(cv2.CAP_PROP_FPS) or 30.0
    width = int(capture.get(cv2.CAP_PROP_FRAME_WIDTH))
    height = int(capture.get(cv2.CAP_PROP_FRAME_HEIGHT))
    raw_total_frames = int(capture.get(cv2.CAP_PROP_FRAME_COUNT))
    output_size = scaled_dimensions(width, height, output_scale)

    if args.max_seconds:
        total_frames = min(raw_total_frames, int(math.ceil(fps * args.max_seconds)))
    else:
        total_frames = raw_total_frames

    output_fps = max(1.0, fps / write_stride)
    writer = cv2.VideoWriter(
        str(args.output),
        cv2.VideoWriter_fourcc(*"mp4v"),
        output_fps,
        output_size,
    )

    if not writer.isOpened():
        raise RuntimeError(f"Could not create output video: {args.output}")

    history = deque(maxlen=OCR_HISTORY_SIZE)

    frame_index = 0
    expected_number = expected_numbers[0]

    last_model_box = None
    last_crop_box = None
    last_yolo_confidence = 0.0
    last_ocr_texts = []
    last_ocr_confidence = 0.0
    last_ocr_method = "none"

    current_candidate = None
    confirmed_number = None
    stable_score = 0
    no_match_count = 0
    detected_once = False
    written_frames = 0
    start_time = time.time()
    progress_interval = max(1, int(fps * 2))

    print("Starting fast presentation render")
    print(f"- mode: {args.mode}")
    print(f"- video: {args.video}")
    print(f"- output: {args.output}")
    print(f"- expected: {', '.join(expected_numbers)}")
    print(
        f"- strides: yolo={yolo_stride}, ocr={ocr_stride}, write={write_stride}"
    )
    print(
        f"- yolo image size: {yolo_image_size}"
        f" | output size: {output_size[0]}x{output_size[1]}"
        f" | cpu threads: {args.cpu_threads}"
    )

    while True:
        if total_frames > 0 and frame_index >= total_frames:
            break

        freeze_after_match = (
            confirmed_number
            and not args.keep_searching_after_match
            and not args.keep_detecting_after_match
        )
        should_run_yolo = frame_index % yolo_stride == 0 and not freeze_after_match
        should_run_ocr = frame_index % ocr_stride == 0

        if confirmed_number and not args.keep_searching_after_match:
            should_run_ocr = False

        should_write_frame = frame_index % write_stride == 0
        needs_frame = should_run_yolo or should_write_frame

        if not needs_frame:
            success = capture.grab()

            if not success:
                break

            if frame_index % progress_interval == 0:
                print_progress(
                    frame_index,
                    total_frames,
                    current_candidate,
                    confirmed_number,
                    start_time,
                )

            frame_index += 1
            continue

        success, frame = capture.read()

        if not success:
            break

        if should_run_yolo:
            results = model.predict(
                frame,
                conf=args.conf,
                imgsz=yolo_image_size,
                device="cpu",
                half=False,
                verbose=False,
            )
            best_box, best_confidence = pick_best_box(results)
            last_yolo_confidence = best_confidence

            if best_box is not None:
                x1, y1, x2, y2 = map(int, best_box.xyxy[0])
                crop_x1, crop_y1, crop_x2, crop_y2 = expand_box(
                    x1,
                    y1,
                    x2,
                    y2,
                    width,
                    height,
                )

                last_model_box = (x1, y1, x2, y2)
                last_crop_box = (crop_x1, crop_y1, crop_x2, crop_y2)

                if should_run_ocr:
                    crop = frame[crop_y1:crop_y2, crop_x1:crop_x2]

                    if crop.size > 0:
                        ocr_texts, ocr_confidence, ocr_method = run_best_ocr(
                            reader,
                            crop,
                            expected_numbers,
                        )

                        last_ocr_texts = ocr_texts
                        last_ocr_confidence = ocr_confidence
                        last_ocr_method = ocr_method

                        current_candidate = extract_route_number(
                            ocr_texts,
                            expected_numbers,
                        )

                        if current_candidate:
                            history.append(current_candidate)

                        new_confirmed, stable_score = choose_confirmed_number(
                            history,
                            expected_numbers,
                        )

                        if new_confirmed:
                            confirmed_number = new_confirmed
                            expected_number = new_confirmed
                            detected_once = True
                            no_match_count = 0
                        else:
                            no_match_count += 1

                        if no_match_count >= NO_MATCH_RESET_COUNT:
                            confirmed_number = None
                            history.clear()
                            stable_score = 0
                            no_match_count = 0

            else:
                last_model_box = None
                last_crop_box = None
                no_match_count += 1

        if frame_index % write_stride == 0:
            display_frame = frame.copy()
            draw_boxes(
                display_frame,
                last_model_box,
                last_crop_box,
                last_yolo_confidence,
            )
            display_frame = draw_overlay(
                display_frame,
                expected_numbers,
                last_yolo_confidence,
                last_ocr_texts,
                last_ocr_confidence,
                last_ocr_method,
                current_candidate,
                confirmed_number,
                stable_score,
                frame_index,
                total_frames,
            )
            writer.write(resize_for_output(display_frame, output_size))
            written_frames += 1

        if frame_index % progress_interval == 0:
            print_progress(
                frame_index,
                total_frames,
                current_candidate,
                confirmed_number,
                start_time,
            )

        frame_index += 1

    capture.release()
    writer.release()

    elapsed = time.time() - start_time

    print(f"Saved presentation video: {args.output}")
    print(f"Processed frames: {frame_index}")
    print(f"Written frames: {written_frames}")
    print(f"Elapsed: {elapsed:.1f}s")

    if detected_once:
        print(f"Detected route number in video: {expected_number}")
    else:
        print("No stable route number was confirmed in this video.")


if __name__ == "__main__":
    main()
