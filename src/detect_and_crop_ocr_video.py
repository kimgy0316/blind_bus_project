from collections import deque
from pathlib import Path
import re

import cv2
import easyocr
import numpy as np
from ultralytics import YOLO

try:
    from PIL import Image, ImageDraw, ImageFont
except ImportError:
    Image = None
    ImageDraw = None
    ImageFont = None


ROOT = Path(__file__).resolve().parents[1]

MODEL_PATH = ROOT / "outputs" / "route_display" / "weights" / "best.pt"
VIDEO_PATH = ROOT / "sample_videos" / "test" / "day_012.mp4"
OUTPUT_VIDEO_PATH = ROOT / "outputs" / "route_number_ocr_result_day.mp4"

CONFIDENCE = 0.3
FRAME_STRIDE = 3
PADDING_RATIO = 0.30

EXPECTED_BUS_NUMBERS = ["30-1"]

OCR_HISTORY_SIZE = 8
CONFIRM_SCORE = 4
NO_MATCH_RESET_COUNT = 10

KOREAN_FONT_PATHS = [
    Path("C:/Windows/Fonts/malgun.ttf"),
    Path("C:/Windows/Fonts/malgunbd.ttf"),
]
FONT_CACHE = {}


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


def preprocess_for_ocr(crop):
    resized = cv2.resize(crop, None, fx=4, fy=4, interpolation=cv2.INTER_CUBIC)
    gray = cv2.cvtColor(resized, cv2.COLOR_BGR2GRAY)
    clahe = cv2.createCLAHE(clipLimit=2.0, tileGridSize=(8, 8))
    return clahe.apply(gray)


def extract_route_number(text):
    compact = text.replace(" ", "")

    hyphen_match = re.search(r"\d{1,3}-\d{1,2}", compact)
    if hyphen_match:
        return hyphen_match.group()

    number_match = re.search(r"\d{1,4}", compact)
    if number_match:
        return number_match.group()

    return None


def read_route_number(reader, crop):
    processed = preprocess_for_ocr(crop)

    raw_results = reader.readtext(
        processed,
        detail=1,
        paragraph=False,
        allowlist="0123456789-",
    )

    if not raw_results:
        return [], None, 0.0

    raw_texts = []
    confidences = []

    for result in raw_results:
        raw_texts.append(result[1])
        confidences.append(float(result[2]))

    joined_text = " ".join(raw_texts)
    parsed_number = extract_route_number(joined_text)
    ocr_confidence = max(confidences) if confidences else 0.0

    return raw_texts, parsed_number, ocr_confidence


def normalize_number(number):
    if number is None:
        return None

    return re.sub(r"\D", "", str(number))


def score_candidate(ocr_text, expected_number):
    ocr_number = normalize_number(ocr_text)
    expected = normalize_number(expected_number)

    if not ocr_number or not expected:
        return 0

    if len(ocr_number) < 2:
        return 0

    if ocr_number == expected:
        return 3

    if len(ocr_number) >= len(expected) and ocr_number.startswith(expected):
        return 2

    if len(ocr_number) >= 2 and expected.startswith(ocr_number):
        return 1

    return 0


def update_stable_number(history, parsed_number):
    if parsed_number:
        history.append(parsed_number)

    scores = {expected: 0 for expected in EXPECTED_BUS_NUMBERS}

    for history_item in history:
        for expected in EXPECTED_BUS_NUMBERS:
            scores[expected] += score_candidate(history_item, expected)

    best_number = None
    best_score = 0

    for number, score in scores.items():
        if score > best_score:
            best_number = number
            best_score = score

    if best_score >= CONFIRM_SCORE:
        return best_number, best_score

    return None, best_score


def has_any_candidate_match(parsed_number):
    if not parsed_number:
        return False

    for expected in EXPECTED_BUS_NUMBERS:
        if score_candidate(parsed_number, expected) > 0:
            return True

    return False


def calculate_decision_confidence(
    parsed_number,
    confirmed_number,
    score,
    ocr_confidence,
):
    if confirmed_number:
        parsed_clean = normalize_number(parsed_number)
        confirmed_clean = normalize_number(confirmed_number)

        if parsed_clean and parsed_clean == confirmed_clean:
            return min(0.99, max(0.95, 0.80 + score * 0.01))

        return min(0.95, max(0.80, 0.60 + score * 0.03))

    if parsed_number:
        return min(0.70, max(ocr_confidence, 0.30 + score * 0.05))

    return 0.0


