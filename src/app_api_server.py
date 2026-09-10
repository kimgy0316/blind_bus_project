import os
import math
from pedestrian_route import pedestrian_route
import time
from concurrent.futures import ThreadPoolExecutor
from live_bus_info import live_info
from driver_requests import dispatch as driver_dispatch
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlparse
import json
import traceback
from datetime import datetime, timezone

from search_bus_arrival import (
    filter_route_arrivals,
    get_bus_arrivals,
    split_arrivals_by_safety,
)
from search_kakao_place import search_place
from search_transit_route import search_transit_route


HOST = "0.0.0.0"
PORT = int(os.environ.get("PORT", "8765"))

# 출발지는 요청에 포함된 기기 좌표를 사용합니다.
DEFAULT_CITY_CODE = "33010"
MAX_PLACE_RESULTS = 5
MAX_ROUTE_OPTIONS = 5
BOARDING_PREPARATION_SECONDS = 180
SIMILAR_TRAVEL_SECONDS = 120


def get_paths(route_data):
    return route_data.get("result", {}).get("path", [])


def get_bus_numbers(bus_path):
    bus_numbers = []

    for lane in bus_path.get("lane", []):
        bus_no = lane.get("busNo")
        if bus_no:
            bus_numbers.append(str(bus_no))

    return bus_numbers


def count_transfers(path):
    info = path.get("info", {})
    bus_count = info.get("busTransitCount") or 0
    subway_count = info.get("subwayTransitCount") or 0
    total_rides = bus_count + subway_count
    return max(0, total_rides - 1)


def get_walk_before(sub_paths, bus_index):
    for index in range(bus_index - 1, -1, -1):
        sub_path = sub_paths[index]
        if sub_path.get("trafficType") == 3:
            return sub_path
    return {}


def get_walk_after(sub_paths, bus_index):
    for index in range(bus_index + 1, len(sub_paths)):
        sub_path = sub_paths[index]
        if sub_path.get("trafficType") == 3:
            return sub_path
    return {}


def extract_boarding_options(route_data, max_options=None):
    options = []

    for path_index, path in enumerate(get_paths(route_data)[:max_options], start=1):
        info = path.get("info", {})
        sub_paths = path.get("subPath", [])

        for sub_index, sub_path in enumerate(sub_paths):
            if sub_path.get("trafficType") != 2:
                continue

            bus_numbers = get_bus_numbers(sub_path)
            if not bus_numbers:
                continue

            # A first bus reached via a train cannot use a walk-only feasibility check.
            if any(p.get("trafficType") != 3 for p in sub_paths[:sub_index]):
                break
            prefix = sub_paths[:sub_index]
            first_walk = {
                "distance": sum(float(p.get("distance") or 0) for p in prefix),
                "sectionTime": sum(float(p.get("sectionTime") or 0) for p in prefix),
            }
            if any(p.get("sectionTime") is None for p in sub_paths):
                break
            if any(not math.isfinite(float(p["sectionTime"])) or float(p["sectionTime"]) < 0 for p in sub_paths):
                break
            final_walk = get_walk_after(sub_paths, sub_index)

            options.append(
                {
                    "path_index": path_index,
                    "total_time": sum(float(p["sectionTime"]) for p in sub_paths),
                    "total_walk_distance": sum(float(p.get("distance") or 0) for p in sub_paths if p.get("trafficType") == 3),
                    "payment": info.get("payment"),
                    "transfer_count": count_transfers(path),
                    "boarding_stop": sub_path.get("startName", ""),
                    "boarding_x": sub_path.get("startX"),
                    "boarding_y": sub_path.get("startY"),
                    "boarding_node_id": sub_path.get("startLocalStationID"),
                    "dropoff_stop": sub_path.get("endName", ""),
                    "dropoff_node_id": sub_path.get("endLocalStationID"),
                    "station_count": sub_path.get("stationCount", ""),
                    "bus_numbers": bus_numbers,
                    "first_walk_distance": first_walk.get("distance") or 0,
                    "first_walk_time": first_walk.get("sectionTime") or 0,
                    "final_walk_distance": final_walk.get("distance") or 0,
                    "final_walk_time": final_walk.get("sectionTime") or 0,
                }
            )
            break

    return options


