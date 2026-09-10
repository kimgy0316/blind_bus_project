# 시각장애인 버스 안내 Flutter 앱

Android 제출용 Flutter 프로토타입입니다.

## 실행

```powershell
cd C:\Users\LG\blind_bus_project\mobile_flutter
flutter pub get
flutter run
```

## APK 빌드

```powershell
cd C:\Users\LG\blind_bus_project\mobile_flutter
flutter build apk --debug
```

빌드 결과는 보통 아래에 생성됩니다.

```text
build\app\outputs\flutter-apk\app-debug.apk
```

## 포함 기능

- 목적지 입력
- 음성 안내 출력(Android TextToSpeech)
- 길 안내 단계 표시
- 실시간 버스 정보 시연
- AI 노선번호 판정 결과 표시
- 기사 알림 mock
