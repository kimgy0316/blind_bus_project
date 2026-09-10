import 'dart:math' as math;
import 'pedestrian_panel.dart';

import 'guide_ui.dart';
import 'driver_request_page.dart';
import 'dart:convert';
import 'dart:io';
import 'boarding_guide_page.dart';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

void main() {
  runApp(const BlindBusGuideApp());
}

enum AppPage { home, voice, placeSelect, routeSelect, guidance }

class PlaceOption {
  const PlaceOption({
    required this.name,
    required this.address,
    required this.description,
    this.x = '',
    this.y = '',
  });

  final String name;
  final String address;
  final String description;
  final String x;
  final String y;
}

class RouteStep {
  const RouteStep({
    required this.icon,
    required this.iconColor,
    required this.title,
    required this.detail,
    required this.time,
    required this.speech,
  });

  final IconData icon;
  final Color iconColor;
  final String title;
  final String detail;
  final String time;
  final String speech;
}

class BusRoute {
  const BusRoute({
    required this.title,
    required this.busNumber,
    required this.arrivalText,
    required this.totalTime,
    required this.walkText,
    required this.transferText,
    required this.summary,
    required this.steps,
    required this.boardingData,
  });

  final String title;
  final String busNumber;
  final String arrivalText;
  final String totalTime;
  final String walkText;
  final String transferText;
  final String summary;
  final List<RouteStep> steps;
  final Map<String, dynamic> boardingData;
}

class BlindBusGuideApp extends StatelessWidget {
  const BlindBusGuideApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: '시각장애인 버스 안내',
      theme: guideTheme(),
      home: const GuideHomePage(),
    );
  }
}

class GuideHomePage extends StatefulWidget {
  const GuideHomePage({super.key});

  @override
  State<GuideHomePage> createState() => _GuideHomePageState();
}

class _GuideHomePageState extends State<GuideHomePage> {
  static const MethodChannel _ttsChannel = MethodChannel('blind_bus_guide/tts');
  static const MethodChannel _speechChannel = MethodChannel(
    'blind_bus_guide/speech',
  );
  static const String _apiBaseUrl = String.fromEnvironment(
    'API_BASE_URL',
    defaultValue: 'http://127.0.0.1:8765',
  );

  static const double _walkingOnlyMaxMeters = 1000.0;

  static const _locationChannel = MethodChannel('blind_bus_guide/location');
  bool _locating = false;

  final TextEditingController _startController = TextEditingController(
    text: '현재 위치',
  );
  final TextEditingController _destinationController = TextEditingController();

  AppPage _page = AppPage.home;
  bool _isListening = false;
  bool _isLoading = false;
  bool _driverNotified = false;
  int _guideIndex = 0;
  String _lastVoiceText = '목적지를 입력하거나 음성으로 말해주세요.';

  List<PlaceOption> _placeOptions = [];
  List<BusRoute> _routeOptions = [];
  PlaceOption? _selectedPlace;
  BusRoute? _selectedRoute;

  String get _pageTitle {
    if (_page == AppPage.voice) {
      return '음성 입력';
    }
    if (_page == AppPage.placeSelect) {
      return '목적지 선택';
    }
    if (_page == AppPage.routeSelect) {
      return '추천 경로';
    }
    if (_page == AppPage.guidance) {
      return '실시간 안내';
    }
    return '경로 안내';
  }

  RouteStep? get _currentStep {
    final route = _selectedRoute;
    if (route == null || route.steps.isEmpty) {
      return null;
    }
    return route.steps[_guideIndex];
  }

  double get _progress {
    final route = _selectedRoute;
    if (route == null || route.steps.isEmpty) {
      return 0;
    }
    return (_guideIndex + 1) / route.steps.length;
  }

  Future<void> _speak(String text) async {
    final message = text.trim();
    if (message.isEmpty) {
      return;
    }

    if (mounted) {
      setState(() {
        _lastVoiceText = message;
      });
    }

    try {
      await _ttsChannel.invokeMethod('speak', {'text': message});
    } catch (_) {
      // TTS가 없는 에뮬레이터에서도 화면 흐름은 계속 진행합니다.
    }
  }

  Future<Map<String, dynamic>> _getJson(
    String path,
    Map<String, String> queryParameters,
  ) async {
    final uri = Uri.parse(
      '$_apiBaseUrl$path',
    ).replace(queryParameters: queryParameters);
    debugPrint(
      '[API_REQUEST] ${uri.scheme}://${uri.host}:${uri.port}${uri.path}',
    );
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 8);

