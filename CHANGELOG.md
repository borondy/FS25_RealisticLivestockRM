# Changelog

## v1.3.0.0-dev.5

### Fixed
- Multiplayer: a mother's post-birth recovery now counts down live for connected players instead of appearing stuck as "recovering" (which had wrongly blocked inseminating her again until a relog).
- Fixed FPS stutter when switching the active implement (G) in some instances - the animal-visibility settings dialog now loads once per session instead of reloading on every switch.

## v1.3.0.0-dev.4

### Fixed
- Multiplayer: husbandry log messages (animal buy/sell/move, births/deaths, and daily summaries) now appear live for connected players instead of only after rejoining.
- Multiplayer: DLC animals (e.g. Highland Cattle) whose DLC is installed but not active in the session are no longer loaded, preventing them from showing as the wrong breed/gender - or being corrupted when bought - for players without the DLC.
- Multiplayer: inseminating a female from the animal menu now works on dedicated servers and clients (previously it silently did nothing on the server - no pregnancy resulted and a straw was wasted); straw counts now stay in sync across all players.

## v1.3.0.0-dev.3

### Changed
- The old built-in herdsman automation (from before the new Herdsman menu) no longer runs or charges wages on saves where it was left enabled, and its now-inaccurate on-screen warning is hidden. Set up rules in the new Herdsman menu to automate your herd.

### Fixed
- Fixed cows producing no milk on Hof Bergmann v1.4 cow pastures: all cow breeds now produce milk cans.

### Documentation
- Added user guides for Saved Filters and Herdsman automation - how to build reusable animal filters and set up daily herd-management rules.

## v1.3.0.0-dev.2

### Added
- Herdsman: a move rule can now target a butcher (Extended Production Point); animals outside the butcher's age range are skipped and reported.
- Dev builds now log a "legacy-tripwire" error if anything still opens the legacy animal screen, to catch leftover paths before it is removed (expected on dev/tester builds; gone by the stable release).

### Changed
- RL Menu now has a default hotkey (Right Shift + O) and a cleaner input-binding name; existing installations need to bind or reset the key manually.
- Walking up to one of your own animal pens, approaching an animal dealer on foot, or opening the animal screen from the in-game menu (R) now open the RL Menu instead of the legacy animal screen.
- Driving a loaded livestock trailer to a butcher now opens the RL Menu with an individual-animal delivery view instead of the legacy cluster-style screen.

### Fixed
- In multiplayer, quickly triggering two animal trades of the same kind (buy, sell, or move) could affect the wrong animals or leave the menu stuck - trades now run one at a time with a "trade in progress" notice and a timeout recovery.
- A declined semen purchase (e.g. not enough money) no longer uses up dealer spawn space, so repeated declined attempts can't eventually make valid purchases fail with a "no space" message.
- Herdsman task editor: the green slider on the Mark / Naming convention / Budget type toggles no longer lands on the wrong option after switching between tasks with different actions (display-only glitch; the stored setting was always correct).

## v1.3.0.0-dev.1

### Added
- "Animal Country of Origin" setting (RL Menu -> Settings -> General): choose the country new animals are registered in (ear tags, identifiers) or keep the map default. New animals only - existing animals keep their country. Admin-only in multiplayer, saved per savegame.

### New RL Menu
- All mod settings now live in the RL Menu's Settings tab; the in-game menu's Settings page shows a single "Realistic Livestock Settings" button that opens it (the 17 duplicated rows are gone).

### Improvements
- Breeding ages now better match real livestock: goats breed from 8 months (was 16), horse stallions from 24 months (was 36).
- Hens now stop hatching chicks by about 5 years (previously ~10); roosters now retire at 6 years (previously bred for life).

## v1.2.6.0

### RL Menu (preview - work in progress)
- Livestock trailers now load and unload in the RL Menu instead of the legacy animal screen.
- At a pen: walk up to a parked livestock trailer to move animals between the pen and the trailer.
- At the dealer: with a trailer present, the Buy tab buys animals straight into the trailer and the Sell tab sells straight from it.
- Out in the world: walk up to a standalone parked trailer to load loose horses into it and unload them back out.
- Multiplayer: trailer transfers run server-side through the same events the legacy screen used, so they sync to all players, including on dedicated servers.

