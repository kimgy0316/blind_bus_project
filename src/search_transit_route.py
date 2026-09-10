# ODsay 대중교통 경로 검색
# 출발지-목적지 좌표
# 대중교통 경로 결과 출력

# SX = 출발지 경도
# SY = 출발지 위도
# EX = 목적지 경도
# EY = 목적지 위도

import os

import requests


ODSAY_API_KEY = os.getenv("ODSAY_API_KEY")


def search_transit_route(start_x, start_y, end_x, end_y):
    if not ODSAY_API_KEY:
        raise ValueError("ODSAY_API_KEY 환경변수가 설정되지 않았습니다.")

    url = "https://api.odsay.com/v1/api/searchPubTransPathT"

    params = {
        "apiKey": ODSAY_API_KEY,
        "SX": start_x,
        "SY": start_y,
        "EX": end_x,
        "EY": end_y,
        "lang": 0,
        "output": "json",
    }

    response = requests.get(url, params=params, timeout=10)
    response.raise_for_status()

    return response.json()


def print_route_summary(data):
    result = data.get("result")

    if not result:
        print("경로 검색 결과가 없습니다.")
        print(data)
        return

    paths = result.get("path", [])

    if not paths:
        print("추천 경로가 없습니다.")
        return

    for index, path in enumerate(paths[:3], start=1):
        info = path.get("info", {})
        total_time = info.get("totalTime")
        payment = info.get("payment")
        bus_transit_count = info.get("busTransitCount")
        subway_transit_count = info.get("subwayTransitCount")

        print(f"\n{index}번 경로")
        print(f"총 소요 시간: {total_time}분")
        print(f"요금: {payment}원")
        print(f"버스 탑승 횟수: {bus_transit_count}")
        print(f"지하철 탑승 횟수: {subway_transit_count}")

        sub_paths = path.get("subPath", [])

        for sub_path in sub_paths:
            traffic_type = sub_path.get("trafficType")

            if traffic_type == 3:
                distance = sub_path.get("distance")
                section_time = sub_path.get("sectionTime")
                print(f"- 도보 {distance}m, 약 {section_time}분")

            elif traffic_type == 2:
                lane_info = sub_path.get("lane", [{}])[0]
                bus_no = lane_info.get("busNo", "버스 번호 없음")
                start_name = sub_path.get("startName", "")
                end_name = sub_path.get("endName", "")
                station_count = sub_path.get("stationCount", "")

                print(f"- 버스 {bus_no}")
                print(f"  탑승: {start_name}")
                print(f"  하차: {end_name}")
                print(f"  정류장 수: {station_count}")

            elif traffic_type == 1:
                lane_info = sub_path.get("lane", [{}])[0]
                subway_name = lane_info.get("name", "지하철")
                start_name = sub_path.get("startName", "")
                end_name = sub_path.get("endName", "")
                station_count = sub_path.get("stationCount", "")

                print(f"- {subway_name}")
                print(f"  탑승: {start_name}")
                print(f"  하차: {end_name}")
                print(f"  역 수: {station_count}")


if __name__ == "__main__":
    # 테스트용 출발지: 청주고속버스터미널 근처
    start_x = "127.431575"
    start_y = "36.626989"

    # 테스트용 목적지: 청주대학교
    end_x = "127.49512976914777"
    end_y = "36.653087976365434"

    data = search_transit_route(start_x, start_y, end_x, end_y)
    print_route_summary(data)