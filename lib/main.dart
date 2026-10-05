import 'package:flutter/material.dart';
import 'package:firebase_core/firebase_core.dart';
import 'firebase_options.dart'; // Step 1에서 생성된 파일
import 'router.dart'; // 앞서 설정한 GoRouter 파일

void main() async {
  // Flutter 바인딩 초기화 및 Firebase 비동기 초기화 보장
  WidgetsFlutterBinding.ensureInitialized();
  
  await Firebase.initializeApp(
    options: DefaultFirebaseOptions.currentPlatform,
  );

  runApp(const RoadmapApp());
}

class RoadmapApp extends StatelessWidget {
  const RoadmapApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp.router(
      title: 'Roadmap App',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        primarySwatch: Colors.blue,
        useMaterial3: true,
      ),
      // GoRouter 연동
      routerConfig: appRouter,
    );
  }
}