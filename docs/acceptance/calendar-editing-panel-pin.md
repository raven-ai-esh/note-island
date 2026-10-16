# Calendar editing and panel pin acceptance

Scope: create/edit/delete Apple Calendar events from Note Island; collapse the expanded panel after an outside click unless pinned; place the panel pin next to Close. Verification date: 2026-10-16, local macOS.

## Acceptance record

| Requirement / regression | Executed verification | Result |
| --- | --- | --- |
| Create, edit and delete the chosen event, refreshing the list | `MeetingEditingTests.testCreateUpdateDeleteRefreshTheListAndTargetTheChosenEvent` | PASS |
| Calendar writes reach the system event database | Signed `Tools/CalendarAcceptance.swift` app; separate `EKEventStore` reads each write | PASS for create, edit, delete |
| UI create reaches Apple Calendar | New meeting form → Create → the synthetic event appears in Note Island and the Apple Calendar week view | PASS |
| Cancel does not create a meeting | Fill new meeting form → Cancel → event count unchanged; opening a new form starts empty | PASS |
| Invalid title, date range, URL and read-only calendar cannot write | `testValidationAndReadOnlyCalendarDoNotWriteAnything` | PASS |
| Permission revocation, missing event and retry are explicit | `testPermissionRevocationAndMissingEventNeverReportSuccess`, `testFailureKeepsTheDraftAndRetryRefreshesList` | PASS |
| No writable calendar | `testNoWritableCalendarIsAnExplicitFailure` | PASS |
| Notifications follow mutation | `testMutationsRescheduleAndCancelMeetingNotifications` | PASS |
| Repeat handling affects only the selected occurrence and keeps existing metadata | Signed Calendar acceptance: edit first occurrence in a 3-event series, verify other 2, verify notes/alarm, delete first, verify remaining 2 | PASS |
| External Calendar changes refresh the active list | Signed Calendar acceptance: save externally → observe list update | PASS |
| All-day range | Unit validation; signed Calendar acceptance multi-day create → reload → edit → resave; EventKit inclusive end converted at both boundaries | PASS |
| Stale or deleted event is not overwritten/recreated | Signed Calendar acceptance with external edits/deletion | PASS |
| Pin policy and persistence | `IslandAutoCollapseTests.testOutsideClickCollapsesOnlyAnExpandedUnpinnedPanel` | PASS |
| Native pin/unpin, manual collapse while pinned, reopening and restart persistence | Pin icon → pin.fill; Collapse → compact; reopen → pinned; restart app → reopen still pinned; unpin → pin | PASS |
| Inside/menu clicks stay open; outside click routes through real AppKit dispatch | `testInsideAndMenuClicksAreNotTreatedAsOutsideButAnotherWindowIs`, `testInstalledMonitorProcessesRealAppKitDispatchAndKeepsOriginalClick` | PASS |
| Pin next to Close, form appearance and new controls | Signed release UI inspection | PASS |
| Real outside click on the unpinned panel | User clicked another window with the physical mouse and confirmed collapse; app inspection shows the compact panel | PASS |
| Real outside click on the pinned panel | Panel pinned through its icon; user clicked another window with the physical mouse and confirmed it stayed open; app inspection confirms expanded `pin.fill` state | PASS |
| UI edit, delete confirmation/cancel/delete, and visible validation error | Open Edit from the clicked synthetic event; change title/location; Save; read both values in Apple Calendar; Delete → Cancel keeps event; Delete → confirm removes it from both apps; empty-title error visible without scrolling | PASS |

Final independent full suite: `swift test --scratch-path /tmp/note-island-calendar-pin-review --disable-index-store -j 4` → 152 tests, 0 failures. Post-fix relevant tests: 9 calendar editing + 3 panel tests, 0 failures. Release compilation passed from the same external scratch path. Build scratch paths are outside the synchronized project directory.

The signed live probe uses only a uniquely named temporary calendar. Final cleanup resolves a fresh calendar and confirms removal through another store before returning. Four empty fixtures left by earlier failed probes were removed by exact title; a separate store confirmed zero remained. The first standalone XCTest live attempt did not have full access; live integration verification uses a signed app with the same authorized identity instead. Tests do not change existing user events. Native UI test events contained synthetic content and were removed; the final one was deleted through the confirmed UI journey.

The release bundle and ZIP were signed and verified. The prior local artifacts were preserved as `dist/Note Island-before-calendar-editing.app` and `dist/Note-Island-macOS-before-calendar-editing.zip` (ignored build outputs).

## Run the live Calendar probe

Compile these four files as a macOS executable (minimum target macOS 14), place it in a temporary `.app` with `App/Info.plist`, sign it with the project's calendar entitlement and authorized app identity, and launch through Launch Services:

```sh
swiftc -target arm64-apple-macosx14.0 -swift-version 6 -parse-as-library \
  Sources/NoteIsland/MeetingEditing.swift \
  Sources/NoteIsland/MeetingsStore.swift \
  Sources/NoteIsland/MeetingNotifications.swift \
  Tools/CalendarAcceptance.swift -o /path/to/temporary.app/Contents/MacOS/NoteIsland
```

Pass an absolute receipt path as the first application argument. Only a `PASS` receipt confirms all assertions and temporary-calendar cleanup. Full Calendar access must already be granted. Sync to other devices/accounts is performed by macOS; remote device delivery is outside this local acceptance record.

## Review

Independent read-only reviewer executed the final full suite and signed live Calendar probe separately: no blocking findings. The all-day write/read boundary finding was fixed and independently retested. Native UI CRUD and pin controls were executed on the signed release; physical unpinned/pinned outside clicks were confirmed by the user and corroborated by app state. All required acceptance paths passed.