    try {
      final request = await client.getUrl(uri);
      request.headers.set('X-Blindbus-Access', const String.fromEnvironment('API_ACCESS_TOKEN'));
      final response = await request.close().timeout(
        const Duration(seconds: 45),
      );
      final responseBody = await response.transform(utf8.decoder).join();

      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw Exception('서버 오류 ${response.statusCode}: $responseBody');
      }

      return jsonDecode(responseBody) as Map<String, dynamic>;
    } finally {
      client.close(force: true);
    }
  }

  Future<Map<String, dynamic>> _postJson(
    String path,
    Map<String, dynamic> body,
  ) async {
    final uri = Uri.parse('$_apiBaseUrl$path');
    final encodedBody = jsonEncode(body);
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 8);

    try {
      final request = await client.postUrl(uri);
      request.headers.set('X-Blindbus-Access', const String.fromEnvironment('API_ACCESS_TOKEN'));
      final bodyBytes = utf8.encode(encodedBody);
      request.headers.set(
        HttpHeaders.contentTypeHeader,
        'application/json; charset=utf-8',
      );
      request.contentLength = bodyBytes.length;
      request.add(bodyBytes);

      final response = await request.close().timeout(
        const Duration(seconds: 25),
      );
      final responseBody = await response.transform(utf8.decoder).join();
      final decoded = jsonDecode(responseBody);

      if (decoded is! Map<String, dynamic>) {
        throw Exception('서버 응답 형식이 올바르지 않습니다.');
      }

      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw Exception(decoded['error'] ?? '서버 오류 ${response.statusCode}');
      }

      return decoded;
    } finally {
      client.close(force: true);
    }
  }

  Future<List<PlaceOption>> _fetchPlaces(String query) async {
    final data = await _getJson('/places', {'query': query, 'size': '5'});

    final places = (data['places'] as List<dynamic>? ?? []);

    return places
        .map((item) {
          final place = item as Map<String, dynamic>;
          return PlaceOption(
            name: '${place['name'] ?? ''}',
            address: '${place['address'] ?? ''}',
            description: '${place['description'] ?? 'Kakao 장소 검색 결과'}',
            x: '${place['x'] ?? ''}',
            y: '${place['y'] ?? ''}',
          );
        })
        .where((place) => place.name.trim().isNotEmpty)
        .toList();
  }

  Future<List<BusRoute>> _fetchRoutes(PlaceOption place) async {
    debugPrint('[fetchRoutes] place.name: ${place.name}');
    debugPrint('[fetchRoutes] place.x: ${place.x}');
    debugPrint('[fetchRoutes] place.y: ${place.y}');

    final position = await _readCurrentLocation();
    final requestBody = {
      'startX': '${position['longitude']}',
      'startY': '${position['latitude']}',
      'startSource': 'device',
      'endX': place.x,
      'endY': place.y,
      'destinationName': place.name,
      'cityCode': '33010',
    };

    debugPrint('[fetchRoutes] requestBody: ${jsonEncode(requestBody)}');

    final data = await _postJson('/routes', requestBody);
    final serverMessage = '${data['message'] ?? data['error'] ?? ''}'.trim();

    final routes = data['routes'] as List<dynamic>? ?? [];

    if (routes.isEmpty && serverMessage.isNotEmpty) {
      throw Exception(serverMessage);
    }

    return routes
        .map((item) {
          final route = item as Map<String, dynamic>;

          final steps = (route['steps'] as List<dynamic>? ?? [])
              .map((step) => _routeStepFromJson(step as Map<String, dynamic>))
              .toList();

          return BusRoute(
            title: '${route['title'] ?? '추천 경로'}',
            busNumber: '${route['busNumber'] ?? '버스 정보 없음'}',
            arrivalText: '${route['arrivalText'] ?? '도착정보 없음'}',
            totalTime: '${route['totalTime'] ?? '정보 없음'}',
            walkText: '${route['walkText'] ?? '도보 정보 없음'}',
            transferText: '${route['transferText'] ?? '환승 정보 없음'}',
            summary: '${route['summary'] ?? ''}',
            steps: steps,
            boardingData: Map<String, dynamic>.from(route),
          );
        })
        .where((route) => route.steps.isNotEmpty)
        .toList();
  }

  RouteStep _routeStepFromJson(Map<String, dynamic> step) {
    final kind = '${step['kind'] ?? ''}';

    IconData icon = Icons.near_me;
    Color iconColor = const Color(0xFF18B657);

    if (kind == 'bus') {
      icon = Icons.directions_bus;
      iconColor = const Color(0xFF2188FF);
    } else if (kind == 'ai') {
      icon = Icons.visibility;
      iconColor = const Color(0xFF7C4DFF);
    } else if (kind == 'notify') {
      icon = Icons.campaign;
      iconColor = const Color(0xFFFFA000);
    } else if (kind == 'finish') {
      icon = Icons.flag;
      iconColor = const Color(0xFF10194F);
    }

    return RouteStep(
      icon: icon,
      iconColor: iconColor,
      title: '${step['title'] ?? ''}',
      detail: '${step['detail'] ?? ''}',
      time: '${step['time'] ?? ''}',
      speech: '${step['speech'] ?? ''}',
    );
  }

  Future<void> _listenDestination() async {
    if (_isListening) {
      return;
    }

    setState(() {
      _page = AppPage.voice;
      _isListening = true;
      _lastVoiceText = '목적지를 듣는 중입니다.';
    });

    await _speak('목적지를 말해주세요.');
    await Future.delayed(const Duration(milliseconds: 1800));

    if (!mounted) {
      return;
    }

    try {
      final spokenText = await _speechChannel.invokeMethod<String>('listen');
      final destination = _cleanDestination(spokenText ?? '');

      if (destination.isEmpty) {
        await _handleVoiceFail('목적지를 인식하지 못했습니다.');
        return;
      }

      _destinationController.text = destination;
      await _searchDestination(destination, fromVoice: true);
    } on PlatformException catch (error) {
      debugPrint('[VOICE_FAILED] ${error.code}');
      await _handleVoiceFail('음성을 인식하지 못했습니다.');
    } finally {
      if (mounted) {
        setState(() {
          _isListening = false;
        });
      }
    }
  }

  Future<void> _handleVoiceFail(String reason) async {
    if (!mounted) {
      return;
    }

    setState(() {
      _page = AppPage.home;
      _lastVoiceText = '$reason 목적지를 직접 입력하거나 다시 음성 입력을 눌러주세요.';
    });

    await _speak('$reason 목적지를 직접 입력하거나 다시 음성 입력을 눌러주세요.');
  }

  String _cleanDestination(String value) {
    return value
        .replaceAll('목적지는', '')
        .replaceAll('목적지', '')
        .replaceAll('으로', '')
        .replaceAll('로', '')
        .replaceAll('가줘', '')
        .replaceAll('가자', '')
        .trim();
  }

  Future<void> _searchDestinationFromInput() async {
    await _searchDestination(_destinationController.text);
  }

  Future<void> _searchDestination(
    String rawQuery, {
    bool fromVoice = false,
  }) async {
    final query = rawQuery.trim();

    if (query.isEmpty) {
      await _speak('목적지를 먼저 입력해주세요.');
      return;
    }

    setState(() {
      _isLoading = true;
      _lastVoiceText = '$query 목적지를 검색하고 있습니다.';
      _placeOptions = [];
      _routeOptions = [];
      _selectedPlace = null;
      _selectedRoute = null;
      _guideIndex = 0;
      _driverNotified = false;
    });

    List<PlaceOption> options;
    try {
      options = await _fetchPlaces(query);
    } catch (error) {
      if (!mounted) {
        return;
      }

      setState(() {
        _isLoading = false;
        _page = AppPage.home;
        _lastVoiceText = '장소를 검색하지 못했습니다. 연결을 확인한 뒤 다시 검색해주세요.';
      });
      final detail = error.toString().replaceAll(
        RegExp(
          r'(serviceKey|apiKey|Authorization)[=:][^&\s]+',
          caseSensitive: false,
        ),
        '[인증값 숨김]',
      );
      final endpoint = Uri.tryParse(_apiBaseUrl);
      final serverLabel = endpoint == null
          ? '서버 주소 형식 오류'
          : '${endpoint.scheme}://${endpoint.host}:${endpoint.port}';
      debugPrint(
        '[PLACE_SEARCH_FAILED] server=$serverLabel type=${error.runtimeType} detail=$detail',
      );
      await _speak('장소를 검색하지 못했습니다. 연결을 확인한 뒤 다시 검색해주세요.');
      if (!mounted) return;
      return;
    }

    if (!mounted) {
      return;
    }

    setState(() {
      _isLoading = false;
      _placeOptions = options;
    });

    if (options.isEmpty) {
      setState(() {
        _page = AppPage.home;
        _lastVoiceText = '$query 검색 결과가 없습니다. 목적지를 다시 입력해주세요.';
      });
      await _speak('$query 검색 결과가 없습니다. 목적지를 다시 입력해주세요.');
      return;
    }

    if (options.length == 1) {
      await _selectPlace(options.first, autoStart: true);
      return;
    }

    setState(() {
      _page = AppPage.placeSelect;
    });

    final names = options
        .asMap()
        .entries
        .map((entry) => '${entry.key + 1}번 ${entry.value.name}')
        .join(', ');

    final prefix = fromVoice ? '음성으로 $query를 인식했습니다. ' : '';
    await _speak('${prefix}목적지 후보가 여러 개 있습니다. $names 중에서 선택해주세요.');
  }

  double _distanceMeters(
    double lat1,
    double lon1,
    double lat2,
    double lon2,
  ) {
    const earthRadius = 6371000.0;

    final dLat =
        (lat2 - lat1) * math.pi / 180.0;
    final dLon =
        (lon2 - lon1) * math.pi / 180.0;

    final a =
        math.sin(dLat / 2) * math.sin(dLat / 2) +
        math.cos(lat1 * math.pi / 180.0) *
            math.cos(lat2 * math.pi / 180.0) *
            math.sin(dLon / 2) *
            math.sin(dLon / 2);

    final c =
        2 * math.atan2(math.sqrt(a), math.sqrt(1 - a));

    return earthRadius * c;
  }

  Future<void> _openWalkingOnly(
    PlaceOption place,
  ) async {
    if (!mounted) return;

    setState(() {
      _isLoading = false;
      _page = AppPage.home;
      _lastVoiceText =
          '${place.name}까지 가까운 거리라 도보로 안내합니다.';
    });

    await _speak(
      '${place.name}까지 가까운 거리라 '
      '버스를 이용하지 않고 도보로 안내합니다.',
    );

    if (!mounted) return;

    await Navigator.of(context).push<void>(
      MaterialPageRoute(
        builder: (_) => Scaffold(
          appBar: AppBar(
            title: Text('${place.name}까지 도보 안내'),
          ),
          body: SafeArea(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(16),
              child: PedestrianPanel(
                route: <String, dynamic>{
                  'walkingOnly': true,
                  'destinationX': place.x,
                  'destinationY': place.y,
                  'destinationName': place.name,
                },
                postJson: _postJson,
              ),
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _selectPlace(
    PlaceOption place, {
    bool autoStart = false,
  }) async {
    setState(() {
      _selectedPlace = place;
      _routeOptions = [];
      _selectedRoute = null;
      _guideIndex = 0;
      _driverNotified = false;
      _page = AppPage.routeSelect;
      _isLoading = true;
      _lastVoiceText =
          '${place.name}까지 이동 경로를 확인하고 있습니다.';
    });

    List<BusRoute> routes;

    try {
      final position =
          await _readCurrentLocation();

      final startLat =
          (position['latitude'] as num).toDouble();

      final startLon =
          (position['longitude'] as num).toDouble();

      final endLon =
          double.tryParse(place.x);

      final endLat =
          double.tryParse(place.y);

      if (endLon == null ||
          endLat == null ||
          !endLon.isFinite ||
          !endLat.isFinite) {
        throw StateError(
          '목적지 좌표를 확인하지 못했습니다.',
        );
      }

      final directDistance = _distanceMeters(
        startLat,
        startLon,
        endLat,
        endLon,
      );

      debugPrint(
        '[ROUTE_MODE] '
        'destination=${place.name} '
        'distance=${directDistance.toStringAsFixed(1)}m',
      );

      if (directDistance <=
          _walkingOnlyMaxMeters) {
        debugPrint(
          '[ROUTE_MODE] WALKING_ONLY',
        );

        await _openWalkingOnly(place);
        return;
      }

      debugPrint(
        '[ROUTE_MODE] BUS',
      );

      routes = await _fetchRoutes(place);
    } catch (error) {
      if (!mounted) {
        return;
      }

      setState(() {
        _isLoading = false;
        _routeOptions = [];
        _lastVoiceText =
            '경로 검색 실패: $error';
      });

      debugPrint(
        '[ROUTE_SEARCH_FAILED] $error',
      );

      await _speak(
        '경로를 찾지 못했습니다. '
        '잠시 후 다시 검색해주세요.',
      );

      return;
    }

    if (!mounted) {
      return;
    }

    if (routes.isEmpty) {
      setState(() {
        _isLoading = false;
        _routeOptions = [];
        _lastVoiceText =
            '${place.name}까지 버스가 포함된 '
            '대중교통 경로를 찾지 못했습니다.';
      });

      await _speak(
        '${place.name}까지 버스가 포함된 '
        '대중교통 경로를 찾지 못했습니다.',
      );

      return;
    }

    setState(() {
      _isLoading = false;
      _routeOptions = routes;
    });

    await _speak(
      '추천 버스는 ${routes.first.busNumber}, '
      '${routes.first.arrivalText}입니다. '
      '이용할 경로를 선택해주세요.',
    );
  }

  bool _boardingPageOpen = false;

  Future<void> _selectRoute(BusRoute route) async {
    if (_boardingPageOpen) return;
    _boardingPageOpen = true;

    try {
      await Navigator.of(context).push<void>(
        MaterialPageRoute(
          builder: (_) => BoardingGuidePage(
            route: route.boardingData,
            getJson: _getJson,
            postJson: _postJson,
          ),
        ),
      );
    } finally {
      _boardingPageOpen = false;
    }
  }

  Future<Map<String, dynamic>> _readCurrentLocation() async {
    if (_locating) {
      throw StateError(
        '위치 확인 중입니다. 잠시 후 다시 시도해주세요.',
      );
    }

    _locating = true;

    try {
      final raw =
          await _locationChannel.invokeMapMethod<String, dynamic>(
        'current',
      );

      if (raw == null) {
        throw StateError('위치 응답이 없습니다.');
      }

      final latitude = raw['latitude'] as num;
      final longitude = raw['longitude'] as num;
      final accuracy = raw['accuracy'] as num;

      if (!latitude.isFinite ||
          !longitude.isFinite ||
          accuracy > 100 ||
          latitude < -90 ||
          latitude > 90 ||
          longitude < -180 ||
          longitude > 180) {
        throw StateError(
          '위치 정확도를 확인하지 못했습니다.',
        );
      }

      if (!mounted) {
        throw StateError('화면이 종료됐습니다.');
      }

      setState(
        () => _startController.text =
            '현재 위치 '
            '(${latitude.toStringAsFixed(5)}, '
            '${longitude.toStringAsFixed(5)}) '
            '· 오차 약 ${accuracy.round()}m',
      );

      return Map<String, dynamic>.from(raw);
    } on PlatformException catch (e) {
      throw StateError(
        e.message ??
            '위치 권한과 위치 기능을 확인해주세요.',
      );
    } finally {
      _locating = false;
    }
  }

  void _useCurrentLocation() async {
    if (_locating) return;

    try {
      await _readCurrentLocation();
      await _speak('현재 위치를 확인했습니다.');
    } catch (e) {
      await _speak(
        '현재 위치 확인 실패. $e',
      );
    }
  }

  Future<void> _moveGuide(int diff) async {
    final route = _selectedRoute;
    if (route == null) {
      return;
    }

    final nextIndex = (_guideIndex + diff)
        .clamp(0, route.steps.length - 1)
        .toInt();

    setState(() {
      _guideIndex = nextIndex;
      _page = AppPage.guidance;
    });

    await _speak(route.steps[nextIndex].speech);
  }

  Future<void> _repeatCurrentGuide() async {
    if (_page == AppPage.placeSelect && _placeOptions.isNotEmpty) {
      final names = _placeOptions
          .asMap()
          .entries
          .map((entry) => '${entry.key + 1}번 ${entry.value.name}')
          .join(', ');
      await _speak('목적지 후보입니다. $names 중에서 선택해주세요.');
      return;
    }

    if (_page == AppPage.routeSelect && _routeOptions.isNotEmpty) {
      final route = _routeOptions.first;
      await _speak(
        '추천 경로입니다. ${route.busNumber}, ${route.arrivalText}, 총 소요 시간은 ${route.totalTime}입니다.',
      );
      return;
    }

    if (_page == AppPage.voice) {
      await _speak('목적지를 말해주세요.');
      return;
    }

    if (_page == AppPage.home) {
      await _speak('목적지 말하기를 누르거나 목적지를 입력해주세요.');
      return;
    }

    final step = _currentStep;
    if (step != null) {
      await _speak(step.speech);
    }
  }

  Future<void> _confirmBusNumber() async {
    await _speak('경로를 선택하면 정류장 도착과 탑승 의사를 확인한 뒤 버스 확인을 기다립니다.');
  }

  Future<void> _notifyDriver() async {
    await _speak('기사 알림은 정류장 도착 후 탑승에 동의한 경우에만 요청합니다.');
  }

  void _goBack() {
    setState(() {
      if (_page == AppPage.guidance) {
        _page = AppPage.routeSelect;
      } else if (_page == AppPage.routeSelect) {
        _page = _placeOptions.length > 1 ? AppPage.placeSelect : AppPage.home;
      } else if (_page == AppPage.placeSelect || _page == AppPage.voice) {
        _page = AppPage.home;
      }
    });
  }

  @override
  void dispose() {
    _startController.dispose();
    _destinationController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final canGoBack = _page != AppPage.home;
    return Scaffold(
      appBar: AppBar(
        toolbarHeight: guideToolbarHeight(context),
        automaticallyImplyLeading: false,
        leading: canGoBack
            ? IconButton(
                tooltip: '뒤로',
                onPressed: _isListening ? null : _goBack,
                icon: const Icon(Icons.arrow_back),
              )
            : null,
        title: Text(_page == AppPage.home ? '함께 가는 버스' : _pageTitle),
        actions: [
          PopupMenuButton<String>(
            tooltip: '더 보기',
            icon: const Icon(Icons.more_horiz),
            onSelected: (value) {
              if (value == 'test')
                Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (_) => DriverRequestPage(
                      getJson: _getJson,
                      postJson: _postJson,
                      isTest: true,
                    ),
                  ),
                );
              if (value == 'location') _useCurrentLocation();
            },
            itemBuilder: (_) => const [
              PopupMenuItem(value: 'location', child: Text('현재 위치 확인')),
              PopupMenuItem(value: 'test', child: Text('개발 테스트: 기사 요청')),
            ],
          ),
        ],
      ),
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 720),
            child: Column(
              children: [
                Expanded(child: _buildPage()),
                if (!_isListening && !_isLoading && _page != AppPage.home)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(24, 8, 24, 12),
                    child: GuideAction(
                      '안내 다시 듣기',
                      onPressed: _repeatCurrentGuide,
                      icon: Icons.volume_up,
                      secondary: true,
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildPage() {
    if (_isLoading) {
      return _LoadingPage(
        key: const ValueKey('loading'),
        message: _lastVoiceText,
      );
    }

    if (_page == AppPage.voice) {
      return _VoicePage(
        key: const ValueKey('voice'),
        isListening: _isListening,
        lastVoiceText: _lastVoiceText,
        onListen: _listenDestination,
      );
    }

    if (_page == AppPage.placeSelect) {
      return _PlaceSelectPage(
        key: const ValueKey('placeSelect'),
        options: _placeOptions,
        onSelect: (place) => _selectPlace(place),
        onRepeat: _repeatCurrentGuide,
      );
    }

    if (_page == AppPage.routeSelect) {
      return _RouteSelectPage(
        key: const ValueKey('routeSelect'),
        place: _selectedPlace,
        routes: _routeOptions,
        onSelect: (route) => _selectRoute(route),
        onRepeat: _repeatCurrentGuide,
      );
    }

    if (_page == AppPage.guidance && _selectedRoute != null) {
      return _GuidancePage(
        key: const ValueKey('guidance'),
        route: _selectedRoute!,
        guideIndex: _guideIndex,
        progress: _progress,
        driverNotified: _driverNotified,
        onPrevious: () => _moveGuide(-1),
        onNext: () => _moveGuide(1),
        onRepeat: _repeatCurrentGuide,
        onConfirmBus: _confirmBusNumber,
        onNotifyDriver: _notifyDriver,
      );
    }

    return _HomePage(
      key: const ValueKey('home'),
      startController: _startController,
      destinationController: _destinationController,
      lastVoiceText: _lastVoiceText,
      onVoiceInput: _listenDestination,
      onCurrentLocation: _useCurrentLocation,
      onSearchRoute: _searchDestinationFromInput,
    );
  }
}

class _HomePage extends StatelessWidget {
  const _HomePage({
    super.key,
    required this.startController,
    required this.destinationController,
    required this.lastVoiceText,
    required this.onVoiceInput,
    required this.onCurrentLocation,
    required this.onSearchRoute,
  });
  final TextEditingController startController, destinationController;
  final String lastVoiceText;
  final VoidCallback onVoiceInput, onCurrentLocation, onSearchRoute;
  @override
  Widget build(BuildContext context) => ListView(
    padding: const EdgeInsets.fromLTRB(24, 16, 24, 32),
    children: [
      const Text(
        '오늘도, 편안한 이동',
        style: TextStyle(
          color: GuideColors.primary,
          fontSize: 20,
          fontWeight: FontWeight.w700,
        ),
      ),
      const SizedBox(height: 8),
      const GuideHeading('어디로 가시나요?'),
      const SizedBox(height: 24),
      FilledButton(
        onPressed: onVoiceInput,
        style: FilledButton.styleFrom(padding: const EdgeInsets.all(28)),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Align(
              alignment: Alignment.centerLeft,
              child: Icon(Icons.mic_rounded, size: 48),
            ),
            const SizedBox(height: 16),
            const Text(
              '목적지 말하기',
              style: TextStyle(fontSize: 30, fontWeight: FontWeight.w800),
            ),
            const SizedBox(height: 8),
            const Text(
              '누른 뒤 목적지를 말씀해주세요',
              style: TextStyle(fontSize: 20, fontWeight: FontWeight.w500),
            ),
          ],
        ),
      ),
      const SizedBox(height: 28),
      const GuideHeading('글자로 입력하기'),
      const SizedBox(height: 12),
      TextField(
        controller: destinationController,
        style: const TextStyle(fontSize: 24),
        textInputAction: TextInputAction.search,
        onSubmitted: (_) => onSearchRoute(),
        decoration: const InputDecoration(
          labelText: '목적지',
          hintText: '예: 청주대학교',
          prefixIcon: Icon(Icons.search),
        ),
      ),
      const SizedBox(height: 10),
      GuideAction(
        '목적지 검색',
        onPressed: onSearchRoute,
        icon: Icons.search,
        secondary: true,
      ),
      const SizedBox(height: 18),
      const Text(
        '출발지는 현재 위치로 자동 설정합니다.',
        style: TextStyle(color: GuideColors.muted, fontSize: 20),
      ),
      if (lastVoiceText != '목적지를 입력하거나 음성으로 말해주세요.') ...[
        const SizedBox(height: 18),
        GuideCard(color: GuideColors.soft, child: Text(lastVoiceText)),
      ],
    ],
  );
}

class _LoadingPage extends StatelessWidget {
  const _LoadingPage({super.key, required this.message});
  final String message;
  @override
  Widget build(BuildContext context) => ListView(
    padding: const EdgeInsets.all(32),
    children: [
      const SizedBox(height: 60),
      const Center(child: CircularProgressIndicator()),
      const SizedBox(height: 32),
      Text(message, textAlign: TextAlign.center),
    ],
  );
}

class _VoicePage extends StatelessWidget {
  const _VoicePage({
    super.key,
    required this.isListening,
    required this.lastVoiceText,
    required this.onListen,
  });
  final bool isListening;
  final String lastVoiceText;
  final VoidCallback onListen;
  @override
  Widget build(BuildContext context) => ListView(
    padding: const EdgeInsets.all(24),
    children: [
      GuideCard(
        color: GuideColors.soft,
        child: Column(
          children: [
            const Icon(Icons.mic_rounded, size: 80, color: GuideColors.primary),
            const SizedBox(height: 24),
            GuideHeading(isListening ? '목적지를 말씀해주세요' : '음성 입력'),
            const SizedBox(height: 16),
            Text(lastVoiceText, textAlign: TextAlign.center),
          ],
        ),
      ),
      if (!isListening)
        GuideAction('다시 말하기', onPressed: onListen, icon: Icons.mic),
    ],
  );
}

class _PlaceSelectPage extends StatelessWidget {
  const _PlaceSelectPage({
    super.key,
    required this.options,
    required this.onSelect,
    required this.onRepeat,
  });
  final List<PlaceOption> options;
  final ValueChanged<PlaceOption> onSelect;
  final VoidCallback onRepeat;
  @override
  Widget build(BuildContext context) => ListView(
    padding: const EdgeInsets.all(24),
    children: [
      const GuideHeading('가실 곳을 선택해주세요'),
      const SizedBox(height: 8),
      const Text('이름과 주소를 확인해주세요.'),
      const SizedBox(height: 24),
      for (var i = 0; i < options.length; i++)
        Padding(
          padding: const EdgeInsets.only(bottom: 16),
          child: Semantics(
            button: true,
            child: Card(
              clipBehavior: Clip.antiAlias,
              child: InkWell(
                onTap: () => onSelect(options[i]),
                child: Padding(
                  padding: const EdgeInsets.all(24),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '${i + 1}번 목적지',
                        style: const TextStyle(
                          color: GuideColors.primary,
                          fontSize: 18,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const SizedBox(height: 8),
                      GuideHeading(options[i].name),
                      const SizedBox(height: 12),
                      Text(options[i].address),
                      const SizedBox(height: 18),
                      const Text(
                        '이곳으로 가기  →',
                        style: TextStyle(
                          color: GuideColors.primary,
                          fontSize: 22,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
    ],
  );
}

class _RouteSelectPage extends StatelessWidget {
  const _RouteSelectPage({
    super.key,
    required this.place,
    required this.routes,
    required this.onSelect,
    required this.onRepeat,
  });
  final PlaceOption? place;
  final List<BusRoute> routes;
  final ValueChanged<BusRoute> onSelect;
  final VoidCallback onRepeat;
  @override
  Widget build(BuildContext context) => ListView(
    padding: const EdgeInsets.all(24),
    children: [
      Text('도착할 곳', style: Theme.of(context).textTheme.bodySmall),
      GuideHeading(place?.name ?? '목적지'),
      const SizedBox(height: 24),
      if (routes.isEmpty)
        const GuideCard(
          child: Text('이용할 버스를 찾지 못했습니다. 뒤로 돌아가 목적지를 다시 선택해주세요.'),
        ),
      for (var i = 0; i < routes.length; i++)
        Padding(
          padding: const EdgeInsets.only(bottom: 24),
          child: _RouteOptionCard(
            route: routes[i],
            recommended: i == 0,
            onTap: () => onSelect(routes[i]),
          ),
        ),
    ],
  );
}

class _RouteOptionCard extends StatelessWidget {
  const _RouteOptionCard({
    required this.route,
    required this.recommended,
    required this.onTap,
  });
  final BusRoute route;
  final bool recommended;
  final VoidCallback onTap;
  @override
  Widget build(BuildContext context) => GuideCard(
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Align(
          alignment: Alignment.centerLeft,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
            decoration: BoxDecoration(
              color: recommended ? GuideColors.yellow : GuideColors.soft,
              borderRadius: BorderRadius.circular(10),
            ),
            child: Text(
              recommended ? '추천 경로' : route.title,
              style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w800),
            ),
          ),
        ),
        const SizedBox(height: 20),
        Text(
          route.busNumber,
          style: const TextStyle(
            fontSize: 42,
            fontWeight: FontWeight.w900,
            color: GuideColors.primary,
          ),
        ),
        Text(
          route.arrivalText,
          style: const TextStyle(fontSize: 26, fontWeight: FontWeight.w800),
        ),
        const SizedBox(height: 16),
        const Divider(),
        GuideFact(
          '타는 곳',
          '${route.boardingData['boardingStop'] ?? '정류장 확인 필요'}',
        ),
        GuideFact(
          '내리는 곳',
          '${route.boardingData['dropoffStop'] ?? '정류장 확인 필요'}',
        ),
        const SizedBox(height: 12),
        Wrap(
          spacing: 18,
          runSpacing: 8,
          children: [
            Text('총 ${route.totalTime}'),
            Text(route.walkText),
            Text(route.transferText),
          ],
        ),
        const SizedBox(height: 18),
        GuideAction('이 버스로 안내 시작', onPressed: onTap, secondary: !recommended),
      ],
    ),
  );
}

// Kept for the existing internal step state; real route selection opens BoardingGuidePage.
class _GuidancePage extends StatelessWidget {
  const _GuidancePage({
    super.key,
    required this.route,
    required this.guideIndex,
    required this.progress,
    required this.driverNotified,
    required this.onPrevious,
    required this.onNext,
    required this.onRepeat,
    required this.onConfirmBus,
    required this.onNotifyDriver,
  });
  final BusRoute route;
  final int guideIndex;
  final double progress;
  final bool driverNotified;
  final VoidCallback onPrevious, onNext, onRepeat, onConfirmBus, onNotifyDriver;
  @override
  Widget build(BuildContext context) => ListView(
    padding: const EdgeInsets.all(24),
    children: [
      GuideCard(child: Text(route.steps[guideIndex].speech)),
      GuideAction(
        '안내 다시 듣기',
        onPressed: onRepeat,
        icon: Icons.volume_up,
        secondary: true,
      ),
    ],
  );
}
