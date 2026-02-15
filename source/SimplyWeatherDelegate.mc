import Toybox.WatchUi;
import Toybox.Lang;

class SimplyWeatherDelegate extends WatchUi.BehaviorDelegate {
    /* Initialize and get a reference to the view, so that
     * user iterations can call methods in the main view. */
     var SWView as SimplyWeatherView;
     
    function initialize(view as SimplyWeatherView) {
        WatchUi.BehaviorDelegate.initialize();
        SWView = view;
    }
}
