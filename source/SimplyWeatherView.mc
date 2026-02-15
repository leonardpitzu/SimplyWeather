import Toybox.Graphics;
import Toybox.WatchUi;
import Toybox.Time;
import Toybox.Time.Gregorian;
import Toybox.Position;
import Toybox.Application.Properties;
import Toybox.Application.Storage;
import Toybox.Sensor;
import Toybox.SensorHistory;
import Toybox.Lang;
import Toybox.Math;
import Toybox.System;
import Toybox.Activity;

import Zambretti;

const cLowPressure = 950;
const cHighPressure = 1050;
const cOffset = 0;
const cTime = 0.0 - ((Gregorian.SECONDS_PER_HOUR * 3) + (Gregorian.SECONDS_PER_MINUTE * 10));
const cSteady = 5.0; // equivalent to 0.5 hPa
const cShowDetails = true;
const cUseMSLPressure = true;
const MINS_5 = (Gregorian.SECONDS_PER_MINUTE * 5);
const DIR_CONFIRM_SAMPLES = 4;
const HEADING_SMOOTH_FACTOR = 0.15;
const HEADING_REDRAW_THRESHOLD = 1.0;
const IDLE_REDRAW_INTERVAL_MS = 1000;
const CALENDAR_REFRESH_INTERVAL_MS = 60000;
const PRESSURE_REFRESH_INTERVAL_MS = 15000;

class SimplyWeatherView extends WatchUi.View {
    var mUseMSLPressure as Boolean = true;
    var mLowPressure as Number = cLowPressure;
    var mHighPressure as Number = cHighPressure;
    var mOffset as Number = cOffset;
    var mUseOriginal as Boolean = false;
    var mTime as Float = cTime;
    var mSteadyLimit as Float = cSteady;
    var mNorthSouth as Number = 1; // Northern hemisphere
    var mDefHemi as Number = 1; // Default hemisphere is Northern
    var mShowDetails as Boolean = true;
    var mNotMetricTemp as Boolean = false;

    var mDir as Number = 0;
    var mAcquiringGPS as Boolean = true;

    var shakeDetected = false;
    var SHAKE_THRESHOLD = 1.2; // Tune this value if needed; higher means less sensitive to shakes
    var SHAKE_TIMEOUT = 3000; // In milliseconds
    var lastShakeTime = 0;

    var mLastHeading as Float = 0.0;
    var mHasHeading as Boolean = false;
    var mPendingDir as Number = 0;
    var mPendingDirSamples as Number = 0;
    hidden var timer;

    var positioning_blink as Number = 0;
    var showImage as Boolean = true;
    var satelliteBitmap;
    var xSatelliteBitmap;
    var ySatelliteBitmap;
    var PrecipitationRain;
    var PrecipitationSnow;
    var xPrecipitationBitmap;
    var yPrecipitationBitmap;
    var arrowBitmap;

    var trend = 0;
    var currentPress = 0;
    var mTemperatureText as String = "";
    var mScreenLayout as Array<Numeric> or Null = null;
    var mCompassLabels as Array<String> = ["N", "NE", "E", "SE", "S", "SW", "W", "NW"];
    var mTrendTextCache as Array<String> = [];
    var mPointTextCache as Array<String> = [];
    var mTickSin as Array<Float> = [];
    var mTickCos as Array<Float> = [];
    var mLabelSin as Array<Float> = [];
    var mLabelCos as Array<Float> = [];
    var mCachedMonth as Number = 1;
    var mLastCalendarRefreshMs as Number = -1;
    var mLastPressureRefreshMs as Number = -1;
    var mForceNextUpdate as Boolean = true;
    var mLastRequestedHeading as Float = 0.0;
    var mHasRequestedHeading as Boolean = false;
    var mLastIdleRedrawMs as Number = 0;

    var mLastForecast = null;
    var mLastDir = null;
    var mLastHemisphere = null;
    var mLastForecastLine1 as String = "";
    var mLastForecastLine2 as String = "";
    var mLastForecastWidth as Number = -1;
    var mForecastFontTop = Graphics.FONT_LARGE;
    var mForecastFontBottom = Graphics.FONT_LARGE;

    var mStoredWindIndex = null;
    var mStoredHemisphere = null;
    var mStoredForecast = null;
    var mStoredForecastNumber = null;
    var mHasFetchedGPSThisRun as Boolean = false;

    var trendStrings as Array<Lang.ResourceId> = [
        Rez.Strings.TrendS,
        Rez.Strings.TrendR,
        Rez.Strings.TrendF
    ] as Array<Lang.ResourceId>;

    var pointStrings as Array<Lang.ResourceId> = [
        Rez.Strings.C,
        Rez.Strings.N,
        Rez.Strings.NNE,
        Rez.Strings.NE,
        Rez.Strings.ENE,
        Rez.Strings.E,
        Rez.Strings.ESE,
        Rez.Strings.SE,
        Rez.Strings.SSE,
        Rez.Strings.S,
        Rez.Strings.SSW,
        Rez.Strings.SW,
        Rez.Strings.WSW,
        Rez.Strings.W,
        Rez.Strings.WNW,
        Rez.Strings.NW,
        Rez.Strings.NNW
    ] as Array<Lang.ResourceId>;