def format_place(place):
    return {
        "name": place.get("place_name", ""),
        "address": place.get("road_address_name") or place.get("address_name", ""),
        "description": place.get("category_name", "") or "Kakao 장소 검색 결과",
        "x": str(place.get("x", "")),
        "y": str(place.get("y", "")),
        "phone": place.get("phone", ""),
        "place_url": place.get("place_url", ""),
    }


def normalize_minutes(value):
    if value is None or value == "":
        return None
    try:
        return int(round(float(value)))
    except (TypeError, ValueError):
        return None


def fetch_arrival_snapshot(city_code, node_id):
    try:
        data = get_bus_arrivals(city_code, node_id, num_of_rows=100)
        if str(data.get("response", {}).get("header", {}).get("resultCode")) not in ("00", "0"):
            return None
        body = data.get("response", {}).get("body", {})
        from search_bus_arrival import normalize_items
        if int(body.get("totalCount") or 0) > len(normalize_items(data)):
            return None  # Do not rank a truncated snapshot as complete.
        return data, time.monotonic()
    except Exception:
        return None


def build_arrival_text(option, city_code, snapshots=None):
    node_id = option.get("boarding_node_id")
    if not node_id or not option.get("bus_numbers"):
        return "실시간 도착정보 없음", None
    snapshot = snapshots.get(node_id) if snapshots is not None else fetch_arrival_snapshot(city_code, node_id)
    if snapshot is None:
        return "실시간 도착정보 조회 실패", None
    data, received = snapshot
    elapsed = max(0, time.monotonic() - received)
    required = math.ceil(float(option["first_walk_time"]) * 60) + BOARDING_PREPARATION_SECONDS
    # Use only the first reported arrival of each route, without assuming a later bus.
    first_by_route = {}
    for bus in filter_route_arrivals(data, option["bus_numbers"]):
        if bus["arrival_seconds"] >= 0:
            first_by_route.setdefault(bus["route_no"], bus)
    eligible = []
    for bus in first_by_route.values():
        remaining = bus["arrival_seconds"] - elapsed
        if remaining >= required:
            selected = dict(bus)
            selected["remaining_seconds"] = remaining
            selected["arrival_minutes"] = math.ceil(remaining / 60)
            eligible.append(selected)
    if not eligible:
        return "도보 및 탑승 준비 시간을 확보할 수 있는 도착편 없음", None
    bus = min(eligible, key=lambda b: b["remaining_seconds"])
    return f"약 {bus['arrival_minutes']}분 후 도착", bus


def rank_routes(routes):
    pending = sorted(routes, key=lambda r: r["estimatedTotalSeconds"])
    ranked = []
    while pending:
        cutoff = pending[0]["estimatedTotalSeconds"] + SIMILAR_TRAVEL_SECONDS
        group = [r for r in pending if r["estimatedTotalSeconds"] <= cutoff]
        pending = [r for r in pending if r["estimatedTotalSeconds"] > cutoff]
        group.sort(key=lambda r: (r["totalWalkDistance"], r["transferCount"], r["estimatedTotalSeconds"]))
        ranked.extend(group)
    for rank, route in enumerate(ranked[:MAX_ROUTE_OPTIONS], 1):
        route["id"] = str(rank)
        route["title"] = "추천 경로" if rank == 1 else f"{rank}번 경로"
    return ranked[:MAX_ROUTE_OPTIONS]


def build_recommended_routes(options, destination_name, city_code):
    nodes = list(dict.fromkeys(o["boarding_node_id"] for o in options if o.get("boarding_node_id")))
    with ThreadPoolExecutor(max_workers=4) as pool:
        snapshots = dict(zip(nodes, pool.map(lambda n: fetch_arrival_snapshot(city_code, n), nodes)))
    routes = []
    for option in options:
        route = build_route_response(option, 1, destination_name, city_code, snapshots)
        if route is not None:
            routes.append(route)
    return rank_routes(routes)


