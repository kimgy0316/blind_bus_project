# 버스 도착 예정 시간
# 국토교통부(TAGO)

import os

import requests


BUS_ARRIVAL_API_KEY = os.getenv("BUS_ARRIVAL_API_KEY")

ARRIVAL_URL = (
    "https://apis.data.go.kr/1613000/ArvlInfoInqireService/"
    "getSttnAcctoArvlPrearngeInfoList"
)


def get_bus_arrivals(city_code, node_id, num_of_rows=20):
    if not BUS_ARRIVAL_API_KEY:
        raise ValueError("BUS_ARRIVAL_API_KEY 환경변수가 설정되지 않았습니다.")

    params = {
        "serviceKey": BUS_ARRIVAL_API_KEY,
        "pageNo": 1,
        "numOfRows": num_of_rows,
        "_type": "json",
        "cityCode": city_code,
        "nodeId": node_id,
    }

    response = requests.get(ARRIVAL_URL, params=params, timeout=10)
    response.raise_for_status()

    return response.json()


def normalize_items(data):
    body = data.get("response", {}).get("body", {})
    items = body.get("items", {})

    if not items:
        return []

    item = items.get("item", [])

    if isinstance(item, dict):
        return [item]

    return item


def normalize_route_no(route_no):
    return str(route_no).replace(" ", "").strip()


def build_arrival_info(item):
    route_no = normalize_route_no(item.get("routeno"))
    arrival_seconds = int(item.get("arrtime"))
    arrival_minutes = round(arrival_seconds / 60)

    return {
        "route_no": route_no,
        "route_type": item.get("routetp"),
        "arrival_seconds": arrival_seconds,
        "arrival_minutes": arrival_minutes,
        "prev_station_count": item.get("arrprevstationcnt"),
        "node_id": item.get("nodeid"),
        "node_name": item.get("nodenm"),
        "route_id": item.get("routeid"),
        "vehicle_type": item.get("vehicletp"),
        "raw": item,
    }


def filter_route_arrivals(data, allowed_route_numbers=None):
    items = normalize_items(data)
    route_buses = []

    allowed_set = None
    if allowed_route_numbers:
        allowed_set = {
            normalize_route_no(route_no)
            for route_no in allowed_route_numbers
        }

    for item in items:
        route_no = item.get("routeno")
        arrival_time = item.get("arrtime")

        if route_no is None or arrival_time is None:
            continue

        normalized_route_no = normalize_route_no(route_no)

        if allowed_set is not None and normalized_route_no not in allowed_set:
            continue

        route_buses.append(build_arrival_info(item))

    route_buses.sort(key=lambda bus: bus["arrival_seconds"])
    return route_buses


def split_arrivals_by_safety(route_buses, min_minutes=3, max_recommend_minutes=20):
    urgent_buses = []
    recommended_buses = []
    long_wait_buses = []

    for bus in route_buses:
        minutes = bus["arrival_minutes"]

        if minutes < min_minutes:
            urgent_buses.append(bus)
        elif minutes <= max_recommend_minutes:
            recommended_buses.append(bus)
        else:
            long_wait_buses.append(bus)

    return {
        "urgent": urgent_buses,
        "recommended": recommended_buses,
        "long_wait": long_wait_buses,
    }


def print_arrivals(data):
    items = normalize_items(data)

    if not items:
        print("도착 예정 버스 정보가 없습니다.")
        return

    print("\n정류소별 버스 도착 예정 정보")

    for index, item in enumerate(items, start=1):
        route_no = item.get("routeno", "노선번호 없음")
        route_type = item.get("routetp", "")
        arrival_time = item.get("arrtime")
        prev_station_count = item.get("arrprevstationcnt")

        arrival_minutes = None
        if arrival_time is not None:
            arrival_minutes = round(int(arrival_time) / 60)

        print(f"{index}. {route_no}번 {route_type}")

        if arrival_minutes is not None:
            print(f"   도착 예정: 약 {arrival_minutes}분 후")

        if prev_station_count is not None:
            print(f"   남은 정류장 수: {prev_station_count}")


def print_route_arrivals(route_buses):
    if not route_buses:
        print("\n경로상 이용 가능한 버스의 도착정보가 없습니다.")
        return

    print("\n경로상 이용 가능한 버스 도착정보")

    for index, bus in enumerate(route_buses, start=1):
        print(
            f"{index}. {bus['route_no']}번, "
            f"약 {bus['arrival_minutes']}분 후 도착"
        )


def print_recommendation_groups(groups, limit=3):
    recommended = groups["recommended"][:limit]
    urgent = groups["urgent"]
    long_wait = groups["long_wait"]

    if recommended:
        print("\n추천 버스")
        for index, bus in enumerate(recommended, start=1):
            print(
                f"{index}. {bus['route_no']}번, "
                f"약 {bus['arrival_minutes']}분 후 도착"
            )
        return

    if urgent:
        print("\n주의가 필요한 버스")
        for index, bus in enumerate(urgent, start=1):
            print(
                f"{index}. {bus['route_no']}번, "
                f"약 {bus['arrival_minutes']}분 후 도착"
            )
        print("탑승 지원 시간 3분이 부족할 수 있습니다.")
        return

    if long_wait:
        print("\n장시간 대기 버스")
        for index, bus in enumerate(long_wait[:limit], start=1):
            print(
                f"{index}. {bus['route_no']}번, "
                f"약 {bus['arrival_minutes']}분 후 도착"
            )
        print("대기 시간이 길어 다른 경로 확인이 필요할 수 있습니다.")
        return

    print("\n현재 도착 예정 정보가 없습니다.")


if __name__ == "__main__":
    city_code = "33010"
    node_id = "CJB271000042"
    allowed_route_numbers = ["109"]

    data = get_bus_arrivals(city_code, node_id)
    print_arrivals(data)

    route_buses = filter_route_arrivals(
        data,
        allowed_route_numbers=allowed_route_numbers,
    )
    print_route_arrivals(route_buses)

    groups = split_arrivals_by_safety(
        route_buses,
        min_minutes=3,
        max_recommend_minutes=20,
    )
    print_recommendation_groups(groups, limit=3)