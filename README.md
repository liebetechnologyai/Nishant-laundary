# LIEBE Laundry Engine — Customer App (Flutter)

## Setup
1. Create the native shells in this folder (keeps `lib/` and `pubspec.yaml`):
   `flutter create --org com.liebe --project-name liebe_customer .`
2. `flutter pub get`
3. Firebase push (optional — the app runs without it):
   - Android: put `google-services.json` in `android/app/`, add the Google Services Gradle plugin.
   - iOS: add `GoogleService-Info.plist` via Xcode, enable Push Notifications + Background Modes, upload your APNs key in Firebase.
4. Android extras:
   - `android/app/build.gradle`: `compileOptions { coreLibraryDesugaringEnabled true }` and
     `dependencies { coreLibraryDesugaring 'com.android.tools:desugar_jdk_libs:2.0.4' }`
     (required by flutter_local_notifications), and `minSdkVersion 21` or higher.
   - `AndroidManifest.xml`: inside `<manifest>` add
     `<uses-permission android:name="android.permission.POST_NOTIFICATIONS"/>` and
     `<queries><intent><action android:name="android.intent.action.VIEW"/><data android:scheme="https"/></intent></queries>`
     (the second one lets the invoice link open on Android 11+).
5. Run:
   `flutter run --dart-define=SUPABASE_URL=https://xxxx.supabase.co --dart-define=SUPABASE_ANON_KEY=... --dart-define=API_URL=http://10.0.2.2:4000`
   (`10.0.2.2` is the Android emulator's alias for your computer's localhost).

Realtime tracking needs the SQL from Step 1 (`orders` and `order_status_history` are in the `supabase_realtime` publication and protected by RLS).
