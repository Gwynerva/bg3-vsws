# How the mod works

Visible Shields and Weapon Sets, for Baldur's Gate 3 (Patch 8, game 4.1.1.x) with Script Extender v33+.

The mod never draws anything itself and never touches items, stats or rules. Everywhere it tells the
engine *what should be shown*, and the engine's own equipment code does the rest.

## State

Each party member has a mode per weapon slot (`MeleeMainHand`, `MeleeOffHand`, `RangedMainHand`,
`RangedOffHand`), stored in a Script Extender user variable on the character (saved with the game,
owned by the server, synced to clients). See `Shared/State.lua`.

| Mode | Stowed weapon is shown… |
|---|---|
| `Visible` | always, whichever weapon set is in use |
| `ActiveSet` | only while its weapon set is the one in use (the game's own behaviour) |
| `CinematicsHidden` | as `Visible`, but not in dialogues and cutscenes |
| `Hidden` | never |

A weapon in the hands is always shown.

## In the world and in photo mode — `Client/Applier.lua`

`ClientEquipmentVisibilityState.Equipment` is the engine's table of slots to draw. A slot without a
row is not drawn. The mod edits it right after the engine's `ClientVisualsVisibilityState` system has
filled it in, so the change is picked up in the same frame.

- **Shield.** Since Patch 8 the engine leaves the shield's row out while weapons are sheathed. The mod
  puts it back; the bone comes from `EquipmentTypes.lsx`, where the mod gives the Shield type the
  sheathed bones it lacks (`Dummy_Sheath_Shield`).
- **The other weapon set.** The engine has rows only for the set in use. A row for a slot of the other
  set, marked as stowed, makes the engine build that weapon as well, on its own sheath bone.
- **Hiding.** The row of a hidden slot is taken out (and kept, to be put back).

In a row, `field_8` is 1 while the weapon is in the hands and `field_9` is 1 for weapons. These are
placeholder names in Script Extender and will be renamed in a future version.

## In dialogues and cutscenes — `Client/Timeline.lua`

Scenes show copies of the characters ("timeline dummies") taken from a pool. A dummy has
`ClientEquipmentVisuals` like a character, but neither of the two components above: the game fills
its slots directly, with the weapon set in use only.

- **Finding the dummy.** There is no event for a dummy being filled in. A scene is noticed on the real
  character (it carries `TimelineActorData` while the scene runs), and its dummy is looked up in the pool.
- **Hiding.** A stowed weapon on a dummy is a model attached to a sheath bone; its render passes are
  switched off. The engine sometimes switches one back on mid-scene, so found dummies are checked every frame.
- **The other weapon set.** Once the dummy is fully dressed, the mod creates `ClientVisualsDesiredState`
  on it, lists what the dummy already wears plus the other set's requests (copied from the character,
  where the engine made them; only `Parent` changes), marks it changed once, and removes the component
  again about a second after the weapons have loaded. The weapons stay.

What does not work: queueing `InventoryEvents` on the equipment visuals system — a dummy ignores them.

## Buttons — `Client/UI.lua`, `GUI/Library/*.xaml`

The XAML is generated from the game's own files (`scripts/gen_ui.py`, `scripts/gen_ui_controller.py`);
regenerate it after a game update.

- **Keyboard and mouse:** the four weapon slots of `CharacterEquipmentTemplate` are wrapped like the
  helmet slot, with a copy of the game's visibility button.
- **Controller:** two options in the "Weapons" section of the equipment options popup; they act on
  the weapon set in use.

Constraints that shaped this:

- A script cannot read bound values off a UI element, and a reference to a UI object is only valid
  inside the call that received it. So the XAML passes the data as command parameters — the character,
  the slot, then a hidden text block — and the mod writes the mode name into that text block, which the
  button's triggers read.
- The commands live on one object in the `Tag` of `ContentRoot`. The game rebuilds its whole UI when
  the player switches between keyboard and controller, so the mod checks once a second that the object
  is still there.
- Other UI mods may carry their own copies of the same templates. Better Inventory UI does, unmodified;
  this mod only has to load after it (`Client/Compat.lua` warns otherwise).

## Building and testing

- `build.ps1` packs `mod/` and copies the package into the game's Mods folder. The game must be closed:
  it keeps the package open. Do not link `mod/` into the game's `Data\Mods` — the game then sees the mod
  twice and hangs while loading.
- `State.DEBUG = true` prints each step to the Script Extender console and to
  `Script Extender/Gwynerva_VisibleShields/debug.log`.
- Console (client context): `!vsws <main|shield|ranged|rangedoff|all> [visible|set|dialog|hidden]`,
  `!vsws_dump`.
- `scripts/webpad.py` is a virtual controller driven from a web page, for testing the controller UI
  without a controller (needs the ViGEmBus driver).
- `tools/`, `vanilla/` and `reference/` are not in the repository: third-party tools, files extracted
  from the game, and other mods studied for the mechanism.

## Credits

The way to bring the shield back after Patch 8 was learned from Sensible Visible Shields by joow92,
which builds on Maximuuus' VisibleShields. Visible Shields and Weapons – Universal by Eola showed that
drawing both weapon sets is possible at all. No code from either is used.
