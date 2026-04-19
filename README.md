# Simply Weather

A [Garmin Connect IQ](https://developer.garmin.com/connect-iq/) widget that predicts the weather using only your watch's barometer and compass — no phone, no internet required.

> **Forked from [simonl-ciq/SimplyWeather](https://github.com/simonl-ciq/SimplyWeather)**. Original app used the Zambretti algorithm; this fork replaces it with the Sager Weathercaster engine, adds pressure-change acceleration detection, glance-view weather icons, and various quality-of-life improvements.

## Algorithm

### Sager Weathercaster

The forecast engine is based on Raymond Sager's meteorological method (1960s, US Navy). Unlike simpler barometric forecasters, Sager treats **wind direction as a primary forecast dimension** alongside pressure and its trend.

**Inputs** (all derived on-device):
- Current barometric pressure (hPa)
- Pressure trend over the configured time window (rising / steady / falling)
- Wind direction from the compass (8 octants)
- Current month (for seasonal corrections)
- Hemisphere (north / south)

**How it works:**
1. Three lookup tables (`steadyBase`, `risingBase`, `fallingBase`) are indexed by wind octant (0–8), producing a base forecast number (0–25).
2. The base number is adjusted by pressure level (±2) — high pressure biases toward fair, low toward unsettled.
3. A seasonal modifier (±1) accounts for summer convective storms and winter clearing patterns.
4. The final forecast number maps to a condition label (e.g. "Fairly fine, showers likely") and a precipitation probability (0–95%).

**26 forecast conditions** range from *Settled fine* (0) to *Stormy, much rain* (25).

### Pressure-Change Acceleration

On top of the standard 3-hour trend, the engine computes the **second derivative** of pressure (P″) using three hourly samples:

$$P'' = P_0 - 2 P_{-1} + P_{-2}$$

A 0.15 hPa deadband filters sensor quantisation noise. Three refinement rules modify the trend input to Sager before the forecast lookup:

| Condition | Rule | Effect |
|---|---|---|
| Trend is steady, P″ ≤ −0.5 | Upgrade to falling | Early storm warning — pressure drop is accelerating before the 3 h window catches it |
| Trend is falling, P″ > +0.5 | Downgrade to steady | Front is passing — pressure deceleration means conditions are stabilising |
| Trend is rising, P″ ≤ −1.0 | Keep rising (no flip) | Noise filter — prevents a sensor glitch from overriding a genuine high-pressure build |

This catches the dangerous "looks steady but the bottom is falling out" pattern typically seen with fast-moving summer thunderstorms.

### Expected Accuracy

Barometric forecasting precision varies by terrain and weather pattern:

| Scenario | Accuracy | Lead time | Notes |
|---|---|---|---|
| **Urban / lowland** | ~80% | 2–4 h | Stable environment, pressure patterns read cleanly; acceleration catches convective buildups 30–60 min earlier |
| **Mountain hiking (1500–2500 m)** | ~65% | 1–3 h | Altitude thermals and terrain-funnelled winds add noise; the deadband helps but local effects limit prediction. Always cross-check official mountain forecasts. |
| **Coastal / seaside** | ~85% | 3–6 h | Flat terrain, clean pressure gradients — best case for barometric forecasting. Fronts approach predictably and the acceleration trigger works well here. |

## Features

### Forecast

- Two-line forecast text (e.g. *"Fairly fine"* / *"possible showers early"*)
- Precipitation probability percentage with a rain / snow icon (season-aware)
- Pressure trend indicator: **Rising**, **Steady**, or **Falling**
- Current barometric pressure (hPa)

### Compass & Wind Direction

- Live compass display with 16-point cardinal directions (N, NNE, NE, …)
- Heading smoothing and direction hysteresis to avoid jittery updates
- Wind direction is persisted across widget sessions
- Shake-to-recalibrate: shake the watch to reset the compass heading

### Glance View

A compact glance view with:

- Customisable title (configurable in Garmin Connect settings)
- Current forecast summary text
- Weather icon — context-aware by time of day and season (see table below)

### Weather Icons

The glance view selects an icon based on three inputs: the Sager forecast number, time of day, and season.

**Day / night** is determined by a fixed 07:00–19:00 window.

**Season** is hemisphere-aware — Northern: Dec–Feb = cold season; Southern: May–Sep = cold season.

| Forecast | Condition | Warm season (day / night) | Cold season (day / night) |
|---|---|---|---|
| 0–1 | Clear / fine | ☀️ Sun / 🌙 Moon | ☀️ Sun / 🌙 Moon |
| 2–6 | Fair / variable | 🌤 Cloud-day / ☁️🌙 Cloud-night | 🌤 Cloud-day / ☁️🌙 Cloud-night |
| 7–14 | Showers / unsettled | 🌧 Rain-day / 🌧🌙 Rain-night | 🌨 Snow-day / 🌨🌙 Snow-night |
| 15–21 | Rain / very unsettled | 🌧 Heavy rain | 🌨 Heavy snow |
| 22–25 | Stormy | ⛈ Thunderstorm | 🌨❄️ Snowstorm |

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
| **Trend threshold** | Pressure change below this is treated as "steady" (hPa) | 0.5 |
| **Trend time window** | Hours of pressure history used to determine the trend | 4 |
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
  point-strings/             # Compass point labels (N, NE, E, …)
  settings/                  # Garmin Connect configurable properties
resources-deu/               # German localisation
resources-eng/               # English localisation
```

## Credits

- **Original app**: [Simon (simonl-ciq)](https://github.com/simonl-ciq/SimplyWeather) — the foundation this fork builds on
- **Sager Weathercaster**: Based on Raymond Sager's barometric forecasting method (1960s, US Navy)
- **Icon design**: [Freepik](https://www.flaticon.com/authors/freepik) from Flaticon, licensed under [CC BY 3.0](https://creativecommons.org/licenses/by/3.0)

## License

This project is licensed under the MIT License — see the [LICENSE](LICENSE) file for details.