    function initializeTextCaches() as Void {
        if (mTrendTextCache.size() == 0) {
            for (var i = 0; i < trendStrings.size(); i++) {
                mTrendTextCache.add(WatchUi.loadResource((trendStrings as Array)[i] as Lang.ResourceId) as String);
            }
        }

        if (mPointTextCache.size() == 0) {
            for (var j = 0; j < pointStrings.size(); j++) {
                mPointTextCache.add(WatchUi.loadResource((pointStrings as Array)[j] as Lang.ResourceId) as String);
            }
        }
    }

    function initializeCompassTables() as Void {
        if (mTickSin.size() > 0) {
            return;
        }

        for (var i = 0; i < 16; i++) {
            var tickAngle = Math.toRadians(i * 22.5);
            mTickSin.add(Math.sin(tickAngle));
            mTickCos.add(Math.cos(tickAngle));
        }

        for (var j = 0; j < 8; j++) {
            var labelAngle = Math.toRadians(j * 45.0);
            mLabelSin.add(Math.sin(labelAngle));
            mLabelCos.add(Math.cos(labelAngle));
        }
    }

    function refreshCalendarMonth(force as Boolean) as Void {
        var nowMs = System.getTimer();
        if (!force && mLastCalendarRefreshMs >= 0 && (nowMs - mLastCalendarRefreshMs) < CALENDAR_REFRESH_INTERVAL_MS) {
            return;
        }

        var today = Gregorian.info(Time.now(), Time.FORMAT_SHORT);
        mCachedMonth = today.month;
        mLastCalendarRefreshMs = nowMs;
    }

    function tString(tr as Number) as String {
        if (mTrendTextCache.size() == 0) {
            initializeTextCaches();
        }

        var idx = tr.toNumber();
        if (idx < 0 || idx >= mTrendTextCache.size()) {
            return "";
        }

        return (mTrendTextCache as Array<String>)[idx];
    }

    function pString(dir as Number) as String {
        if (mPointTextCache.size() == 0) {
            initializeTextCaches();
        }

        var idx = dir.toNumber();
        if (idx < 0 || idx >= mPointTextCache.size()) {
            idx = 0;
        }

        return (mPointTextCache as Array<String>)[idx];
    }

    function getSettings() as Void {
        var temp;

        var deviceSettings = System.getDeviceSettings();
        mNotMetricTemp = deviceSettings.temperatureUnits != System.UNIT_METRIC;

        try {
            temp = Properties.getValue("AdjustedPressure");
        }
        catch (ex) {
            temp = null;
        }
           mUseMSLPressure = (temp != null && temp instanceof Number) ? (temp == 0) : cUseMSLPressure;
        try {
            temp = Properties.getValue("LowPressure");
        }
        catch (ex) {
            temp = null;
        }
        try {
            if (!(temp instanceof Number)) {
                temp = cLowPressure;
            }
            if (temp >= 850 && temp <= 1100) {
                mLowPressure = temp;
            }
        }
        catch (ex) {
            mLowPressure = cLowPressure;
        }
        try {
            temp = Properties.getValue("HighPressure");
            if (!(temp instanceof Number)) {
                temp = cHighPressure;
            }
            if (temp >= 850 && temp <= 1100) {
                mHighPressure = temp;
            }
        }
        catch (ex) {
            mHighPressure = cHighPressure;
        }
        if (mHighPressure < mLowPressure) {
            temp = mHighPressure;
            mHighPressure = mLowPressure;
            mLowPressure = temp;
        }
        try {
            temp = Properties.getValue("Offset");
        }
        catch (ex) {
            temp = cOffset;
        }
        if (!(temp instanceof Number)) {
            temp = cOffset;
        }
        mOffset = temp;
        try {
            temp = Properties.getValue("Steady");
        }
        catch (ex) {
            temp = null;
        }
        mSteadyLimit = (temp == null) ? cSteady : (temp as Numeric).toFloat();
        try {
            temp = Properties.getValue("Time");
        }
        catch (ex) {
            temp = null;
        }
        if (temp == null) {
            mTime = cTime;
        } else {
            try {
                temp = (temp as Numeric).toFloat();
            }
            catch (ex) {
                temp = null;
            }
            mTime = (temp == null) ? cTime : (temp * -Gregorian.SECONDS_PER_HOUR - 10 * Gregorian.SECONDS_PER_MINUTE);
        }

        try {
            temp = Properties.getValue("ShowDetails");
        }
        catch (ex) {
            temp = 1;
        }

        mShowDetails = (temp instanceof Number) ? (temp == 0) : cShowDetails;

        try {
            temp = Properties.getValue("UseOriginal");
        }
        catch (ex) {
            temp = 1;
        }
        mUseOriginal = (temp instanceof Number) ? (temp == 0) : false;

        // Default is 1 North, 0 South
        try {
            temp = Properties.getValue("DefaultHemisphere");
        }
        catch (ex) {
            temp = 1;
        }
           temp = ((temp instanceof Number) ? temp : 1); // Northern if not chosen correctly
        mDefHemi = temp>0 ? 1 : 0;
        mNorthSouth = mDefHemi;

        // Recompute forecast on next update when settings change.
        mLastDir = null;
        mLastHemisphere = null;
        mLastForecast = null;
        mLastPressureRefreshMs = -1;
        mForceNextUpdate = true;
    }

    function initialize() {
        View.initialize();

        getSettings();
        initializeTextCaches();
        initializeCompassTables();
        refreshCalendarMonth(true);
    }

    function persistWindDirection(dir as Number) as Void {
        if (mStoredWindIndex == null || mStoredWindIndex != dir) {
            mStoredWindIndex = dir;
            Storage.setValue("windIndex", dir);
        }
    }