def build_steps(option, bus_no, destination_name):
    first_walk_distance = option.get("first_walk_distance") or 0
    first_walk_time = option.get("first_walk_time") or 0
    final_walk_distance = option.get("final_walk_distance") or 0
    final_walk_time = option.get("final_walk_time") or 0
    boarding_stop = option.get("boarding_stop") or "탑승 정류장"
    dropoff_stop = option.get("dropoff_stop") or "하차 정류장"
    station_count = option.get("station_count") or 0

    return [
        {
            "kind": "walk",
            "title": f"{boarding_stop}까지 이동",
            "detail": f"도보 {first_walk_distance}m",
            "time": f"약 {first_walk_time}분",
            "speech": (
                f"{boarding_stop} 정류장까지 도보 {first_walk_distance}미터, "
                f"약 {first_walk_time}분 이동하세요."
            ),
        },
        {
            "kind": "ai",
            "title": "AI 버스 번호 확인",
            "detail": f"YOLO와 OCR로 {bus_no}번 확인",
            "time": "탑승 전",
            "speech": (
                f"AI가 버스 전광판 번호를 확인합니다. "
                f"목표 버스는 {bus_no}번입니다."
            ),
        },
        {
            "kind": "notify",
            "title": "기사님 탑승 알림",
            "detail": "시각장애인 탑승 요청 전송",
            "time": "탑승 전",
            "speech": "기사님에게 시각장애인 탑승 요청 알림을 보냈습니다.",
        },
        {
            "kind": "bus",
            "title": f"{bus_no}번 탑승",
            "detail": f"{dropoff_stop}까지 {station_count}개 정류장 이동",
            "time": "버스 이동",
            "speech": (
                f"{bus_no}번 버스에 탑승하세요. "
                f"{dropoff_stop} 정류장까지 {station_count}개 정류장 이동합니다."
            ),
        },
        {
            "kind": "walk",
            "title": destination_name,
            "detail": f"하차 후 도보 {final_walk_distance}m",
            "time": f"약 {final_walk_time}분",
            "speech": (
                f"하차 후 {destination_name}까지 도보 "
                f"{final_walk_distance}미터, "
                f"약 {final_walk_time}분 이동하세요."
            ),
        },
        {
            "kind": "finish",
            "title": "안내 완료",
            "detail": "목적지 근처에 도착",
            "time": "완료",
            "speech": "목적지 근처에 도착했습니다. 안내를 종료합니다.",
        },
    ]