def should_record_event(events, number, frame_index, min_frame_gap=30):
    if not events:
        return True

    last_event = events[-1]

    if last_event["number"] != number:
        return True

    if frame_index - last_event["frame"] >= min_frame_gap:
        return True

    return False


def get_korean_font(font_size):
    if ImageFont is None:
        return None

    if font_size in FONT_CACHE:
        return FONT_CACHE[font_size]

    for font_path in KOREAN_FONT_PATHS:
        if font_path.exists():
            FONT_CACHE[font_size] = ImageFont.truetype(str(font_path), font_size)
            return FONT_CACHE[font_size]

    FONT_CACHE[font_size] = ImageFont.load_default()
    return FONT_CACHE[font_size]


def draw_text_lines(frame, lines, x, y, font_size=28, line_gap=34):
    if Image is None or ImageDraw is None:
        for index, (text, rgb_color) in enumerate(lines):
            bgr_color = (rgb_color[2], rgb_color[1], rgb_color[0])
            cv2.putText(
                frame,
                text,
                (x, y + index * line_gap),
                cv2.FONT_HERSHEY_SIMPLEX,
                0.75,
                bgr_color,
                2,
                cv2.LINE_AA,
            )
        return frame

    font = get_korean_font(font_size)
    rgb_frame = cv2.cvtColor(frame, cv2.COLOR_BGR2RGB)
    pil_image = Image.fromarray(rgb_frame)
    draw = ImageDraw.Draw(pil_image)

    for index, (text, rgb_color) in enumerate(lines):
        draw.text(
            (x, y + index * line_gap),
            text,
            font=font,
            fill=rgb_color,
        )

    frame[:] = cv2.cvtColor(np.array(pil_image), cv2.COLOR_RGB2BGR)
    return frame


def draw_terminal_overlay(
    frame,
    ocr_frame_index,
    raw_results,
    parsed_number,
    confirmed_number,
    score,
    no_match_count,
    ocr_confidence,
    decision_confidence,
    detection_confidence,
):
    height, width = frame.shape[:2]
    overlay = frame.copy()

    panel_width = min(width - 24, 760)
    panel_height = 190

    cv2.rectangle(
        overlay,
        (12, 12),
        (12 + panel_width, 12 + panel_height),
        (0, 0, 0),
        -1,
    )

    frame[:] = cv2.addWeighted(overlay, 0.65, frame, 0.35, 0)

    frame_text = "None" if ocr_frame_index is None else str(ocr_frame_index)
    confirmed_text = "None" if confirmed_number is None else str(confirmed_number)
    parsed_text = "None" if parsed_number is None else str(parsed_number)

    lines = [
        (f"OCR 프레임: {frame_text}", (255, 255, 255)),
        (f"읽은 번호: {parsed_text}", (255, 255, 0) if parsed_number else (255, 255, 255)),
        (f"확정 번호: {confirmed_text}", (0, 255, 0) if confirmed_number else (255, 255, 255)),
        (f"점수: {score}", (255, 255, 255)),
        (
            f"판정 신뢰도: {decision_confidence:.2f} ",
            (255, 255, 255),
        ),
    ]

    return draw_text_lines(frame, lines, 32, 35, font_size=28, line_gap=32)