    function persistHemisphere(hemisphere as Number) as Void {
        if (mStoredHemisphere == null || mStoredHemisphere != hemisphere) {
            mStoredHemisphere = hemisphere;
            Storage.setValue("hemisphere", hemisphere);
        }
    }

    function persistForecastValues(forecastText as String, forecastNumber) as Void {
        if (mStoredForecast == null || mStoredForecast != forecastText) {
            mStoredForecast = forecastText;
            Storage.setValue("forecast", forecastText);
        }

        if (mStoredForecastNumber == null || mStoredForecastNumber != forecastNumber) {
            mStoredForecastNumber = forecastNumber;
            Storage.setValue("forecastNumber", forecastNumber);
        }
    }

    function smoothHeading(heading as Float) as Float {
        if (!mHasHeading) {
            mLastHeading = heading;
            mHasHeading = true;
            return mLastHeading;
        }

        var delta = heading - mLastHeading;
        if (delta > 180.0) {
            delta -= 360.0;
        } else if (delta < -180.0) {
            delta += 360.0;
        }

        mLastHeading += delta * HEADING_SMOOTH_FACTOR;
        return mLastHeading;
    }

    function headingDeltaAbs(a as Float, b as Float) as Float {
        var delta = a - b;
        if (delta > 180.0) {
            delta -= 360.0;
        } else if (delta < -180.0) {
            delta += 360.0;
        }

        if (delta < 0.0) {
            delta = -delta;
        }

        return delta;
    }

    function headingToDirection(heading as Float) as Number {
        var normalized = myMod(heading, 360.0).toFloat();
        var bucket = ((normalized + 11.25) / 22.5).toLong();

        return ((bucket % 16) + 1).toNumber();
    }

    function updateDirectionWithHysteresis(heading as Float) as Boolean {
        var candidateDir = headingToDirection(heading);
        if (candidateDir == mDir) {
            mPendingDir = 0;
            mPendingDirSamples = 0;
            return false;
        }

        if (candidateDir != mPendingDir) {
            mPendingDir = candidateDir;
            mPendingDirSamples = 1;
        } else {
            mPendingDirSamples += 1;
        }

        if (mPendingDirSamples >= DIR_CONFIRM_SAMPLES) {
            mDir = mPendingDir;
            mPendingDir = 0;
            mPendingDirSamples = 0;
            persistWindDirection(mDir);
            return true;
        }

        return false;
    }

    function updateForecastFonts(dc as Dc, line1 as String, line2 as String, maxHalfWidth as Number) as Void {
        if (line1 == mLastForecastLine1 && line2 == mLastForecastLine2 && maxHalfWidth == mLastForecastWidth) {
            return;
        }

        var fontTop = Graphics.FONT_LARGE;
        while (fontTop >= Graphics.FONT_XTINY && dc.getTextDimensions(line1, fontTop)[0] / 2 > maxHalfWidth) {
            fontTop -= 1;
        }

        var fontBottom = fontTop;
        while (fontBottom >= Graphics.FONT_XTINY && dc.getTextDimensions(line2, fontBottom)[0] / 2 > maxHalfWidth) {
            fontBottom -= 1;
        }

        mForecastFontTop = fontTop;
        mForecastFontBottom = fontBottom;

        mLastForecastLine1 = line1;
        mLastForecastLine2 = line2;
        mLastForecastWidth = maxHalfWidth;
    }

    function refreshPressureTrendAndCurrent() as Void {
        var samples = new Array<SensorHistory.SensorSample>[0];
        var pressureIter = getPressureIterator();
        var oldest = null;

        if (pressureIter != null) {
            var firstSample = pressureIter.next();
            if (firstSample != null) {
                samples.add(firstSample as SensorHistory.SensorSample);

                var now = Time.now();
                var start = now.add(new Time.Duration(-mTime.toNumber()));
                oldest = pressureIter.getOldestSampleTime();
                if (oldest == null || (start as Time.Moment).greaterThan(oldest as Time.Moment)) {
                    oldest = start;
                }

                var i = 0;
                var minus5Mins = new Time.Duration(-MINS_5);

                while (i < samples.size() && samples[i].when.greaterThan(oldest)) {
                    var sampleNextTime = samples[i].when.add(minus5Mins);
                    var nextSample = pressureIter.next();
                    if (nextSample == null) {
                        break;
                    }

                    samples.add(nextSample as SensorHistory.SensorSample);
                    i = samples.size() - 1;

                    while (samples[i].when.greaterThan(sampleNextTime) && samples[i].when.greaterThan(oldest)) {
                        var skipSample = pressureIter.next();
                        if (skipSample == null) {
                            break;
                        }
                        samples[i] = skipSample as SensorHistory.SensorSample;
                    }
                }
            }
        }

        var final = samples.size() - 1;
        var p1 = 0.0;
        var p2 = 0.0;
        var cnt = 0;

        if (final > 4) {
            for (var j = 0; j < 3; j++) {
                var s1 = (samples[j] as SensorHistory.SensorSample).data;
                var s2 = (samples[final - j] as SensorHistory.SensorSample).data;
                if (s1 != null && s2 != null) {
                    p1 += (s1 as Float);
                    p2 += (s2 as Float);
                    cnt += 1;
                }
            }
        } else if (final >= 0) {
            for (var k = 0; k <= final; k++) {
                if ((samples[k] as SensorHistory.SensorSample).data != null) {
                    p1 = (samples[k] as SensorHistory.SensorSample).data;
                    break;
                }
            }

            for (var l = final; l >= 0; l--) {
                if ((samples[l] as SensorHistory.SensorSample).data != null) {
                    p2 = (samples[l] as SensorHistory.SensorSample).data;
                    break;
                }
            }

            cnt = 1;
        }

        var pressureDiff = 0.0;
        if (cnt > 0) {
            pressureDiff = (p1 - p2) / cnt;
            if (pressureDiff < 0 && pressureDiff > -0.05) {
                pressureDiff = 0.0;
            }
        }

        trend = 0;
        if (pressureDiff > mSteadyLimit) {
            trend = 1;
        } else if ((pressureDiff + mSteadyLimit) < 0) {
            trend = 2;
        }

        var current = 0.0;
        var activityInfo = Activity.getActivityInfo();

        if (mUseMSLPressure) {
            if (mUseOriginal) {
                if (activityInfo != null && activityInfo has :meanSeaLevelPressure && activityInfo.meanSeaLevelPressure != null) {
                    current = activityInfo.meanSeaLevelPressure;
                }
            } else if (final >= 0) {
                for (var n = 0; n <= final; n++) {
                    if ((samples[n] as SensorHistory.SensorSample).data != null) {
                        current = (samples[n] as SensorHistory.SensorSample).data;
                        break;
                    }
                }
            }
        } else if (activityInfo != null && activityInfo has :ambientPressure && activityInfo.ambientPressure != null) {
            current = activityInfo.ambientPressure;
        }

        currentPress = mOffset + Math.round((current as Float) / 100.0).toNumber();
    }

