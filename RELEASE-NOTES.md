# VoltDeck 0.4.0 Alpha

VoltDeck is an Early Access driver utility for Windows 10 and 11 (x64). This release brings together the redesigned dashboard, safer update workflows, offline diagnostics, and new privacy controls.

## What's new

- The dashboard puts the clock, scan status, and protection settings in a sidebar. The main area shows driver search, shortcuts, and a grid of tools. Choose Light, Dark, or Windows appearance with any of the four color themes.
- Test mode verifies that Windows Update has downloaded the package and asks separately before installing it. With restore-point protection enabled, VoltDeck stops if Windows cannot confirm a new restore point.
- Back up all third-party driver packages to a local or removable drive. VoltDeck generates a SHA-256 manifest and can verify the backup later.
- Inspect devices, hardware IDs, INF files, versions, Windows-reported signers, and available Driver Store paths. Use Ctrl+F, filters, category badges, favorites, or Copy details to find and share individual entries.
- Review disabled devices, missing drivers, and Windows error codes. Export offline HTML and JSON diagnostics or open the first-aid guides. Windows Device Manager shows whether a previous driver is available for rollback.
- Daily and weekly scan plans check for offers while VoltDeck is open and online access is enabled. These plans may show a notification. They do not install drivers. A separate lock can block automatic Game Ready installation for critical drivers.

## Privacy and security

- VoltDeck starts with online access off and has no telemetry, project server, or automatic uploads. Online driver searches and downloads use the Windows Update service configured on your PC. That service can process device and configuration data after you grant access for the session.
- Settings, favorites, history, backups, and diagnostics are stored locally. Diagnostic files can include hardware IDs and activity logs. Cloud synchronization and manual sharing are controlled by the software you use to share them.
- The **About VoltDeck** dialog explains these boundaries. Vendor and Discord links open in your browser after confirmation.
- VoltDeck loads PowerShell and its modules from Windows system locations. Backup and diagnostic actions reject network drives and detected folder redirects.

## Downloads

- **Setup.exe** installs VoltDeck for the current Windows account and adds a Start menu entry. A desktop shortcut is optional.
- **Portable.zip** runs from a writable folder. Extract all files, launch VoltDeck.exe, and keep portable.flag beside it. The portable edition stores its data under the data folder.
- **SHA256SUMS.txt** contains hashes for both packages.

## Early Access notes

Driver installations and restores require administrator access. The release files are unsigned. Windows may limit how often it creates restore points, and its driver ranking determines which package becomes active after a backup import.

Please share feedback through GitHub Issues or [Discord](https://discord.gg/8JGu5Ecerh).

Developed by LokiFieber with OpenAI Codex.
