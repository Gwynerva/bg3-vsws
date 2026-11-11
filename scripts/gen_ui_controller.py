"""Generate the mod's controller UI library from the game's own XAML.

The controller UI has no buttons next to the slots. It has an "equipment
options" popup instead (EquipmentOptionsTemplate) listing weapon set, dual
wielding, helmet, clothes and stowed gear. This adds to its "Weapons" section
an option for the main hand and one for the off-hand, built like the helmet
option. They act on the weapon set in use (melee or ranged).

Two resources are produced:

  * EquipmentOptionsTemplate - the game's popup plus the four options;
  * PreloadedCharacterPanel_c - the game's controller character panel,
    unchanged. It has to be repeated because it refers to the popup with a
    static reference, which would otherwise keep pointing at the game's copy.

Regenerate after a game update:

    python scripts/gen_ui_controller.py

Needs the vanilla XAML extracted to vanilla/ (see docs/recon.md).
"""
import pathlib
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
VANILLA = ROOT / "vanilla/Game/Public/Game/GUI/Library/PreloadedCharacterPanel_c.xaml"
OUT = ROOT / "mod/Mods/Gwynerva_VisibleShieldsAndWeaponSets/GUI/Library/Lib_Controller.xaml"

# Labels (Localization/*/Gwynerva_VisibleShieldsAndWeaponSets.xml): the same two for either weapon set.
MAIN_HAND = "hcc6fff75g71f5g42e0gbd4bg91c52dcf72c8"
OFF_HAND = "h3e2ec6f9g6f2eg47d1ga3ebg827473b216c6"

# Slot -> handle of its label.
SLOTS = {
    "MeleeMainHand": MAIN_HAND,
    "MeleeOffHand": OFF_HAND,
    "RangedMainHand": MAIN_HAND,
    "RangedOffHand": OFF_HAND,
}

# Mode -> (label handle, icon resource of the popup) ; "Visible" is the default look.
MODE_VISIBLE = ("h153c3f7cga3aeg4d25gb8dcg439be99a27e1", "c_ico_equipmentVisible")
MODES = {
    # The icon is the set's own (sword or crosshair); see triggers().
    "ActiveSet": ("h02045512g42b3g4e65gbb80g2860f50b9145", None),
    "CinematicsHidden": ("h4015e57fg601ag44eagac2fga543834139c8", "c_ico_equipment_dialogueOnly"),
    "Hidden": ("hb8aca5ffg5327g491eg9cd9gcfcde0e667bd", "c_ico_equipment_off"),
}

# The mod's commands live on one object in the Tag of ContentRoot (see UI.lua).
COMMANDS = "ElementName=ContentRoot"
# The popup's data context is the panel's, as the game's own triggers in it assume.
# (A trigger action has no ancestors to search, so a RelativeSource binding gives it nothing.)
CHARACTER = "{Binding CurrentPlayer.SelectedCharacter}"


def text(handle):
    return "{Binding Source='" + handle + "',Converter={StaticResource TranslatedStringConverter}}"


def call(command, parameter):
    return f'<b:InvokeCommandAction Command="{{Binding Tag.{command}, {COMMANDS}}}" CommandParameter="{parameter}"/>'


def report_and_show(indent):
    """Tell the mod which character is shown, then have it fill in all four states."""
    rows = [call("GwyVS_CharacterCommand", CHARACTER)]
    rows += [call(f"GwyVS_Show{slot}Command", f"{{Binding ElementName=GwyVS_{slot}State}}") for slot in SLOTS]
    return ("\n" + indent).join(rows)


def host():
    """An invisible element holding the state text blocks and the triggers that keep them current."""
    pad = " " * 32
    states = "\n".join(
        f'                        <TextBlock x:Name="GwyVS_{slot}State" Text="Visible" Visibility="Collapsed"/>'
        for slot in SLOTS)
    return f"""
                    <!-- The mode of each weapon slot, written by the mod's Lua and read by the triggers below.
                         Refreshed when the popup is created, each time it is opened or closed, and whenever
                         another character is selected. -->
                    <Grid x:Name="GwyVS_Host" Width="0" Height="0">
                        <b:Interaction.Triggers>
                            <b:EventTrigger EventName="Loaded">
                                {report_and_show(pad)}
                            </b:EventTrigger>
                            <b:PropertyChangedTrigger Binding="{{Binding CurrentPlayer.SelectedCharacter}}">
                                {report_and_show(pad)}
                            </b:PropertyChangedTrigger>
                            <b:PropertyChangedTrigger Binding="{{Binding IsEnabled, ElementName=EquipmentOptions}}">
                                {report_and_show(pad)}
                            </b:PropertyChangedTrigger>
                        </b:Interaction.Triggers>
{states}
                    </Grid>
"""


