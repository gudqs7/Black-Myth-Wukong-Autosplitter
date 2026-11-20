# Black Myth: Wukong LiveSplit Auto Splitter Installation Guide

1. Close LiveSplit.
2. Copy the following files from the archive's `Components` folder into LiveSplit's `Components` folder, replacing existing files when prompted:
   - `BlackMythWukong.asl`
   - `BMWukong.Settings.xml`
   - `BMWukong.Settings.en.xml`
   - `uhara10-BMW`
3. Start LiveSplit, edit the layout, add `Scriptable Auto Splitter`, and select `BlackMythWukong.asl`.
4. Enable `Auto Splits Enabled` in the component settings and select the Bosses you need. `CG Load Removal` controls whether cutscene time is removed from Game Time.

## Notes

If Auto Splits works but load removal does not, check:

1. Whether any mods are installed. Some mods also hook the game and conflict with load removal; remove the mods.
2. Check whether load removal is active in Edit Splits (if Settings is clickable, it is active). If so, deactivate it, save the splits, and restart LiveSplit.