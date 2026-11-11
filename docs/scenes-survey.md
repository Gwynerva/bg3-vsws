# What the game's scenes do to an actor's gear

A survey of every timeline (dialogue and cutscene) in the game data, made without running the game,
to find the places where a scene changes what an actor wears or carries — places where this mod,
which adds the other weapon set to the scene's copy of a character, has to follow along.

Game 4.1.1.x (Patch 8, hotfix 10). 19,741 timelines from `Gustav.pak`, `GustavX.pak` and the two
hotfix packages. Reproduce with `scripts/survey_timelines.py` (see its header for the input).

## How scenes are written

A timeline is a list of tracks, each for one actor, with keys along the time line. The tracks that
matter here are on/off tracks. Their default is "shown": the files only ever spell out `False`.

| Track | Scenes with it | Scenes where it hides something | …and shows it again later |
|---|---|---|---|
| `TLShowWeapon` — the actor's weapons | 3,597 | **618** | 482 |
| `TLShowArmor` — pieces of clothing, one channel per piece | 105 | **85** | 52 |
| `TLShowVisual` — the whole actor | 1,235 | **1,166** | 978 |
| `TLShapeShift` — replace the actor's model | 148 | — | — |
| `TLMaterial` — material parameters (fades, glows) | 630 | — | — |
| `TimelineActorPropertiesReflection` | 112 | — | — |
| `TLAttachToEvent` — attach one actor to another | 2 | — | — |

## Where weapons are hidden (618 scenes)

| Kind of scene | Scenes |
|---|---|
| Romance and night scenes | 60 |
| Sleep and dreams | 9 |
| Other camp scenes (Volo's operation is `CAMP_VoloOperation`) | 69 |
| Endings and epilogue | 55 |
| Intro and character creation | 22 |
| Scenes out in the world | 403 |

The world scenes are mostly ones where an actor does something with their hands or body: dead and
dying characters, fights and executions, surrenders, ceremonies, carried or bound characters.

So this is not a rarity: roughly one scene in thirty hides somebody's weapons for a while, and in
most of those (482) the weapons come back before the scene ends. A rule of the kind "decide once
when the scene starts" cannot work; the mod has to follow the scene as it plays.

## Where clothing is taken off (85 scenes)

75 of the 85 also hide the weapons. The ten that do not are scenes where a single piece is removed
(a branding, a mask, a glove) and the weapons are meant to stay. So "armour hidden" is not by
itself a reason to hide weapons: the weapon track is the one to follow.

## Where the whole actor is hidden (1,166 scenes)

The commonest of the three: actors that are not in a shot are switched off. 383 of the 618
weapon-hiding scenes also do this at some point. What the mod adds to a copy must disappear and
reappear with the copy.

## What the mod should do

| What the scene does | What the mod should do | Status |
|---|---|---|
| Hides the actor's weapons | Hide the weapon set the mod added as well; show it again when the scene does | to do — the visible symptom reported in Volo's scene |
| Hides the whole actor | Nothing of the mod's may stay visible; and the mod must not switch a model back on while the actor is hidden | to check in game |
| Replaces the actor's model | The copy is rebuilt; the added set must be requested again for the new model, or dropped if the new model is not a weapon-bearing one | to check in game |
| Takes clothing off | Nothing by itself (see above) | — |
| Fades the actor through materials | Added weapons should fade with the rest | to check in game |

## What the data cannot tell

The mod does not see a scene's tracks: Script Extender does not expose a timeline's components.
It sees the copy of the character. Which mark each track leaves on the copy (a flag, a model
switched off, a model removed) has to be read in game, once per kind of track — not once per
scene.