    function refreshForecast(month as Number) as Void {
        var nowMs = System.getTimer();
        if (mLastPressureRefreshMs < 0 || (nowMs - mLastPressureRefreshMs) >= PRESSURE_REFRESH_INTERVAL_MS) {
            refreshPressureTrendAndCurrent();
            mLastPressureRefreshMs = nowMs;
        }

        mTemperatureText = getTemperature();

        var summer = (mNorthSouth == 1)
                                        ? (month >= 5 && month <= 9)
                                        : (month >= 11 || month <= 3);

        mLastForecast = Zambretti.WeatherForecast(currentPress, month, mDir, trend, mNorthSouth, mHighPressure, mLowPressure);

        var forecast = mLastForecast as Array;
        if (forecast[0] == Rez.Strings.SH as String && currentPress > 1018) {
            forecast[0] = Rez.Strings.FF as String;
            forecast[1] = "High pressure, stable trend — promoted to Fine";
            mLastForecast = forecast;
        } else if (forecast[0] == Rez.Strings.SH as String && summer && currentPress > 1015 && trend == 0) {
            forecast[0] = Rez.Strings.FW as String;
            forecast[1] = "Summer & stable pressure — adjusted to Fair";
            mLastForecast = forecast;
        }

        mLastDir = mDir;
        mLastHemisphere = mNorthSouth;
        persistForecastValues(((forecast as Array)[0] == null) ? "" : (forecast as Array)[0].toString(), (forecast as Array)[2]);

        // Force one-time font re-fit when forecast text changes
        mLastForecastLine1 = "";
        mLastForecastLine2 = "";
        mLastForecastWidth = -1;
    }
    
    function onAccel(sensorData as Sensor.SensorData) as Void {
        var x = sensorData.accelerometerData.x[0] / 1000.0;
        var y = sensorData.accelerometerData.y[0] / 1000.0;
        var z = sensorData.accelerometerData.z[0] / 1000.0;

        var accelMagnitude = Math.sqrt(x * x + y * y + z * z);
        var delta = accelMagnitude - 1.0;
        if (delta < 0) { delta = -delta; }

        if (delta > SHAKE_THRESHOLD) {
            if (System.getTimer() - lastShakeTime > SHAKE_TIMEOUT) {
                lastShakeTime = System.getTimer();
                shakeDetected = true;
                mDir = 0;
                mPendingDir = 0;
                mPendingDirSamples = 0;
                persistWindDirection(mDir);
                mForceNextUpdate = true;
            }
        }
    }

    function onPosition(positionInfo as Position.Info) as Void {
        if (positionInfo != null && positionInfo.position != null) {
            mNorthSouth = positionInfo.position.toDegrees()[0] >= 0 ? 1 : 0;
        } else {
            mNorthSouth = mDefHemi;
        }

        persistHemisphere(mNorthSouth);

        mAcquiringGPS = false;
        mForceNextUpdate = true;
    }

    function onLayout(dc as Dc) as Void {
        mScreenLayout = getLayout(dc.getHeight());
        var layouts = mScreenLayout as Array<Numeric>;

        if (satelliteBitmap == null) {
            satelliteBitmap = WatchUi.loadResource(Rez.Drawables.Satellite);
        }
        xSatelliteBitmap = (dc.getWidth() - satelliteBitmap.getWidth()) / 2;
        ySatelliteBitmap = (dc.getHeight() - satelliteBitmap.getHeight()) / 2 + layouts[6];

        if (PrecipitationRain == null) {
            PrecipitationRain = WatchUi.loadResource(Rez.Drawables.PrecipitationRain);
        }
        if (PrecipitationSnow == null) {
            PrecipitationSnow = WatchUi.loadResource(Rez.Drawables.PrecipitationSnow);
        }
        xPrecipitationBitmap = (dc.getWidth() - PrecipitationRain.getWidth()) / 2 + layouts[7];
        yPrecipitationBitmap = (dc.getHeight() - PrecipitationRain.getHeight()) / 2 + layouts[8];

        if (arrowBitmap == null) {
            arrowBitmap = WatchUi.loadResource(Rez.Drawables.CompassArrow);
        }

        // Trigger one-time font recalculation after layout changes.
        mLastForecastWidth = -1;
    }

