import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:pedometer/pedometer.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:go_router/go_router.dart';
import 'package:geolocator/geolocator.dart';
import 'package:permission_handler/permission_handler.dart' as ph;

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  // 만보기 관련 변수
  StreamSubscription<StepCount>? _stepCountSubscription;
  StreamSubscription<PedestrianStatus>? _pedestrianStatusSubscription;
  String _pedometerStatus = '확인 중...';
  int _currentSteps = 0;
  int? _baseSteps;
  int? _lastSensorSteps;
  int _todaySavedSteps = 0;
  String _activeDateKey = '';
  bool _pedometerInitialized = false;

  // 위치 로깅 관련 변수
  bool _isLoggingLocation = false;
  StreamSubscription<Position>? _positionStreamSubscription;
  final List<Map<String, dynamic>> _routePoints = [];
  double _totalDistanceMeters = 0.0;
  DateTime? _loggingStartTime;
  int _elapsedSeconds = 0;
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _loadLocalSteps();
    // 권한 확인 후 만보기 스트림을 시작합니다.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _requestRequiredPermissions();
    });
  }

  @override
  void dispose() {
    _positionStreamSubscription?.cancel();
    _pedestrianStatusSubscription?.cancel();
    _stepCountSubscription?.cancel();
    _timer?.cancel();
    super.dispose();
  }

  /// 필요한 권한을 확인하고, 최초 실행에서만 권한 안내를 표시합니다.
  Future<void> _requestRequiredPermissions() async {
    if (!mounted) return;

    final prefs = await SharedPreferences.getInstance();

    // 비동기 작업이 끝난 뒤에도 위젯이 살아 있는지 확인
    if (!mounted) return;

    const introKey = 'permissions_intro_shown_v1';
    final introAlreadyShown = prefs.getBool(introKey) ?? false;

    if (!introAlreadyShown) {
      final shouldContinue = await showDialog<bool>(
        context: context,
        barrierDismissible: false,
        builder: (dialogContext) => AlertDialog(
          title: const Text('권한 허용 안내'),
          content: const Text(
            '로드맵의 경로 기록 기능은 위치 권한을, 만보기 기능은 신체 활동 권한을 사용합니다. '
            '두 권한을 허용해야 해당 기능을 사용할 수 있습니다.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(false),
              child: const Text('나중에'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(dialogContext).pop(true),
              child: const Text('권한 허용하기'),
            ),
          ],
        ),
      );
      if (!mounted) return;
      // 사용자가 선택한 안내는 다시 표시하지 않습니다. 권한 요청 자체는
      // 아래에서 현재 권한 상태를 확인해 필요한 경우 계속 진행합니다.
      await prefs.setBool(introKey, true);
      if (shouldContinue != true) return;
    }

    // Android 10 이상에서 만보기 센서 접근에 필요한 신체 활동 권한입니다.
    var activityStatus = await ph.Permission.activityRecognition.status;
    if (activityStatus.isDenied) {
      activityStatus = await ph.Permission.activityRecognition.request();
    }
    if (!mounted) return;

    if (activityStatus.isPermanentlyDenied) {
      _showPermissionSettingsMessage('신체 활동');
    }

    // 위치 권한은 만보기와 별도로 확인합니다.
    var locationPermission = await Geolocator.checkPermission();
    if (locationPermission == LocationPermission.denied) {
      locationPermission = await Geolocator.requestPermission();
    }
    if (!mounted) return;

    if (locationPermission == LocationPermission.deniedForever) {
      _showPermissionSettingsMessage('위치');
    } else if (locationPermission == LocationPermission.denied) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('위치 권한이 거부되었습니다. 경로 기록을 사용하려면 권한을 허용해 주세요.')),
      );
    }

    // 신체 활동 권한이 실제로 허용된 다음에 센서 스트림을 구독합니다.
    // 권한보다 먼저 구독하면 초기 센서 오류 후 걸음 수가 갱신되지 않을 수 있습니다.
    if (activityStatus.isGranted) {
      _initPedometer();
    } else if (mounted) {
      setState(() => _pedometerStatus = '신체 활동 권한 필요');
    }
  }

  void _showPermissionSettingsMessage(String permissionName) {
    if (!mounted) return;
    showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text('$permissionName 권한이 필요합니다'),
        content: Text(
          '$permissionName 권한이 영구적으로 거부되어 있습니다. 앱 설정에서 권한을 허용해 주세요.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text('닫기'),
          ),
          FilledButton(
            onPressed: () async {
              Navigator.of(dialogContext).pop();
              await ph.openAppSettings();
            },
            child: const Text('앱 설정 열기'),
          ),
        ],
      ),
    );
  }

  // --- [만보기 로직] ---
  String get _todayKey {
    final now = DateTime.now();
    final month = now.month.toString().padLeft(2, '0');
    final day = now.day.toString().padLeft(2, '0');
    return '${now.year}-$month-$day';
  }

  Future<void> _loadLocalSteps() async {
    final prefs = await SharedPreferences.getInstance();
    final dateKey = _todayKey;
    final savedSteps = prefs.getInt('today_steps_$dateKey') ?? 0;
    if (!mounted) return;
    setState(() {
      _todaySavedSteps = savedSteps;
      _activeDateKey = dateKey;
    });
  }

  void _initPedometer() {
    if (_pedometerInitialized) {
      debugPrint('[Pedometer] 이미 초기화되어 있습니다.');
      return;
    }

    _pedometerInitialized = true;
    debugPrint('[Pedometer] 초기화를 시작합니다.');

    _pedestrianStatusSubscription =
        Pedometer.pedestrianStatusStream.listen(
      (event) {
        debugPrint('[Pedometer] 보행 상태 수신: ${event.status}');

        if (!mounted) return;

        setState(() {
          _pedometerStatus = event.status;
        });
      },
      onError: (Object error, StackTrace stackTrace) {
        debugPrint('[Pedometer] 보행 상태 오류: $error');
        debugPrintStack(stackTrace: stackTrace);

        if (!mounted) return;

        setState(() {
          _pedometerStatus = '센서 에러';
        });
      },
    );

    _stepCountSubscription = Pedometer.stepCountStream.listen(
      (event) async {
        debugPrint('[Pedometer] 센서 이벤트 수신: steps=${event.steps}');

        final dateKey = _todayKey;
        final prefs = await SharedPreferences.getInstance();

        if (!mounted) return;

        setState(() {
          if (_activeDateKey != dateKey) {
            _activeDateKey = dateKey;
            _todaySavedSteps =
                prefs.getInt('today_steps_$dateKey') ?? 0;

            _baseSteps = event.steps;
            _currentSteps = 0;
          } else {
            _baseSteps ??= event.steps;

            final difference = event.steps - _baseSteps!;
            _currentSteps = difference > 0 ? difference : 0;
          }

          _lastSensorSteps = event.steps;
        });

        debugPrint(
          '[Pedometer] 계산 결과: '
          'sensor=${event.steps}, '
          'base=$_baseSteps, '
          'current=$_currentSteps, '
          'saved=$_todaySavedSteps, '
          'total=${_todaySavedSteps + _currentSteps}',
        );
      },
      onError: (Object error, StackTrace stackTrace) {
        debugPrint('[Pedometer] 걸음 수 센서 오류: $error');
        debugPrintStack(stackTrace: stackTrace);

        if (!mounted) return;

      setState(() {
        _pedometerStatus = '센서 에러';
      });
    },
    onDone: () {
      debugPrint('[Pedometer] 걸음 수 스트림이 종료되었습니다.');
    },
  );

  debugPrint('[Pedometer] 두 센서 스트림의 구독을 요청했습니다.');
}

  Future<void> _saveStepsToServer() async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('로그인 후 걸음 수를 저장할 수 있습니다.')),
        );
      }
      return;
    }

    final dateKey = _todayKey;
    final totalStepsToSave = _todaySavedSteps + _currentSteps;

    try {
      await FirebaseFirestore.instance
          .collection('users')
          .doc(user.uid)
          .collection('pedometer')
          .doc(dateKey)
          .set({
        'date': dateKey,
        'steps': totalStepsToSave,
        'updatedAt': FieldValue.serverTimestamp(),
      }, SetOptions(merge: true));

      final prefs = await SharedPreferences.getInstance();
      await prefs.setInt('today_steps_$dateKey', totalStepsToSave);

      if (!mounted) return;
      setState(() {
        _todaySavedSteps = totalStepsToSave;
        // 저장 직후 센서의 현재 누적값을 새 기준점으로 삼아 중복 합산을 막습니다.
        _baseSteps = _lastSensorSteps;
        _currentSteps = 0;
      });

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('걸음 수 저장 완료: users/${user.uid}/pedometer/$dateKey')),
      );
    } catch (e, stackTrace) {
      debugPrint('Firestore pedometer save error: $e\n$stackTrace');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('걸음 수 저장 실패: $e')),
        );
      }
    }
  }

  // --- [위치 로깅 로직 (3번)] ---
  Future<void> _startLocationLogging() async {
    bool serviceEnabled = await Geolocator.isLocationServiceEnabled();
    if (!serviceEnabled) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('위치 서비스를 켜주세요.')));
      return;
    }

    LocationPermission permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
      if (permission == LocationPermission.denied) {
        if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('위치 권한이 거부되었습니다.')));
        return;
      }
    }

    if (permission == LocationPermission.deniedForever) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('설정에서 위치 권한을 허용해주세요.')));
      return;
    }

    // 로깅 초기화
    setState(() {
      _isLoggingLocation = true;
      _routePoints.clear();
      _totalDistanceMeters = 0.0;
      _loggingStartTime = DateTime.now();
      _elapsedSeconds = 0;
    });

    // 타이머 시작 (경과 시간 측정)
    _timer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (!mounted) return;
      setState(() => _elapsedSeconds++);
    });

    // 위치 스트림 구독 (오프라인 우선: 로컬 리스트에 계속 누적)
    const LocationSettings locationSettings = LocationSettings(
      accuracy: LocationAccuracy.bestForNavigation,
      distanceFilter: 3, // 더 세밀하게 위치 변화를 수집합니다.
    );

    _positionStreamSubscription = Geolocator.getPositionStream(
      locationSettings: locationSettings,
    ).listen((Position position) async {
      if (!mounted) return;

      // 정확도가 낮은 GPS 표본은 경로에 넣지 않습니다.
      // 첫 위치는 기록 시작점을 확보하기 위해 정확도 35m까지 허용합니다.
      final maxAccuracyMeters = _routePoints.isEmpty ? 35.0 : 25.0;
      if (!position.latitude.isFinite ||
          !position.longitude.isFinite ||
          position.latitude < -90 ||
          position.latitude > 90 ||
          position.longitude < -180 ||
          position.longitude > 180 ||
          !position.accuracy.isFinite ||
          position.accuracy <= 0 ||
          position.accuracy > maxAccuracyMeters) {
        debugPrint(
          'GPS 표본 제외: accuracy=${position.accuracy.toStringAsFixed(1)}m',
        );
        return;
      }

      // GPS 튐으로 인한 비현실적인 순간 이동을 제외합니다.
      if (_routePoints.isNotEmpty) {
        final last = _routePoints.last;
        final lastLat = (last['latitude'] as num).toDouble();
        final lastLng = (last['longitude'] as num).toDouble();
        final distance = Geolocator.distanceBetween(
          lastLat,
          lastLng,
          position.latitude,
          position.longitude,
        );
        final lastTime = DateTime.tryParse(last['timestamp'] as String);
        final elapsed = lastTime == null
            ? 0.0
            : position.timestamp.difference(lastTime).inMilliseconds / 1000.0;

        // 시간 차이가 0에 가깝다면 속도 판정은 하지 않고, 50m/s 초과 점프만 제외합니다.
        if (elapsed > 0 && distance / elapsed > 50) {
          debugPrint('GPS 점프 제외: ${distance.toStringAsFixed(1)}m / ${elapsed.toStringAsFixed(1)}s');
          return;
        }

        // 거의 같은 좌표를 반복 저장하지 않아 경로 데이터의 불필요한 증가를 막습니다.
        if (distance < 2) return;
      }

      setState(() {
        final newPoint = {
          'latitude': position.latitude,
          'longitude': position.longitude,
          'timestamp': position.timestamp.toIso8601String(),
          'accuracy': position.accuracy,
        };

        if (_routePoints.isNotEmpty) {
          final last = _routePoints.last;
          final distance = Geolocator.distanceBetween(
            (last['latitude'] as num).toDouble(),
            (last['longitude'] as num).toDouble(),
            position.latitude,
            position.longitude,
          );
          _totalDistanceMeters += distance;
        }

        _routePoints.add(newPoint);
      });

      // 오프라인 대비 로컬 SharedPreferences에 임시 저장
      try {
        final prefs = await SharedPreferences.getInstance();
        await prefs.setString('temp_route', jsonEncode(_routePoints));
        await prefs.setDouble('temp_distance', _totalDistanceMeters);
      } catch (e) {
        debugPrint('Temporary route save error: $e');
      }
    });

    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('위치 로깅이 시작되었습니다.')));
    }
  }

  // 위치 로깅 종료 및 서버(Firestore) 저장
  Future<void> _stopAndSaveLocationLogging() async {
    if (!_isLoggingLocation) return;

    await _positionStreamSubscription?.cancel();
    _positionStreamSubscription = null;
    _timer?.cancel();
    _timer = null;

    final user = FirebaseAuth.instance.currentUser;
    if (user == null) {
      if (mounted) {
        setState(() => _isLoggingLocation = false);
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('로그인 상태를 확인한 후 다시 시도해 주세요.')),
        );
      }
      return;
    }

    if (_routePoints.isEmpty) {
      if (mounted) {
        setState(() => _isLoggingLocation = false);
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('기록된 위치가 없습니다. GPS 신호를 확인한 후 다시 시도해 주세요.')),
        );
      }
      return;
    }

    final docId = DateTime.now().toIso8601String();
    final summaryData = <String, dynamic>{
      'startTime': _loggingStartTime?.toIso8601String(),
      'endTime': DateTime.now().toIso8601String(),
      'totalDistanceKm': double.parse((_totalDistanceMeters / 1000).toStringAsFixed(2)),
      'elapsedSeconds': _elapsedSeconds,
      'steps': _currentSteps,
      'routePoints': List<Map<String, dynamic>>.from(_routePoints),
      'createdAt': FieldValue.serverTimestamp(),
    };

    try {
      await FirebaseFirestore.instance
          .collection('users')
          .doc(user.uid)
          .collection('location_logs')
          .doc(docId)
          .set(summaryData);

      final prefs = await SharedPreferences.getInstance();
      await prefs.remove('temp_route');
      await prefs.remove('temp_distance');

      if (!mounted) return;
      setState(() => _isLoggingLocation = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('경로 저장 완료: users/${user.uid}/location_logs/$docId')),
      );
    } catch (e, stackTrace) {
      debugPrint('Firestore location save error: $e\n$stackTrace');
      if (!mounted) return;
      setState(() => _isLoggingLocation = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('경로 저장 실패: $e\n임시 경로는 기기에 남아 있을 수 있습니다.')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final totalDisplaySteps = _todaySavedSteps + _currentSteps;
    final user = FirebaseAuth.instance.currentUser;
    final distanceKm = (_totalDistanceMeters / 1000).toStringAsFixed(2);
    final minutes = _elapsedSeconds ~/ 60;
    final seconds = _elapsedSeconds % 60;

    return Scaffold(
      appBar: AppBar(
        title: const Text('로드맵 홈'),
        actions: [
          IconButton(
            icon: const Icon(Icons.logout),
            onPressed: () async {
              await FirebaseAuth.instance.signOut();
              if (context.mounted) context.go('/login');
            },
          )
        ],
      ),
      drawer: Drawer(
        child: ListView(
          padding: EdgeInsets.zero,
          children: [
            UserAccountsDrawerHeader(
              accountName: Text(user?.displayName ?? '사용자'),
              accountEmail: Text(user?.email ?? ''),
              currentAccountPicture: const CircleAvatar(child: Icon(Icons.person)),
            ),
            ListTile(
              leading: const Icon(Icons.directions_walk),
              title: const Text('만보기 상세 (주간 그래프)'),
              onTap: () {
                Navigator.pop(context);
                context.push('/pedometer-detail');
              },
            ),
            ListTile(
              leading: const Icon(Icons.map),
              title: const Text('위치 로깅 기록 리스트'),
              onTap: () {
                Navigator.pop(context);
                context.push('/location-list');
              },
            ),
          ],
        ),
      ),
      body: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // 1. 만보기 요약 카드
            Card(
              elevation: 4,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
              child: Padding(
                padding: const EdgeInsets.all(20.0),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        const Text('오늘의 만보기', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
                        Chip(
                          label: Text(_pedometerStatus, style: const TextStyle(color: Colors.white, fontSize: 12)),
                          backgroundColor: _pedometerStatus == 'walking' ? Colors.green : Colors.grey,
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    Text('$totalDisplaySteps 걸음', style: const TextStyle(fontSize: 32, fontWeight: FontWeight.bold)),
                    const SizedBox(height: 8),
                    Row(
                      children: [
                        Expanded(
                          child: ElevatedButton(
                            onPressed: _saveStepsToServer,
                            child: const Text('만보기 서버 저장'),
                          ),
                        ),
                        const SizedBox(width: 8),
                        OutlinedButton(
                          onPressed: () => context.push('/pedometer-detail'),
                          child: const Text('주간 상세'),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 20),

            // 2. 위치 로깅 요약 및 시작/종료 카드 (3번 구현)
            Card(
              elevation: 4,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
              child: Padding(
                padding: const EdgeInsets.all(20.0),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        const Text('위치 경로 로깅', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
                        Chip(
                          label: Text(_isLoggingLocation ? '로깅 중...' : '대기 중', style: const TextStyle(color: Colors.white, fontSize: 12)),
                          backgroundColor: _isLoggingLocation ? Colors.red : Colors.grey,
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    Text('이동 거리: $distanceKm km', style: const TextStyle(fontSize: 16)),
                    const SizedBox(height: 4),
                    Text('경과 시간: $minutes분 $seconds초', style: const TextStyle(fontSize: 16, color: Colors.grey)),
                    const SizedBox(height: 16),
                    Row(
                      children: [
                        Expanded(
                          child: ElevatedButton.icon(
                            style: ElevatedButton.styleFrom(backgroundColor: Colors.green, foregroundColor: Colors.white),
                            onPressed: _isLoggingLocation ? null : _startLocationLogging,
                            icon: const Icon(Icons.play_arrow),
                            label: const Text('로깅 시작'),
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: OutlinedButton.icon(
                            style: OutlinedButton.styleFrom(foregroundColor: Colors.red),
                            onPressed: _isLoggingLocation ? _stopAndSaveLocationLogging : null,
                            icon: const Icon(Icons.stop),
                            label: const Text('종료 및 저장'),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
