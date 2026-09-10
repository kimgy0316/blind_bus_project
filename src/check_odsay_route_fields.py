# 테스트 코드
# 실시간 도착 예정 정보

from pprint import pprint

from search_transit_route import search_transit_route


START_X = "127.431575"
START_Y = "36.626989"

# 청주대학교 정문
END_X = "127.49006049704707"
END_Y = "36.65172751469753"


def main():
    data = search_transit_route(START_X, START_Y, END_X, END_Y)

    paths = data.get("result", {}).get("path", [])

    if not paths:
        print("경로가 없습니다.")
        pprint(data)
        return

    first_path = paths[0]
    sub_paths = first_path.get("subPath", [])

    for index, sub_path in enumerate(sub_paths, start=1):
        print(f"\n{sub_path.get('trafficType')}번 구간 / index {index}")
        pprint(sub_path)


if __name__ == "__main__":
    main()
