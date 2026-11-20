# PuggleSheets

**Crunch numbers, happily.**

PuggleSheets is a fast, familiar spreadsheet for the Mac, for budgets, gradebooks, inventories and trip plans. It recalculates as you type and explains its errors in plain words.

- More than 200 functions, from SUM and VLOOKUP to XLOOKUP, QUERY and LAMBDA
- Charts, pivot tables, filters, slicers and conditional formatting
- Tables, dropdowns, checkboxes and named ranges
- Comments, notes and protected ranges
- Collaborate live with other Mac users through iCloud, each person able to edit or only comment

It opens and saves Excel (.xlsx), OpenDocument (.ods), CSV and TSV files, and exports PDF.

PuggleSheets is free, needs no account of its own and has no tracking. It runs inside Apple's app sandbox with no permission to use the network (macOS takes the spreadsheets you share to and from iCloud for it), on macOS 14 Sonoma or later with Apple silicon or Intel. It's written in Swift with AppKit and SwiftUI, and is part of the PuggleSoft family with [PuggleDocs](https://github.com/StaticPrime/PuggleDocs) and [PuggleSlides](https://github.com/StaticPrime/PuggleSlides).

## Features

### The grid and editing

- **The grid.** A fast, canvas-style grid: 1,000 rows by 26 columns to start, with "Add 1,000 more rows" at the bottom. Column and row headers, gridlines, frozen rows and columns (View ▸ Freeze), zoom from 50% to 200% (and pinch to zoom), drag a header edge to resize a column or row and double-click it to fit the data, hide and unhide rows and columns.
- **Selecting and moving.** Click, drag, Shift-click and ⌘-click to select one or more ranges; click headers for whole rows and columns, or the corner for everything. The arrow keys, Tab and Return move between cells (Return after a run of Tabs goes back to the first column; inside a selected range they cycle through it), ⌘ arrows jump to the edge of the data, ⌥↑ and ⌥↓ switch sheets. The name box shows the selection and jumps to whatever you type (`B5`, `A1:C10`, `Sheet2!A1`).
- **Entering data.** Type over a cell, or press Return, F2 or double-click to edit it, or edit in the formula bar. Numbers, percentages, currency, dates, times and TRUE/FALSE are recognized as you type and get a matching number format. ⌥Return adds a line break in a cell, ⌘Return fills every selected cell, Esc cancels. Long text overflows into empty neighbors.
- **Editing.** Undo and redo for everything; cut, copy and paste within PuggleSheets keeps formulas (with references shifted, or following the cells on cut and paste), formats and merges, and copies to other apps as text and as a table; Paste special (values or format only); fill down and right (⌘D, ⌘R); the fill handle continues series (1, 2, 3…; Jan, Feb…; Item 1, Item 2…; dates); insert and delete rows and columns, with formulas following; sort a range or the sheet.
- **Cells.** Insert ▸ Cells and Edit ▸ Delete ▸ Cells shift cells right or down, or left or up, with formulas following.
- **Sheets.** Add, rename (double-click the tab), duplicate, delete, reorder and color sheet tabs; formulas follow renamed sheets. The bottom bar sums the selection in its own number format (or shows its average, minimum, maximum or count).
- **Freezing by dragging.** Drag the gray bars at the top left of the grid to freeze rows and columns.
- **Groups.** View ▸ Group (⌥⇧→ and ⌥⇧←) groups rows or columns, with nested groups, and + and − buttons beside the headers to collapse and expand them.
- **Text rotation.** The toolbar and Format ▸ Rotation tilt text up or down, rotate it, stack it vertically or turn it by any angle; rows grow to fit.
- **Find.** ⌘F opens a find box: matches are tinted, counted ("2 of 5") and stepped through with Return, ⌘G and ⇧⌘G.
- **Find and replace.** Edit ▸ Find and replace (⇧⌘H) searches all sheets, this sheet or a range, with match case, match entire cell contents, regular expressions (with `$1` in the replacement) and searching within formulas. Find, Replace and Replace all (one undo step).
- **Data cleanup.** Split text to columns (detecting the separator, which you can change), Remove duplicates and Trim whitespace.
- **More tools.** View ▸ Show ▸ Formulas (⌃`), Paste special ▸ Transposed, Data ▸ Randomize range, Data ▸ Column stats, and File ▸ Import, which brings a spreadsheet, CSV or TSV file into a new spreadsheet, new sheets, the current sheet or the selected cell.

### Formulas

- **Formulas.** A formula engine with its own parser and more than 200 functions (math, statistics, logic, text, lookup, dates, information, finance, and arrays such as FILTER, SORT and UNIQUE inside other functions), references across sheets, whole columns and open ranges (`A2:A`), and incremental recalculation. Among them are `QUERY` (a SQL-like query language: select, where, group by, pivot, order by, limit, offset and label), `SPARKLINE` (line, column, bar and win/loss charts in a cell), `LET`, `LAMBDA`, `MAP`, `REDUCE`, `SCAN`, `BYROW`, `BYCOL`, `MAKEARRAY`, `SORTN` and `GETPIVOTDATA`. While you type a formula its references are colored and outlined in the grid, and clicking or dragging over cells inserts their references. Errors explain themselves when you hover the red corner, and missing closing parentheses are added for you.
- **Arrays that spill.** Formulas like `=SORT(A2:A9)`, `=UNIQUE(…)` or `=SEQUENCE(5)` fill the cells below and beside them. A spill that would overwrite data shows `#REF!` and explains why. The formula bar shows the formula, grayed out, for spilled cells.
- **Formula help.** While you type a formula, names of functions (and named ranges) complete as you type, and a card shows the function's arguments with the current one highlighted.
- **Named ranges.** Data ▸ Named ranges: formulas can say `=SUM(Sales)`; names follow inserted and deleted rows and renamed sheets.

### Formatting and data tools

- **Formatting.** A familiar toolbar: currency, percent, decimal places and the "123" number formats; font and size; bold, italic, strikethrough, text and fill color; borders (with color and style); merge cells; horizontal and vertical alignment; wrap, overflow and clip; paint format; clear formatting (⌘\\). Rows grow to fit wrapped or larger text.
- **Conditional formatting.** Format ▸ Conditional formatting: single-color rules for empty and filled cells, text, dates, numbers and custom formulas, and two- or three-point color scales, in a sidebar with a preview of each rule.
- **Alternating colors.** Format ▸ Alternating colors with ready-made styles, header and footer colors, and custom colors.
- **Data validation.** Data ▸ Data validation and Insert ▸ Dropdown and Checkbox: dropdowns from a list or a range (shown as chips with a chevron), checkboxes (Space or a click ticks them) and conditions on text, numbers and dates, with help text, and a choice between a warning (a red corner) and rejecting the input.
- **Filters.** Data ▸ Create a filter adds filter buttons to the header row of the data around the selection. Each button sorts the range, or filters it by values (with search, Select all and Clear) or by a condition; filtered columns get a green funnel.
- **Filter views.** Data ▸ Filter views saves filters with names. Opening one hides rows only in that window, darkens the headers and shows its name and range in a bar across the top; the sheet's own filter and data stay as they are.
- **Tables.** Format ▸ Convert to table (⌥⌘T) turns data into a named table with a colored header, banded rows, a filter button on every header and the table's name in a chip. Table settings rename it, change its color and set column types (text, number, percent, currency, date, time, date time, checkbox or dropdown). Typing just below a table adds a row to it, and formulas can refer to it as `Table1[Amount]`, `Table1[#DATA]` and so on; renaming a table updates them.
- **Slicers.** Data ▸ Add a slicer places a slicer over the grid that filters a range or table by one of its columns, by values or by a condition. Charts that use the data follow, and so do pivot tables built on the same range.

### Charts, pivot tables, images and links

- **Charts.** Insert ▸ Chart suggests a chart for the selected data and opens the chart editor. Setup chooses the type (column, bar, line, area, pie, doughnut, scatter and combo, with stacked and 100% versions), the data range, headers, labels, switching rows and columns, and aggregation. Customize sets the background and font, titles, each series' color, line thickness, points, data labels and axis, the legend, the vertical axis range and log scale, gridlines, and pie options. Charts float over the grid: drag to move them, drag a handle to resize them, and use the ⋮ menu to edit, delete, copy, download (PNG, PDF or SVG) or add alt text. They update as the data changes and print with the sheet.
- **Pivot tables.** Insert ▸ Pivot table summarizes a range on a new or existing sheet. The pivot table editor adds rows, columns, values (SUM, COUNTA, COUNT, COUNTUNIQUE, AVERAGE, MAX, MIN, MEDIAN, PRODUCT, STDEV, VAR…, shown as values or as percentages of the row, column or total) and filters, with sorting and totals. Results update when the source data changes, formulas can refer to them, and the Edit button under a pivot table opens its editor. Clearing a pivot table's top-left cell deletes it.
- **Images.** Insert ▸ Image puts an image in a cell (fitted to it) or over the cells, where it moves and resizes like a chart. Images can also be pasted or dropped onto the grid, and have alt text.
- **Links.** Insert ▸ Link (⌘K) links a cell to a web page, an email address, another sheet, a range or a named range. Linked cells show a link card with buttons to open, copy, edit or remove the link. Typed web addresses and `HYPERLINK()` formulas become links too.

### Comments, notes and protection

- **Comments.** Insert ▸ Comment (⌥⌘M) starts a discussion on a cell, signed with your Mac's user name. Threads show beside their cell with replies, editing, deleting and resolving, an amber corner marks cells with open threads, and the Comments button in the header lists every thread, open or resolved.
- **Notes.** Insert ▸ Note (⇧F2) adds a note that shows when you point at the cell, marked with a black corner. Notes copy and paste with their cells.
- **Protected sheets and ranges.** Data ▸ Protect sheets and ranges protects a range or a whole sheet (with exceptions). A protection either warns before an edit (with "Don't show this again for 5 minutes") or refuses edits until it's removed. Protected sheets show a lock on their tab, and View ▸ Show ▸ Protected ranges stripes protected cells.

### Collaboration

- **Collaborate.** The Collaborate button in the header, left of Download (or File ▸ Collaborate…, ⌥⌘C), which only a spreadsheet's owner has, shares a spreadsheet with other people who use PuggleSheets on their Macs, through iCloud. A spreadsheet is kept on your Mac first: one that has never been saved asks where, and that file stays yours. Invite Collaborators sends the link by Messages, Mail or AirDrop, where you choose whether the people you invite can make changes; or choose Anyone with the Link, whether those people can edit or only comment, and Copy Link to pass it on yourself. Whoever clicks the link joins, and the spreadsheet opens for them in PuggleSheets. If clicking it opens a web page instead, copy the link and choose File ▸ Shared spreadsheets ▸ Open Invitation Link….
- **Editing together.** Everyone's changes show on everyone else's Mac as they're made, a moment after each one and every couple of seconds while someone else has the spreadsheet open: cells, formulas (worked out on every Mac), formatting, column widths and row heights, merges, rules, filters, charts and pivot tables, and sheets added, renamed, moved or deleted. Rows, columns and cells inserted or deleted on one Mac move what others type at the same time, formulas included, so it lands where they meant it. Two people editing different cells both keep their edits; two editing the same cell at once end with whichever reached iCloud last, the same on every Mac. Undo and Redo take back only your own changes, wherever other people's have moved them to. When the owner renames the spreadsheet, its new name shows for everyone who has it open.
- **Who's here.** Everyone who has opened it shows as a round badge with their initials in the header, with a green dot while they have it open. Each person's Mac says who they are when they open it, so names show even when iCloud doesn't give them. Click a badge to see their name, their email address or phone number when iCloud says it, whether they own it, edit or comment, and when they were last there.
- **Edit or comment.** In the Collaborate sheet the owner sets, person by person, whether each can edit or only comment, and can take anyone out. People who can only comment see every change as it's made, and add comments and replies, but can't change the cells: iCloud itself turns their changes down. Everyone can print a shared spreadsheet and save a copy of it on their Mac (File ▸ Save, Make a copy, or Download), whatever they can do.
- **Comments.** Comments, replies and resolving go to everyone, on their cells however rows and columns have moved since. People edit and delete their own comments; people who can edit can delete anyone's.
- **Notifications.** When someone changes a shared spreadsheet and then does nothing more to it for two minutes, everyone else gets one notification summing it up ("Ana Lopez edited “Budget”: edited 14 cells on Sheet1, inserted a row and added a comment"), not one for every change, even when PuggleSheets isn't open. Clicking it opens the spreadsheet.
- **Offline.** When iCloud can't be reached (the Mac is offline, say), a shared spreadsheet turns read-only and the window says why: you can still read it, comments and notes included, print it and save a copy, but not change it or comment on it. Nothing is kept to send later. As soon as iCloud can be reached again it catches up with what everyone else did meanwhile and can be changed again.
- **Stopping.** Stop Sharing… in the Collaborate sheet takes the spreadsheet out of your iCloud and from everyone it was shared with, and keeps it on your Mac, saved as it was. Anyone who has it open sees it go at once, with a note saying you stopped sharing it. People can also leave a spreadsheet shared with them, with File ▸ Leave shared spreadsheet…. File ▸ Shared spreadsheets lists the spreadsheets shared with you and those you share.

### Files and output

- **Files.** Open and save **Microsoft Excel (.xlsx)** and **OpenDocument spreadsheets (.ods)**, as used by LibreOffice, with our own readers and writers, and **CSV** and **TSV** (with spilled values). Excel and OpenDocument files keep values, formulas, number formats, fonts, colors, borders, alignment, merged cells, column widths, row heights, frozen panes, hidden rows and columns and tab colors; named ranges, data validation (checkboxes travel as TRUE/FALSE lists and come back as checkboxes), conditional formatting (conditions and color scales), filters and the rows they hide, and arrays that spill (saved as array formulas with their values); charts, images (over and in cells), links, pivot tables and filter views; comments, notes, protected ranges, text rotation and groups; and tables, slicers and table references. Alternating colors are saved as cell fills. Files with features PuggleSheets can't keep yet open as an untitled copy with a notice, so the original is never overwritten with a lossy version.
- **Printing and PDF.** File ▸ Print (⌘P) and File ▸ Download ▸ PDF open print settings with a live preview: current sheet, workbook or selected cells; paper size and orientation; normal, fit to width, height or page, or a custom scale; margins; gridlines; page order; alignment; and page numbers, the title, the sheet name, the date and the time in the headers and footers.
- **macOS integration.** Autosave, version history, Make a copy, Rename, Move, and the menus in the macOS menu bar.

Help ▸ Keyboard shortcuts (⌘/) lists every keyboard shortcut.

## Known limits

- Filter views hide rows but don't keep their own sort order; sorting from a filter view sorts the data.
- Protections guard against accidental edits rather than other people: in a shared spreadsheet, anyone who can edit it can change or remove them.
- Collaborating goes through iCloud, so it needs an iCloud account, for you and for everyone you share with, and a copy of PuggleSheets signed to use it (see Sharing through iCloud); when it can't, the Collaborate sheet says why. Edits are merged cell by cell and, for the rest of a sheet, part by part (each column width and row height, the merges, the rules, the filter, the charts…): two people changing the same cell, or the same part, at the same moment end with one of their changes. A comment that two people start on the same empty cell at the same moment shows only one of the two threads.
- A shared spreadsheet opens from iCloud, so it needs the connection to open, and it's read-only while iCloud can't be reached. A change made just before the connection dropped goes once it's back; closing the spreadsheet before then asks first. While a spreadsheet is shared, its copy in iCloud is the one that counts: the file on the owner's Mac follows it, and changes made to that file in other apps are replaced.
- Notifications reach people once they've opened the shared spreadsheet in PuggleSheets, and macOS asks once whether PuggleSheets may show them. Sharing a spreadsheet clears its undo history up to then. Filter views and the open filter view stay each person's own.
- Formulas in Excel tables' calculated columns that use `[#This Row]` or `@` keep their text but don't calculate, and tables have no totals row. `QUERY` has no `count(*)` and ignores `options`.
- The `IMAGE()` function isn't supported, because PuggleSheets doesn't fetch anything from the internet.
- Pivot tables don't have calculated fields or date grouping. Charts don't have trendlines, error bars or the less common types (histogram, candlestick, map, gauge and so on), and can't move to their own sheet.
- Excel and OpenDocument files don't keep data bars, icon sets, top 10, duplicate and above-average rules, or filters by color. Functions that Excel and OpenDocument don't define (such as REGEXMATCH, SPLIT and ARRAYFORMULA) are saved as they are, so other apps show `#NAME?` for them, and Excel shows a spilled array as an `{=…}` array formula.
- Excel files keep their look, but a workbook's default font (such as Calibri 11) is stored on each cell rather than as a default, and indents, gradient fills and print settings aren't kept yet.

## Requirements

- macOS 14 Sonoma or later
- Xcode 16 or later (developed with Xcode 27.2, Swift 6)

## Building and running

Open `PuggleSheets.xcodeproj` in Xcode and run the **PuggleSheets** scheme. Or, from the command line:

```sh
xcodebuild -project PuggleSheets.xcodeproj -scheme PuggleSheets -configuration Debug \
  -derivedDataPath build/DerivedData build
open build/DerivedData/Build/Products/Debug/PuggleSheets.app
```

The app is sandboxed. Debug builds are signed to run on the Mac that built them, unless `Config/Signing.xcconfig` names a team (see Sharing from Xcode below); releases are signed by `Tools/make-installer.sh`.

### Installer

```sh
Tools/make-installer.sh
```

This builds `build/PuggleSheets.pkg`, which installs PuggleSheets.app in /Applications for all users (macOS asks for an administrator's password). The app runs on Apple silicon and Intel Macs with macOS 14 or later.

A local build is ad-hoc signed and the installer is unsigned. That's fine on the Mac that built it, but a copy that arrives by download, email or AirDrop is blocked the first time: the user has to click **Open Anyway** in System Settings ▸ Privacy & Security. To sign with a Developer ID and have Apple notarize the installer, set the variables described at the top of `Tools/make-installer.sh` before running it. Releases built on GitHub are signed and notarized this way when the repository has the Developer ID secrets (see below).

### Releasing a new version

Versions are MAJOR.MINOR.FIX. To release the next one, run this on `main`, up to date with GitHub and with everything committed:

```sh
Tools/release.sh            # a fix:          1.2.3 → 1.2.4
Tools/release.sh minor      # a minor update: 1.2.3 → 1.3.0
Tools/release.sh major      # a major update: 1.2.3 → 2.0.0
```

The script raises the version and the build number in the Xcode project, commits "Release version 1.2.4", tags it `v1.2.4` and pushes both. The tag starts the Release workflow on GitHub, which runs the package tests, builds the installer with `Tools/make-installer.sh` and publishes it as a GitHub release. The installer keeps the same name in every release, so https://github.com/StaticPrime/PuggleSheets/releases/latest/download/PuggleSheets.pkg always downloads the newest one. `Tools/release.sh --dry-run` shows the next version without changing anything.

To sign and notarize releases, add these secrets under the repository's Settings ▸ Secrets and variables ▸ Actions. Without them, releases are published unsigned, with a warning on the run.

| Secret | What it holds |
| --- | --- |
| `DEVELOPER_ID_P12_BASE64` | A .p12 file with the "Developer ID Application" and "Developer ID Installer" certificates and their private keys, base64-encoded (`base64 -i DeveloperID.p12 \| pbcopy`) |
| `DEVELOPER_ID_P12_PASSWORD` | The .p12 file's password |
| `NOTARY_API_KEY` | The text of an App Store Connect API key file (`AuthKey_….p8`), used to notarize |
| `NOTARY_KEY_ID` | That key's ID |
| `NOTARY_ISSUER_ID` | The issuer ID shown above the keys in App Store Connect |
| `DEVELOPER_ID_PROFILE_BASE64` | The Developer ID provisioning profile for iCloud, base64-encoded (see below), which released copies need to collaborate. A signed release stops without it |

### Sharing through iCloud

Shared spreadsheets are kept in iCloud, in the container `iCloud.com.pugglesoft.PuggleSheets`, so only a copy of PuggleSheets signed for that container can share them. Any other copy, like one built from a fresh clone, says so in the Collaborate sheet; debug runs can collaborate through a stand-in for iCloud on the Mac instead (see Tests). To set it up, once:

1. In the Apple Developer account, under Certificates, Identifiers & Profiles ▸ Identifiers, register the iCloud container `iCloud.com.pugglesoft.PuggleSheets`. Then edit the App ID `com.pugglesoft.PuggleSheets`: turn on iCloud, with CloudKit and that container, and Push Notifications.
2. Under Profiles, make a Developer ID provisioning profile for that App ID and the Developer ID Application certificate, and download it.
3. Make the container's schema. iCloud's development environment adds record types as they're first saved, but production only takes what's deployed to it. Either collaborate once from Xcode in the development environment with two iCloud accounts (see Sharing from Xcode below), or add the types by hand in CloudKit Console's development environment, then deploy the schema to production. They're the same as PuggleDocs', so a schema exported from its container (`xcrun cktool export-schema`) can be imported into this one (`xcrun cktool import-schema`):

   | Record type | Fields |
   | --- | --- |
   | `Document` | `info` (Bytes), `revision` (Int64), `snapshot` (Asset) |
   | `Change` | `revision` (Int64), `changeID` (String), `author` (String), `authorName` (String), `change` (Bytes), `changeFile` (Asset, for very large changes like a pasted image or an imported sheet) |
   | `Comment` | `info` (Bytes) |
   | `Presence` | `info` (Bytes) |
   | `Notice` | `title`, `body`, `document`, `owner`, `author` (all String); give `recordName` a Queryable index |

   iCloud's own record of a share, `cloudkit.share`, only appears in the development schema once a share has been saved there, so share one spreadsheet in the development environment before deploying.
4. Add the profile to the repository as the secret `DEVELOPER_ID_PROFILE_BASE64` (`base64 -i PuggleSheets.provisionprofile | pbcopy`). To build a signed installer on your Mac instead, set `DEVELOPER_ID_PROFILE` to the profile's path along with the Developer ID variables before running `Tools/make-installer.sh`.

`Tools/make-installer.sh` then puts the profile inside the app and signs it for the container, the production environment and pushes. To try collaborating, install it on two Macs signed in to different iCloud accounts.

#### Sharing from Xcode

A debug build can collaborate too, once it's signed with the team. Make `Config/Signing.xcconfig` (Git ignores it) with your team's ID:

```
DEVELOPMENT_TEAM = ABCDE12345
CODE_SIGN_IDENTITY = Apple Development
CODE_SIGN_ENTITLEMENTS = Config/iCloud.entitlements
```

Add an Apple ID in that team under Xcode ▸ Settings ▸ Accounts, then build: Xcode makes the development certificate and provisioning profile itself (the App ID needs iCloud and Push Notifications turned on first, as in step 1). If Xcode can't sign in to that Apple ID, make a macOS App Development provisioning profile for the App ID on the developer website, install it, and add `CODE_SIGN_STYLE = Manual` and `PROVISIONING_PROFILE_SPECIFIER = PuggleSheets Development` (the profile's name). Set the team in that file rather than under *Signing & Capabilities*, which would write it into the project for everyone. Debug builds use iCloud's production environment, as installed copies do, so a spreadsheet shared from Xcode reaches someone who installed PuggleSheets. Production only takes the kinds of records already deployed to it: when PuggleSheets starts saving a new kind, and once at the start, add `ICLOUD_ENVIRONMENT = Development` to `Config/Signing.xcconfig`, collaborate on a spreadsheet, deploy the schema to production in CloudKit Console, and take the line out again. `Config/iCloud.entitlements` is `PuggleSheets/PuggleSheets.entitlements` with iCloud's added, so keep the two alike.

While debug builds use the development environment, everyone collaborating has to run a debug build too, since installed copies use production: another Mac building from Xcode with the same `Config/Signing.xcconfig`, or a second account on the same Mac, signed in to another iCloud account, running a copy of the debug build. In a fresh development environment the first summary notification someone is sent adds the kind of record notifications need, so it isn't shown; the ones after it are. Anything iCloud turns down is written to the Mac's log under the Collaboration category, which Xcode's console shows.

## Tests

The spreadsheet model, formula engine, rules, number formats, file formats and the engine that keeps shared spreadsheets the same on every Mac live in a Swift package with 648 unit tests, including randomized checks that incremental recalculation (spilled arrays included) always matches a full one, that damaged files never crash the readers, and that three simulated Macs editing one workbook at random through its log (cells, formulas, layout, rows and columns inserted and deleted, sheets added, renamed and removed, with changes answered at once or late) always end with the same workbook, and a change that didn't come being asked for until it does:

```sh
cd Packages/PuggleSheetsKit && swift test
```

Debug builds also include an end-to-end check that drives a real window and prints `SELFTEST PASS/FAIL` lines. It covers tables, slicers, QUERY, SPARKLINE, LAMBDA and friends, SORTN, notes, comments, protected ranges, groups, rotation, transposed paste and importing, charts (inserting, dragging, resizing, copying and deleting), images, links, pivot tables, filter views, typing with real key events, formulas and recalculation, pointing at cells while typing a formula, undo, formatting, inserting and deleting rows and columns, copy, cut and paste, fill and autofill, merging, sorting, find, freezing, hiding, sheets, automatic row heights, Excel and CSV files, zoom, data validation, conditional formatting, named ranges, spilling, filters, find and replace, shifting cells, data cleanup, dragging the freeze bar, formula help, printing to PDF and OpenDocument files:

```sh
build/DerivedData/Build/Products/Debug/PuggleSheets.app/Contents/MacOS/PuggleSheets -PSSelfTest YES
```

A second suite checks collaboration end to end on a stand-in for iCloud, with simulated people on other "Macs": sharing a spreadsheet (saved first), inviting one person to edit and one to comment, their Mac opening it with the same cells, typing and formulas both ways, a big picture put in a cell arriving whole, rows inserted on one Mac moving what the other types at the same moment, the same cell typed into at once and random edits at once ending the same, undo and redo taking back only this Mac's edits (undoing an inserted row keeping what someone typed below it), the badges and who's viewing, comments, replies and resolving both ways and comments moving with rows, taking someone down to commenting (their changes turned down, their comments still arriving), summary notifications after a quiet spell, going offline (read-only with a note saying so, typing, commenting, inserting rows and undo changing nothing, catching up once iCloud's back, and a change made as the connection dropped going once it's back), renaming, stopping sharing (the spreadsheet kept here, gone for the others), and a spreadsheet someone else shares opening read-only (comments allowed, typing and inserting rows changing nothing, their edits, comments and pictures arriving live, a change iCloud passes over while reading still arriving with the ones after it, printing, downloading and copying allowed, and the window saying so and closing when they stop sharing), and invitation links pasted in:

```sh
build/DerivedData/Build/Products/Debug/PuggleSheets.app/Contents/MacOS/PuggleSheets -PSSelfTest YES -PSSelfTestSuite collaboration
```

Other debug launch arguments: `-PSSampleDocument YES` fills new spreadsheets with a sample budget, a Tracker sheet with rules, a chart, an image and a filter view, links and an image in a cell on the Notes sheet, a pivot table, and an Orders sheet with a table, a slicer, sparklines and QUERY and MAP formulas. `-PSSnapshot name.png` saves a screenshot of the first window (or its open sheet) to the app's temporary folder and quits. Combine it with `-PSWindowWidth`, `-PSZoom`, `-PSSheet name`, `-PSSelect A1:C5`, `-PSType text` (starts typing into the active cell), `-PSFormulaBarEdit YES`, `-PSFind text`, `-PSOpenSheet shortcuts`, `-PSShowAbout YES`, `-PSSidebar conditionalFormatting` (or `dataValidation`, `alternatingColors`, `namedRanges`), `-PSFilterColumn 2` (opens a filter popover), `-PSFindReplace text` (with `-PSReplaceWith`, `-PSReplaceAll YES` and `-PSSnapshotPanel YES`), `-PSPrintSettings YES`, `-PSSelectObject YES`, `-PSChartEditor YES`, `-PSPivotEditor YES`, `-PSFilterView YES`, `-PSLinkEditor YES`, `-PSShowNote YES`, `-PSCommentCard YES`, `-PSShowProtected YES`, `-PSShowFormulas YES`, `-PSSidebar comments` (or `protections`, `columnStats`), `-PSTableSettings YES`, `-PSSlicerEditor YES`, `-PSWritePDF name.pdf` or `-PSWriteFile name.xlsx` (saves the workbook to the temporary folder) to check layouts. `-PSBenchmark YES` fills a sheet with 100,000 cells and prints how long recalculating, drawing and editing take. `-PSStandInCloud YES` collaborates through the stand-in for iCloud, and with `-PSCollaborationDemo YES` too the window's spreadsheet is shared with two simulated people who open it, type and comment (add `-PSOpenSheet collaborate` for the Collaborate sheet, or `-PSDemoOffline YES` to show it while iCloud can't be reached).

## Project layout

```
PuggleSheets/               macOS app target (files are picked up automatically by Xcode)
  App/                      Entry point, app delegate, debug-only sample and self-tests
  Collaboration/            Sharing through iCloud: each shared spreadsheet's session, iCloud, the Collaborate sheet,
                            the badges, and a stand-in for iCloud for debug runs
  Document/                 SpreadsheetDocument (NSDocument)
  Editor/                   SpreadsheetController: edits, undo, clipboard, fill, sort, structure, rules,
                            cleanup, find and replace, print layout
  Grid/                     The grid view: layout, drawing, keyboard, mouse, the cell editor
  UI/                       Window controller, SwiftUI header, toolbar and sheet bar, formula bar, menus,
                            sidebars, dialogs, formula help, print settings
  Resources/                Asset catalog (app icon, About window logo)
Packages/PuggleSheetsKit/   Spreadsheet model, formula engine, number formats and file formats (no UI)
  Model/                    Cells, ranges, formats, sheets, workbooks, date serials, rules, objects, charts,
                            pivot tables, filter views, links, comments, protections, groups, tables,
                            slicers
  Formula/                  Parser, evaluator, functions, recalculation, reference rewriting, rules, pivot tables
  Charts/                   Chart data and drawing (Core Graphics), PNG, PDF and SVG export
  Formats/                  Number format patterns, cell display, typed-input recognition
  IO/                       ZIP, XLSX, ODS and CSV/TSV readers and writers
  Editing/                  Workbook-wide edits (rows, columns, sheets) that rewrite formulas
  Collaboration/            Shared workbooks' ops, rewriting them to follow each other, the log client, snapshots,
                            iCloud records and summaries
Config/                     Signing for debug builds (see Sharing from Xcode)
Tools/make-icons.swift      Regenerates the app icon PNGs
Tools/make-installer.sh     Builds the PuggleSheets.pkg installer
Tools/release.sh            Releases the next version (see Releasing a new version)
```

## How it works

- **The grid** is one custom view that draws only what's on screen: the headers, up to four panes (frozen corner, frozen rows, frozen columns and the scrolling area) and the selection on top. Row and column positions come from `AxisLayout`, which stores only the rows and columns whose size differs from the default, so finding row 900,000 is a binary search, not a loop.
- **Sizes** are in pixels: a column is 100 and a row 21 at 100% zoom, where a pixel is a point. Fonts keep their point sizes as a browser shows them (96 dpi), so Arial 10 is 13.33 pixels tall.
- **Cells** are stored sparsely: a sheet keeps only cells with content or formatting. A cell holds its value, its formula text and its format; a formula's value is its latest result.
- **Recalculation** is incremental: the formula engine keeps a dependency graph and recomputes only the formulas that depend on what changed (plus volatile ones like `NOW()`), in dependency order and without recursion, so long chains can't overflow the stack. With 40,000 formulas, an edit recalculates in well under a millisecond.
- **Text** in cells is laid out once with Core Text and cached, so scrolling redraws a full window of cells in a few milliseconds.
- **Number formats** use the standard spreadsheet pattern language (`#,##0.00`, `0%`, `"$"#,##0`, `M/d/yyyy`, `[h]:mm:ss`, sections, colors and conditions), parsed once and cached, with no system formatters involved.
- **Excel files** are read and written with our own ZIP and XML code; worksheets are streamed, so 100,000 cells load in a fraction of a second.
- **Edits** are recorded as the cells (or sheet layout, or whole workbook for structural edits) they replace, so undo and redo restore exactly what was there, along with the selection.
- **Inserting or deleting rows, columns, cells or sheets** rewrites every formula, rule and named range that refers to them; references to deleted cells become `#REF!`.
- **Rules** (conditional formatting, data validation and filters) share one set of conditions, evaluated by the formula engine, so a custom formula rule works like a formula in a cell. The grid evaluates rules for the cells around what's on screen once per edit, so scrolling stays fast.
- **Spilled values** are kept beside the cells, not in them: the engine records which formula spilled where, so editing a cell in the way shows `#REF!` on the formula, and clearing it lets the array spill again.
- **Printing** draws pages with the same code that draws the grid, so what you print matches the screen; PDFs are written page by page with Core Graphics.
- **Charts and images** float over the grid, anchored to a cell with an offset and a size in pixels, so they move with inserted and deleted rows and columns. Charts are drawn with Core Graphics from their data on every redraw, so they always match the cells.
- **Pivot tables** are computed by the formula engine and placed like an array formula's spilled values, so they update incrementally and show `#REF!` if data is in the way.
- **Collaboration.** A shared spreadsheet is two zones in its owner's iCloud. The document zone holds a snapshot of the whole workbook now and then, and its log: one record per revision, each one change, named for its revision so that only one change can ever take it. A change is a list of ops: cells set to values (comments aside), parts of a sheet's layout set to values (each column width and row height on its own), rows, columns or cells inserted or deleted, and sheets added, removed, renamed or moved. Every Mac applies the same ops in the log's order the same way, with the workbook's own editing code, so every Mac ends with the same workbook. Each Mac keeps the log's workbook and its own changes not yet in; when another Mac's change gets in first, the waiting changes are rewritten to follow it (cells typed below inserted rows move down, formulas and ranges follow, deletions skip what's gone) and the workbook is made afresh from the log's, or, when both only set values, the incoming change is applied minus what the waiting changes set. That zone is shared with each person as edit or read-only, so iCloud itself refuses changes from people who may only comment. The talk zone, which everyone in the spreadsheet can write to through a link kept in the document zone, holds the comments (each placed on a cell at a revision of the log, followed through the rows and columns inserted and deleted since) and who has it open. While a spreadsheet is shared, undo steps are the ops that take an edit back, rewritten as other people's changes arrive. Each person's Mac also keeps an inbox zone shared by link with the people they work with, who leave a short summary there after a quiet spell; a subscription on it makes iCloud show the notification.

## Contributing

Bug reports, ideas and pull requests are welcome. Before your first pull request is merged, you sign the [PuggleSoft Contributor License Agreement](CLA.md) by posting one comment, and a bot walks you through it. See [CONTRIBUTING.md](CONTRIBUTING.md).

## License

Copyright © 2026 PuggleSoft.

PuggleSheets is free software: you can redistribute it and/or modify it under the terms of the GNU General Public License, version 3, as published by the Free Software Foundation. It is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See [LICENSE](LICENSE) for the full terms.