### Herdsman automation tasks (preview)
- New Herdsman tab in the RL Menu: create, duplicate, and delete named automation tasks. Each task runs one action - sell, buy, castrate, naming, AI insemination, or move - on the animals matched by one of your saved filters, across the pens you choose.
- Task editor: set a name, enable or disable the task, configure its options (animals per day, budget, naming convention, AI semen choice), and choose whether the task marks matching animals for review or performs the action outright. Per-row help tooltips explain each option.
- Pick the filter and target pens from inside the editor: the filter list is scoped to the task's action (buy draws from the dealer pool; sell, castrate, and AI from your own herd) and the pen list to the filter's animal type. A task needs a filter and at least one pen to be enabled, so incomplete drafts can be saved disabled.
- Tasks run automatically on each day-change, server-side, in order (sell -> buy -> castrate -> naming -> AI -> move), respecting each task's animal cap, budget, and the destination pen's free space. A herdsman wage is deducted per farm.
- Day-change notifications: the herdsman posts the same per-pen messages the legacy herdsman did (sold, bought, castrated, named, inseminated, moved, or "marked for ..."), folded into daily counts when message summary mode is on.
- The menu-based tasks run alongside the legacy per-pen herdsman, not instead of it. An orange banner warns when a pen still has the legacy herdsman enabled - avoid running both for the same pen, or actions and wages get applied twice.
- Multiplayer: task create / edit / delete sync to all players and an open menu refreshes live; the day-change actions replicate to clients, including on dedicated servers.

### Fixed
- Goats now show milk (not wool) production in the animal genetics overview, across the RL Menu, the legacy info dialog, and the on-foot look-at panel.
- Pregnancies now track each animal's configured gestation period much more closely, especially at higher days-per-period settings where they previously ran too long (contributed by borondy).
- Young animals now grow to full size over their proper age range instead of maturing far too fast at higher days-per-period settings (contributed by borondy).
- Multiplayer: settings changed in the RL Menu (Settings -> General) now sync to the server, persist across save/reload, and update live for other players - previously these changes were silently lost on dedicated servers.
- Hardened against a possible crash when a mod or game code path looked up a missing (nil) text label - the lookup now falls back safely instead of stopping the game, and logs a warning.

### Compatibility
- FS25_AnimalFoodCalculator is now a blocking conflict instead of a dismissible warning - it breaks RLRM's animal feeding and milk/egg/wool output, so the game stops and prompts a restart to disable it.

### Translations
- Danish: the herdsman sell tooltip now shows the specific sell age again instead of a vaguer phrasing that dropped it.
- French: translated the new herdsman task editor, filter editor, daily-summary, mod-compatibility, and saved-filter strings that were still showing in English (contributed by squall39).
- German: the animal-move confirmation no longer shows a leftover price that the other languages never displayed.
- Italian: native-speaker refresh across the menu, settings, and help text, plus the herdsman move strings that were still showing in English (contributed by FirenzeIT).
- Turkish: filled in the many menu, herdsman, settings, and message strings that were still showing in English (contributed by Cyber-Syntax).
- All languages: new filter and herdsman labels now fall back to English instead of showing raw text codes in languages that have not translated them yet.

## v1.2.5.0

### Added
- Mod compatibility bridge: RLRM can now coexist with some foreign mods that overlap its hooks, via per-mod shim files in `mod_support/<ModName>/` (same layout as the map-support bridges). The framework activates automatically when a registered foreign mod is detected; shim files self-disable cleanly when their target mod is absent, with no impact on RLRM-only setups.

### Improved
- Hereford calves now use the breed-accurate red-and-white coat (adults shipped in 1.2.4.0; UV-layout tip from [MA] BavarianRedneck).

### Compatibility
- Seasonal Wool Production (Argsy Gaming): RLRM + SWP now coexist without the previous double-production of wool. SWP handles wool as a seasonal event with a single output per sheep per season; per-pen yield matches vanilla SWP based on flock size (mature sheep aged >= 8 months). Trade-off: wool yield does not reflect RLRM per-animal genetics.

