from search_bus_arrival import (
    filter_route_arrivals,
    get_bus_arrivals,
    split_arrivals_by_safety,
)
from search_kakao_place import search_place
from search_transit_route import search_transit_route
from voice_destination import listen_destination, listen_speech, speak
from voice_place_search import read_places


START_X = "127.431575"
START_Y = "36.626989"
TAGO_CITY_CODE = "33010"

MAX_PATH_OPTIONS = 5


def parse_choice(text):
    text = text.replace(" ", "")

    mapping = {
        "1": 1, "1번": 1, "일": 1, "일번": 1, "첫번째": 1, "첫": 1,
        "2": 2, "2번": 2, "이": 2, "이번": 2, "두번째": 2, "둘": 2,
        "3": 3, "3번": 3, "삼": 3, "삼번": 3, "세번째": 3, "셋": 3,
        "4": 4, "4번": 4, "사": 4, "사번": 4, "네번째": 4, "넷": 4,
        "5": 5, "5번": 5, "오": 5, "오번": 5, "다섯번째": 5, "다섯": 5,
    }

    return mapping.get(text)


def choose_place_by_voice(places):
    if not places:
        return None

    for attempt in range(3):
        choice_text = listen_speech("선택할 번호를 말씀해 주세요.")

        if not choice_text:
            continue

        print(f"인식된 선택: {choice_text}")

        choice = parse_choice(choice_text)

        if choice is None:
            speak("번호를 알아듣지 못했습니다.")
            print("번호를 알아듣지 못했습니다.")
            continue

        if 1 <= choice <= len(places):
            return places[choice - 1]

        speak("목록에 없는 번호입니다.")
        print("목록에 없는 번호입니다.")

    print("음성 선택에 실패했습니다.")
    speak("음성 선택에 실패했습니다. 키보드로 번호를 입력해 주세요.")

    while True:
        choice = input("선택할 번호를 입력하세요: ").strip()

        if choice.isdigit():
            index = int(choice)
            if 1 <= index <= len(places):
                return places[index - 1]

        print("올바른 번호를 입력해 주세요.")


def get_paths(route_data):
    return route_data.get("result", {}).get("path", [])


def get_bus_numbers(bus_path):
    lanes = bus_path.get("lane", [])
    bus_numbers = []

    for lane in lanes:
        bus_no = lane.get("busNo")
        if bus_no:
            bus_numbers.append(str(bus_no))

    return bus_numbers


def get_first_walk_before_bus(sub_paths, bus_index):
    for index in range(bus_index - 1, -1, -1):
        sub_path = sub_paths[index]
        if sub_path.get("trafficType") == 3:
            return sub_path
    return None


def get_final_walk_after_first_bus(sub_paths, bus_index):
    for index in range(bus_index + 1, len(sub_paths)):
        sub_path = sub_paths[index]
        if sub_path.get("trafficType") == 3:
            return sub_path
    return None


def count_transfers(path):
    info = path.get("info", {})
    bus_count = info.get("busTransitCount") or 0
    subway_count = info.get("subwayTransitCount") or 0
    total_rides = bus_count + subway_count

    return max(0, total_rides - 1)


def extract_boarding_options(route_data, max_options=5):
    paths = get_paths(route_data)
    options = []

    for path_index, path in enumerate(paths[:max_options], start=1):
        info = path.get("info", {})
        sub_paths = path.get("subPath", [])

        for sub_index, sub_path in enumerate(sub_paths):
            if sub_path.get("trafficType") != 2:
                continue

            bus_numbers = get_bus_numbers(sub_path)

            if not bus_numbers:
                continue

            first_walk = get_first_walk_before_bus(sub_paths, sub_index)
            final_walk = get_final_walk_after_first_bus(sub_paths, sub_index)

            options.append({
                "path_index": path_index,
                "path": path,
                "bus_path": sub_path,
                "total_time": info.get("totalTime"),
                "payment": info.get("payment"),
                "transfer_count": count_transfers(path),
                "boarding_stop": sub_path.get("startName", ""),
                "boarding_node_id": sub_path.get("startLocalStationID"),
                "dropoff_stop": sub_path.get("endName", ""),
                "station_count": sub_path.get("stationCount", ""),
                "bus_numbers": bus_numbers,
                "first_walk_distance": first_walk.get("distance") if first_walk else 0,
                "first_walk_time": first_walk.get("sectionTime") if first_walk else 0,
                "final_walk_distance": final_walk.get("distance") if final_walk else 0,
                "final_walk_time": final_walk.get("sectionTime") if final_walk else 0,
            })
            break

    return options