def option(slot, label):
    """One option of the popup, modelled on the game's HelmetOption."""
    name = f"GwyVS_{slot}Option"
    visible_label, visible_icon = MODE_VISIBLE
    shown = "Visible" if slot.startswith("Melee") else "Collapsed"  # see set_triggers()
    return f"""
                    <Button x:Name="{name}" Command="{{Binding Tag.GwyVS_Toggle{slot}Command, {COMMANDS}}}" CommandParameter="{{Binding ElementName=GwyVS_{slot}State}}" Style="{{StaticResource FocusableContentControlStyle}}" Margin="0,0,0,12" Visibility="{shown}">
                        <b:Interaction.Triggers>
                            <!-- Runs before the command: makes sure the mod acts on the character of this panel. -->
                            <b:EventTrigger EventName="Click">
                                {call("GwyVS_CharacterCommand", CHARACTER)}
                            </b:EventTrigger>
                        </b:Interaction.Triggers>
                        <DockPanel Margin="20,10">
                            <!-- Unfocused icon -->
                            <Grid Style="{{StaticResource equipmentMenuIconBGgrid}}" Visibility="{{Binding Path=(ls:MoveFocus.IsFocused), ElementName={name}, Converter={{StaticResource BoolToCollapsedConverter}}}}">
                                <Ellipse Style="{{StaticResource equipmentMenuIconBG}}"/>
                                <Image x:Name="GwyVS_{slot}Icon" Style="{{StaticResource equipmentMenuIconStyle}}" Source="{{StaticResource {visible_icon}_d}}"/>
                            </Grid>
                            <!-- Focused icon -->
                            <Grid Style="{{StaticResource equipmentMenuIconBGgrid}}" Visibility="{{Binding Path=(ls:MoveFocus.IsFocused), ElementName={name}, Converter={{StaticResource BoolToVisibleConverter}}}}">
                                <Ellipse Style="{{StaticResource equipmentMenuIconBG}}"/>
                                <Image x:Name="GwyVS_{slot}Icon_h" Style="{{StaticResource equipmentMenuIconStyle}}" Source="{{StaticResource {visible_icon}_h}}" />
                            </Grid>

                            <TextBlock Style="{{StaticResource equipmentMenuOptionLabel}}" Text="{text(label)}"/>

                            <TextBlock x:Name="GwyVS_{slot}Setting" Text="{text(visible_label)}" Style="{{StaticResource equipmentMenuOptionSetting}}"/>

                        </DockPanel>
                    </Button>
"""


def triggers(slot):
    out = []
    for mode, (label, icon) in MODES.items():
        icon = icon or ("c_ico_equipment_meleeSet" if slot.startswith("Melee") else "c_ico_equipment_rangedSet")
        out.append(f"""
            <DataTrigger Binding="{{Binding Text, ElementName=GwyVS_{slot}State}}" Value="{mode}">
                <Setter TargetName="GwyVS_{slot}Setting" Property="Text" Value="{text(label)}"/>
                <Setter TargetName="GwyVS_{slot}Icon" Property="Source" Value="{{StaticResource {icon}_d}}"/>
                <Setter TargetName="GwyVS_{slot}Icon_h" Property="Source" Value="{{StaticResource {icon}_h}}"/>
            </DataTrigger>
""")
    return "".join(out)


def block(lines, opening, closing):
    """Lines of the top-level resource that starts with `opening`, through its `closing` line."""
    start = next((i for i, l in enumerate(lines) if l.startswith(opening)), None)
    if start is None:
        sys.exit(f"not found: {opening}")
    end = next(i for i in range(start, len(lines)) if lines[i].rstrip() == closing)
    return lines[start:end + 1]


def popup(lines):
    tpl = block(lines, '    <DataTemplate x:Key="EquipmentOptionsTemplate">', "    </DataTemplate>")

    # In the "Weapons" section, after the last of the game's options there...
    dual = next((i for i, l in enumerate(tpl) if 'x:Name="DualWieldOption"' in l), None)
    if dual is None:
        sys.exit("DualWieldOption not found in the popup")
    after = next(i for i in range(dual, len(tpl)) if tpl[i].rstrip() == "                    </Button>")
    options = host() + "".join(option(slot, label) for slot, label in SLOTS.items())

    # ...and at the end of the popup's triggers.
    closing = next((i for i, l in enumerate(tpl) if l.rstrip() == "        </DataTemplate.Triggers>"), None)
    if closing is None or closing < after:
        sys.exit("the popup's trigger section was not found where expected")
    state_triggers = "\n            <!-- Weapon slot visibility (mod) -->\n" + "".join(triggers(slot) for slot in SLOTS)

    return "\n".join(tpl[:after + 1]) + "\n" + options + "\n".join(tpl[after + 1:closing]) + "\n" \
        + state_triggers + set_triggers() + "\n".join(tpl[closing:])


def set_triggers():
    """Only the two options of the weapon set in use are shown; the game's own
    "current weapon set" option above them switches between the pairs."""
    hide = "".join(
        f'                <Setter TargetName="GwyVS_{slot}Option" Property="Visibility" Value="Collapsed"/>\n'
        for slot in SLOTS if slot.startswith("Melee"))
    reveal = "".join(
        f'                <Setter TargetName="GwyVS_{slot}Option" Property="Visibility" Value="Visible"/>\n'
        for slot in SLOTS if slot.startswith("Ranged"))
    return f"""
            <DataTrigger Binding="{{Binding CurrentPlayer.SelectedCharacter.PlayerCharacterProperties.HasRangedSetActive}}" Value="True">
{hide}{reveal}            </DataTrigger>
"""


def main():
    lines = VANILLA.read_text(encoding="utf-8-sig").splitlines()

    # The root tag with the game's namespaces, without its merged dictionaries.
    root_end = next(i for i, l in enumerate(lines) if l.rstrip().endswith(">"))
    header = "\n".join(lines[:root_end + 1]) \
        + "\n\n    <!-- Generated by scripts/gen_ui_controller.py from the game's PreloadedCharacterPanel_c.xaml. -->"

    panel = block(lines, '    <ControlTemplate x:Key="PreloadedCharacterPanel_c"', "    </ControlTemplate>")
    if not any("{StaticResource EquipmentOptionsTemplate}" in l for l in panel):
        sys.exit("the character panel no longer refers to EquipmentOptionsTemplate")

    parts = [header, popup(lines), "\n".join(panel), "</ResourceDictionary>"]
    OUT.parent.mkdir(parents=True, exist_ok=True)
    OUT.write_text("\n\n".join(parts) + "\n", encoding="utf-8", newline="\n")
    print(f"wrote {OUT.relative_to(ROOT)}: {OUT.read_text(encoding='utf-8').count(chr(10))} lines")


if __name__ == "__main__":
    main()
