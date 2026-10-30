# PPL Flight

A native SwiftUI flight-planning and moving-map app for **iPhone and iPad**, built for private pilot (PPL) training.
It covers the same core workflow as an EFB: plan a VFR flight, brief the weather, look at charts and plates, and
fly with a moving map, synthetic vision and terrain alerts.

> **Training and situational-awareness aid only. Not certified for navigation.** Always use current FAA charts,
> an official weather briefing, your POH/AFM and your instructor's guidance.

## Features

| Area | What it does |
| --- | --- |
| **Maps** | FAA VFR Sectional, Terminal Area (TAC), IFR Low and IFR High charts (FAA AIS tile services) over Apple Maps; airports colored by flight category from live METARs; NEXRAD radar; route line; ownship with track vector, 5/10/20 nm range rings and glide-range ring; track-up/north-up; long-press for terrain elevation, nearest airports and Direct-To. |
| **Basic planning** | Route entry (`KCNO PDZ KRAL`, fixes, lat/lon), Direct-To, cruise altitude with the VFR hemispheric rule, nav log (TC, wind, WCA, TH, VAR, MH, GS, ETE, fuel per leg with climb/cruise/descent split), fuel required vs usable, route weather briefing, ICAO flight-plan text for 1800wxbrief, return flight. |
| **Airports** | Search by ident/name/city, nearest, favorites. Airport card with Direct To / Add to Route, sunrise/sunset, Info (frequencies, runways, nearby VORs, magnetic variation), Weather (decoded METAR with density altitude, TAF, winds aloft incl. decoded FB, 7-day forecast), Runway (head/crosswind per runway end vs your aircraft's crosswind limit, best runway), Procedures, NOTAM/TFR links. |
| **Geo-referenced plates & taxi diagrams** | FAA d-TPP plates for the current cycle (cycle detected via the FAA APRA API; index from the d-TPP metafile). Airport diagrams are geo-referenced automatically from their printed lat/lon graticule labels so your aircraft is drawn on the diagram. A vector **Taxi Map (GPS)** (runways + OpenStreetMap taxiways, aprons, hold lines) works at any airport. |
| **Synthetic vision** | SceneKit 3D terrain (AWS Terrain Tiles) around the aircraft with runway models, hazard coloring (red within 100 ft, yellow within 1,000 ft of your altitude), GPS-derived pseudo-attitude, airspeed (GS) and GPS altitude tapes, heading tape, roll scale. Shown as a split view on the map (side-by-side on iPad landscape). |
| **Hazard Advisor** | Map overlay that paints terrain red/yellow relative to your altitude (GPS altitude above 30 kt, otherwise a slider for preflight planning), FAA Digital Obstacle File towers colored by the same rule, and a route profile with highest terrain and clearance. |
| **By-Altitude performance** | Groundspeed bubbles for every altitude × route segment from the aircraft performance profile + GFS winds aloft, terrain profile, and an altitude table (ETE, fuel, head/tailwind, VFR-rule check, fastest altitude). Tap a row to set the cruise altitude. |
| **Animated winds & temps aloft** | Animated wind particles over a temperature or wind-speed heat map at Surface / 3k / 5k / 10k / 14k / 18k ft, with a 48-hour time slider. FB winds-aloft table with decoding help. |
| **Logbook** | 14 CFR 61.51-style entries, totals, private pilot requirement progress (61.109), automatic track recording above 35 kt, CSV export. |
| **Simulator** | Flies your active route (takeoff, climb, cruise, descent, approach) at 1×/4×/16× so you can rehearse with every feature on the ground. |

Default aircraft is a **Cessna 172N** (figures from the kneeboard card: 55/65/75 % → 99/107/114 KTAS at 6.3/7.3/8.4 gph,
Vy 73, 770 fpm, 40 gal usable). Every number is editable in **More → Settings → Aircraft** (the Settings tab on iPad). Default home base: **KCNO**.

## Build and run

Requirements: Xcode 26 or newer, iOS/iPadOS 18+.

1. Open `PPLFlight.xcodeproj` in Xcode.
2. Select the **PPLFlight** target → *Signing & Capabilities* → choose your **Team** (a free Apple ID works for your own devices).
   If Xcode complains about the bundle identifier, change `com.yuhongzhang.PPLFlight` to something unique.
3. Pick an iPhone or iPad (or a simulator) and press **Run**.
4. On first launch the app downloads the airport database (~20 MB, OurAirports) and the FAA procedures index (~16 MB).

The project uses an Xcode *synchronized folder*: any Swift file you add under `PPLFlight/` is compiled automatically.

### Try it quickly
1. **Flights** → **+** → route `KCNO PDZ KRAL` → *Update route*.
2. *By-Altitude Performance*, *Navigation Log*, *Route Weather Briefing*.
3. *Simulate flight* → on the map turn on the mountain button (synthetic vision) and the profile button; open the layer
   picker to enable Hazard Advisor, radar, obstacles and animated winds.
4. **Plates** → KCNO → *Airport Diagram* while the simulator is near the field to see the geo-referenced ownship.

## Data sources

| Data | Source |
| --- | --- |
| Charts (Sectional, TAC, IFR Low/High) | FAA Aeronautical Information Services ArcGIS tile services |
| Terminal procedures (d-TPP), cycle | aeronav.faa.gov d-TPP, FAA APRA API |
| Obstacles, fixes | FAA AIS ArcGIS feature services (Digital Obstacle File, Designated Points) |
| METAR, TAF, PIREP, FB winds | aviationweather.gov Data API (NOAA) |
| Winds/temps aloft grid, daily forecast | Open-Meteo (GFS), CC BY 4.0 |
| Radar | Iowa Environmental Mesonet NEXRAD composite tiles |
| Terrain | AWS Open Data Terrain Tiles (Terrarium) |
| Airports, runways, frequencies, navaids | OurAirports (public domain) |
| Taxiways, aprons, hold lines | © OpenStreetMap contributors (ODbL), via Overpass API |

## Project layout

```
PPLFlight/
  App/        App entry, root TabView, AppModel (state, persistence, routing)
  Core/       Geodesy, networking, CSV, formatting/theme, sunrise/sunset
  Data/       Airport DB, weather, winds aloft, terrain, plates, obstacles, OSM
  Flight/     Ownship state (GPS + pseudo-attitude), simulator, track recorder
  Planning/   Route parser, performance engine, flights, nav log, by-altitude, filing
  Map/        MKMapView wrapper, chart/radar/hazard tiles, wind layer, panels, profile
  SV/         Synthetic vision scene + PFD overlay
  Airports/   Airport search and the airport card tabs
  Plates/     d-TPP browser, PDF viewer with geo-referencing, GPS taxi map
  Weather/    METAR list, FB winds aloft, imagery
  Logbook/    Logbook, PPL progress, editor
  More/       Settings, aircraft profiles, offline data
```