    function onUpdate(dc as Dc) as Void {
        // Clear screen and prepare drawing
        dc.setColor(Graphics.COLOR_WHITE, Graphics.COLOR_BLACK);
        dc.clear();
        dc.setColor(Graphics.COLOR_WHITE, Graphics.COLOR_TRANSPARENT);

        refreshCalendarMonth(false);
        var month = mCachedMonth;
        var mCentre = dc.getWidth() / 2;
        var layouts = mScreenLayout;
        if (layouts == null) {
            layouts = getLayout(dc.getHeight());
            mScreenLayout = layouts;
        }

        // --- Compass + Heading ---
        var sensorInfo = Sensor.getInfo();
        var rawHeading = (sensorInfo != null && sensorInfo has :heading && sensorInfo.heading != null) ? Math.toDegrees(sensorInfo.heading).toFloat() : mLastHeading;
        var smoothedHeading = smoothHeading(rawHeading);
        var now = System.getTimer();
        
        // Reset calm state if timeout passed and revert to regular compass direction logic
        if (shakeDetected && (now - lastShakeTime > SHAKE_TIMEOUT + 5000)) {
            shakeDetected = false;
            mPendingDir = 0;
            mPendingDirSamples = 0;
        }

        if (!shakeDetected) {
            updateDirectionWithHysteresis(smoothedHeading);
        }

        drawCompass(dc, smoothedHeading);

        dc.drawText(mCentre, layouts[0], Graphics.FONT_TINY, pString(mDir), Graphics.TEXT_JUSTIFY_CENTER);

        // --- Forecast Update (only if inputs change) ---
        if (mLastDir != mDir || mLastHemisphere != mNorthSouth || mLastForecast == null) {
            refreshForecast(month);
        }

        // --- Pressure, Temperature and Trend Display ---
        if (mShowDetails) {
            var trendText = tString(trend);
            dc.drawText(mCentre, layouts[1], Graphics.FONT_SYSTEM_XTINY, mTemperatureText + " | " + currentPress.toString() + " hPa | " + trendText, Graphics.TEXT_JUSTIFY_CENTER);
        }

        var forecast = (mLastForecast != null) ? (mLastForecast as Array) : ["", "", "0", "0"];
        var forecastLine1 = (forecast[0] == null) ? "" : forecast[0].toString();
        var forecastLine2 = (forecast[1] == null) ? "" : forecast[1].toString();
        var precipChance = (forecast[3] == null) ? "0" : forecast[3].toString();

        // Forecast Drawing with Adaptive Font
        var sw2 = mCentre - layouts[5];
        updateForecastFonts(dc, forecastLine1, forecastLine2, sw2);
        dc.drawText(mCentre, layouts[2], mForecastFontTop, forecastLine1, Graphics.TEXT_JUSTIFY_CENTER);
        dc.drawText(mCentre, layouts[3], mForecastFontBottom, forecastLine2, Graphics.TEXT_JUSTIFY_CENTER);
        dc.drawText(mCentre - 15, layouts[4], mForecastFontBottom, precipChance + "%", Graphics.TEXT_JUSTIFY_CENTER);
        
        var winter = (mNorthSouth == 1)
                                        ? (month == 12 || month <= 2)   // Northern hemisphere: Dec–Feb
                                        : (month >= 5 && month <= 9);   // Southern hemisphere: May–Sep

        var precipitationBitmap = winter ? PrecipitationSnow : PrecipitationRain;
        dc.drawBitmap(xPrecipitationBitmap, yPrecipitationBitmap, precipitationBitmap);

        // Satellite Blinking Icon
        if (mAcquiringGPS && showImage) {
            dc.drawBitmap(xSatelliteBitmap, ySatelliteBitmap, satelliteBitmap);
        }
    }

    function onHide() as Void {
        if (timer != null) {
            timer.stop();
            timer = null;
        }

        if (Sensor has :unregisterSensorDataListener) {
            Sensor.unregisterSensorDataListener();
        } else {
            Sensor.enableSensorEvents(null);
        }

        Position.enableLocationEvents(Position.LOCATION_DISABLE, null);
    }

