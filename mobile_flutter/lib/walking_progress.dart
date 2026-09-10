import 'dart:math' as math;

class WalkPoint {
  const WalkPoint(this.lon, this.lat);
  final double lon, lat;
  double distance(WalkPoint other) {
    final x = (other.lon - lon) * 111195 * math.cos(lat * math.pi / 180);
    final y = (other.lat - lat) * 111195;
    return math.sqrt(x * x + y * y);
  }
}

class WalkFix extends WalkPoint {
  const WalkFix(super.lon, super.lat, this.accuracy, this.timestamp);
  final double accuracy;
  final int timestamp;
  bool get reliable =>
      lon.isFinite &&
      lat.isFinite &&
      lon.abs() <= 180 &&
      lat.abs() <= 90 &&
      accuracy.isFinite &&
      accuracy > 0 &&
      accuracy <= 25;
}

class WalkInstruction {
  const WalkInstruction(this.offset, this.turn, this.description);
  final double offset;
  final int turn;
  final String description;
  String get action => switch (turn) {
    11 => '직진',
    12 => '좌회전',
    13 => '우회전',
    14 => '되돌아가기',
    16 => '왼쪽 뒤편 8시 방향',
    17 => '왼쪽 앞편 10시 방향',
    18 => '오른쪽 앞편 2시 방향',
    19 => '오른쪽 뒤편 4시 방향',
    125 => '육교',
    126 => '지하보도',
    127 => '계단',
    128 => '경사로',
    129 => '계단과 경사로',
    >= 211 && <= 217 => '횡단보도',
    218 => '엘리베이터',
    201 => '정류장 근처',
    _ => '다음 안내 지점',
  };
}

class WalkingProgress {
  WalkingProgress(Map<String, dynamic> data) {
    path = (data['path'] as List)
        .map(
          (p) => WalkPoint((p[0] as num).toDouble(), (p[1] as num).toDouble()),
        )
        .toList();
    if (path.length < 2 ||
        path.any((p) => !p.lon.isFinite || !p.lat.isFinite)) {
      throw const FormatException('보행 경로가 올바르지 않습니다.');
    }
    lengths = [0];
    for (var i = 1; i < path.length; i++) {
      lengths.add(lengths.last + path[i - 1].distance(path[i]));
    }
    instructions = (data['instructions'] as List)
        .map(
          (p) => WalkInstruction(
            (p['offset'] as num).toDouble(),
            (p['turnType'] as num).toInt(),
            '${p['description'] ?? ''}',
          ),
        )
        .toList();
    // Server uses haversine; scale offsets to the local projection metric.
    final sourceLength = (data['geometryDistance'] as num).toDouble();
    if (!sourceLength.isFinite || sourceLength <= 0)
      throw const FormatException('경로 길이 오류');
    instructions = instructions
        .map(
          (p) => WalkInstruction(
            p.offset * lengths.last / sourceLength,
            p.turn,
            p.description,
          ),
        )
        .toList();
  }
  late final List<WalkPoint> path;
  late final List<double> lengths;
  late List<WalkInstruction> instructions;
  double progress = 0, crossTrack = 0;
  int? _lastTimestamp, _offSince;
  int _nearCount = 0;
  bool needsReroute = false, nearStop = false;
  bool get offRoute => _offSince != null;
  double get remaining => math.max(0, lengths.last - progress);
  WalkInstruction get next => instructions.firstWhere(
    (p) => p.turn != 200 && p.offset > progress - 8,
    orElse: () => WalkInstruction(lengths.last, 201, '정류장 근처'),
  );
  double get nextDistance => math.max(0, next.offset - progress);

  bool update(WalkFix fix) {
    if (!fix.reliable ||
        (_lastTimestamp != null && fix.timestamp <= _lastTimestamp!))
      return false;
    final elapsed = _lastTimestamp == null
        ? 0.0
        : (fix.timestamp - _lastTimestamp!) / 1000;
    _lastTimestamp = fix.timestamp;
    // A nearby crossing/parallel section must not jump progress to a later leg.
    final maxAdvance = math.max(35.0, math.min(90.0, elapsed * 3 + 15));
    var bestDistance = double.infinity;
    var bestProgress = progress;
    for (var i = 0; i < path.length - 1; i++) {
      if (lengths[i] > progress + maxAdvance || lengths[i + 1] < progress - 35)
        continue;
      final a = path[i], b = path[i + 1];
      final scale = 111195 * math.cos(a.lat * math.pi / 180);
      final dx = (b.lon - a.lon) * scale, dy = (b.lat - a.lat) * 111195;
      final px = (fix.lon - a.lon) * scale, py = (fix.lat - a.lat) * 111195;
      final denominator = dx * dx + dy * dy;
      if (denominator == 0) continue;
      final t = ((px * dx + py * dy) / denominator).clamp(0.0, 1.0);
      final offset = lengths[i] + t * (lengths[i + 1] - lengths[i]);
      if (offset > progress + maxAdvance) continue;
      final distance = math.sqrt(
        math.pow(px - t * dx, 2) + math.pow(py - t * dy, 2),
      );
      if (distance < bestDistance) {
        bestDistance = distance;
        bestProgress = offset;
      }
    }
    crossTrack = bestDistance;
    if (crossTrack > math.max(40, fix.accuracy * 2)) {
      _offSince ??= fix.timestamp;
      needsReroute = fix.timestamp - _offSince! >= 10000;
      _nearCount = 0;
      nearStop = false;
      return true;
    }
    _offSince = null;
    needsReroute = false;
    // Do not issue a turn based on a fix that is still ambiguous across paths.
    if (crossTrack > 25) return false;
    progress = math.max(progress, bestProgress);
    if (remaining <= 25 &&
        fix.distance(path.last) <= 20 &&
        fix.accuracy <= 20) {
      _nearCount++;
    } else {
      _nearCount = 0;
    }
    nearStop = _nearCount >= 2;
    return true;
  }

  double get bearing {
    var i = 0;
    while (i < path.length - 2 && lengths[i + 1] <= progress) {
      i++;
    }
    final a = path[i], b = path[i + 1];
    return (math.atan2(
                  (b.lon - a.lon) * math.cos(a.lat * math.pi / 180),
                  b.lat - a.lat,
                ) *
                180 /
                math.pi +
            360) %
        360;
  }
}
