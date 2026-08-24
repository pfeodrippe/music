# Accurate-Salamander Grand Piano V6.2beta2

This notice records the provenance of an optional development instrument. The
sample archive and extracted soundbank are intentionally kept under ignored
`local-content/` paths and are not distributed by this repository.

- Project: Accurate-Salamander Project
- Project URL: https://www.ir.isas.jaxa.jp/~cyamauch/AccurateSalamander/
- Soundbank/remaster author: Chisato Yamauchi
- Original Salamander Grand Piano author: Alexander Holm
- Instrument: Yamaha C5 grand piano
- Release used: `AccurateSalamanderGrandPianoV6.2beta2_48khz24bit.zip`
- Archive size: 1,657,769,640 bytes
- Archive SHA-256: `4abf8f81751176534ead0130fdb078931941d887ebf6690c0b7203033d811dbd`
- Audio format stated by the project: 48 kHz, 24-bit
- Attack material stated by the project: 480 WAV sources across 16 velocity
  layers, subsequently mapped with release, resonance, and mechanical regions
- License: Creative Commons Attribution 3.0 (CC BY 3.0), the same license as the
  original Salamander Grand Piano
- License URL: https://creativecommons.org/licenses/by/3.0/

The native development default, when the optional pack is present, is:

`sfz_live/Accurate-SalamanderGrandPiano_flat.Recommended.sfz`

The live profile documents damper-pedal resonance, repedaling, and continuous
half-pedal behavior. Score initializes CC20/21/22/23 to 64 for sampled release,
hammer noise, pedal mechanics, and damper resonance. The file currently loads
1,704 SFZ regions and 641 preloaded samples through sfizz.

Local verification on 2026-08-22 measured an eight-point velocity span of
33.478 dB, distinct pedal-up/half/full release tails, audible pedal mechanics,
bit-exact repeated MIDI attacks with random mechanics disabled, and zero queue
drops or raw-mix overload samples in the stress chord. These engineering checks
do not replace attribution, redistribution review, browser/iOS resource testing,
or blind listening before any optional asset-pack release.
