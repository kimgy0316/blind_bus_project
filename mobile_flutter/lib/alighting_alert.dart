/// One alert per threshold for one boarding request; regressing data cannot repeat it.
class AlightingAlert {
  int _delivered = 0;

  int candidate(Map<String, dynamic>? progress) {
    if (progress == null || progress['available'] != true) return 0;
    if (progress['state'] == 'at_stop' || progress['state'] == 'passed') {
      _delivered = 2;
      return 0;
    }
    if (progress['state'] != 'riding') return 0;
    final count = progress['remainingStops'];
    final level = count == 1 ? 2 : count == 2 ? 1 : 0;
    return level > _delivered ? level : 0;
  }

  void delivered(int level) {
    if (level > _delivered) _delivered = level;
  }
}
