import 'dart:async';
import 'dart:convert';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:geolocator/geolocator.dart';
import 'package:pedometer/pedometer.dart';
import 'package:shared_preferences/shared_preferences.dart';

String _dayKey(DateTime date) => '${date.year.toString().padLeft(4, '0')}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}';

@pragma('vm:entry-point')
void startRoadmapBackgroundTask() {
  FlutterForegroundTask.setTaskHandler(RoadmapBackgroundTaskHandler());
}

class RoadmapBackgroundTaskHandler extends TaskHandler {
  StreamSubscription<StepCount>? _stepsSub;
  StreamSubscription<Position>? _positionSub;
  Timer? _clock;
  int? _rawBaseline;
  String _activeDay = '';
  bool _stepsEnabled = true;
  bool _routeEnabled = false;
  List<Map<String, dynamic>> _points = [];
  double _distanceMeters = 0;
  DateTime? _routeStart;
  int _lastRawSteps = 0;

  @override
  Future<void> onStart(DateTime timestamp, TaskStarter starter) async {
    final prefs = await SharedPreferences.getInstance();
    _activeDay = _dayKey(DateTime.now());
    _stepsEnabled = prefs.getBool('background_steps_enabled') ?? true;
    _routeEnabled = prefs.getBool('route_logging_active') ?? false;
    _points = _decodePoints(prefs.getString('temp_route'));
    _distanceMeters = prefs.getDouble('temp_distance') ?? 0;
    final startString = prefs.getString('route_start_time');
    _routeStart = startString == null ? null : DateTime.tryParse(startString);
    _lastRawSteps = prefs.getInt('step_raw_last') ?? 0;
    _rawBaseline = prefs.getInt('step_raw_baseline_$_activeDay');
    if (_stepsEnabled) _listenSteps();
    if (_routeEnabled) _listenLocation();
    _clock = Timer.periodic(const Duration(seconds: 5), (_) => _checkDay());
  }

  List<Map<String, dynamic>> _decodePoints(String? value) {
    if (value == null) return [];
    try { return (jsonDecode(value) as List).cast<Map>().map((e) => Map<String, dynamic>.from(e)).toList(); }
    catch (_) { return []; }
  }

  void _listenSteps() {
    _stepsSub?.cancel();
    _stepsSub = Pedometer.stepCountStream.listen((event) async {
      final prefs = await SharedPreferences.getInstance();
      final today = _dayKey(DateTime.now());
      if (today != _activeDay) await _rollToNewDay(event.steps, prefs);
      var baseline = prefs.getInt('step_raw_baseline_$_activeDay');
      final current = prefs.getInt('today_steps_$_activeDay') ?? 0;
      if (baseline == null) {
        baseline = event.steps - current;
        await prefs.setInt('step_raw_baseline_$_activeDay', baseline);
      }
      if (event.steps < (prefs.getInt('step_raw_last') ?? event.steps)) {
        // Sensor counter restarted (e.g. reboot): preserve today's total.
        baseline = event.steps - current;
        await prefs.setInt('step_raw_baseline_$_activeDay', baseline);
      }
      final calculated = (event.steps - baseline).clamp(0, 1000000);
      final total = calculated > current ? calculated : current;
      await prefs.setInt('today_steps_$_activeDay', total);
      await prefs.setInt('step_raw_last', event.steps);
      _lastRawSteps = event.steps;
      FlutterForegroundTask.sendDataToMain({'type':'steps','day':_activeDay,'steps':total});
    }, onError: (Object e) => FlutterForegroundTask.sendDataToMain({'type':'error','message':'만보기 센서 오류'}));
  }

  Future<void> _rollToNewDay(int raw, SharedPreferences prefs) async {
    _activeDay = _dayKey(DateTime.now());
    await prefs.setInt('today_steps_$_activeDay', 0);
    await prefs.setInt('step_raw_baseline_$_activeDay', raw);
    _rawBaseline = raw;
    await prefs.setString('active_steps_day', _activeDay);
    FlutterForegroundTask.sendDataToMain({'type':'steps','day':_activeDay,'steps':0});
  }

  Future<void> _checkDay() async {
    final prefs = await SharedPreferences.getInstance();
    final today = _dayKey(DateTime.now());
    if (today != _activeDay) {
      await _rollToNewDay(_lastRawSteps, prefs);
    }
    if (_routeEnabled) {
      FlutterForegroundTask.sendDataToMain({'type':'route','points':_points.length,'distance':_distanceMeters,'start':_routeStart?.toIso8601String()});
    }
  }

  void _listenLocation() {
    _positionSub?.cancel();
    _positionSub = Geolocator.getPositionStream(locationSettings: const LocationSettings(accuracy: LocationAccuracy.high, distanceFilter: 5)).listen((p) async {
      if (p.accuracy > 50) return;
      if (_points.isNotEmpty) {
        final last = _points.last;
        final d = Geolocator.distanceBetween((last['latitude'] as num).toDouble(), (last['longitude'] as num).toDouble(), p.latitude, p.longitude);
        if (d > 150 || (p.speed > 0 && p.speed > 50)) return;
        if (d < 2) return;
        _distanceMeters += d;
      }
      _points.add({'latitude':p.latitude,'longitude':p.longitude,'timestamp':p.timestamp.toIso8601String()});
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('temp_route', jsonEncode(_points));
      await prefs.setDouble('temp_distance', _distanceMeters);
      await prefs.setString('route_start_time', (_routeStart ?? DateTime.now()).toIso8601String());
      FlutterForegroundTask.sendDataToMain({'type':'route','points':_points.length,'distance':_distanceMeters,'start':_routeStart?.toIso8601String()});
    }, onError: (Object e) => FlutterForegroundTask.sendDataToMain({'type':'error','message':'GPS 위치 기록 오류'}));
  }

  @override
  void onRepeatEvent(DateTime timestamp) { _checkDay(); }

  @override
  void onReceiveData(Object data) async {
    if (data is! Map) return;
    final command = data['command'];
    final prefs = await SharedPreferences.getInstance();
    if (command == 'stepsEnabled') {
      _stepsEnabled = data['enabled'] == true;
      await prefs.setBool('background_steps_enabled', _stepsEnabled);
      if (_stepsEnabled) { _listenSteps(); } else { await _stepsSub?.cancel(); _stepsSub = null; }
      if (!_stepsEnabled && !_routeEnabled) await FlutterForegroundTask.stopService();
    } else if (command == 'startRoute') {
      _routeEnabled = true; _routeStart = DateTime.now(); _points = []; _distanceMeters = 0;
      await prefs.setBool('route_logging_active', true);
      await prefs.setString('route_start_time', _routeStart!.toIso8601String());
      await prefs.setString('temp_route', '[]'); await prefs.setDouble('temp_distance', 0);
      _listenLocation();
    } else if (command == 'stopRoute') {
      _routeEnabled = false; await _positionSub?.cancel(); _positionSub = null;
      await prefs.setBool('route_logging_active', false);
      await prefs.setString('temp_route', jsonEncode(_points)); await prefs.setDouble('temp_distance', _distanceMeters);
      FlutterForegroundTask.sendDataToMain({'type':'routeStopped','points':_points,'distance':_distanceMeters,'start':_routeStart?.toIso8601String()});
      if (!_stepsEnabled) await FlutterForegroundTask.stopService();
    }
  }

  @override
  Future<void> onDestroy(DateTime timestamp, bool isTimeout) async {
    await _stepsSub?.cancel(); await _positionSub?.cancel(); _clock?.cancel();
  }
}
