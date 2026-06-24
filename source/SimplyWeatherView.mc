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

import Sager;

const cTime = 0.0 - ((Gregorian.SECONDS_PER_HOUR * 6) + (Gregorian.SECONDS_PER_MINUTE * 10));
const cSteady = 35.0; // Pa/h dead-zone (0.35 hPa/h) — tighter for barometer-only forecast
const cShowDetails = true;
const MINS_5 = (Gregorian.SECONDS_PER_MINUTE * 5);
const DIR_CONFIRM_SAMPLES = 4;
// Compass heading playback: Sensor.getInfo().heading only refreshes at ~1 Hz, so
// the needle is animated by linearly interpolating between the last two samples on
// a clock delayed by HEADING_LAG_MS. This reproduces the native "smooth but follows
// a bit later" feel — constant-velocity glide (no stutter), tracks true wrist speed
// (no molasses). LAG must be >= the sensor sample interval so the playhead stays
// within the [prev, curr] segment during continuous motion.
const HEADING_LAG_MS = 700.0;
const HEADING_NEW_SAMPLE_EPS = 0.5; // deg; rejects rest jitter and ignores no-op reads
const HEADING_MAX_GAP_MS = 4000.0;  // deg; stale/huge gap -> snap instead of interpolate
// Output low-pass applied to the interpolated value. The delay line already emits a
// continuously-moving 30 Hz signal, so this rounds the per-sample velocity kinks and
// damps sensor jitter WITHOUT freezing (input moves every frame). alpha per 33 ms
// tick: ~0.30 -> tau ~= 90 ms of extra, glassy lag. Raise toward 1.0 to disable.
const HEADING_OUT_ALPHA = 0.45;
const HEADING_REDRAW_THRESHOLD = 0.50;
const IDLE_REDRAW_INTERVAL_MS = 1000;
const CALENDAR_REFRESH_INTERVAL_MS = 60000;
const PRESSURE_REFRESH_INTERVAL_MS = 15000;

class SimplyWeatherView extends WatchUi.View {
    var mTime as Float = cTime;
    var mSteadyLimit as Float = cSteady;
    var mNorthSouth as Number = 1; // Northern hemisphere
    var mDefHemi as Number = 1; // Default hemisphere is Northern
    var mShowDetails as Boolean = true;
    var mNotMetricTemp as Boolean = false;

    var mDir as Number = 0;
    var mAcquiringGPS as Boolean = true;

    var mWindCalm as Boolean = false;
    var SHAKE_THRESHOLD = 1.0;
    var SHAKE_TIMEOUT = 3000; // debounce between shakes
    var lastShakeTime = 0;

    var mLastHeading as Float = 0.0;
    var mHasHeading as Boolean = false;
    // Two most recent raw heading keyframes (+ their System.getTimer() timestamps)
    // for the interpolating delay line. mLastHeading holds the smoothed output that
    // is rendered; mDispHeading is the low-pass accumulator (same value).
    var mPrevHeading as Float = 0.0;
    var mCurrHeading as Float = 0.0;
    var mPrevKeyMs as Number = 0;
    var mCurrKeyMs as Number = 0;
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
    var mSteadyHours = 0;
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
    var mLastTemperatureRefreshMs as Number = -1;
    var mForceNextUpdate as Boolean = true;
    var mLastDrawnHeading as Float = 0.0;
    var mHasDrawnHeading as Boolean = false;
    var mLastIdleRedrawMs as Number = 0;

    var mCompassTextHeight as Number = -1;

