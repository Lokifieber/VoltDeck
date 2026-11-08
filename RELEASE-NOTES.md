# VoltDeck 0.3.0-alpha.1 · Early Access

The first public preview for Windows 10 and 11 (x64). VoltDeck checks Windows Update for compatible drivers, compares installed and offered versions, records driver changes locally, and imports driver packages from INF backups.

## Downloads

- **Setup.exe** installs VoltDeck for the current Windows account and adds a Start menu entry. A desktop shortcut is optional.
- **Portable.zip** runs from a writable folder. Extract all files, launch `VoltDeck.exe`, and keep `portable.flag` beside it. Settings, driver history, and automatic backups are stored under `data/`.
- **SHA256SUMS.txt** contains checksums for both packages.

## Early Access notes

- Installing or restoring drivers requires administrator privileges. The builds are unsigned, so Windows may show an unknown publisher prompt.
- Available updates depend on your hardware and Windows Update configuration. When you import a backup, Windows chooses the active package according to its driver ranking.

Please share feedback through GitHub Issues or [Discord](https://discord.gg/8JGu5Ecerh). Thanks for testing!

**Credits:** LokiFieber and OpenAI Codex.
