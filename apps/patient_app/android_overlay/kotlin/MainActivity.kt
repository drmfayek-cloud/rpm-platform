package __PACKAGE__

import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine

class MainActivity : FlutterActivity() {
    private var hc03: Hc03Bridge? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        hc03 = Hc03Bridge(this, flutterEngine.dartExecutor.binaryMessenger)
    }

    override fun onDestroy() {
        hc03?.dispose()
        hc03 = null
        super.onDestroy()
    }
}
