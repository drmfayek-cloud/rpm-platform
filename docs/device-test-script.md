# HC03 device test — week 1–2

**Purpose:** prove that our app, built on the Linktop SDK, connects to the HC03 and returns blood pressure
readings reliably on the phones we will put in patient kits, **before** patient screens are built on top.

**You need:** 2–3 HC03 units (charged), 1–2 Android phones (ideally the kit model), the
`rpm-patient-hc03-N.apk` from GitHub Actions, and 30–45 minutes.

Record every test in the table at the end (or a spreadsheet with the same columns) and send it back.

## Set-up (once per phone)

1. Install the APK. Open **RPM** → tap **Start** → allow **Nearby devices** (Android 12+) or **Location** (older Android).
2. Note the phone model and Android version (Settings → About phone).

## Tests

| # | Test | Steps | Expected |
|---|---|---|---|
| T1 | Find and connect | Tap **Find devices**. Tap the HC03 in the list. | Status goes `connecting` → `ready`. **Device ID** and **Battery** appear. |
| T2 | Device identity | Write down the Device ID shown, and the serial/label printed on the unit and its box. | One Device ID per unit. (This becomes the device register for all 100 units.) |
| T3 | Normal reading | Seated 5 min, back supported, feet flat, cuff on bare **upper arm** at heart level, no talking. Tap **Measure**. | Cuff inflates/deflates; result in roughly 30–60 s. Values look sensible. |
| T4 | Repeat readings | Repeat T3 twice more, 1 minute apart, same person. | Three results within roughly ±10 mmHg of each other. |
| T5 | Reference check (if available) | If you have a clinic-grade or validated home cuff, alternate: HC03, reference, HC03, reference (1 min apart). | Informal sense-check only — not a validation study. Note big gaps (>10 mmHg). |
| T6 | Leak | Loosen the cuff tube at the device, then **Measure**. | Message: "Air leak — check the cuff and tube…". App is usable again afterwards. |
| T7 | Movement | During a measurement, move the arm and talk. | Either a reading or "Movement or talking disturbed the reading". No freeze. |
| T8 | Cancel | Start a measurement, tap **Cancel**. | Cuff deflates; app returns to ready. |
| T9 | Device switched off mid-reading | Start a measurement, switch the HC03 off. | Status goes `disconnected`; no crash; you can reconnect after switching it on. |
| T10 | Restart | Close the app fully, reopen, **Start**, reconnect. | Connects again without re-installing. |
| T11 | Several units nearby | Switch on 2–3 HC03s next to each other, **Find devices**. | All appear; connecting to one shows that unit's Device ID (matches T2). |
| T12 | Low battery (if a unit is low) | Try to measure with battery under 20%. | Message asking to charge; no measurement starts. |

If anything fails, open **Technical log** at the bottom of the screen, take a screenshot, and attach it.

## Results log

| Date | Tester | Phone model / Android | App build | Device ID | Test | Result (values or message) | Pass? | Notes |
|---|---|---|---|---|---|---|---|---|
| | | | | | | | | |
