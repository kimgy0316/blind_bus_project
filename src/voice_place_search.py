# 음성인식
# 목적지 설정

from search_kakao_place import search_place
from voice_destination import listen_destination, speak


def read_places(places):
    if not places:
        print("검색 결과가 없습니다.")
        speak("검색 결과가 없습니다.")
        return

    speak("검색 결과를 안내합니다.")

    for index, place in enumerate(places, start=1):
        name = place.get("place_name", "")
        address = place.get("road_address_name") or place.get("address_name", "")

        print(f"{index}. {name}")
        print(f"   주소: {address}")

        speak(f"{index}번, {name}. 주소는 {address}입니다.")


def parse_choice(text):
    text = text.replace(" ", "")

    mapping = {
        "1": 1,
        "1번": 1,
        "일": 1,
        "일번": 1,
        "첫번째": 1,
        "첫": 1,

        "2": 2,
        "2번": 2,
        "이": 2,
        "이번": 2,
        "두번째": 2,
        "둘": 2,

        "3": 3,
        "3번": 3,
        "삼": 3,
        "삼번": 3,
        "세번째": 3,
        "셋": 3,

        "4": 4,
        "4번": 4,
        "사": 4,
        "사번": 4,
        "네번째": 4,
        "넷": 4,

        "5": 5,
        "5번": 5,
        "오": 5,
        "오번": 5,
        "다섯번째": 5,
        "다섯": 5,
    }

    return mapping.get(text)


def choose_place_by_voice(places):
    if not places:
        return None

    for attempt in range(3):
        speak("선택할 번호를 말씀해 주세요.")
        print("선택할 번호를 말씀해 주세요.")

        choice_text = listen_destination()

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
    longitude = selected_place.get("x", "")
    latitude = selected_place.get("y", "")

    print("\n선택된 목적지")
    print(f"이름: {name}")
    print(f"주소: {address}")
    print(f"경도: {longitude}")
    print(f"위도: {latitude}")

    speak(f"목적지가 {name}로 설정되었습니다.")


if __name__ == "__main__":
    main()