# Black Myth: Wukong LiveSplit Auto Splitter Installation Guide

1. Close LiveSplit.
2. Copy the following files from the `Components` folder in the archive to LiveSplit's `Components` folder, replacing existing files when prompted:
   - `BlackMythWukong.asl`
   - `BMWukong.Settings.xml`
   - `BMWukong.Settings.en.xml`
   - `uhara10-BMW`
3. Start LiveSplit, edit layout and add `Scriptable Auto Splitter`, then select the copied `Components\BlackMythWukong.asl`.

# Notes

If Auto Splits works but load removal does not, check:

1. Whether any mods are installed. Some mods also hook and conflict with load removal; remove the mods.
2. Check whether load removal is active in Edit Splits (if the Setting button is clickable, it is active). If so, deactivate it, save the splits, and restart LiveSplit.