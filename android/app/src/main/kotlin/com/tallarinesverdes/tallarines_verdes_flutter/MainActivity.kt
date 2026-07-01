package com.tallarinesverdes.tallarines_verdes_flutter
import de.minimalme.spotify_sdk.SpotifySdkPlugin

import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine

class MainActivity : FlutterActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        if (!flutterEngine.plugins.has(SpotifySdkPlugin::class.java)) {
            flutterEngine.plugins.add(SpotifySdkPlugin())
        }
    }
}
