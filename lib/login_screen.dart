import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:go_router/go_router.dart';

class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  bool _isLoading = false;

  Future<void> _signInWithGoogle() async {
    setState(() => _isLoading = true);

    try {
      // 1. 구글 팝업창 띄우기
      debugPrint('[GoogleSignIn] 1. 로그인 시작');

      final GoogleSignInAccount? googleUser = await GoogleSignIn(
        serverClientId: '76487740850-uh3q0jfoluik19p3frokbp14slmj4gel.apps.googleusercontent.com',
      ).signIn();

      debugPrint('[GoogleSignIn] 2. Google 계정 선택 완료');

      if (googleUser == null) {
        debugPrint('[GoogleSignIn] 사용자가 로그인을 취소함');
        setState(() => _isLoading = false);
        return;
      }

      // 2. 구글 인증 정보 가져오기
      final GoogleSignInAuthentication googleAuth = await googleUser.authentication;

      debugPrint('[GoogleSignIn] 3. 인증 토큰 획득 완료');

      // 3. Firebase 자격 증명 생성
      final credential = GoogleAuthProvider.credential(
        accessToken: googleAuth.accessToken,
        idToken: googleAuth.idToken,
      );

      // 4. Firebase로 로그인
      await FirebaseAuth.instance.signInWithCredential(credential);

      if (mounted) {
        context.go('/home'); // 로그인 성공 시 홈으로 이동
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('구글 로그인 실패: $e')),
        );
      }
    } finally {
      if (mounted) {
        setState(() => _isLoading = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('로드맵 로그인'),
      ),
      body: Padding(
        padding: const EdgeInsets.all(24.0),
        child: Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Icon(Icons.map_rounded, size: 80, color: Colors.blueAccent),
              const SizedBox(height: 24),
              const Text(
                '오프라인 우선 위치 로깅 & 만보기',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 8),
              const Text(
                '구글 계정으로 간편하게 시작하세요.',
                textAlign: TextAlign.center,
                style: TextStyle(color: Colors.grey, fontSize: 14),
              ),
              const SizedBox(height: 48),
              _isLoading
                  ? const Center(child: CircularProgressIndicator())
                  : ElevatedButton.icon(
                      style: ElevatedButton.styleFrom(
                        padding: const EdgeInsets.symmetric(vertical: 14),
                        backgroundColor: Colors.white,
                        foregroundColor: Colors.black87,
                        elevation: 2,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(8),
                          side: const BorderSide(color: Colors.grey, width: 0.5),
                        ),
                      ),
                      onPressed: _signInWithGoogle,
                      // 구글 로고 또는 아이콘 사용
                      icon: const Icon(Icons.g_mobiledata, size: 32, color: Colors.blue),
                      label: const Text(
                        'Google로 계속하기',
                        style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                      ),
                    ),
            ],
          ),
        ),
      ),
    );
  }
}