# Simply Weather

A [Garmin Connect IQ](https://developer.garmin.com/connect-iq/) widget that predicts the weather using only your watch's barometer and compass — no phone, no internet required. Forecasts are generated on-device using barometric pressure, its trend, and wind direction.

This is a software implementation of the [Zambretti Forecaster](https://en.wikipedia.org/wiki/Zambretti_Forecaster), a mechanical weather prediction instrument from WWI-era England. A forecast made around 09:00 local solar time is claimed to be over 90% accurate for the next 12 hours in temperate zones.

> **Forked from [simonl-ciq/SimplyWeather](https://github.com/simonl-ciq/SimplyWeather)**. All credit for the original app and the Zambretti algorithm adaptation goes to Simon. This fork adds UI polish, glance view improvements, and a handful of quality-of-life tweaks.

## Install

Compile yourself, copy to the watch and enjoy!

## Features

### Forecast

The widget uses the [Zambretti algorithm](https://en.wikipedia.org/wiki/Zambretti_Forecaster) adapted from [Beteljuice's JavaScript implementation](https://www.beteljuice.co.uk/zambretti/forecast.html) to produce a short-term (up to 12 h) local weather forecast:

- Two-line forecast text (e.g. *"Fairly fine"* / *"possible showers early"*)
- Precipitation probability percentage with a rain/snow icon (season-aware)
- Pressure trend indicator: **Rising**, **Steady**, or **Falling**
- Current barometric pressure (hPa)

### Compass & Wind Direction

The widget reads the watch's magnetometer to determine wind direction, using it as a key input for the Zambretti algorithm:

- Live compass display with 16-point cardinal directions (N, NNE, NE, …)
- Heading smoothing and direction hysteresis to avoid jittery updates
- Wind direction is persisted across widget sessions
- Shake-to-recalibrate: shake the watch to reset the compass heading

### Glance View

A compact glance-view shows:

- Customisable title (configurable in Garmin Connect settings)
- Current forecast summary text
- Context-aware weather icon (day/night, summer/winter)

### Hemisphere Awareness

- Automatic hemisphere detection via GPS (one-shot fix)
- Falls back to the configured default (Northern or Southern) when GPS is unavailable
- Seasonal adjustments for pressure trends and precipitation type (rain vs. snow)

## Settings

All settings are configurable from the Garmin Connect app:

| Setting | Description | Default |
|---|---|---|
| **Adjust Pressure to MSL** | Use mean sea level pressure instead of local ambient | Yes |
| **Local pressure range (low)** | Lower bound of local barometric range (hPa) | 950 |
| **Local pressure range (high)** | Upper bound of local barometric range (hPa) | 1050 |
| **Device pressure correction** | Offset added to the barometer reading (hPa) | 0 |
| **Trend threshold** | Pressure change below this is treated as "steady" (hPa) | 0.5 |
| **Trend time window** | Hours of pressure history used to determine the trend | 4 |
| **Display details** | Show temperature and extended info on the widget face | Yes |
| **Default hemisphere** | Hemisphere fallback when GPS is not available | Northern |
| **Original pressure method** | Use the legacy pressure reading method (for older watches) | No |
| **Glance title** | Custom title displayed in the glance view | Weather |

## Supported Devices

The widget targets Garmin watches with barometer and compass sensors, including:

- Fenix 6 / 6S / 6X Pro
- Fenix 7 / 7S / 7X / 7 Pro
- Fenix 8 (43 mm, 47 mm, Solar 47 mm, Solar 51 mm)
- Fenix E, Fenix Chronos
- Forerunner 965

See [manifest.xml](manifest.xml) for the full list of supported products.

## Languages

- English
- German (Deutsch)

## Credits

- **Original app**: [Simon (simonl-ciq)](https://github.com/simonl-ciq/SimplyWeather) — the foundation this fork builds on
- **Zambretti algorithm**: Adapted from [Beteljuice's JavaScript code](https://www.beteljuice.co.uk/zambretti/forecast.html) (June 2008)
- **Icon design**: [Freepik](https://www.flaticon.com/authors/freepik) from Flaticon, licensed under [CC BY 3.0](https://creativecommons.org/licenses/by/3.0)

## License

This project is licensed under the MIT License — see the [LICENSE](LICENSE) file for details.