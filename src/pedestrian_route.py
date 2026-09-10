"""TMAP pedestrian routes. Keys stay on the Python server."""
import math
import os
import requests


def coordinate(value, latitude=False):
    try:
        number = float(value)
    except (TypeError, ValueError):
        raise ValueError("도보 출발지와 정류장 좌표가 필요합니다.") from None
    limit = 90 if latitude else 180
    if isinstance(value, bool) or not math.isfinite(number) or not -limit <= number <= limit:
        raise ValueError("도보 좌표가 올바르지 않습니다.")
    return number


def distance(a, b):
    lat1, lat2 = math.radians(a[1]), math.radians(b[1])
    h = math.sin((lat2-lat1)/2)**2 + math.cos(lat1)*math.cos(lat2)*math.sin(math.radians(b[0]-a[0])/2)**2
    return 6371000 * 2 * math.asin(min(1, math.sqrt(h)))


def normalize(data):
    features = data.get("features", [])
    if not isinstance(features, list) or not features:
        raise ValueError("보행 경로를 찾지 못했습니다.")
    path, instructions = [], []
    length = 0.0
    total_distance = total_time = None
    for feature in features:
        geometry = feature.get("geometry") or {}
        properties = feature.get("properties") or {}
        kind = geometry.get("type")
        if kind not in ("Point", "LineString"):
            continue
        coordinates = geometry.get("coordinates") or []
        points = [coordinates] if kind == "Point" else coordinates
        for point in points:
            if not isinstance(point, list) or len(point) < 2:
                raise ValueError("보행 경로 좌표를 확인할 수 없습니다.")
            pos = [coordinate(point[0]), coordinate(point[1], True)]
            if path:
                gap = distance(path[-1], pos)
                if gap < 0.05:
                    continue
                length += gap
            path.append(pos)
        if properties.get("totalDistance") is not None:
            total_distance = float(properties["totalDistance"])
            total_time = float(properties["totalTime"])
        if kind == "Point":
            instructions.append({
                "offset": round(length, 2),
                "turnType": int(properties.get("turnType") or 0),
                "description": str(properties.get("description") or "")[:500],
                "facilityType": properties.get("facilityType"),
            })
    if len(path) < 2 or length < 1 or total_distance is None or total_time is None:
        raise ValueError("사용할 수 있는 보행 경로가 없습니다.")
    if not all(math.isfinite(x) and x >= 0 for x in (length, total_distance, total_time)):
        raise ValueError("보행 경로의 거리와 시간을 확인할 수 없습니다.")
    return {"ok": True, "provider": "TMAP", "path": path,
            "instructions": instructions, "geometryDistance": length,
            "totalDistance": total_distance, "totalTime": total_time}


def pedestrian_route(body):
    start = [coordinate(body.get("startX")), coordinate(body.get("startY"), True)]
    end = [coordinate(body.get("endX")), coordinate(body.get("endY"), True)]
    if distance(start, end) > 30000:
        raise ValueError("정류장까지의 도보 거리가 너무 멉니다. 출발 위치를 확인해주세요.")
    key = os.getenv("TMAP_APP_KEY", "").strip()
    if not key:
        raise ValueError("서버의 TMAP_APP_KEY를 설정해주세요.")
    try:
        response = requests.post(
            "https://apis.openapi.sk.com/tmap/routes/pedestrian?version=1",
            headers={"appKey": key, "Accept": "application/json"},
            json={"startX": start[0], "startY": start[1], "endX": end[0], "endY": end[1],
                  "startName": "Start", "endName": "BusStop", "reqCoordType": "WGS84GEO",
                  "resCoordType": "WGS84GEO", "searchOption": "0", "sort": "index"},
            timeout=(5, 15))
    except requests.RequestException:
        raise ValueError("도보 경로 서버에 연결하지 못했습니다. 다시 시도해주세요.") from None
    if response.status_code in (401, 403):
        raise ValueError("TMAP 앱 키와 보행자 경로 API 이용 권한을 확인해주세요.")
    if response.status_code == 429:
        raise ValueError("TMAP 조회 한도를 초과했습니다. 잠시 후 다시 시도해주세요.")
    if response.status_code != 200:
        raise ValueError("TMAP에서 보행 경로를 받지 못했습니다.")
    try:
        result = normalize(response.json())
    except (KeyError, TypeError, OverflowError):
        raise ValueError("TMAP 경로 응답을 확인할 수 없습니다.") from None
    if distance(result["path"][0], start) > 80 or distance(result["path"][-1], end) > 60:
        raise ValueError("보행 경로의 출발점 또는 도착점이 요청 위치와 다릅니다.")
    return dict(result, nodeId=str(body.get("nodeId") or ""), destination=end)
