import Toybox.Application;
import Toybox.Lang;
import Toybox.WatchUi;

class SimplyWeatherApp extends Application.AppBase {
    hidden var weatherView as SimplyWeatherView or Null;
    hidden var weatherGlanceView as SimplyWeatherGlanceView or Null;

    function initialize() {
        AppBase.initialize();
    }

    // onStart() is called on application start up
    function onStart(state as Dictionary?) as Void {
    }

    // onStop() is called when your application is exiting
(:typecheck(disableGlanceCheck))
    function onStop(state as Dictionary?) as Void {
        Sensor.enableSensorEvents(null);
        Position.enableLocationEvents(Position.LOCATION_DISABLE, null);
    }

(:typecheck(disableGlanceCheck))
    function getInitialView() {
        weatherView = new SimplyWeatherView();
        return [ weatherView, new SimplyWeatherDelegate(weatherView) ];
    }

// New app settings have been received so trigger a UI update
(:typecheck(disableGlanceCheck))
    function onSettingsChanged() {
        if (weatherView != null) {
            weatherView.getSettings();
        }
        if (weatherGlanceView != null) {
            weatherGlanceView.refreshTitle();
        }

        WatchUi.requestUpdate();
    }

(:glance)
    function getGlanceView() {
        weatherGlanceView = new SimplyWeatherGlanceView();
        return [ weatherGlanceView ];
    }

}

function getApp() as SimplyWeatherApp {
    return Application.getApp() as SimplyWeatherApp;
}