### Documentation
- Hof Bergmann support page + FAQ: the HB bull stable's BULLSPERM trigger stays empty under RLRM (HB models bull sperm as a milk output; RLRM only produces milk for lactating female cows). HB pasture bulls remain decorative.

### Fixed
- Selling or buying animals via a livestock trailer at the dealer no longer logs `Error in AnimalSellEvent` / `Error in AnimalBuyEvent ... missing method 'addRLMessage'`. The sales themselves always completed.
- Multiplayer: animal lists no longer show wrong breeds or species on clients missing a DLC the server has installed (e.g. Highland Cattle rendering as Water Buffalo). Server data was always correct; only the receiving client misrendered.
- Multiplayer: player-initiated insemination from non-host clients now propagates to the server and other clients within one network frame (previously applied locally only).
- Empty dewars (0 straws remaining) no longer survive save/load or storage round-trip; they self-delete on the server in every code path. Affected saves clean up on next load.
- Newborns of the same farm no longer inherit "Children" counts from another species' male with the same identifier (e.g. a Texel ram showing 61 children due to a rooster collision). Existing bogus counts are not auto-cleaned.
- AI insemination "not enough money" check now correctly blocks dewar purchases priced above farm balance (both RL Menu AI tab and the legacy R-key flow).
- Artificial Insemination dialog: the Inseminate button now enables/disables per selected dewar instead of staying latched to the first row.
- Per-visual `canBeBought="false"` on animal sale stages now takes effect at the dealer (previously silently ignored). Packs can restrict a breed to juvenile-only or adult-only sales; default bundle behavior unchanged.
- Pen no longer overflows past capacity when multiple pregnancies mature on the same day-change. Existing overcap saves heal gradually via natural deaths or sold animals.
- Defensive pregnancy backfill on legacy / orphaned saves now uses the mother's quality for offspring of mothers missing `impregnatedBy.quality`, instead of nil. Normal pregnancies were always correct.
- Quick filter dialog no longer silently applies a "Healthy animals only" filter on open + OK; the disease filter now defaults to any.
- Quick filter dialog polish: added a title, aligned the scrollbar inside the dialog body, stopped clamping slider ranges to a previously-applied filter, and fixed option rows drifting to the wrong segment or slider thumb after scrolling. Applies to both the new RL Menu and the legacy R-key screen.
- Quick filter persistence is now tab-local and shown in the chip ("QF" alone or combined with a saved-filter name); it clears automatically when you leave the tab.
- Settings -> General is now admin-only end-to-end. Non-admin players could previously edit most rows; changes would revert or briefly affect the server.

### RL Menu (preview - work in progress)
- Saveable Filters are now editable in-game from Settings -> Filters. All engine field types supported (numeric, boolean, gender, subType, name); multi-value "in" / "not in" via a Select Values dialog; cross-species matching when Animal type = ANY. Out-of-range numeric values are rejected with a visible hint.
- Saveable Filters gain a per-screen "Show on" axis (All / Owned-herd / Dealer) so the F-cycle stays uncrowded once you have several filters.
- Quick Filter dialog gains a Save filter button that turns the current dialog state into a new saveable filter and opens Settings -> Filters on the new row. Price conditions cannot be saved and are dropped with a warning.
- Settings -> Filters: New filter / Duplicate now picks the next free suffix as max existing N + 1, so names no longer collide after deleting earlier-numbered entries. Saved-filter cards now use the dealer-card visual style so more fit on screen.
- Multiplayer: filter create / rename / delete now refresh peer Info / Buy / Sell / Move tabs live, no menu reopen needed.
- Animal Dealer now opens the new RL Menu (Buy tab) at the shop counter and on walk-up; trailer loading still uses the legacy screen.
- Pen Info and Move tabs now estimate feed runway in the "Total Capacity" row: a `(~N-Mm)` range shows how many in-game months the current feed lasts, accounting for lactation, gestation surge, scheduled births, and per-animal metabolism. The capacity bar and text turn red when the runway drops below 2 months.
- RL Menu tab and header icons now render at the proper size (previously about half base-game size).

