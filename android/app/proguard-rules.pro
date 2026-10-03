# Flutter engine and embedding must survive shrinking — the engine
# looks up these classes from native code.
-keep class io.flutter.** { *; }
-keep class io.flutter.plugins.** { *; }
-dontwarn io.flutter.embedding.**

# Optional dependencies Flutter references only on some platforms.
-dontwarn com.google.android.play.core.**
-dontwarn javax.annotation.**
-dontwarn org.conscrypt.**
