Replaces xp bar for forever. It emulates something that I used to use a weakaura for.

Tracks
 - xp/hour and time to level
 - quest log completed quests (shown on the bar as how far turning them in gets you)
 - rested xp
 - time played this level and this session (hover the bar)

![Example Screenshot of XP Bar](https://github.com/kwyatt/krrl-xp-bar/blob/main/media/example.png)

## Options

Ctrl+Right-click the bar, type `/kxp options`, or go to Escape -> Options -> AddOns -> Krrl XP Bar.

 - Font: any font from the game, plus fonts other addons share through LibSharedMedia (EllesmereUI, SharedMedia packs, etc.). Type in the dropdown to filter.
 - Font size: slider, or type a number
 - Bar texture: built-in textures plus any shared through LibSharedMedia
 - Bar width and height: sliders, type a number, or drag the grip in the bar's corner while options are open
 - Lock bar: stops the bar from being moved or resized
 - Reset to Defaults

## Moving the bar

Drag it anywhere. Lock it from the options or with `/kxp lock`.

## Commands

 - `/kxp options` - open the options window
 - `/kxp lock` - lock/unlock the bar
 - `/kxp <option>` - toggle `leveltime-text`, `sessiontime-text`, `showxphour-text`, `questrested-text`, `showincompletequest-bar`, `showmaxlevel`, `reset_reload`, `hide_xpbar`, `debug-profile`
 - `/kxp` - list commands