    var mLastForecast = null;
    var mLastDir = null;
    var mLastHemisphere = null;
    var mLastForecastLine as String = "";
    var mLastForecastWidth as Number = -1;
    var mForecastFont = Graphics.FONT_LARGE;

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
            temp = Properties.getValue("Steady");
        }
        catch (ex) {
            temp = null;
        }
        mSteadyLimit = (temp == null) ? cSteady : (temp as Numeric).toFloat() * 100.0;
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

        // Default is 1 North, 0 South
        try {
            temp = Properties.getValue("DefaultHemisphere");
        }
        catch (ex) {
            temp = 1;
        }
        temp = ((temp instanceof Number) ? temp : 1);
        mDefHemi = temp>0 ? 1 : 0;
        mNorthSouth = mDefHemi;

        // Recompute forecast on next update when settings change.
        mLastDir = null;
        mLastHemisphere = null;
        mLastForecast = null;
        mLastPressureRefreshMs = -1;
        mLastTemperatureRefreshMs = -1;
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

    function wrapDelta(delta as Float) as Float {
        if (delta > 180.0) {
            delta -= 360.0;
        } else if (delta < -180.0) {
            delta += 360.0;
        }
        return delta;
    }

    // Record a new raw heading sample as the latest keyframe. Repeated identical
    // reads (the same 1 Hz sample seen by the 30 Hz timer) and sub-EPS jitter are
    // ignored so the interpolation segment isn't restarted spuriously.
    function pushRawHeading(raw as Float, nowMs as Number) as Void {
        if (!mHasHeading) {
            mLastHeading = raw;
            mPrevHeading = raw;
            mCurrHeading = raw;
            mPrevKeyMs = nowMs;
            mCurrKeyMs = nowMs;
            mHasHeading = true;
            return;
        }

        var d = wrapDelta(raw - mCurrHeading);
        if (d < 0.0) { d = -d; }
        if (d < HEADING_NEW_SAMPLE_EPS) {
            return;
        }

        mPrevHeading = mCurrHeading;
        mPrevKeyMs = mCurrKeyMs;
        mCurrHeading = raw;
        mCurrKeyMs = nowMs;
    }

    // Interpolate the displayed heading from a clock delayed by HEADING_LAG_MS,
    // sliding linearly across the last keyframe segment, then apply an output
    // low-pass. Linear interp removes the 1 Hz staircase; the low-pass rounds the
    // per-sample velocity kinks and damps jitter for a glassy, native-like glide.
    function advanceHeading(nowMs as Number) as Float {
        if (!mHasHeading) {
            return mLastHeading;
        }

        var target;
        var snap = false;
        var span = (mCurrKeyMs - mPrevKeyMs).toFloat();
        if (span <= 0.0 || span > HEADING_MAX_GAP_MS) {
            target = mCurrHeading;
            snap = true;
        } else {
            var playMs = nowMs.toFloat() - HEADING_LAG_MS;
            var t = (playMs - mPrevKeyMs.toFloat()) / span;
            if (t <= 0.0) {
                target = mPrevHeading;
            } else if (t >= 1.0) {
                target = mCurrHeading;
            } else {
                var seg = wrapDelta(mCurrHeading - mPrevHeading);
                target = myMod(mPrevHeading + seg * t, 360.0).toFloat();
            }
        }

        if (snap) {
            mLastHeading = target;
        } else {
            mLastHeading = myMod(mLastHeading + wrapDelta(target - mLastHeading) * HEADING_OUT_ALPHA, 360.0).toFloat();
        }
        return mLastHeading;
    }

    function headingDeltaAbs(a as Float, b as Float) as Float {
        var delta = wrapDelta(a - b);
        if (delta < 0.0) { delta = -delta; }
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

    function updateForecastFonts(dc as Dc, line as String, maxHalfWidth as Number) as Void {
        if (line == mLastForecastLine && maxHalfWidth == mLastForecastWidth) {
            return;
        }

        var font = Graphics.FONT_LARGE;
        while (font >= Graphics.FONT_XTINY && dc.getTextDimensions(line, font)[0] / 2 > maxHalfWidth) {
            font -= 1;
        }

        mForecastFont = font;

        mLastForecastLine = line;
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
                var start = now.add(new Time.Duration(mTime.toNumber()));
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

        // Track pressure range + quadratic regression (single-pass)
        var pressureMax = null;
        var pressureMin = null;
        var regN = 0;
        var regRef = 0.0;
        var regSx = 0.0;
        var regSx2 = 0.0;
        var regSx3 = 0.0;
        var regSx4 = 0.0;
        var regSy = 0.0;
        var regSxy = 0.0;
        var regSx2y = 0.0;
        var t0 = (final >= 0) ? (samples[0] as SensorHistory.SensorSample).when.value() : 0;
        for (var m = 0; m <= final; m++) {
            var sd = (samples[m] as SensorHistory.SensorSample).data;
            if (sd != null) {
                if (pressureMax == null || (sd as Float) > (pressureMax as Float)) {
                    pressureMax = sd;
                }
                if (pressureMin == null || (sd as Float) < (pressureMin as Float)) {
                    pressureMin = sd;
                }
                var ageH = (t0 - (samples[m] as SensorHistory.SensorSample).when.value()) / 3600.0;
                if (regN == 0) { regRef = sd as Float; }
                var yNorm = (sd as Float) - regRef;
                var xSq = ageH * ageH;
                regN += 1;
                regSx += ageH;
                regSx2 += xSq;
                regSx3 += xSq * ageH;
                regSx4 += xSq * xSq;
                regSy += yNorm;
                regSxy += ageH * yNorm;
                regSx2y += xSq * yNorm;
            }
        }

        // --- Trend calculation (quadratic regression) ---
        var windowHours = (-mTime) / Gregorian.SECONDS_PER_HOUR.toFloat();
        if (windowHours < 0.5) { windowHours = 0.5; }

        var pressureDiff = 0.0;
        var quadA = 0.0;
        var quadB = 0.0;

        if (regN > 5) {
            var nf = regN.toFloat();
            var xMean = regSx / nf;

            var cx2 = regSx2 - regSx * regSx / nf;
            var cx4 = regSx4 - 4.0 * xMean * regSx3 + 6.0 * xMean * xMean * regSx2 - 3.0 * nf * xMean * xMean * xMean * xMean;
            var cxy = regSxy - regSx * regSy / nf;
            var cx2y = regSx2y - 2.0 * xMean * regSxy + xMean * xMean * regSy;

            if (cx2 > 0.001) {
                quadB = cxy / cx2;
            }
            var denomQ = nf * cx4 - cx2 * cx2;
            if (denomQ > 0.001 || denomQ < -0.001) {
                quadA = (nf * cx2y - regSy * cx2) / denomQ;
            }

            pressureDiff = windowHours * (quadA * (2.0 * xMean - windowHours) - quadB);
        } else if (final >= 0) {
            var pNewest = null;
            var pOldest = null;
            for (var k = 0; k <= final; k++) {
                if ((samples[k] as SensorHistory.SensorSample).data != null) {
                    pNewest = (samples[k] as SensorHistory.SensorSample).data;
                    break;
                }
            }
            for (var l = final; l >= 0; l--) {
                if ((samples[l] as SensorHistory.SensorSample).data != null) {
                    pOldest = (samples[l] as SensorHistory.SensorSample).data;
                    break;
                }
            }
            if (pNewest != null && pOldest != null) {
                pressureDiff = (pNewest as Float) - (pOldest as Float);
            }
        }

        // --- Diurnal tide correction ---
        var timeInfo = Gregorian.info(Time.now(), Time.FORMAT_SHORT);
        var hourNow = timeInfo.hour.toFloat() + timeInfo.min.toFloat() / 60.0;
        var hourStart = hourNow + (mTime / Gregorian.SECONDS_PER_HOUR.toFloat());
        var phase = 2.0 * Math.PI / 12.0;
        var tideAmp = getDiurnalAmplitude();
        var diurnalCorr = tideAmp * (Math.cos(phase * (hourNow - 9.5)) - Math.cos(phase * (hourStart - 9.5)));
        pressureDiff = pressureDiff - diurnalCorr;

        var scaledLimit = mSteadyLimit * windowHours;

        trend = 0;
        if (pressureDiff > scaledLimit) {
            trend = 1;
        } else if ((pressureDiff + scaledLimit) < 0) {
            trend = 2;
        }

        // --- 3h front detection (from quadratic fit) ---
        if (trend == 0 && regN > 5) {
            var xMean = regSx / regN.toFloat();
            var shortDiff = 3.0 * (quadA * (2.0 * xMean - 3.0) - quadB);
            var hourMid = hourNow - 3.0;
            var shortDiurnal = tideAmp * (Math.cos(phase * (hourNow - 9.5)) - Math.cos(phase * (hourMid - 9.5)));
            shortDiff = shortDiff - shortDiurnal;
            var shortLimit = mSteadyLimit * 3.0;
            if (shortDiff > shortLimit) {
                trend = 1;
            } else if (shortDiff < -shortLimit) {
                trend = 2;
            }
        }

        // --- Acceleration from quadratic fit ---
        var accelHpa = 2.0 * quadA / 100.0;
        if (accelHpa > -0.3 && accelHpa < 0.3) { accelHpa = 0.0; }

        if (trend == 0 && accelHpa <= -0.4) {
            trend = 2;
        } else if (trend == 2 && accelHpa > 0.5) {
            trend = 0;
        }

        // --- Trend hysteresis: quick to alarm, slow to clear ---
        var prevTrend = Storage.getValue("pT");
        if (prevTrend != null && (prevTrend as Number) != 0 && trend == 0) {
            var absDiff = pressureDiff;
            if (absDiff < 0) { absDiff = -absDiff; }
            if (absDiff > scaledLimit * 0.6) {
                trend = prevTrend as Number;
            }
        }
        Storage.setValue("pT", trend);

        // --- Front passage detection ---
        if (prevTrend != null && (prevTrend as Number) == 2 && trend == 0 && regN > 5) {
            var xMean = regSx / regN.toFloat();
            var slopeNow = quadB - 2.0 * quadA * xMean;
            if (slopeNow < 0) {
                trend = 1;
            }
        }

        // Use MSL pressure from sensor history (altitude-safe for Sager).
        var current = 0.0;
        if (final >= 0) {
            for (var n = 0; n <= final; n++) {
                if ((samples[n] as SensorHistory.SensorSample).data != null) {
                    current = (samples[n] as SensorHistory.SensorSample).data;
                    break;
                }
            }
        }

        currentPress = getSeaLevelPressure(current as Float);

        // --- Persistence tracking (Storage-backed, survives reboots) ---
        // Timestamp-guarded: max 1 increment per hour regardless of call frequency.
        if (pressureMax != null && pressureMin != null) {
            var pressureRange = (pressureMax as Float) - (pressureMin as Float);
            if (pressureRange < 200.0) {
                var stored = Storage.getValue("sH");
                var lastTs = Storage.getValue("sT");
                var nowSec = Time.now().value();
                if (lastTs != null && (nowSec - (lastTs as Number)) < 3600) {
                    // Less than 1h since last increment — just re-read
                    mSteadyHours = (stored != null) ? (stored as Number) : 0;
                } else {
                    // ≥1h elapsed or first run — increment
                    mSteadyHours = (stored != null) ? (stored as Number) + 1 : 1;
                    Storage.setValue("sT", nowSec);
                }
            } else {
                mSteadyHours = 0;
                Storage.setValue("sT", null);
            }
            Storage.setValue("sH", mSteadyHours);
        }
    }

    function refreshForecast(month as Number) as Void {
        var nowMs = System.getTimer();
        if (mLastPressureRefreshMs < 0 || (nowMs - mLastPressureRefreshMs) >= PRESSURE_REFRESH_INTERVAL_MS) {
            refreshPressureTrendAndCurrent();
            mLastPressureRefreshMs = nowMs;
        }

        mLastForecast = Sager.WeatherForecast(currentPress, month, mDir, trend, mNorthSouth, mSteadyHours);

        var forecast = mLastForecast as Array;

        mLastDir = mDir;
        mLastHemisphere = mNorthSouth;
        persistForecastValues(((forecast as Array)[0] == null) ? "" : (forecast as Array)[0].toString(), (forecast as Array)[1]);

        // Force one-time font re-fit when forecast text changes
        mLastForecastLine = "";
        mLastForecastWidth = -1;
    }
    
    function onSensor(sensorInfo as Sensor.Info) as Void {
        // Shake detection from processed accelerometer data
        if (sensorInfo has :accel && sensorInfo.accel != null) {
            var accelData = sensorInfo.accel as Array<Numeric>;
            var x = accelData[0] / 1000.0;
            var y = accelData[1] / 1000.0;
            var z = accelData[2] / 1000.0;

            var accelMagnitude = Math.sqrt(x * x + y * y + z * z);
            var delta = accelMagnitude - 1.0;
            if (delta < 0) { delta = -delta; }

            if (delta > SHAKE_THRESHOLD) {
                if (System.getTimer() - lastShakeTime > SHAKE_TIMEOUT) {
                    lastShakeTime = System.getTimer();
                    mWindCalm = !mWindCalm;
                    Storage.setValue("windCalm", mWindCalm);
                    if (mWindCalm) {
                        mDir = 0;
                        mPendingDir = 0;
                        mPendingDirSamples = 0;
                        persistWindDirection(mDir);
                    }
                    mForceNextUpdate = true;
                }
            }
        }
    }

    function onPosition(positionInfo as Position.Info) as Void {
        if (positionInfo != null && positionInfo.position != null) {
            var lat = positionInfo.position.toDegrees()[0];
            mNorthSouth = lat >= 0 ? 1 : 0;
            // Cache diurnal tide amplitude from latitude: A ≈ 125 * cos²(lat) Pa
            var latRad = (lat as Double).toFloat() * Math.PI / 180.0;
            var cosLat = Math.cos(latRad);
            Storage.setValue("dA", (125.0 * cosLat * cosLat).toNumber());
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

        mCompassTextHeight = dc.getFontHeight(Graphics.FONT_SYSTEM_XTINY);

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
        // The interpolating delay line is advanced in onTimer; render its current
        // output here so the needle keeps gliding between 1 Hz sensor samples.
        var sensorInfo = Sensor.getInfo();
        var smoothedHeading;
        if (mHasHeading) {
            smoothedHeading = advanceHeading(System.getTimer());
        } else if (sensorInfo != null && sensorInfo has :heading && sensorInfo.heading != null) {
            pushRawHeading(Math.toDegrees(sensorInfo.heading).toFloat(), System.getTimer());
            smoothedHeading = mLastHeading;
        } else {
            smoothedHeading = mLastHeading;
        }

        if (!mWindCalm) {
            updateDirectionWithHysteresis(smoothedHeading);
        }

        drawCompass(dc, smoothedHeading);
        mLastDrawnHeading = smoothedHeading;
        mHasDrawnHeading = true;

        dc.drawText(mCentre, layouts[0], Graphics.FONT_TINY, pString(mDir), Graphics.TEXT_JUSTIFY_CENTER);

        // --- Forecast Update (only if inputs change) ---
        if (mLastDir != mDir || mLastHemisphere != mNorthSouth || mLastForecast == null) {
            refreshForecast(month);
        }

        // --- Temperature refresh (decoupled from wind/forecast) ---
        var nowMs = System.getTimer();
        if (mLastTemperatureRefreshMs < 0 || (nowMs - mLastTemperatureRefreshMs) >= PRESSURE_REFRESH_INTERVAL_MS) {
            mTemperatureText = getTemperature(sensorInfo);
            mLastTemperatureRefreshMs = nowMs;
        }

        // --- Pressure, Temperature and Trend Display ---
        if (mShowDetails) {
            var trendText = tString(trend);
            dc.drawText(mCentre, layouts[1], Graphics.FONT_SYSTEM_XTINY, mTemperatureText + " | " + currentPress.toString() + " hPa | " + trendText, Graphics.TEXT_JUSTIFY_CENTER);
        }

        var forecast = (mLastForecast != null) ? (mLastForecast as Array) : ["", 0, 0];
        var forecastLine = (forecast[0] == null) ? "" : forecast[0].toString();
        var precipChance = (forecast[2] == null) ? "0" : forecast[2].toString();

        // Forecast Drawing with Adaptive Font
        var sw2 = mCentre - layouts[5];
        updateForecastFonts(dc, forecastLine, sw2);
        dc.drawText(mCentre, layouts[2], mForecastFont, forecastLine, Graphics.TEXT_JUSTIFY_CENTER);
        dc.drawText(mCentre - 15, layouts[4], mForecastFont, precipChance + "%", Graphics.TEXT_JUSTIFY_CENTER);
        
        var winter = (mNorthSouth == 1)
                                        ? (month == 12 || month <= 2)   // Northern hemisphere: Dec–Feb
                                        : (month >= 6 && month <= 8);   // Southern hemisphere: Jun–Aug

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

        Sensor.enableSensorEvents(null);

        Position.enableLocationEvents(Position.LOCATION_DISABLE, null);
    }

    function onShow() as Void {
        timer = new Timer.Timer();
        timer.start(method(:onTimer), 33, true);

        refreshCalendarMonth(true);

        var storedDir = Storage.getValue("windIndex");
        if (storedDir != null && storedDir has :toNumber) {
            mDir = storedDir.toNumber();
            mStoredWindIndex = mDir;
        }

        var storedCalm = Storage.getValue("windCalm");
        mWindCalm = (storedCalm != null && storedCalm == true);

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
        mLastTemperatureRefreshMs = -1;
        mHasHeading = false;
        mHasDrawnHeading = false;
        mForceNextUpdate = true;
        mLastIdleRedrawMs = 0;

        Sensor.enableSensorEvents(method(:onSensor));

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

        if (positioning_blink == 15) {
            positioning_blink = 0;
            showImage = !showImage;
            blinkChanged = true;
        }

        var nowMs = System.getTimer();
        var shouldUpdate = mForceNextUpdate;

        var sensorInfo = Sensor.getInfo();
        if (sensorInfo != null && sensorInfo has :heading && sensorInfo.heading != null) {
            pushRawHeading(Math.toDegrees(sensorInfo.heading).toFloat(), nowMs);
        }
        if (mHasHeading) {
            var smoothed = advanceHeading(nowMs);
            if (!mHasDrawnHeading || headingDeltaAbs(smoothed, mLastDrawnHeading) >= HEADING_REDRAW_THRESHOLD) {
                shouldUpdate = true;
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

    // Semidiurnal tide amplitude scaled by latitude: A ≈ 125 * cos²(lat) Pa.
    // Computed at GPS fix time (onPosition); read from Storage afterwards.
    hidden function getDiurnalAmplitude() as Float {
        var stored = Storage.getValue("dA");
        return (stored != null) ? (stored as Number).toFloat() : 60.0;
    }

    hidden function getSeaLevelPressure(stationPa as Float) as Number {
        // Try OS-provided MSL pressure (requires prior GPS fix)
        var activityInfo = Activity.getActivityInfo();
        if (activityInfo != null && activityInfo has :meanSeaLevelPressure) {
            var mslPa = activityInfo.meanSeaLevelPressure;
            if (mslPa != null) {
                return Math.round((mslPa as Float) / 100.0).toNumber();
            }
        }

        // Fallback: elevation history + barometric formula
        if ((Toybox has :SensorHistory) && (Toybox.SensorHistory has :getElevationHistory)) {
            var elevIter = SensorHistory.getElevationHistory({:period => 1, :order => SensorHistory.ORDER_NEWEST_FIRST});
            if (elevIter != null) {
                var sample = elevIter.next();
                if (sample != null && sample.data != null) {
                    var altitude = (sample.data as Float);
                    var stationHpa = stationPa / 100.0;
                    var factor = Math.pow(1.0 - (0.0065 * altitude / 288.15), 5.255);
                    return Math.round(stationHpa / factor).toNumber();
                }
            }
        }

        // Final fallback: raw station pressure
        return Math.round(stationPa / 100.0).toNumber();
    }

    function getTemperatureIterator() as SensorHistory.SensorHistoryIterator or Null {
        // Check device for SensorHistory compatibility
        if ((Toybox has :SensorHistory) && (Toybox.SensorHistory has :getTemperatureHistory)) {
            return SensorHistory.getTemperatureHistory({:order => SensorHistory.ORDER_NEWEST_FIRST});
        }

        return null;
    }

    function getTemperature(sensorInfo as Sensor.Info or Null) as String {
        var temperature = null;
        var bias = 0.0;

        var temperatureIter = getTemperatureIterator();

        if (temperatureIter != null) {
            var histTemp = temperatureIter.next();
            if (histTemp != null && histTemp.data != null) {
                temperature = histTemp.data;
            }
        }

        var worn = sensorInfo != null && sensorInfo has :onBody && sensorInfo.onBody != null ? sensorInfo.onBody : true;

        if (temperature != null && worn) {
            // Use heart rate as activity proxy for body-heat bias.
            // Higher HR → more blood flow → warmer skin → larger offset.
            var hr = (sensorInfo != null && sensorInfo has :heartRate && sensorInfo.heartRate != null) ? sensorInfo.heartRate : 0;
            if (hr > 130)      { bias = 9.0; }
            else if (hr > 100) { bias = 7.5; }
            else if (hr > 70)  { bias = 6.0; }
            else if (hr > 0)   { bias = 5.0; }
            else               { bias = 6.0; }
        }

        if (temperature != null) {
            temperature = Math.round(temperature - bias);
            if (mNotMetricTemp) {
                temperature = Math.round(temperature * 9.0 / 5.0 + 32);
            }
            return temperature.format("%.0f") + (mNotMetricTemp ? "°F" : "°C");
        }

        return "";
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
        var textHeight = (mCompassTextHeight >= 0) ? mCompassTextHeight : dc.getFontHeight(font);

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

        // Minor ticks — single state setup, then batch all 12
        dc.setPenWidth(1);
        dc.setColor(0x888888, Graphics.COLOR_TRANSPARENT);
        for (var i = 0; i < 16; i++) {
            if (i % 4 == 0) { continue; }
            var sinA = (tickSin[i] * cosH) - (tickCos[i] * sinH);
            var cosA = (tickCos[i] * cosH) + (tickSin[i] * sinH);
            dc.drawLine(
                centerX + tickInnerMinor * sinA, centerY - tickInnerMinor * cosA,
                centerX + tickOuter * sinA, centerY - tickOuter * cosA
            );
        }
        // Major ticks — single state setup, then batch all 4
        dc.setPenWidth(2);
        dc.setColor(Graphics.COLOR_WHITE, Graphics.COLOR_TRANSPARENT);
        for (var i = 0; i < 16; i += 4) {
            var sinA = (tickSin[i] * cosH) - (tickCos[i] * sinH);
            var cosA = (tickCos[i] * cosH) + (tickSin[i] * sinH);
            dc.drawLine(
                centerX + tickInnerMajor * sinA, centerY - tickInnerMajor * cosA,
                centerX + tickOuter * sinA, centerY - tickOuter * cosA
            );
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
        mTitleCache = (AppTitle != null) ? (AppTitle as String) : mFallbackTitle;
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
        } else if (forecastNumber <= 6) {
            return isDaytime ? mIconCloudDay : mIconCloudNight;
        } else if (forecastNumber <= 14) {
            return winter ? (isDaytime ? mIconSnowDay : mIconSnowNight) : (isDaytime ? mIconRainDay : mIconRainNight);
        } else if (forecastNumber <= 21) {
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
                                        : (mCachedMonth >= 6 && mCachedMonth <= 8);   // Southern hemisphere: Jun–Aug

        var weatherIcon = getWeatherIcon(forecastNumber, isDaytime, winter);

        var xWeatherIcon = dc.getWidth() - weatherIcon.getWidth() - 10;
        var yWeatherIcon = valueY - 25;

        dc.drawBitmap(xWeatherIcon, yWeatherIcon, weatherIcon);
    }

}
