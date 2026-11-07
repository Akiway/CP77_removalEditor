# Removal Editor

Creates ArchiveXL `.xl` files that remove world objects (nodes) of Cyberpunk 2077, by picking them in game with
RedHotTools.

# Installation
- Download and install this mod
- Download and install [RedHotTools](https://github.com/psiberx/cp2077-red-hot-tools) (1.3.0 or newer for game
  version 2.5), with all its dependencies
- To use the files it creates, install [ArchiveXL](https://github.com/psiberx/cp2077-archive-xl) (1.28.6 or newer
  for game version 2.5)

# Usage
- Open the CET Overlay and find the `Removal Editor` window
- Without RedHotTools, the window only says that it is missing
## Important Note
- Removal Editor only creates a ready to use `.xl` file in its `data` folder.
- This means that it does not remove anything by itself: for that, place the `.xl` file in the game's
  `archive\pc\mod` folder and have ArchiveXL installed, or use `Install & Reload` (see below)
- **When sending a node to Removal Editor from RHT, the node visibility (for those which support it, e.g. mesh
  nodes) gets toggled off, for easier previewing. This is only temporary, and reverts as soon as the node is un and
  re-streamed.**
## Presets Tab
Here you can create a new preset by entering a name in the `Name...` field and hitting `Create`
- Each preset is a collection of removed objects. Use this to organise things.
- Expanding a preset's header reveals more information and its buttons:
  - `Edit` loads the preset into the editor (`Edit` tab)
  - `Delete` deletes its file, after a second click on `Confirm delete`
  - `Install & Reload` installs the preset in the game and reloads the last save (only while a game is loaded).
    Make a Quick-Save first, to keep your progress and speed up the reload.
- Presets are read from JSON or YAML `.xl` files, and saved in the format they were read in (new presets are YAML)
- A YAML preset keeps its comments and key order, but its layout is made regular (2 spaces indentation, one list
  item per line). Comments stay above the line they were above. When a node is removed from the preset, the comments
  above it go with it, but the entries commented out above it (`# - index: 41`, as ArchiveXL Sector Updater writes
  the nodes it could not convert, with their reason) are kept: they move above the next node. A sector that only has
  entries commented out left is kept with them
- A file that cannot be read (invalid JSON / YAML, no `streaming.sectors`...) is listed in red with the reason. Fix
  it, then hit `Retry`
### Game version
- Patch 2.5 reordered the nodes of every sector: the indices of a preset made for an older game version now point to
  other objects
- A YAML preset gives the game version it was made for in a comment at the start of its file:
  `# Game version: 2.5`. New presets get it. A JSON preset cannot hold comments: its version is unknown
- If it is not the running version, or unknown, a warning is shown, and `Install & Reload` asks for a second click
  (`Install anyway`)
- Convert such presets with [ArchiveXL Sector Updater](https://github.com/Akiway/ArchiveXL-Sector-Updater), then
  check them and hit `Mark as made for <version>` (YAML presets), which writes that comment
## Edit Tab
- Here you can see what nodes the preset removes
- You can add a node to an opened preset directly, by identifying the node in RHT, then pressing the
  `Send node to Removal Editor` button in RHT. The `Add [Inspect] node` hotkey (CET bindings) adds the node targeted
  in RHT's `Inspect` tab
- By changing the staging mode to `Add with confirmation`, each node sent to Removal Editor is staged first,
  allowing you to add a Note to the node, before hitting the `Add Staged Node` button
- `Add all scanned & filtered nodes` adds every result of RHT's `Scan` tab matching its current filter (those that
  are not world nodes are skipped)
- Below, you will see a list of all the nodes in the preset, which can be searched by type, sector, index, debug
  name, resource or note
- You can expand each node's header to edit its note, its removed actors / instances, or remove the node from the
  preset
## Notes
- Notes are saved in the preset, in the `note` field of each removal (ignored by ArchiveXL). They follow their node
  when the preset is converted to another game version with ArchiveXL Sector Updater
- Older versions of Removal Editor kept them in `data\notes.json`, by sector and node index. On its first start,
  Removal Editor moves them into the presets of the `data` folder and renames the file `notes.migrated.json`. Notes
  of nodes that are in no preset are only kept in that file. To move them again (e.g. into a preset that could not
  be read), rename it back to `notes.json` and restart the game
## Finding Nodes
- For finding collision nodes with RHT, use the `Inspect` tab, and look directly at the collision
- For any non-targetable node (Not entities or collisions), use the `Scan` tab of RHT
## Node information
- Cooked nodes (2.5): most objects of a sector are now grouped by type into cooked nodes
  (`worldCookedStaticMeshNode`, `worldCookedStaticDecalNode`, `worldCookedCollisionNode`...). Each object still has
  its own node index: removing it removes only that object
- Collision Nodes: Collision Nodes are made up of multiple `Actors`, each actor can be some shape, like a box,
  sphere / pill, and more complex shapes
  - A collision hit in RHT's `Inspect` tab removes only the actor that was hit (`actorDeletions`, with the node's
    actor count in `expectedActors`). Other actors of the same node can be added by targeting them too, or ticked in
    the node's `Collision Actors` list
  - A collision added from the `Scan` tab removes the whole node, as RHT does not know its actors there
  - ArchiveXL removes the whole node when `actorDeletions` comes without `expectedActors`: such removals are shown
    in red. Re-send the node from RHT's `Inspect` tab to fix them
- Instanced Mesh Nodes: an instance targeted in RHT is removed alone (`instanceDeletions`, with `expectedInstances`)
- Proxy Nodes: when a removed node is part of a proxy (a low detail mesh shown from afar instead of a group of
  nodes), Removal Editor also lowers the proxy's node count (`nbNodesUnderProxyDiff`), so that the proxy hides
  properly
- Occluder nodes: Currently RHT does not pick up on instanced mesh occluder nodes, so often it is impossible to
  remove the ones you want, you can try and use [VS2077](https://github.com/notaspirit/VolumetricSelection2077)
  instead
