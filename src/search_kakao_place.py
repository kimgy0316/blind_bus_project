# kakao 지도
# 출발지-목적지 위치 좌표

import os

import requests


KAKAO_REST_API_KEY = os.getenv("KAKAO_REST_API_KEY")


def search_place(query, size=5):
    if not KAKAO_REST_API_KEY:
        raise ValueError("KAKAO_REST_API_KEY 환경변수가 설정되지 않았습니다.")

    url = "https://dapi.kakao.com/v2/local/search/keyword.json"
    headers = {
        "Authorization": f"KakaoAK {KAKAO_REST_API_KEY}"
    }
    params = {
        "query": query,
        "size": size
    }

    response = requests.get(url, headers=headers, params=params, timeout=5)
    response.raise_for_status()

    data = response.json()
    return data["documents"]


def print_places(places):
    if not places:
        print("검색 결과가 없습니다.")
        return

    for index, place in enumerate(places, start=1):
        name = place.get("place_name", "")
        address = place.get("road_address_name") or place.get("address_name", "")
        x = place.get("x", "")
        y = place.get("y", "")

        print(f"{index}. {name}")
        print(f"   주소: {address}")
        print(f"   좌표: 경도 {x}, 위도 {y}")


if __name__ == "__main__":
    query = input("검색할 목적지를 입력하세요: ").strip()

    if not query:
        print("검색어가 비어 있습니다.")
    else:
        places = search_place(query)
        print_places(places)