    function onShow() as Void {
        timer = new Timer.Timer();
        timer.start(method(:onTimer), 100, true);

        refreshCalendarMonth(true);

        var storedDir = Storage.getValue("windIndex");
        if (storedDir != null && storedDir has :toNumber) {
            mDir = storedDir.toNumber();
            mStoredWindIndex = mDir;
        }

        var hasStoredHemisphere = false;
        var storedHemisphere = Storage.getValue("hemisphere");
        if (storedHemisphere != null && storedHemisphere has :toNumber) {
            var hemi = storedHemisphere.toNumber();
            if (hemi == 0 || hemi == 1) {
                mNorthSouth = hemi;
                mStoredHemisphere = hemi;
                hasStoredHemisphere = true;
            }
        }
        if (!hasStoredHemisphere) {
            mNorthSouth = mDefHemi;
        }

        mPendingDir = 0;
        mPendingDirSamples = 0;
        mLastDir = null;
        mLastHemisphere = null;
        mLastForecast = null;
        mLastPressureRefreshMs = -1;
        mHasRequestedHeading = false;
        mForceNextUpdate = true;
        mLastIdleRedrawMs = 0;

        var optionsACCEL = {
            :period => 1,         // 1 second sample time
            :accelerometer => {
                :enabled => true, // Enable the accelerometer
                :sampleRate => 25 // 25 samples
            }
        };

        Sensor.registerSensorDataListener(method(:onAccel), optionsACCEL);

        if (!mHasFetchedGPSThisRun) {
            var optionsGPS = {
                :acquisitionType => Position.LOCATION_ONE_SHOT // only one fix needed
            };

            if (Position has :hasConfigurationSupport) {
                if ((Position has :CONFIGURATION_SAT_IQ) && (Position.hasConfigurationSupport(Position.CONFIGURATION_SAT_IQ))) {
                    optionsGPS[:configuration] = Position.CONFIGURATION_SAT_IQ;
                } else if ((Position has :CONFIGURATION_GPS_GLONASS_GALILEO_BEIDOU_L1_L5) && (Position.hasConfigurationSupport(Position.CONFIGURATION_GPS_GLONASS_GALILEO_BEIDOU_L1_L5))) {
                    optionsGPS[:configuration] = Position.CONFIGURATION_GPS_GLONASS_GALILEO_BEIDOU_L1_L5;
                } else if ((Position has :CONFIGURATION_GPS_GLONASS_GALILEO_BEIDOU_L1) && (Position.hasConfigurationSupport(Position.CONFIGURATION_GPS_GLONASS_GALILEO_BEIDOU_L1))) {
                    optionsGPS[:configuration] = Position.CONFIGURATION_GPS_GLONASS_GALILEO_BEIDOU_L1;
                } else if ((Position has :CONFIGURATION_GPS_GLONASS) && (Position.hasConfigurationSupport(Position.CONFIGURATION_GPS_GLONASS))) {
                    optionsGPS[:configuration] = Position.CONFIGURATION_GPS_GLONASS;
                }
            } else {
                optionsGPS[:configuration] = Position.LOCATION_ONE_SHOT;
            }

            try {
                Position.enableLocationEvents(optionsGPS, method(:onPosition));
            } catch (ex) {
                Position.enableLocationEvents(Position.LOCATION_ONE_SHOT, method(:onPosition));
            }

            positioning_blink = 0;
            showImage = true;
            mAcquiringGPS = true;
            mHasFetchedGPSThisRun = true;
        } else {
            mAcquiringGPS = false;
        }
    }

    function onTimer() as Void {
        var blinkChanged = false;
        positioning_blink += 1;

        if (positioning_blink == 5) {
            positioning_blink = 0;
            showImage = !showImage;
            blinkChanged = true;
        }

        refreshCalendarMonth(false);

        var nowMs = System.getTimer();
        var shouldUpdate = mForceNextUpdate;

        if (!shakeDetected) {
            var sensorInfo = Sensor.getInfo();
            if (sensorInfo != null && sensorInfo has :heading && sensorInfo.heading != null) {
                var heading = Math.toDegrees(sensorInfo.heading).toFloat();
                if (!mHasRequestedHeading) {
                    mHasRequestedHeading = true;
                    mLastRequestedHeading = heading;
                    shouldUpdate = true;
                } else if (headingDeltaAbs(heading, mLastRequestedHeading) >= HEADING_REDRAW_THRESHOLD) {
                    mLastRequestedHeading = heading;
                    shouldUpdate = true;
                }
            }
        }

        if (blinkChanged && mAcquiringGPS) {
            shouldUpdate = true;
        }

        if (!shouldUpdate && (mLastIdleRedrawMs == 0 || (nowMs - mLastIdleRedrawMs) >= IDLE_REDRAW_INTERVAL_MS)) {
            shouldUpdate = true;
        }

        if (shouldUpdate) {
            mForceNextUpdate = false;
            mLastIdleRedrawMs = nowMs;
            WatchUi.requestUpdate();
        }
    }

// 42mm
(:round_240)
    function getLayout(height as Number) as Array<Numeric> {
        return [47, 70, 90, 125, 160, 12, 90, 40, 60];
    }

// 47mm solar
(:round_260)
    function getLayout(height as Number) as Array<Numeric> {
        return [47, 71, 95, 130, 170, 12, 92, 37, 60];
    }

// 51mm solar
(:round_280)
    function getLayout(height as Number) as Array<Numeric> {
        return [47, 71, 95, 130, 175, 12, 95, 40, 56];
    }

// 43mm AMOLED
(:round_416)
    function getLayout(height as Number) as Array<Numeric> {
        return [47, 90, 125, 190, 260, 20, 140, 65, 85];
    }

// 47/51mm AMOLED
(:round_454)
    function getLayout(height as Number) as Array<Numeric> {
        return [47, 110, 145, 210, 285, 20, 150, 75, 95];
    }

    function getPressureIterator() as SensorHistory.SensorHistoryIterator or Null {
        // Check device for SensorHistory compatibility
        if ((Toybox has :SensorHistory) && (Toybox.SensorHistory has :getPressureHistory)) {
            return SensorHistory.getPressureHistory({:order => SensorHistory.ORDER_NEWEST_FIRST});
        }

        return null;
    }

    function getTemperatureIterator() as SensorHistory.SensorHistoryIterator or Null {
        // Check device for SensorHistory compatibility
        if ((Toybox has :SensorHistory) && (Toybox.SensorHistory has :getTemperatureHistory)) {
            return SensorHistory.getTemperatureHistory({:order => SensorHistory.ORDER_NEWEST_FIRST});
        }

        return null;
    }