def build_route_response(option, rank, destination_name, city_code, snapshots=None):
    total_time = normalize_minutes(option.get("total_time"))
    transfer_count = option.get("transfer_count") or 0
    arrival_text, arrival_bus = build_arrival_text(option, city_code, snapshots)

    if arrival_bus is None:
        return None

    bus_no = arrival_bus["route_no"]
    walking_seconds = float(option["first_walk_time"]) * 60
    waiting_seconds = max(0, arrival_bus["remaining_seconds"] - walking_seconds)
    # Sum movement sections and add initial waiting exactly once.
    total_seconds = float(option["total_time"]) * 60 + waiting_seconds
    total_time = math.ceil(total_seconds / 60)

    total_time_text = f"약 {total_time}분" if total_time is not None else "정보 없음"
    walk_text = f"도보 {option.get('first_walk_distance') or 0}m"
    transfer_text = "환승 없음" if transfer_count == 0 else f"환승 {transfer_count}회"

    return {
        "id": str(rank),
        "title": "추천 경로" if rank == 1 else f"{rank}번 경로",
        "busNumber": f"{bus_no}번",
        "arrivalText": arrival_text,
        "totalTime": total_time_text,
        "walkText": walk_text,
        "transferText": transfer_text,
        "summary": (
            f"{option.get('boarding_stop')}에서 {bus_no}번 버스를 타고 "
            f"{option.get('dropoff_stop')}에서 하차합니다. "
            f"정류장까지 도보 약 {math.ceil(float(option['first_walk_time']))}분, 탑승 준비 3분을 반영했습니다."
            + (" 총시간은 환승 대기시간을 제외한 예상입니다." if transfer_count else "")
        ),
        "boardingStop": option.get("boarding_stop", ""),
        "boardingX": option.get("boarding_x"),
        "boardingY": option.get("boarding_y"),
        "dropoffStop": option.get("dropoff_stop", ""),
        "dropoffNodeId": option.get("dropoff_node_id"),
        "stationCount": option.get("station_count", ""),
        "payment": option.get("payment"),
        "nodeId": option.get("boarding_node_id"),
        "cityCode": str(city_code),
        "routeNo": bus_no,
        "routeId": arrival_bus.get("route_id"),
        "vehicleArrivalLinked": False,
        "transferCount": transfer_count,
        "estimatedTotalSeconds": total_seconds,
        "totalWalkDistance": option.get("total_walk_distance", option.get("first_walk_distance", 0)),
        "boardingWalkMinutes": option["first_walk_time"],
        "boardingPreparationSeconds": BOARDING_PREPARATION_SECONDS,
        "initialWaitSeconds": waiting_seconds,
        "transferWaitIncluded": False,
        "arrival": arrival_bus,
        "steps": build_steps(option, bus_no, destination_name),
    }


def make_json_response(handler, status_code, payload):
    if status_code >= 400:
        error_text = str(payload.get("error", "unknown error"))
        print(f"[app_api ERROR] {handler.command} {urlparse(handler.path).path}: {error_text}", flush=True)
        if urlparse(handler.path).path.startswith("/driver"):
            print("[app_api BODY FORMAT] Content-Length=" + str(handler.headers.get("Content-Length"))
                  + ", Transfer-Encoding=" + str(handler.headers.get("Transfer-Encoding")), flush=True)
    body = json.dumps(payload, ensure_ascii=False).encode("utf-8")
    handler.send_response(status_code)
    handler.send_header("Content-Type", "application/json; charset=utf-8")
    handler.send_header("Access-Control-Allow-Origin", "*")
    handler.send_header("Access-Control-Allow-Methods", "GET, POST, OPTIONS")
    handler.send_header("Access-Control-Allow-Headers", "Content-Type")
    handler.send_header("Content-Length", str(len(body)))
    handler.end_headers()
    handler.wfile.write(body)


def resolve_destination_from_body(body):
    """
    Flutter에서 endX, endY를 보내면 그대로 사용하고,
    endX, endY가 없으면 destinationName으로 Kakao 장소 검색 후 첫 번째 결과 좌표를 사용합니다.
    """

    end_x = str(body.get("endX") or body.get("end_x") or body.get("x") or "").strip()
    end_y = str(body.get("endY") or body.get("end_y") or body.get("y") or "").strip()

    destination_name = str(
        body.get("destinationName")
        or body.get("destination")
        or body.get("query")
        or body.get("placeName")
        or "목적지"
    ).strip()

    if end_x and end_y:
        return end_x, end_y, destination_name

    if not destination_name or destination_name == "목적지":
        return "", "", destination_name

    places = search_place(destination_name, size=1)

    if not places:
        return "", "", destination_name

    first_place = places[0]
    end_x = str(first_place.get("x", "")).strip()
    end_y = str(first_place.get("y", "")).strip()

    if first_place.get("place_name"):
        destination_name = first_place.get("place_name")

    return end_x, end_y, destination_name


