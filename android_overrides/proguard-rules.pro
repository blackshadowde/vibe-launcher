# Release builds shrink code (R8). ML Kit's on-phone AI finds some of its parts by name at runtime,
# so keep them, otherwise Generation.getClient() fails with a NullPointerException.
-keep class com.google.mlkit.** { *; }
-keep class com.google.android.gms.internal.mlkit_** { *; }
-keep class com.google.android.gms.common.** { *; }
-keep class com.google.firebase.components.** { *; }
-keep class com.google.ai.edge.** { *; }
-keep class com.google.android.aicore.** { *; }
-dontwarn com.google.mlkit.**
-dontwarn com.google.ai.edge.**
# Background music player (Media3) and its session service
-keep class androidx.media3.session.** { *; }
