# BodyFasciNation — For the Compensating Man

A satirical self-comparison physique tester inside the Physiqo Body screen. The premise is absurd; the arithmetic is not.

## What it measures

- Chest, waist, flexed upper arm, and wrist tape circumferences.
- Push-ups in one set and plank duration in seconds, reported by the participant.
- Chest / waist and upper arm / wrist circumference ratios. These are raw arithmetic, not a clinical, aesthetic, or masculinity score.
- Up to 24 dated records per profile, locally. Changes compare to the preceding entry, not population norms.
- Metric/inch switching preserves the entered physical quantity; numbers are stored in centimeters.
- The Compensation Amplifier is explicitly fictional and never affects the measured data.
- Optional access to the original AI photo scan is behind a disclosure prompt. It sends photos to a configured external AI provider.

## Measurement protocol

Stand relaxed for chest and waist measurements. Use consistent tape landmarks, clothing, and breathing. For the upper arm, use the same flexed arm and landmark. At the wrist use the same place and tape tension. Use consistent push-up depth and plank posture each session. Try to compare sessions at similar times of day.

This is not a medical or mental-health assessment. It does not infer body fat, fascial health, posture, psychological compensation, masculinity, illness, or attractiveness.

## Code map

- Entry from BodyScreen under the existing scan button
- Route: /body_fascination
- Screen: lib/screens/body_fascination_screen.dart
- Model: lib/models/body_fascination_metrics.dart
- Tests: test/body_fascination_test.dart
- Data key: body_fascination_history_v1, scoped via AccountManager.getPrefKey
- Erase button confirms deletion of stored records, not app profile data

## Privacy and limitations

Manual testing requires no AI credentials, photo permissions, telemetry, or network request. Measurement history is kept in app SharedPreferences and is not encrypted; it is per profile, not secure archival storage. The separately accessed original scanner may upload front/back photographs to a third-party AI service according to the existing BYOK configuration. Its scores are model estimates rather than direct measurements.

Experimental satirical UI text is English-first; layout follows RTL in Persian, Arabic, and Urdu. Existing Physiqo localization and overall brand are preserved. Translate all new copy before treating it as fully localized.