class AppApiHandler(BaseHTTPRequestHandler):
    def log_message(self, format_text, *args):
        print(f"[app_api] {self.address_string()} - {format_text % args}")

    def do_OPTIONS(self):
        make_json_response(self, 200, {"ok": True})

    def do_GET(self):
        parsed_url = urlparse(self.path)
        query = parse_qs(parsed_url.query)

        try:
            result = driver_dispatch("GET", parsed_url.path, {k: v[0] for k, v in query.items()})
            if result is not None:
                make_json_response(self, *result)
                return
            if parsed_url.path == "/health":
                make_json_response(self, 200, {"ok": True, "message": "blind bus api server"})
                return

            if parsed_url.path == "/live-buses":
                city = query.get("cityCode", [DEFAULT_CITY_CODE])[0]
                node = query.get("nodeId", [""])[0].strip()
                route = query.get("routeNo", [""])[0].strip()
                if not node or not route:
                    make_json_response(self, 400, {"ok": False, "error": "정류장 ID와 노선번호가 필요합니다."})
                    return
                make_json_response(self, 200, live_info(city, node, route))
                return

            if parsed_url.path == "/arrivals":
                node_id = query.get("nodeId", [""])[0].strip()
                route_no = query.get("routeNo", [""])[0].strip()
                city_code = query.get("cityCode", [DEFAULT_CITY_CODE])[0].strip()
                if not node_id or not route_no:
                    make_json_response(self, 400, {"ok": False, "error": "nodeId와 routeNo가 필요합니다."})
                    return
                # 초기 추천의 시간을 재사용하지 않고 정류장 도착 시 다시 조회합니다.
                data = get_bus_arrivals(city_code, node_id)
                header = data.get("response", {}).get("header", {})
                code = str(header.get("resultCode", "00"))
                if code not in ("00", "0"):
                    raise ValueError("버스 도착정보 제공기관 오류: " + str(header.get("resultMsg", code)))
                buses = filter_route_arrivals(data, allowed_route_numbers=[route_no])
                buses = [bus for bus in buses if bus["arrival_seconds"] >= 0]
                make_json_response(self, 200, {
                    "ok": True,
                    "nodeId": node_id,
                    "routeNo": route_no,
                    "checkedAt": datetime.now(timezone.utc).isoformat(),
                    "arrival": buses[0] if buses else None,
                })
                return

            if parsed_url.path == "/places":
                keyword = query.get("query", [""])[0].strip()
                if not keyword:
                    make_json_response(self, 400, {"ok": False, "error": "query가 필요합니다."})
                    return

                size = int(query.get("size", [MAX_PLACE_RESULTS])[0])
                places = [format_place(place) for place in search_place(keyword, size=size)]
                make_json_response(self, 200, {"ok": True, "places": places})
                return

            make_json_response(self, 404, {"ok": False, "error": "없는 API 경로입니다."})

        except Exception as error:
            traceback.print_exc()
            make_json_response(self, 500, {"ok": False, "error": str(error)})

    def do_POST(self):
        parsed_url = urlparse(self.path)

        try:
            content_length = int(self.headers.get("Content-Length", "0"))
            raw_body = self.rfile.read(content_length).decode("utf-8") if content_length else "{}"

            try:
                body = json.loads(raw_body or "{}")
            except json.JSONDecodeError:
                make_json_response(
                    self,
                    400,
                    {
                        "ok": False,
                        "error": "JSON 형식이 올바르지 않습니다.",
                        "rawBody": raw_body,
                    },
                )
                return

            if not isinstance(body, dict):
                make_json_response(self, 400, {"ok": False, "error": "JSON 객체가 필요합니다."})
                return
            if parsed_url.path == "/pedestrian-route":
                try:
                    print("[app_api] pedestrian-route request:", body, flush=True)

                    result = pedestrian_route(body)

                    print(
                        "[app_api] pedestrian-route response:",
                        json.dumps(result, ensure_ascii=False, indent=2),
                        flush=True,
                    )

                    make_json_response(self, 200, result)

                except ValueError as error:
                    print(
                        "[app_api] pedestrian-route error:",
                        str(error),
                        flush=True,
                    )
                    make_json_response(
                        self,
                        400,
                        {
                            "ok": False,
                            "error": str(error),
                        },
                    )

                return
            result = driver_dispatch("POST", parsed_url.path, body)
            if result is not None:
                make_json_response(self, *result)
                return
            print("[app_api] POST body:", body)

            if parsed_url.path == "/routes":
                import os
                if not os.getenv("BUS_ARRIVAL_API_KEY"):
                    make_json_response(self, 503, {"ok": False, "error": "서버의 BUS_ARRIVAL_API_KEY가 설정되지 않았습니다."})
                    return
                start_x = str(body.get("startX") or body.get("start_x") or "")
                start_y = str(body.get("startY") or body.get("start_y") or "")
                try:
                    lon, lat = float(start_x), float(start_y)
                    valid = math.isfinite(lon) and math.isfinite(lat) and -180 <= lon <= 180 and -90 <= lat <= 90
                except (ValueError, TypeError):
                    valid = False
                if not valid:
                    make_json_response(self, 400, {"ok": False, "error": "기기의 출발 위치가 필요합니다. 승객 앱을 업데이트하고 위치를 허용해주세요."})
                    return
                city_code = str(body.get("cityCode") or body.get("city_code") or DEFAULT_CITY_CODE)

                end_x, end_y, destination_name = resolve_destination_from_body(body)

                if not end_x or not end_y:
                    make_json_response(
                        self,
                        400,
                        {
                            "ok": False,
                            "error": "endX, endY가 필요합니다. 또는 destinationName으로 장소 검색이 가능해야 합니다.",
                            "receivedBody": body,
                        },
                    )
                    return

                print(
                    "[app_api] route request:",
                    {
                        "startX": start_x,
                        "startY": start_y,
                        "endX": end_x,
                        "endY": end_y,
                        "destinationName": destination_name,
                        "cityCode": city_code,
                    },
                )

                route_data = search_transit_route(start_x, start_y, end_x, end_y)
                paths = get_paths(route_data)
                options = extract_boarding_options(route_data)

                if not options:
                    message = "추천 가능한 버스 경로가 없습니다."
                    if not paths:
                        result = route_data.get("result") or {}
                        error_message = (
                            route_data.get("error")
                            or result.get("message")
                            or route_data.get("message")
                        )
                        if error_message:
                            message = f"ODsay 경로 검색 결과가 없습니다: {error_message}"
                        else:
                            message = "ODsay 경로 검색 결과가 없습니다."
                    else:
                        message = "ODsay 경로는 찾았지만 버스 탑승 구간을 찾지 못했습니다."

                    make_json_response(
                        self,
                        200,
                        {
                            "ok": True,
                            "routes": [],
                            "message": message,
                            "pathCount": len(paths),
                        },
                    )
                    return

                routes = build_recommended_routes(options, destination_name, city_code)

                if not routes:
                    make_json_response(
                        self,
                        200,
                        {
                            "ok": True,
                            "routes": [],
                            "message": "현재 조회 결과에서 도보 시간과 탑승 준비 3분을 확보할 수 있는 버스가 없습니다. 도착정보 미제공 또는 조회 실패일 수도 있습니다. 잠시 후 다시 검색해주세요.",
                            "pathCount": len(paths),
                            "boardingOptionCount": len(options),
                        },
                    )
                    return

                make_json_response(self, 200, {"ok": True, "routes": routes})
                return

            make_json_response(self, 404, {"ok": False, "error": "없는 API 경로입니다."})

        except Exception as error:
            traceback.print_exc()
            make_json_response(self, 500, {"ok": False, "error": str(error)})


def main():
    server = ThreadingHTTPServer((HOST, PORT), AppApiHandler)
    print(f"Blind Bus 앱 API 서버 실행 중: http://127.0.0.1:{PORT}")
    print("Android 에뮬레이터에서는 http://10.0.2.2:8765 로 접속합니다.")
    print("종료하려면 Ctrl+C를 누르세요.")
    server.serve_forever()


if __name__ == "__main__":
    main()