    function getTemperature() as String {
        var ret = "";
        var temperature = null;
        var bias = 0.0;

        var sensorInfo = Sensor.getInfo();
        var activity = Activity.getActivityInfo();
        var temperatureIter = getTemperatureIterator();

        if (temperatureIter != null) {
            var histTemp = temperatureIter.next();
            if (histTemp != null && histTemp.data != null) {
                temperature = histTemp.data;
            }
        }

        var worn = sensorInfo != null && sensorInfo has :onBody && sensorInfo.onBody != null ? sensorInfo.onBody : true;

        if (temperature != null && worn) {
            // If temperature is already high, assume it's ambient
            if (temperature > 30.0) {
                bias = 0.0;
            } else if (activity != null && activity has :activeTime) {
                var act = activity.activeTime;
                if (act < 10) { bias = 6.0; }
                else if (act < 60) { bias = 7.0; }
                else if (act < 300) { bias = 8.0; }
                else { bias = 9.0; }
            } else {
                bias = 7.0;
            }
        }

        // Elevation correction (mild)
        var elev = (activity != null && activity has :elevation && activity.elevation != null) ? activity.elevation.toFloat() : 300.0;
        bias += elev / 2000.0;

        // Seasonal correction
        var summer = (mCachedMonth >= 5 && mCachedMonth <= 9);
        if (summer && temperature != null && temperature > 30.0) {
            bias += 0.8;
        } else if (!summer && temperature != null && temperature < 26.0) {
            bias -= 0.5;
        }

        // Trend correction
        if (trend == 1) { bias -= 0.5; }
        else if (trend == 2) { bias += 0.5; }

        // Final calculation
        if (temperature != null) {
            temperature = (temperature - bias).toNumber();
            var units = "°C";
            if (mNotMetricTemp) {
                temperature = (temperature * 9.0 / 5.0) + 32;
                units = "°F";
            }
            ret = temperature.format("%.0f") + units;
        }

        return ret;
    }

    function myMod(a as Numeric, b as Numeric) as Numeric {
        var d = (b < 0) ? -b : b;
        var m = (a - ((a / d).toLong() * d));
        var r = ((m < 0) ? (d + m) : m);
        
        return ((b < 0) ? (r + b) : r);
    }

    function drawCompass(dc as Dc, heading as Float) as Void {
        var w = dc.getWidth();
        var h = dc.getHeight();
        var centerX = w / 2;
        var centerY = h / 2;
        var layouts = mScreenLayout;
        if (layouts == null) {
            layouts = getLayout(h);
        }
        var radius = ((w < h) ? centerX : centerY) - layouts[5];

        var font = Graphics.FONT_SYSTEM_XTINY;
        var textHeight = dc.getFontHeight(font);

        // Tick radii
        var tickOuter = radius - textHeight + 5;
        var tickInnerMajor = tickOuter - 8;
        var tickInnerMinor = tickOuter - 4;
        var headingRad = Math.toRadians(heading);
        var sinH = Math.sin(headingRad);
        var cosH = Math.cos(headingRad);

        var tickSin = mTickSin as Array<Float>;
        var tickCos = mTickCos as Array<Float>;
        var labelSin = mLabelSin as Array<Float>;
        var labelCos = mLabelCos as Array<Float>;

        // Draw 16 tick marks
        for (var i = 0; i < 16; i++) {
            var isMajor = (i % 4 == 0);
            var innerR = isMajor ? tickInnerMajor : tickInnerMinor;

            var baseTickSin = tickSin[i];
            var baseTickCos = tickCos[i];
            var sinA = (baseTickSin * cosH) - (baseTickCos * sinH);
            var cosA = (baseTickCos * cosH) + (baseTickSin * sinH);

            var x1 = centerX + innerR * sinA;
            var y1 = centerY - innerR * cosA;
            var x2 = centerX + tickOuter * sinA;
            var y2 = centerY - tickOuter * cosA;

            dc.setPenWidth(isMajor ? 2 : 1);
            dc.setColor(isMajor ? Graphics.COLOR_WHITE : 0x888888, Graphics.COLOR_TRANSPARENT);
            dc.drawLine(x1, y1, x2, y2);
        }

        // Draw 8 cardinal labels
        for (var j = 0; j < mCompassLabels.size(); j++) {
            var baseLabelSin = labelSin[j];
            var baseLabelCos = labelCos[j];
            var sinB = (baseLabelSin * cosH) - (baseLabelCos * sinH);
            var cosB = (baseLabelCos * cosH) + (baseLabelSin * sinH);

            var x = centerX + radius * sinB;
            var y = centerY - radius * cosB - (textHeight / 2);

            dc.setColor((j == 0) ? Graphics.COLOR_RED : Graphics.COLOR_WHITE, Graphics.COLOR_TRANSPARENT);
            dc.drawText(x, y, font, mCompassLabels[j], Graphics.TEXT_JUSTIFY_CENTER);
        }

        // Draw static arrow
        dc.drawBitmap(centerX - arrowBitmap.getWidth() / 2, centerY - radius, arrowBitmap);
    }
}

(:glance)
class SimplyWeatherGlanceView extends WatchUi.GlanceView {
    var titleY as Number = 30;
    var valueY as Number = 60;
    var mFallbackTitle as String = "";
    var mTitleCache as String = "";
    var mCachedMonth as Number = 1;
    var mCachedHour as Number = -1;
    var mCachedMinute as Number = -1;

