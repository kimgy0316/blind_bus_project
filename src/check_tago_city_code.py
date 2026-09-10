# TAGO 청주 인증키 확인용

import os

import requests


BUS_ARRIVAL_API_KEY = os.getenv("BUS_ARRIVAL_API_KEY")

CITY_CODE_URL = (
    "https://apis.data.go.kr/1613000/ArvlInfoInqireService/"
    "getCtyCodeList"
)


def get_city_codes():
    if not BUS_ARRIVAL_API_KEY:
        raise ValueError("BUS_ARRIVAL_API_KEY 환경변수가 설정되지 않았습니다.")

    params = {
        "serviceKey": BUS_ARRIVAL_API_KEY,
        "_type": "json",
    }

    response = requests.get(CITY_CODE_URL, params=params, timeout=10)
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


if __name__ == "__main__":
    data = get_city_codes()
    items = normalize_items(data)

    print("청주 관련 도시코드")

    for item in items:
        city_name = item.get("cityname", "")
        if "청주" in city_name:
            print(item)