import 'package:go_router/go_router.dart';
import 'package:firebase_auth/firebase_auth.dart';

// 화면 임포트 (경로는 프로젝트 구조에 맞게 조정해주세요)
import 'login_screen.dart';
import 'home_screen.dart';
import 'pedometer_detail_screen.dart';
import 'location_list_screen.dart';
import 'location_detail_screen.dart';

final GoRouter appRouter = GoRouter(
  initialLocation: FirebaseAuth.instance.currentUser == null ? '/login' : '/home',
  routes: [
    // 1. 로그인 화면
    GoRoute(
      path: '/login',
      builder: (context, state) => const LoginScreen(),
    ),
    
    // 2. 홈 화면
    GoRoute(
      path: '/home',
      builder: (context, state) => const HomeScreen(),
    ),
    
    // 3. 만보기 주간 상세 화면
    GoRoute(
      path: '/pedometer-detail',
      builder: (context, state) => const PedometerDetailScreen(),
    ),
    
    // 4. 위치 로깅 리스트 화면
    GoRoute(
      path: '/location-list',
      builder: (context, state) => const LocationListScreen(),
    ),
    
    // 5. 위치 로깅 상세 화면 (데이터 객체를 extra로 전달받음)
    GoRoute(
      path: '/location-detail',
      builder: (context, state) {
        final logData = state.extra as Map<String, dynamic>? ?? {};
        return LocationDetailScreen(logData: logData);
      },
    ),
  ],
);