    var mIconClearDay;
    var mIconClearNight;
    var mIconCloudDay;
    var mIconCloudNight;
    var mIconSnowDay;
    var mIconSnowNight;
    var mIconRainDay;
    var mIconRainNight;
    var mIconSnow;
    var mIconRain;
    var mIconSnowStorm;
    var mIconThunderStorm;

    function initialize() {
        GlanceView.initialize();

        mFallbackTitle = WatchUi.loadResource(Rez.Strings.AppName) as String;
        refreshTitle();

        mIconClearDay = WatchUi.loadResource(Rez.Drawables.ClearDay);
        mIconClearNight = WatchUi.loadResource(Rez.Drawables.ClearNight);
        mIconCloudDay = WatchUi.loadResource(Rez.Drawables.CloudDay);
        mIconCloudNight = WatchUi.loadResource(Rez.Drawables.CloudNight);
        mIconSnowDay = WatchUi.loadResource(Rez.Drawables.SnowDay);
        mIconSnowNight = WatchUi.loadResource(Rez.Drawables.SnowNight);
        mIconRainDay = WatchUi.loadResource(Rez.Drawables.RainDay);
        mIconRainNight = WatchUi.loadResource(Rez.Drawables.RainNight);
        mIconSnow = WatchUi.loadResource(Rez.Drawables.Snow);
        mIconRain = WatchUi.loadResource(Rez.Drawables.Rain);
        mIconSnowStorm = WatchUi.loadResource(Rez.Drawables.SnowStorm);
        mIconThunderStorm = WatchUi.loadResource(Rez.Drawables.ThunderStorm);
    }

    function refreshTitle() as Void {
        var AppTitle = Properties.getValue("AppTitle");
        if (AppTitle == null ) {
            mTitleCache = mFallbackTitle;
        } else {
            mTitleCache = AppTitle as String;
        }
    }

    function getTitle() as String {
        if (mTitleCache == "") {
            refreshTitle();
        }

        return mTitleCache;
    }

    function refreshMonthCache(hour as Number, minute as Number) as Void {
        if (hour == mCachedHour && minute == mCachedMinute) {
            return;
        }

        var today = Gregorian.info(Time.now(), Time.FORMAT_SHORT);
        mCachedMonth = today.month;
        mCachedHour = hour;
        mCachedMinute = minute;
    }

    function onLayout(dc as Dc) as Void {
        var dHeight = dc.getHeight();
        var tHeight = dc.getFontHeight(Graphics.FONT_GLANCE);
        var vHeight = dc.getFontHeight(Graphics.FONT_GLANCE);
        
        titleY = (dHeight - tHeight - vHeight) / 2;
        
        if ((tHeight + vHeight) > dHeight) {
            titleY -= 2;
        }
        
        valueY = titleY + tHeight;
    }

    function getWeatherIcon(forecastNumber as Number, isDaytime as Boolean, winter as Boolean) {
        if (forecastNumber <= 1) {
            return isDaytime ? mIconClearDay : mIconClearNight;
        } else if (forecastNumber <= 3) {
            return isDaytime ? mIconCloudDay : mIconCloudNight;
        } else if (forecastNumber <= 13) {
            return winter ? (isDaytime ? mIconSnowDay : mIconSnowNight) : (isDaytime ? mIconRainDay : mIconRainNight);
        } else if (forecastNumber <= 23) {
            return winter ? mIconSnow : mIconRain;
        }

        return winter ? mIconSnowStorm : mIconThunderStorm;
    }

    function onUpdate(dc as Dc) as Void {
        dc.setColor(Graphics.COLOR_BLACK,Graphics.COLOR_BLACK);
        dc.clear();
        dc.setColor(Graphics.COLOR_WHITE,Graphics.COLOR_TRANSPARENT);

        var fc = Storage.getValue("forecast");
        if (fc == null) { fc = ""; }

        dc.setColor(Graphics.COLOR_WHITE,Graphics.COLOR_BLACK);
        dc.drawText(0, valueY, Graphics.FONT_GLANCE, fc, Graphics.TEXT_JUSTIFY_LEFT); // tiny font

        var AppTitle = getTitle();
        var fnt = Graphics.FONT_GLANCE;

        dc.setColor(Graphics.COLOR_WHITE,Graphics.COLOR_BLACK);
        dc.drawText(0, titleY, fnt, AppTitle, Graphics.TEXT_JUSTIFY_LEFT);

        // Weather icons
        var forecastNumber = Storage.getValue("forecastNumber");
        if (forecastNumber == null) { forecastNumber = 0; }
        var clockTime = System.getClockTime();
        var hour = clockTime.hour;
        refreshMonthCache(hour, clockTime.min);
        var isDaytime = (hour >= 7 && hour < 19);

        var hemisphere = Storage.getValue("hemisphere");
        if (!(hemisphere instanceof Number)) { hemisphere = 1; } // fallback to northern

        var winter = (hemisphere == 1)
                                        ? (mCachedMonth == 12 || mCachedMonth <= 2)   // Northern hemisphere: Dec–Feb
                                        : (mCachedMonth >= 5 && mCachedMonth <= 9);   // Southern hemisphere: May–Sep

        var weatherIcon = getWeatherIcon(forecastNumber, isDaytime, winter);

        var xWeatherIcon = dc.getWidth() - weatherIcon.getWidth() - 20;
        var yWeatherIcon = valueY - 25;

        dc.drawBitmap(xWeatherIcon, yWeatherIcon, weatherIcon);
    }

}