def print_and_speak_initial_overview(options):
    if not options:
        print("버스 구간이 포함된 경로를 찾지 못했습니다.")
        speak("버스 구간이 포함된 경로를 찾지 못했습니다.")
        return

    first_option = options[0]

    print("\n이동 개요")
    print(f"예상 총 소요 시간: {first_option['total_time']}분")
    print(f"예상 요금: {first_option['payment']}원")
    print(f"첫 탑승 정류장: {first_option['boarding_stop']}")
    print(f"하차 예정 정류장: {first_option['dropoff_stop']}")
    print(f"환승 횟수: {first_option['transfer_count']}")
    print(f"탑승 정류장까지 도보 거리: {first_option['first_walk_distance']}미터")
    print(f"탑승 정류장까지 도보 시간: 약 {first_option['first_walk_time']}분")
    print(f"하차 후 목적지까지 도보 거리: {first_option['final_walk_distance']}미터")
    print(f"하차 후 목적지까지 도보 시간: 약 {first_option['final_walk_time']}분")

    print("\n대중교통 경로 후보")
    for option in options:
        print(
            f"- {option['path_index']}번 경로: "
            f"{option['boarding_stop']}에서 "
            f"{', '.join(option['bus_numbers'])}번 탑승 가능, "
            f"총 {option['total_time']}분, "
            f"환승 {option['transfer_count']}회"
        )

    speak(
        f"이동 개요입니다. 예상 총 소요 시간은 {first_option['total_time']}분이고, "
        f"예상 요금은 {first_option['payment']}원입니다. "
        f"먼저 {first_option['boarding_stop']} 정류장까지 "
        f"{first_option['first_walk_distance']}미터, "
        f"약 {first_option['first_walk_time']}분 이동합니다. "
        f"정류장에 도착하면 실시간 도착정보를 기준으로 탑승할 버스를 다시 안내하겠습니다."
    )

    print("\n정류장 도착 후 안내 예정")
    print("정류장 비콘으로 실제 도착이 확인되면,")
    print("현재 정류장에서 탈 수 있는 경로 후보들을 실시간 도착정보와 비교합니다.")
    print("3분 미만은 주의, 3분에서 20분 사이는 추천, 20분 초과는 장시간 대기로 분류합니다.")

    speak(
        "정류장에 도착하면 비콘으로 실제 도착 여부를 확인하고, "
        "현재 정류장에서 탈 수 있는 버스 후보를 안내하겠습니다."
    )


def wait_for_bus_stop_arrival_mock():
    print("\n[프로토타입] 실제 앱에서는 이 단계에서 정류장 비콘을 감지합니다.")
    print("정류장에 도착했다고 가정하려면 Enter를 누르세요.")
    input()


def group_options_by_boarding_stop(options):
    grouped = {}

    for option in options:
        node_id = option.get("boarding_node_id")
        if not node_id:
            continue

        if node_id not in grouped:
            grouped[node_id] = {
                "node_id": node_id,
                "boarding_stop": option.get("boarding_stop", ""),
                "options": [],
                "bus_numbers": set(),
            }

        grouped[node_id]["options"].append(option)
        grouped[node_id]["bus_numbers"].update(option.get("bus_numbers", []))

    return grouped


def build_arrival_recommendations(options):
    grouped = group_options_by_boarding_stop(options)
    recommendations = []

    for group in grouped.values():
        node_id = group["node_id"]
        bus_numbers = sorted(group["bus_numbers"])

        arrival_data = get_bus_arrivals(TAGO_CITY_CODE, node_id)
        route_buses = filter_route_arrivals(
            arrival_data,
            allowed_route_numbers=bus_numbers,
        )
        safety_groups = split_arrivals_by_safety(
            route_buses,
            min_minutes=3,
            max_recommend_minutes=20,
        )

        for option in group["options"]:
            option_bus_numbers = set(option["bus_numbers"])

            for category_name, category_buses in safety_groups.items():
                for bus in category_buses:
                    if bus["route_no"] not in option_bus_numbers:
                        continue

                    recommendations.append({
                        "category": category_name,
                        "bus": bus,
                        "option": option,
                    })

    return recommendations


def sort_recommendations(recommendations):
    category_rank = {
        "recommended": 0,
        "urgent": 1,
        "long_wait": 2,
    }

    return sorted(
        recommendations,
        key=lambda item: (
            category_rank.get(item["category"], 99),
            item["option"]["transfer_count"],
            item["option"]["total_time"] or 9999,
            item["bus"]["arrival_seconds"],
        )
    )


def get_recommendation_reason(item, rank):
    bus = item["bus"]
    option = item["option"]
    category = item["category"]

    if category == "recommended":
        if rank == 1:
            return (
                "추천 이유: 탑승 지원 시간을 확보할 수 있고, "
                "환승 횟수와 전체 이동 시간이 가장 유리합니다."
            )
        return (
            "추천 이유: 탑승 지원 시간이 확보되며, "
            "대체 경로로 이용할 수 있습니다."
        )

    if category == "urgent":
        return (
            "주의 이유: 버스가 너무 빨리 도착하여 "
            "기사 알림과 탑승 지원 시간이 부족할 수 있습니다."
        )

    if category == "long_wait":
        return (
            "안내 이유: 탑승은 가능하지만 대기 시간이 길어 "
            "다른 경로 확인이 필요할 수 있습니다."
        )

    return "안내 이유: 경로 후보에 포함된 버스입니다."


