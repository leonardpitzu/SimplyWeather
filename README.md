# Simply Weather

A [Garmin Connect IQ](https://developer.garmin.com/connect-iq/) widget that predicts the weather using only your watch's barometer and compass - no phone, no internet required.

> **Forked from [simonl-ciq/SimplyWeather](https://github.com/simonl-ciq/SimplyWeather)**. Original app used the Zambretti algorithm; this fork replaces it with the Sager Weathercaster engine, adds a regression-based barometric trend analyser (altitude-immune and diurnal-corrected), glance-view weather icons, and various quality-of-life improvements.

## Algorithm

### Sager Weathercaster

The forecast engine is based on Raymond Sager's meteorological method (1960s, US Navy). Unlike simpler barometric forecasters, Sager treats **wind direction as a primary forecast dimension** alongside pressure and its trend.

**Inputs** (all derived on-device):
- Current barometric pressure (hPa)
- Pressure trend over the configured time window (rising / steady / falling)
- Wind direction from the compass (8 octants)
- Current date (for continuous seasonal corrections)
- Hemisphere (north / south)

**How it works:**
1. Three lookup tables (`steadyBase`, `risingBase`, `fallingBase`) are indexed by wind octant (0-8), producing a base forecast number (0-25).
2. The base number is adjusted by pressure level (±2) - high pressure biases toward fair, low toward unsettled.
3. A seasonal modifier (±1) accounts for summer convective storms and winter clearing patterns, ramping continuously with the date instead of stepping at month boundaries.
4. The final forecast number maps to a condition label (e.g. "Fairly fine, showers likely") and a precipitation probability (0-95%).

**26 forecast conditions** range from *Settled fine* (0) to *Stormy, much rain* (25).

> **Provenance, honestly:** the 26 condition labels are **Zambretti's** vocabulary, not Sager's, and the three lookup tables are hand-built rather than transcribed from Sager's published matrix. Full Sager takes five inputs - wind direction, *wind-direction change*, barometer reading, barometer change and present weather - and this engine feeds it two. The precipitation percentages have no published source. Neither method's original calibration survives that, which is what the measured skill below reflects.

### Barometric Trend Analysis

The rising / steady / falling input to Sager is not a naive "now minus three hours ago" comparison - it comes from a small on-device regression pipeline run over the barometer's stored history:

1. **Mean-sea-level reduction.** Every pressure sample is first reduced to mean sea level using the watch's barometric **elevation history**, so a change in altitude (a climb, a drive uphill, an elevator) cancels out and only genuine weather moves the trend. With no elevation history available it falls back to raw station pressure - identical to the previous behaviour.
2. **Quadratic regression.** A single-pass least-squares parabola is fitted to the sea-level series across the trend window (~6 h). The fitted curve gives the net pressure change over the window, tested against a deadband (default 0.35 hPa/h) to decide rising, steady, or falling. Fitting a parabola rather than a straight line lets a curving pressure profile be read correctly.
3. **Diurnal tide correction.** The atmosphere has a twice-daily pressure tide (~0.6 hPa swing at mid-latitudes). The expected tidal change over the window - amplitude derived from latitude - is subtracted, so the normal daily rhythm is never mistaken for an approaching system.
4. **Short-window front detection.** An **independent** linear fit over only the **last 3 hours** flags a fast-moving front before the longer window catches it. Because it is computed from the recent samples alone, a large pressure wiggle earlier in the window cannot contaminate it.
5. **Hysteresis & front passage.** The trend is quick to raise an alarm and slow to clear it, and a passing front (was falling, now levelling with pressure recovering) is upgraded to rising.

A glitched elevation sample cannot poison the series: the sea-level reduction clamps altitude to a physical range. This pipeline replaces an earlier point-sample second-derivative ("acceleration") trigger that over-reacted to short pressure wiggles and to altitude changes.

### Measured Skill

Earlier revisions of this file quoted accuracy figures of 65-85%. Those were never measured. They have been replaced with a verification against a rain gauge.

Scored over 40 days against a co-located weather station - 926 hourly forecasts, 13.2% of 6-hour windows wet. The run below is the no-bearing configuration, which is what the engine falls back to before you have pointed the watch into the wind:

| Metric | Value | Reading |
|---|---|---|
| Brier score | 0.159 | climatology scores 0.114 |
| Brier skill score | **-0.39** | negative: worse than always forecasting the average |
| Reliability | 75% stated -> 25% observed | the stated probability is not a probability |
| False-alarm ratio | 0.76 | three in four warnings did not verify |
| Resolution | 0.002 | almost no information about *when* rain arrives |

The barometric tendency carries essentially no 6-hour rain signal at the test site (rank correlation +0.00 against observed rain) but a clear 24-hour one (-0.68), so the forecast horizon is itself under review. The wind-bearing path is not separately verified: the reference station logs wind direction without long-term statistics, so there is no history to score it against yet.

A calibrated replacement is in progress. It is blocked on data rather than on code: 40 days spans a single regime change, so every cross-validation fold trains on a climate the held-out fold does not share.

> **Read the forecast as a barometer readout with a label attached, not as a probability of rain.**

## Features

### Forecast

- Two-line forecast text (e.g. *"Fairly fine"* / *"possible showers early"*)
- Precipitation probability percentage with a rain / snow icon (season-aware)
- Pressure trend indicator: **Rising**, **Steady**, or **Falling**
- Current barometric pressure (hPa)

### Compass & Wind Direction

- Live compass display with 16-point cardinal directions (N, NNE, NE, ...)
- Heading smoothing and direction hysteresis to avoid jittery updates
- Wind direction is persisted across widget sessions
- Shake-to-recalibrate: shake the watch to reset the compass heading

### Glance View

A compact glance view with:

- Customisable title (configurable in Garmin Connect settings)
- Current forecast summary text
- Weather icon - context-aware by time of day and season (see table below)

### Weather Icons

The glance view selects an icon based on three inputs: the Sager forecast number, time of day, and season.

**Day / night** is determined by a fixed 07:00-19:00 window.

**Season** is hemisphere-aware - Northern: Dec-Feb = cold season; Southern: May-Sep = cold season.

| Forecast | Condition | Warm season (day / night) | Cold season (day / night) |
|---|---|---|---|
| 0-1 | Clear / fine | ☀️ Sun / 🌙 Moon | ☀️ Sun / 🌙 Moon |
| 2-6 | Fair / variable | 🌤 Cloud-day / ☁️🌙 Cloud-night | 🌤 Cloud-day / ☁️🌙 Cloud-night |
| 7-14 | Showers / unsettled | 🌧 Rain-day / 🌧🌙 Rain-night | 🌨 Snow-day / 🌨🌙 Snow-night |
| 15-21 | Rain / very unsettled | 🌧 Heavy rain | 🌨 Heavy snow |
| 22-25 | Stormy | ⛈ Thunderstorm | 🌨❄️ Snowstorm |

The main widget view shows a small **raindrop** (warm season) or **snowflake** (cold season) icon next to the precipitation percentage.

### Hemisphere Awareness

- Automatic hemisphere detection via GPS (one-shot fix)
- Falls back to the configured default (Northern or Southern) when GPS is unavailable
- Seasonal adjustments for precipitation type (rain vs. snow) and forecast modifiers

## Supported Devices

- Fenix 6 / 6 Pro / 6S / 6S Pro / 6X Pro
- Fenix 7 / 7 Pro / 7S / 7S Pro / 7X / 7X Pro
- Fenix 8 (43 mm / 47 mm) / Fenix 8 Solar (47 mm / 51 mm)
- Fenix Chronos / Fenix E
- Forerunner 965

> Requires Connect IQ SDK 2.4.0 or later. Additional devices can be added via `manifest.xml`.

## Permissions

| Permission | Reason |
|---|---|
| **Sensor** | Access barometer and magnetometer for pressure readings and compass heading |
| **SensorHistory** | Read barometric pressure history to calculate pressure trends |
| **Positioning** | Detect hemisphere (north/south) via GPS for seasonal corrections |

## Settings

Configurable from the Garmin Connect app:

| Setting | Description | Default |
|---|---|---|
| **Device pressure correction** | Offset added to the barometer reading (hPa) | 0 |
| **Trend threshold** | Rate of pressure change below which the trend reads "steady" (hPa/h) | 0.22 |
| **Trend time window** | Hours of pressure history used to determine the trend | 6 |
| **Display details** | Show temperature and extended info on the widget face | Yes |
| **Default hemisphere** | Hemisphere fallback when GPS is not available | Northern |
| **Glance title** | Custom title displayed in the glance view | Weather |

## Languages

- English
- German (Deutsch)

## Install

Build with the Garmin Connect IQ SDK and side-load the `.prg` file to your watch.

### Side-load (manual)

1. Clone or download this repository.
2. Open the project in Visual Studio Code with the [Monkey C extension](https://marketplace.visualstudio.com/items?itemName=garmin.monkey-c).
3. Build for your device (`Monkey C: Build for Device`).
4. Copy the generated `.prg` file to your watch's `GARMIN/APPS` directory.

## Development

### Prerequisites

- [Connect IQ SDK](https://developer.garmin.com/connect-iq/sdk/) 2.4.0+
- Visual Studio Code with the Monkey C extension

### Build

```sh
# Build via the VS Code command palette:
#   Monkey C: Build for Device
# or use the Connect IQ CLI:
monkeyc -f monkey.jungle -o SimplyWeather.prg -d fenix7
```

### Project Structure

```
source/
  SimplyWeatherApp.mc        # Application entry point
  SimplyWeatherDelegate.mc   # Input handling & compass interaction
  SimplyWeatherForecast.mc   # Sager Weathercaster forecast engine
  SimplyWeatherView.mc       # Widget layout, rendering & pressure logic
resources/
  drawables/                 # SVG icons (weather, compass, etc.)
  strings/                   # App name
  forecast-strings/          # Forecast condition descriptions (26 outcomes)
  point-strings/             # Compass point labels (N, NE, E, ...)
  settings/                  # Garmin Connect configurable properties
resources-deu/               # German localisation
resources-eng/               # English localisation
```

## Credits

- **Original app**: [Simon (simonl-ciq)](https://github.com/simonl-ciq/SimplyWeather) - the foundation this fork builds on
- **Sager Weathercaster**: Based on Raymond Sager's barometric forecasting method (1960s, US Navy)
- **Icon design**: [Freepik](https://www.flaticon.com/authors/freepik) from Flaticon, licensed under [CC BY 3.0](https://creativecommons.org/licenses/by/3.0)

## License

This project is licensed under the MIT License - see the [LICENSE](LICENSE) file for details.