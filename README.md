# st-housing

Player housing system for RedM (RSGCore framework).
This script is using free house models provided by favmathx  [Three Houses Pack](https://forum.cfx.re/t/free-three-houses-pack-custom-vanilla/5372803)

Currently only two Houses are configured, going to add the third house from this pack later. 

Players purchase building plans, place a ghost prop in the world, deposit crafted materials to complete construction, and then furnish and manage their property.

---

## Dependencies

| Resource | Purpose |
|---|---|
| `rsg-core` | Player data, callbacks, money, items |
| `ox_lib` | UI (notify, context menus, input dialogs, cron) |
| `oxmysql` | Database |
| `ox_target` | World interactions on house props and NPCs |
| `rsg-inventory` | Item management and property storage |

---

## Installation

1. Copy the `st-housing` folder into your `resources/[custom]/` directory (or equivalent).
2. Import the database schema:
   ```sql
   -- Run in HeidiSQL or any MySQL client
   source resources/[custom]/st-housing/sql/st_housing.sql
   ```
3. Add all items listed in shared/items.lua in your rsg-core/shared/items.lua.
4. you can find the item images in ST-IMAGES, simply copy all the images from there into your rsg-inventory/html/images folder.

5. Add to `server.cfg`:
   ```
   ensure st-housing
   ```

---

## Configuration (`shared/config.lua`)

### General

| Setting | Default | Description |
|---|---|---|
| `Config.Debug` | `false` | Enables debug prints and the instant-build menu option. **Never enable in production.** |
| `Config.MinPlotDistance` | `35.0` | Minimum distance (metres) between any two plots |
| `Config.PropRenderDistance` | `300.0` | Distance at which house props are streamed in |
| `Config.VegetationRadius` | `10.0` | Radius of vegetation cleared around each house |
| `Config.PlaceDistance` | `50.0` | Max raycast distance used during placement |

### Tax

| Setting | Default | Description |
|---|---|---|
| `Config.TaxCronJob` | `'0 * * * *'` | Cron schedule for the tax check (default: every hour) |
| `Config.TaxGraceDays` | `3` | Days before overdue tax triggers the abandoned warning |
| `Config.AbandonDays` | `7` | Days after the warning before the property is repossessed |

When paying tax, the amount due is `taxPerDay`. Tax can only be paid once per 24 hours.

### Furniture

| Setting | Default | Description |
|---|---|---|
| `Config.FurniturePlacementRadius` | `20.0` | Max distance from plot centre the owner can place furniture |
| `Config.FurniturePreviewDuration` | `5000` | Milliseconds the in-world ghost preview is shown before auto-deleting |

---

## Adding a New House Type

Add a new key to `Config.Houses` in `shared/config.lua`:

```lua
Config.Houses['my_house'] = {
    label        = 'My House',          -- display name shown in menus
    propmodel    = 'my_prop_model',     -- streamed prop model name
    price        = 8000,                -- cash cost of the building plan
    planItem     = 'plan_my_house',     -- rsg-inventory item name
    storageSlots  = 100,
    storageWeight = 750000,
    taxPerDay     = 300,

    -- Materials required to complete construction
    totalMaterials = {
        { item = 'wood_plank', amount = 600 },
        { item = 'iron_nail',  amount = 500 },
        { item = 'stone',      amount = 400 },
        { item = 'iron_bar',   amount = 150 },
        { item = 'rope',       amount = 150 },
        { item = 'glass_pane', amount = 60  },
    },

    -- Window props (optional) — local-space offsets relative to the house heading
    windows = {
        { model = 'p_win_njmpl_clean03x', offset = { x = 4.2, y = -0.6, z = -1.7, heading = 0.0 } },
    },

    -- Door props — local-space offsets relative to the house heading
    doors = {
        {
            model  = 'p_door04x',
            offset = { x = 2.29, y = -2.59, z = -2.62, heading = -90.0 },
        },
    },
}
```

You must also:
- Add `plan_my_house` to your rsg-inventory shared items.
- Stream the prop model (add `my_prop_model.ydr` to a stream resource).

---

## Adding a Housing Agent NPC

Append to `Config.HousingAgents` in `shared/config.lua`:

```lua
{
    label  = 'Rhodes Housing Agent',
    coords = vector4(1255.0, -1320.0, 76.5, 200.0),  -- x, y, z, heading
    model  = `A_M_M_ValFarmer_01`,
},
```

A blip and ox_target interaction are automatically created. The agent opens both the housing plans shop and the furniture NUI.

---

## Player Workflow

### Buying and Placing a Property

1. Visit a **Housing Agent** NPC (Valentine by default).
2. Select **Housing Plans** and purchase a plan. Cash is deducted immediately.
3. The plan item appears in your inventory. **Use** the item to enter placement mode.
4. In placement mode:
   - Move your camera to aim the ghost prop at a valid surface.
   - **Rotate Left / Right** (Q / E equivalent) to adjust heading (1°/frame).
   - **Raise / Lower** (Up / Down arrows) to adjust height (0.05m/step).
   - **Hold Confirm** to place the ghost at the current position.
   - **Hold Cancel** to abort — the plan is returned to your inventory.
5. Placement is rejected if:
   - The location is inside a town boundary.
   - Another plot exists within 35 metres.

### Constructing the House

While the house is a **ghost** (semi-transparent):

1. Approach the prop and use the **ox_target** interaction (crosshair aim, 7m range).
2. Select **Deposit [Material]** for each required item. An input dialog lets you choose how many to deposit at once.
3. Progress is shown as a floating bar above the ghost.
4. Once all materials are deposited the prop becomes solid, windows spawn, and doors are created as networked entities.

**Adjust Placement** is available (owner only, ghost phase) to reposition the ghost without losing any deposited materials.
**Cancel Building** returns the plan and removes the ghost (ghost phase only).

### Managing a Completed Property

Interact with the prop (ox_target, 7m) to open the property menu:

| Option | Who | Description |
|---|---|---|
| Lock / Unlock Door | Owner, Key Holders | Persisted to DB; synced to all clients |
| Open Storage | Owner, Key Holders | Opens rsg-inventory storage chest |
| Manage Keys | Owner only | Give or revoke key access to other players |
| Pay Property Tax | Owner only | Clears the abandoned flag and resets the tax timer |
| Transfer Ownership | Owner only | Transfers to another online player (they must not own property) |
| Demolish Property | Owner only | Permanent — removes storage contents |

### Furniture

1. Visit a **Housing Agent** → **Furniture** to open the NUI shop.
2. Browse by category; click an item to preview it in a 3D orbit camera.
3. Set quantity (1–10) and click **Purchase**. Each unit is added to inventory as an `st_furniture` item with the model stored in metadata.
4. **Use** the item from inventory to enter furniture placement mode.
5. Placement mode uses the same prompts as house placement. The ghost must be within `Config.FurniturePlacementRadius` metres of the plot centre.
6. To **remove** furniture, aim at it (owner only, 2.5m) and select **Remove [Item Name]** — the item is returned to inventory.

---

## Door System

Doors are **server-side networked entities** using OneSync. This means all clients share the same entity handle via `NetworkGetEntityFromNetworkId`.

- On house completion, the server delegates entity creation to the first available connected client.
- If no client is online, creation is deferred until the next player joins.
- Door state (open/closed) replicates automatically through entity ownership transfers.
- Lock state is persisted to the database and broadcast to all clients on change.
- Doors auto-open within 1.8 metres of the player and close when they move away.

---

## Tax System

A cron job (default: every hour) checks all owned properties:

| Overdue period | Action |
|---|---|
| `> TaxGraceDays` days | Property flagged as abandoned; blip turns red; owner notified if online |
| `> TaxGraceDays + AbandonDays` days | Property repossessed: `citizenid` cleared, storage deleted |

Players can pay tax from the property menu. The cost is `taxPerDay`. Tax can only be paid once per 24 hours — paying again before that window expires is blocked server-side. Paying resets the `last_tax_paid` timestamp and clears the abandoned flag.

---

## Map Blips

| Blip | Colour | Condition |
|---|---|---|
| My Property | Green | `citizenid` matches the local player |
| Friend's Property | Green | Player is in `allowed_players` |
| Player Property | Grey (default) | Another player's completed house |
| Abandoned Property | Red | `is_abandoned = 1` |
| Housing Agent | Green | Always visible |

Blips are entity-attached for spawned props (auto-remove on demolish) and coord-based for out-of-range plots.

---

## Security

All server events validate:

- **Ownership** — `citizenid` match or presence in `allowed_players`.
- **Phase** — ghost-phase and completed-phase operations are strictly separated.
- **Pending token** — plan placement and furniture placement both consume a server-side token set during the use-item callback. This prevents item duplication exploits where a client fires the confirm event without going through the use-item flow.
- **Placement radius** — furniture coordinates are validated server-side against `Config.FurniturePlacementRadius`.
- **Door debounce** — lock/unlock changes are ignored if called within 500ms of the previous change.
- **Debug guard** — the instant-build event is a no-op unless `Config.Debug = true`.

---

## Database Schema

Table: `st_plots`

| Column | Type | Description |
|---|---|---|
| `id` | INT AUTO_INCREMENT | Internal primary key |
| `plotid` | VARCHAR(20) UNIQUE | Random 8-digit plot identifier (`PLOT12345678`) |
| `citizenid` | VARCHAR(50) NULL | Owner's character ID; NULL when repossessed |
| `house_type` | VARCHAR(50) | Config key (e.g. `ranch_house`) |
| `propmodel` | VARCHAR(100) | Prop model name |
| `x`, `y`, `z` | DOUBLE | World position |
| `heading` | FLOAT | World heading in degrees |
| `stage_materials` | LONGTEXT JSON | `{"item": amount, ...}` deposited so far |
| `is_complete` | TINYINT | `0` = ghost, `1` = built |
| `is_abandoned` | TINYINT | `1` = tax overdue warning active |
| `is_locked` | TINYINT | `1` = doors locked |
| `allowed_players` | LONGTEXT JSON | `["citizenid", ...]` key holders |
| `furniture` | LONGTEXT JSON | `[{model, x, y, z, heading}, ...]` |
| `last_tax_paid` | TIMESTAMP | Resets on each tax payment |
| `created_at` | TIMESTAMP | Plot creation time |

Indexes: `UNIQUE(plotid)`, `INDEX(citizenid)`, `INDEX(is_complete)`.

---

## File Structure

```
st-housing/
├── fxmanifest.lua
├── README.md
├── sql/
│   └── st_housing.sql          Database schema
├── shared/
│   └── config.lua              All configuration (houses, recipes, furniture, agents)
├── client/
│   ├── prompts.lua             RDR2 prompt registration (placement controls)
│   ├── doors.lua               Networked door entities, proximity open/close, lock sync
│   ├── placement.lua           Ghost prop placement loop (initial + adjustment)
│   ├── building.lua            Property interaction menu, material deposit
│   ├── furniture.lua           Local furniture entity management and placement loop
│   ├── furniture_nui.lua       Furniture shop NUI, orbit camera preview
│   └── client.lua              Prop spawning, blips, spatial index, state handlers
├── server/
│   ├── tax.lua                 Tax cron job and payment handler
│   └── server.lua              Core server logic: DB ops, item events, door delegation
└── html/
    └── furniture_shop.html     Furniture shop NUI (split-panel, category browser)
```

---

## Exports

### Client

| Export | Arguments | Description |
|---|---|---|
| `HideLocalProp` | `plotId` | Temporarily hides a spawned prop (used before adjustment placement) |
| `AllowPlotSpawn` | `plotId` | Lifts spawn suppression, forces spawn loop to re-evaluate |
| `SpawnFurnitureForPlot` | `propData` | Spawns all furniture entities for a plot |
| `DeleteFurnitureForPlot` | `plotId` | Deletes all local furniture entities for a plot |
| `OpenPlotMenu` | `plotId, plotData` | Opens the property interaction context menu |
| `DrawProgressBar` | `coords, progress, label` | Draws a floating progress bar above a ghost prop |
| `CalculateProgress` | `depositedMaterials, houseType` | Returns 0–100 build completion percentage |
| `StartAdjustmentPlacement` | `plotId, houseType, houseConfig, heading` | Enters ghost-reposition mode |
| `GetHousingPromptGroup` | — | Returns the RDR2 prompt group ID |
| `SetPlotDoorLock` | `plotId, locked` | Applies lock state to door runtime entities |