def main():
    model = YOLO(MODEL_PATH)
    reader = easyocr.Reader(["en"], gpu=False)

    capture = cv2.VideoCapture(str(VIDEO_PATH))

    if not capture.isOpened():
        raise FileNotFoundError(f"Video file could not be opened: {VIDEO_PATH}")

    fps = capture.get(cv2.CAP_PROP_FPS)
    width = int(capture.get(cv2.CAP_PROP_FRAME_WIDTH))
    height = int(capture.get(cv2.CAP_PROP_FRAME_HEIGHT))

    OUTPUT_VIDEO_PATH.parent.mkdir(parents=True, exist_ok=True)

    writer = cv2.VideoWriter(
        str(OUTPUT_VIDEO_PATH),
        cv2.VideoWriter_fourcc(*"mp4v"),
        fps,
        (width, height),
    )

    frame_index = 0
    ocr_history = deque(maxlen=OCR_HISTORY_SIZE)
    stable_route_number = None
    latest_ocr_frame_index = None
    latest_raw_results = []
    latest_parsed_number = None
    latest_ocr_confidence = 0.0
    latest_decision_confidence = 0.0
    latest_detection_confidence = 0.0
    latest_score = 0
    no_match_count = 0
    confirmed_events = []

    while True:
        success, frame = capture.read()

        if not success:
            break

        if frame_index % FRAME_STRIDE == 0:
            results = model.predict(frame, conf=CONFIDENCE, verbose=False)

            for result in results:
                for box in result.boxes:
                    x1, y1, x2, y2 = box.xyxy[0].tolist()
                    detection_confidence = float(box.conf[0])
                    latest_detection_confidence = detection_confidence

                    x1, y1, x2, y2 = map(int, [x1, y1, x2, y2])

                    expanded_x1, expanded_y1, expanded_x2, expanded_y2 = expand_box(
                        x1,
                        y1,
                        x2,
                        y2,
                        width,
                        height,
                        PADDING_RATIO,
                    )

                    crop = frame[expanded_y1:expanded_y2, expanded_x1:expanded_x2]

                    if crop.size == 0:
                        continue

                    raw_results, parsed_number, ocr_confidence = read_route_number(
                        reader,
                        crop,
                    )

                    latest_ocr_frame_index = frame_index
                    latest_raw_results = raw_results
                    latest_parsed_number = parsed_number
                    latest_ocr_confidence = ocr_confidence

                    if has_any_candidate_match(parsed_number):
                        no_match_count = 0
                    else:
                        no_match_count += 1

                    confirmed_number, score = update_stable_number(
                        ocr_history,
                        parsed_number,
                    )

                    latest_score = score

                    if confirmed_number:
                        stable_route_number = confirmed_number

                        if should_record_event(
                            confirmed_events,
                            confirmed_number,
                            frame_index,
                        ):
                            confirmed_events.append(
                                {
                                    "frame": frame_index,
                                    "number": confirmed_number,
                                    "score": latest_score,
                                }
                            )

                    if stable_route_number and no_match_count >= NO_MATCH_RESET_COUNT:
                        stable_route_number = None
                        ocr_history.clear()
                        latest_score = 0
                        no_match_count = 0

                    latest_decision_confidence = calculate_decision_confidence(
                        latest_parsed_number,
                        stable_route_number,
                        latest_score,
                        latest_ocr_confidence,
                    )

                    print(
                        f"프레임 {frame_index} | "
                        f"읽은 번호={parsed_number} | "
                        f"확정 번호={stable_route_number} | "
                        f"판정 신뢰도={latest_decision_confidence:.2f} | "
                        f"OCR 신뢰도={latest_ocr_confidence:.2f} | "
                        f"YOLO 신뢰도={latest_detection_confidence:.2f} | "
                        f"점수={latest_score} | "
                    )

                    label_1 = (
                        f"읽은번호:{latest_parsed_number or '?'} "
                        f"판정:{latest_decision_confidence:.2f}"
                    )

                    label_2 = (
                        f"확정:{stable_route_number or '?'} "
                        f"점수:{latest_score} "
                        f"OCR:{latest_ocr_confidence:.2f} "
                        f"YOLO 신뢰도:{detection_confidence:.2f}"
                    )

                    cv2.rectangle(
                        frame,
                        (expanded_x1, expanded_y1),
                        (expanded_x2, expanded_y2),
                        (0, 255, 0),
                        2,
                    )

                    draw_text_lines(
                        frame,
                        [
                            (label_1, (0, 255, 0)),
                            (label_2, (0, 255, 0)),
                        ],
                        expanded_x1,
                        max(0, expanded_y1 - 52),
                        font_size=22,
                        line_gap=25,
                    )

        draw_terminal_overlay(
            frame,
            latest_ocr_frame_index,
            latest_raw_results,
            latest_parsed_number,
            stable_route_number,
            latest_score,
            no_match_count,
            latest_ocr_confidence,
            latest_decision_confidence,
            latest_detection_confidence,
        )

        writer.write(frame)
        frame_index += 1

    capture.release()
    writer.release()

    print(f"OCR 결과 영상 저장 완료: {OUTPUT_VIDEO_PATH}")

    if confirmed_events:
        print("감지된 노선번호 이벤트:")

        for event in confirmed_events:
            print(
                f"- 프레임 {event['frame']}: "
                f"{event['number']} "
                f"(점수 {event['score']})"
            )
    else:
        print("확정된 노선번호 이벤트가 없습니다.")


if __name__ == "__main__":
    main()