def print_driver_notification_mock(item):
    bus = item["bus"]
    option = item["option"]

    print("\n기사 앱 알림 mock")
    print(f"알림 대상 버스: {bus['route_no']}번")
    print(f"탑승 정류장: {option['boarding_stop']}")
    print(f"하차 정류장: {option['dropoff_stop']}")
    print(f"도착 예정: 약 {bus['arrival_minutes']}분 후")
    print("승객 유형: 시각장애인")
    print("요청 내용: 탑승 및 하차 지원 요청")


def print_and_speak_recommendations(recommendations):
    if not recommendations:
        print("\n현재 경로 후보에 해당하는 버스 도착정보가 없습니다.")
        speak("현재 경로 후보에 해당하는 버스 도착정보가 없습니다.")
        return

    sorted_recommendations = sort_recommendations(recommendations)
    recommended = [item for item in sorted_recommendations if item["category"] == "recommended"]
    urgent = [item for item in sorted_recommendations if item["category"] == "urgent"]
    long_wait = [item for item in sorted_recommendations if item["category"] == "long_wait"]

    if recommended:
        print("\n추천 버스")
        for index, item in enumerate(recommended[:3], start=1):
            bus = item["bus"]
            option = item["option"]
            reason = get_recommendation_reason(item, index)

            print(
                f"{index}. {bus['route_no']}번, "
                f"약 {bus['arrival_minutes']}분 후 도착, "
                f"{option['boarding_stop']} 탑승, "
                f"{option['dropoff_stop']} 하차, "
                f"총 {option['total_time']}분, "
                f"환승 {option['transfer_count']}회"
            )
            print(f"   {reason}")

        first = recommended[0]
        print_driver_notification_mock(first)

        speak(
            f"추천 버스는 {first['bus']['route_no']}번입니다. "
            f"약 {first['bus']['arrival_minutes']}분 후 도착 예정입니다. "
            f"{first['option']['boarding_stop']} 정류장에서 탑승하고, "
            f"{first['option']['dropoff_stop']} 정류장에서 하차합니다. "
            f"기사에게 탑승 지원 알림을 보냅니다."
        )
        return

    if urgent:
        print("\n주의가 필요한 버스")
        for index, item in enumerate(urgent[:3], start=1):
            bus = item["bus"]
            option = item["option"]
            reason = get_recommendation_reason(item, index)

            print(
                f"{index}. {bus['route_no']}번, "
                f"약 {bus['arrival_minutes']}분 후 도착, "
                f"{option['boarding_stop']} 탑승"
            )
            print(f"   {reason}")

        first = urgent[0]
        speak(
            f"{first['bus']['route_no']}번 버스가 약 "
            f"{first['bus']['arrival_minutes']}분 후 도착 예정입니다. "
            f"하지만 탑승 지원 시간 3분이 부족할 수 있어 주의가 필요합니다."
        )
        return

    if long_wait:
        print("\n장시간 대기 버스")
        for index, item in enumerate(long_wait[:3], start=1):
            bus = item["bus"]
            option = item["option"]
            reason = get_recommendation_reason(item, index)

            print(
                f"{index}. {bus['route_no']}번, "
                f"약 {bus['arrival_minutes']}분 후 도착, "
                f"{option['boarding_stop']} 탑승"
            )
            print(f"   {reason}")

        first = long_wait[0]
        speak(
            f"{first['bus']['route_no']}번 버스는 약 "
            f"{first['bus']['arrival_minutes']}분 후 도착 예정입니다. "
            f"대기 시간이 길어 다른 경로를 확인할 수 있습니다."
        )


def guide_after_bus_stop_arrival(options):
    print("\n정류장 도착 확인")
    print("비콘 감지 성공: 탑승 정류장에 도착했습니다.")
    print("실시간 버스 도착정보를 조회합니다.")

    speak("정류장 도착이 확인되었습니다. 실시간 버스 도착정보를 조회합니다.")

    recommendations = build_arrival_recommendations(options)
    print_and_speak_recommendations(recommendations)


def main():
    destination = listen_destination()

    if not destination:
        return

    print(f"인식된 목적지: {destination}")
    speak(f"{destination}를 검색합니다.")

    places = search_place(destination)
    read_places(places)

    selected_place = choose_place_by_voice(places)

    if not selected_place:
        return

    name = selected_place.get("place_name", "")
    address = selected_place.get("road_address_name") or selected_place.get("address_name", "")
    end_x = selected_place.get("x", "")
    end_y = selected_place.get("y", "")

    print("\n선택된 목적지")
    print(f"이름: {name}")
    print(f"주소: {address}")
    print(f"경도: {end_x}")
    print(f"위도: {end_y}")

    speak(f"목적지가 {name}로 설정되었습니다. 대중교통 경로 개요를 검색합니다.")

    route_data = search_transit_route(START_X, START_Y, end_x, end_y)
    options = extract_boarding_options(route_data, max_options=MAX_PATH_OPTIONS)

    if not options:
        print("버스 구간이 포함된 경로를 찾지 못했습니다.")
        speak("버스 구간이 포함된 경로를 찾지 못했습니다.")
        return

    print_and_speak_initial_overview(options)

    wait_for_bus_stop_arrival_mock()
    guide_after_bus_stop_arrival(options)


if __name__ == "__main__":
    main()