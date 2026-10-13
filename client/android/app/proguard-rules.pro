# Downloaded DEX references these names and methods outside R8's call graph.
-keep class com.github.catvod.crawler.** { *; }
-keep class com.whl.quickjs.** { *; }
-keep class okhttp3.** { *; }
-keep class okio.** { *; }
-keep class com.google.gson.** { *; }
-keepattributes Signature,*Annotation*