### Herdsman automation rules (preview - backend groundwork, no in-game UI yet)
- Foundation for upcoming saveable Herdsman rules that pair a saved filter with an automated operation (sell, buy, castrate, naming, or AI) across chosen pens. Rules persist across save/load in rm_RlSettings.xml; a corrupt or hand-edited rule record is dropped safely on load. Multiplayer: rule add / edit / delete propagate to all players, and a player who joins mid-session receives the server's full rule set on connect.

## v1.2.4.0

### Added
- Map support: Le Mechet by MA7Studio (https://farming-simulator.com/mod.php?mod_id=357964) - four French cow breeds (Charolaise, Montbeliarde, Simmental, Vosgienne) with bull variants; full breeding, genetics, and reproduction; per-breed pricing, milk curves, and reproduction signatures preserved from the map's source XML.
- In-game warning when two map bridges or animal packs replace the same animal type's husbandry. The second one wins and the first one's animals can become invisible (ghost animals); RLRM now shows a dismissible warning at mission start so the cause is visible instead of silent.
- Witcombe Park Farm 1.3.0.0 (v4) now loads cleanly with the existing map bridge.

### Improved
- Hereford adult cow and bull skin updated to a more breed-accurate red-and-white coat. Texture contributed by [MA] BavarianRedneck.
- French translation refreshed by community contributor @squall39 (PR #83): native-speaker corrections to existing strings and translations for the new RL Tabbed Menu strings (Messages, Info, Move, Sell, Buy, AI tabs).
- User guide cattle milk chart now reconciles with the breed-range table; footnote spells out which factors compose into the table range (chart is the lifetime age envelope; the table folds in lactation-phase factor and genetics multiplier).

### Fixed
- Finance overview now shows "Medicine" for animal medicine costs instead of the `Missing 'finance_medicine' in l10n_en.xml` fallback.

### Compatibility
- Le Mechet is NOT compatible with the Cow Breeds Pack for RLRM (FS25_CowBreedsRLRM) unless you use the latest development version of the Cow Breeds Pack - both replace the cow husbandry config and only one can win. Use Le Mechet alone, or pair it with the latest dev Cow Breeds Pack. The new in-game warning will fire if you load both together.
- Hereford is removed from the dealer when Le Mechet is the active map.

### RL Menu (preview - work in progress)
- Added saveable animal filters: define filters that match on age, gender, pregnancy, lactation, genetics, subtype, weight, health, marks, and name, nested with AND/OR groups; filters persist across sessions in the savegame. For now filters are authored by hand-editing rm_RlSettings.xml - the in-game editor ships in a future release.
- Press F on Info / Buy / Sell / Move tabs to cycle through saved filters; the active filter shows as a chip on the tab. Filter selection is shared across Info / Move / Sell; Buy keeps its own selection per dealer flow.
- Multiplayer: filter create / update / delete sync across all connected players (admin or tradeAnimals permission required); late-joining clients receive the full filter set on connect.
- Added Settings tab with two subtabs: [General] surfaces the existing RL settings (now editable from both the new menu and the legacy GAME SETTINGS page, reordered into thematic groups - Mortality, Health & Disease, Husbandry & Economy, Custom Animals, Message Log, Display Preferences, Tools & Admin), and [Filters] lists your saved filters (read-only view today; in-game editor in a future release). Toggling a setting on either General page reflects on the other when re-opened.
- Added Filter Hand-Crafting reference page in the user guide for power users authoring saveable filters in rm_RlSettings.xml until the in-game editor lands.

## v1.2.3.0

### Added
- Non-blocking startup warning for known-trouble mods: dismissible dialog at game start with a link to the new Mod Compatibility reference page; hard-conflict mods are unchanged.
- Breeding Reference page in the user guide: per-breed table of female and male breeding ages, gestation, and peak litter sizes across all base species.
- Support-log diagnostics for lag triage and bug reports: per-pen timing summaries for day-change/cluster-update/visual-update/buy operations, an `rlDumpSettings` console command, and a one-time startup dump of active RL settings (set log level to DEBUG to see timing detail).

### Improved
- Bulk animal operations (move, sell, buy, AI sell) and multiplayer sync of reproduction/death cycles: large herds no longer freeze the game; clients receive a single update per affected husbandry instead of one per animal; day-change with simultaneous births collapses to one cluster-update per pen.
- Pregnancy food and water consumption now caps at 2x the non-pregnant baseline (previously sows with large litters reached 4-9x during late gestation; cattle and sheep with typical litters are unaffected). Builds on contributor PR #72 - thanks @borondy.

### Fixed
- Multiplayer hard-conflict dialog now fires on every peer; pure clients connecting to a host with a known-conflict mod are returned to the main menu instead of silently entering a broken session.
- Pregnant and lactating cows/goats now actually drink more water - the multiplier was being computed but silently discarded.
- Pregnancy state occasionally clearing the pregnant flag inconsistently after an internal cleanup; affected pregnancy sync across multiplayer peers and sale animals at the dealer.
- Multiplayer error that left pig and horse pregnancies unsynced to clients (both natural conception and AI-straw insemination would appear to succeed on the host but never replicate to other players).
- Multiplayer crash on per-animal load/unload from the trailer animal screen: clicking the single-row load button crashed the client and corrupted the move packet on the server. Multi-select bulk was the only working path until now.
- Rabbits on Witcombe never getting pregnant: the Witcombe bridge now ships a fertility-by-age curve for the RABBIT type.
- Witcombe Highland Cattle rendering as a small Angus calf at all ages and Witcombe Herefords rendering as Limousin-coloured Angus instead of the white-face Hereford. Witcombe's custom Hereford dealer-menu thumbnails are preserved.
- Jersey cows on Witcombe showing the marker spray and monitor collar permanently regardless of actual state; same fix applies to Witcombe-bridge sheep and pig breeds (Texel / Suffolk / Blue-Faced Leicester rams, Gloucestershire Old Spot boar) and Hereford bulls.
- Marker tool no longer crashes on Jersey or Highland (added cream and auburn marker colours; unregistered breeds fall back to white).
- RL Menu Messages tab not clearing the per-pen unread flag on open; existing saves with stuck unread flags will auto-heal the first time you open the Messages tab.
- Redundant "animals changed" notifications firing multiple times per mutation.
- User guide accuracy: Witcombe Hereford peak (the value at 18 months is not the peak; the peak is at 24 months), PED disease fatality framing (time-since-infection rather than age-when-infected), and lactation-bonus wording.

## v1.2.2.0
- Added Witcombe map support: new UK breeds (Jersey, Gloucestershire Old Spot, Texel, Suffolk, Blue Faced Leicester) with full breeding, genetics, and reproduction; rabbits get viable weights, litter sizes, and consumption rates; automatic version-aware compatibility
- Hereford on Witcombe now uses a heritage breed profile: 9-month gestation, premium pricing (300/3000), and an 18-month sell-price peak
- Info tab genetics now show a 0-99 score next to each label (e.g. "97 - Extremely high") so animals within the same bucket can be compared at a glance
- Fixed singleplayer: RL Messages tab now shows "Bought/Sold N animal(s) for €X" entries after buying or selling (previously these entries only appeared in multiplayer)
- Fixed potential multiplayer crash when changing monitor, name, or disease treatment on an animal while the husbandry is being sold or demolished
- Fixed multiplayer: insemination result notification to clients no longer reports success when the insemination actually failed

### RL Menu (preview - work in progress):
- Added Buy tab: browse dealer animals, see per-row prices and a running cart total, then buy one or many at a time via a destination-picker flow
- Added Artificial Insemination tab: browse dealer bulls by species, pick a straw quantity with live price preview, favourite bulls, and buy straws without leaving the menu
- Fixed multiplayer: Sell and Info tabs now refresh the farm balance display immediately instead of showing a stale value until the next action

## v1.2.1.0
- Added multiplayer support for "Reset Animal Dealer" and "Reset AI Animals" buttons (admin-only in MP, syncs to all players)
- Fixed multiplayer: straw pickup from dewar now syncs to server (dewar no longer "refills" on reconnect)
- Fixed multiplayer: empty straw hand tool now deleted from client inventory after insemination or return
- Fixed animal mark/unmark: 3D visual marker now updates immediately when unmarking (previously required relog)
- Fixed potential multiplayer crash when receiving unknown mark keys from newer mod versions
- Fixed straw hand tool crash when no player is carrying it
- Fixed crash when selling an animal from a livestock trailer at the animal dealer
- Fixed crash when opening the animal trailer screen near a rideable horse created by third-party mods (e.g. AdditionalContracts animal missions)
- Fixed prop horses from third-party mods being incorrectly converted to real animals when loaded onto trailers or into pens
- Fixed animals marked as non-sellable being sellable after loading onto a trailer

### RL Menu (preview - work in progress):
- Added Sell tab with shopping cart summary (selected count, price, fee, total); animals marked as non-sellable are filtered out
- Husbandry selector now sorted alphabetically by name
- RL Menu now remembers selected husbandry and animal when switching between Manage, Move, and Sell tabs
- Single sell/move no longer clears other checkbox selections
- Renamed "Info" tab to "Manage" to better reflect its actions (mark, inseminate, monitor, etc.)
- Reordered tabs: Sell, Move, Manage, Messages
- Fixed status icons jumping position when switching between tabs
- Fixed animal age not showing in the RL Menu stats area

## v1.2.0.1
- Fixed deprecated fillUnit warning in game log for semen dewar

## v1.2.0.0
- Rewrote semen dewar as a vehicle/pallet - fixes game freeze when looking at dewar, multiplayer pickup failures, and invisible dewars after mid-game purchase
- Dewar state (straws, bull genetics) now persists through save/load and object storage cycles
- Fixed crash in third-party mods that inspect stored pallets (e.g. Time Saving Stock Check) when a semen dewar is placed in object storage
- Fixed multiplayer desync: mark, castrate, monitor toggle, rename, and disease treatment changes from a client now sync to all other connected players
- Fixed all pre-existing animals getting the same identity (e.g. "UK 1 1") when installing RL on an existing save for the first time - also self-heals saves already affected
- Added Czech translation update (community contribution by Kynuska)
- Added Hungarian translation (community contribution by Toamsz93)
- Added missing translation keys across all 16 languages
- Fixed fillType errors in log when third-party selling station mods reference the ANIMAL category

### New RL Menu (preview - work in progress):
- Added new RL Menu (assign key in Settings -> Controls): a standalone tabbed menu. The legacy animal screen (R key) still works unchanged
- Messages tab: chronological message feed with single and bulk delete
- Info tab: husbandry selector, animal list with detail pane (pedigree, genetics, diseases, inputs/outputs), and action buttons (Mark, Monitor, Rename, Diseases, Inseminate, Castrate)
- Move tab: move animals between husbandries or to butchers with single-move and bulk-move using checkbox multi-select
- Status icons on animal list cards showing pregnancy, recovering, infertile/castrated, lactating, producing wool, and laying eggs at a glance

## v1.1.4.0
- Fixed horse breed visuals on Hof Bergmann: adult horses no longer display as foals, breed colors now match correctly, foal-to-adult model transition now works
- Fixed horse riding and equipment on Hof Bergmann v1.4: saddles, carriages, and tools from the Horse Addon Pack now attach correctly
- Disabled four horse breeds not natively supported by Hof Bergmann (Pinto, Chestnut, Bay, Dun) from the dealer - existing savegame horses of those breeds are unaffected
- Fixed dealer generating sale animals for breeds marked as not purchasable on the current map
- Fixed wool not spawning on Hof Bergmann v1.4: bridge now remaps WOOL to SHEEPWOOL_SHEARED to match HB's husbandry buildings
- Fixed chicken eggs not spawning on Hof Bergmann v1.4: bridge now remaps EGG to EGG_HB to match HB's husbandry buildings
- Fixed Hof Bergmann egg incubator failing to add hatched chicks to husbandry when RLRM is active
- Fixed crash when animal output curve returns nil, which could silently stop all production in a building
- Fixed bridge output overrides replacing valid production curves with empty ones when only the fillType needed remapping
- Fixed Hof Bergmann user guide with horse breed availability, riding notes, and wild duck clarification
- Added diagnostic logging for fillType mismatches in pallet and milk output

## v1.1.3.0
- Fixed bridge animals (rabbits, quail, etc.) getting duplicate IDs in multiplayer, causing animals to disappear on clients
- Fixed bridge animal ID counter, now tracks per-type counters with savegame persistence
- Fixed bulk buy silently failing when map husbandries reject animal breeds (e.g. Hereford in Hof Bergmann filtered pens)
- Existing saves with duplicate bridge animal IDs are automatically repaired on load
- Added pre-validation for bulk buy: shows which animals can't be purchased and why before confirming
- Added diagnostic logging for animal loading, breeding, and pack compatibility troubleshooting
- Added warnings when animals are lost due to removed packs or breed mismatches

## v1.1.2.0
- Added animal pack system: third-party mods can add breeds, override animal properties, or provide custom balance via rlrm_pack.xml
- Added Hof Bergmann 1.4 support with alpacas, quail, corrected chicken visuals, and version detection
- Added cross-color alpaca breeding (any male color can breed with any female color)
- Added user documentation for Hof Bergmann map support (exotic animals, known limitations, FAQ)
- Added: Exiting the RL animal screen returns to ingame menu animals tab when opened from there
- Added: RL animal screen opens on the Info tab by default when entered from ingame menu animals tab
- Fixed: Animal list scroll position jumping every 5 seconds in the ESC menu animals tab
- Fixed: Click sound playing every 5 seconds while viewing animal list
- Fixed: Crash when husbandry doesn't register a pallet or milk fillType that its animals produce
- Fixed: Animal model accumulation when maps redefine existing animal types
- Fixed: Base game reloads no longer clobber RLRM's superset animal configs
- Fixed: Random death money compensation (33% sell price) now correctly reaches farm balance
- Fixed: Bridge animal descriptions showing "Missing" in animal info dialog
- Fixed: Pig ear tag errors on Hof Bergmann maps
- Fixed: Sale animals of non-reproductive subtypes (e.g. bulls, dogs) could incorrectly become pregnant
- Fixed: Bridge animals' offspring could receive wrong breed when using non-standard subtype layout
- Fixed: Map-defined subtypes for existing animal types not loading alongside base game configs
- Improved Italian translation (community contribution)
- Improved German translation (community contribution)
- Internal refactoring: split Animal.lua into focused modules (reproduction, health, persistence, serialization)

## v1.1.1.0:
- Added version-aware map support: detects installed map version and loads the matching configuration
- Added warning dialog when an untested map version is detected (with link to report issues)
- Added breed and visual override support for map-based animal subtypes
- Fixed division-by-zero risk in horse riding fitness calculation at boundary threshold values
- Fixed horse riding value not being clamped (could accept values outside 0-100 range)
- Fixed male animals could theoretically become pregnant (missing gender guard in reproduction check)
- Fixed AI herdsman castrate notifications showing "marked for castrating" instead of "castrated" when in execute mode
- Fixed AI herdsman state tracking error after auto-buying animals
- Fixed BUM ID branding on cows showing all zeros and overlapping text

## v1.1.0.3:
- Fixed selected animal jumping to a different animal in the in-game animal menu

## v1.1.0.2:
- Fixed crash on Messages tab caused by unrecognized message IDs from older dev versions
- Invalid messages are now discarded on savegame load and handled gracefully in the UI

## v1.1.0.1:
- Fixed crash when moving animals between pens (nil subtraction on visual animal count)

## v1.1.0.0:
- Added Move tab for transferring animals between husbandries with destination picker and bulk move
- Added custom icons for all Animal Screen tabs
- Hidden castration tab in herdsman screen for chickens (not applicable)
- Fixed visual glitch in herdsman screen when enabling castration
- Internal refactoring for code quality and testability

## v1.0.2.0:
- Added genetics display in animal names (average score, or full breakdown per trait)
- Added sort by genetics option for animal lists
- Added selection count on bulk action buttons
- Fixed move messages in husbandry message log (were silently failing due to incorrect message keys)
- Fixed move messages showing wrong direction (to/from was swapped)
- Fixed typo in move message ("1 animals" -> "1 animal")

## v1.0.1.1:
- Fixed compatibility with Hof Bergmann's subtype filter for animal pens

## v1.0.1.0:
- Add Hof Bergmann map support - exotic animals (ducks, geese, cats, rabbits) now support full breeding and reproduction
- Add basic support for butchers using Extended Production Point (EPP) mod
- Add missing translation keys across all languages
- Improve offspring subtype selection for maps with non-standard animal configurations
- Update Italian translation (contributed by FirenzeIT)
- Fix "Manage Animals" (R) key interfering with other mods' keybindings in different menu tabs
- Fix bulk move allowing more animals than target pen capacity
- Fix error when moving animals to Extended Production Points (EPP butchers)

## v1.0.0.0:
- Add "Manage Animals" (R) button to in-game animal menu for easier management
- Add "Select" (A) to check/uncheck selection boxes in buy and sell
- Disable insemination button when female is ineligible (pregnant, too young, recovering)
- Show "Removing..." state on monitor button when removal is pending
- Fix keybinding collisions in AnimalScreen - each action now has a unique key (D=Diseases, C=Castrate, M=Monitor, I=Insemination, X=Mark)
- Fix Mother/Father/Children info buttons intercepting Mark/Castrate keypresses - now mouse-only
- Fix insemination button showing on male animals
- Fix monitor visual not disappearing when removing monitor from animal
- Fix batch "Remove All Monitors" button not reflecting pending removal state
- Fix milk/wool/goat milk info not showing on dedicated server clients
- Protect GUI setup with pcall for dedicated server safety

## v0.6.1.0:
- Fix AI dialog insemination not syncing in multiplayer (AnimalAIDialog)
- Fix AI dialog insemination blocked for cows that never gave birth (missing isParent guard)
- Fix server crash when client inseminates cow with straw (AnimalInseminationEvent)
- Fix stream corruption in AI auto-insemination event (AIAnimalInseminationEvent)
- Fix pregnancy event silently failing to match animals on client (AnimalPregnancyEvent)
- Fix dewars bought mid-game not syncing to connected clients in multiplayer (SemenBuyEvent)
- Fix client-side error when buying semen in multiplayer (SemenBuyEvent)
- Fix disease treatment toggle not syncing to server in multiplayer (DiseaseDialog)
- Fix settings dependency check using undefined variable (RL_BroadcastSettingsEvent)
- Fixed error spam when dismounting horse outside pen in multiplayer
- Fix black screen when multiplayer client tries to ride a horse
- Fix multiplayer client unable to clean horses

## v0.6.0.0
- Add user guides and factsheets
- Add optional daily summary mode for message log to reduce noise on large farms (new setting: Message Log Summaries)
- Added "Reset AI Animals" button to settings to regenerate the AI straw catalog with new randomly generated animals
- Fix potential milk production loss that could occur when birth errors were silently caught
- Fix potential game freeze when selling animals with an active filter
- Fix potential mod errors blocking crop growth and other periodic game updates
- Fix texture warning for LED panel mask map
- Add Danish translation update and Chinese translation (community contributions)

## v0.5.0.0
- Randomize father selection during breeding - eligible males are now chosen randomly instead of always the first one
- Improve genetic inheritance with natural variation - offspring can now exceed or fall below parent trait values
- Fix wrong text shown for straw in monitor menu
- Detect conflicting mods (e.g., MoreVisualAnimals) and show a unified conflict dialog at startup
- Add Italian translation (community contribution by @FirenzeIT)

## v0.4.2.0
- Fix multiplayer sync issues when subTypeIndex differs between server/client (PR by killemth)
- Add fallback for days per month calculation during early load (PR by killemth)
- Refactor subType resolution into helper function with logging

## v0.4.1.0
- Fix crash caused by invalid animal root node in some cases.
- Fix death message count for auto-sold newborns
- Fix wrong text for when females can reproduce

## v0.4.0.0
- Remove Font Library dependency by inlining the required functionality directly in the mod.
- Refactor file loading and source folder.
- Update mod icon.

## v0.3.0.0
- Add Highland Bulls based on Renfordt's PR in 389 Arrow-kb's original mod.

## v0.2.0.0
- Migrate savegames from Arrow-kb's Realistic Livestock to RitterMod version. To avoid conflits with original mod and other forks of it, this mod uses a different mod ID. Therefore, when you load a savegame that used the original Realistic Livestock mod, you will be prompted to migrate the data to this mod.
