import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/foundation.dart';

Future initFirebase() async {
  if (kIsWeb) {
    await Firebase.initializeApp(
        options: FirebaseOptions(
            apiKey: "AIzaSyDzE_AkOyv0-SxS1h-SZtqCCtm7rVjy4GE",
            authDomain: "onetest-demo.firebaseapp.com",
            projectId: "onetest-demo",
            storageBucket: "onetest-demo.firebasestorage.app",
            messagingSenderId: "1016240511800",
            appId: "1:1016240511800:web:1a4b088e59813460323fcd",
            measurementId: "G-4DXJK5BF7C"));
  } else {
    await Firebase.initializeApp();
  }
}
