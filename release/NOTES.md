Note Island 0.1.0 — first macOS binary release preparation

**Private draft: public binaries are blocked on Developer ID/notarization and
clean-Mac installation acceptance. Candidate archives are for local QA only.**

Note Island is a native panel at the top of your Mac for notes, translation,
Apple Calendar, recordings and screenshot history. A notch is not required.

- macOS 15 or newer. Universal Apple Silicon/Intel binary; physical Intel
  execution acceptance remains separate from architecture validation.
- The current application interface is Russian.
- Notes with live Markdown, pinned panel, color labels and search.
- Apple Translation by default; optional Google Cloud/DeepL with your own key.
- Calendar features can create/edit/delete events after permission is granted.
- Recording and screenshot tools use local files; capture requires the relevant
  macOS permissions. Screenshot history monitors copied images while running.

No Xcode is required to use a final binary. Personal notes, calendars, media and
credentials are not included. Existing data stays outside the app bundle; back
up ~/Library/Application Support/NoteIsland before updating.

See `release/INSTALL.txt` for permissions, shortcuts and installation. Before
publishing, attach notarized ZIP/DMG, committed source ZIP, `manifest.json`,
`SHA256SUMS` and instructions matching the exact release commit.
[Installation feedback](https://github.com/raven-ai-esh/note-island/issues).
