# Flutter Wrapper
-keep class io.flutter.app.** { *; }
-keep class io.flutter.plugin.**  { *; }
-keep class io.flutter.util.**  { *; }
-keep class io.flutter.view.**  { *; }
-keep class io.flutter.**  { *; }
-keep class io.flutter.plugins.**  { *; }

# Keep Dart VM stuff if needed
-keep class dart.** { *; }

# Protect WindowManager / UI components if necessary
-keep class com.omarafifi.daphq.** { *; }

# Flutter Play Store Split Compatibility
-dontwarn com.google.android.play.core.**
-keep class io.flutter.embedding.engine.deferredcomponents.** { *; }