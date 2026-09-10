enum BoardingPhase { walking, refreshing, asking, notifying, waiting, arrived, riding, completed }

enum BoardingAnswer { yes, no, unknown }

BoardingAnswer parseBoardingAnswer(String text) {
  final value = text.replaceAll(RegExp(r'[\s.,!?。]'), '');
  if (const {'아니요', '아니오', '안탈래요', '안타요', '타지않을래요', '취소'}.contains(value)) {
    return BoardingAnswer.no;
  }
  if (const {'네', '예', '응', '탈게요', '타겠습니다', '탈래요', '탑승할게요'}.contains(value)) {
    return BoardingAnswer.yes;
  }
  return BoardingAnswer.unknown;
}

// 번호만 같거나 이전 세션의 이벤트인 경우에는 도착으로 처리하지 않습니다.
bool isMatchingArrival(Map<dynamic, dynamic> event, String sessionId,
    String nodeId, String routeNo) {
  return event['type'] == 'busAtStop' &&
      event['sessionId'] == sessionId &&
      event['nodeId'] == nodeId &&
      event['routeNo'] == routeNo &&
      event['atStop'] == true &&
      event['numberConfirmed'] == true;
}
