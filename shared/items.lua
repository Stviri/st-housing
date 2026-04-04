-- ============================================================
-- st-housing — Required Items
-- Add these entries to rsg-core/shared/items.lua
-- Items marked [SHARED] are also used by other st-* resources;
-- define them only once in the master list.
-- ============================================================

-- Building Plans (one per house type in Config.Houses)
plan_ranch_house  = { name = 'plan_ranch_house',  label = 'Wooden House Plan',  weight = 50,   type = 'item', image = 'plan_ranch_house.png',  unique = false, useable = true,  shouldClose = true,  description = 'A building plan for a wooden house. Use to enter placement mode.'                     },

-- Furniture (metadata-driven: prop model stored in item info)
st_furniture      = { name = 'st_furniture',      label = 'Furniture',          weight = 500,  type = 'item', image = 'st_furniture.png',      unique = false, useable = true,  shouldClose = true,  description = 'A piece of furniture. Use to place it inside your property.'                          },

-- Building Materials
wood_plank        = { name = 'wood_plank',        label = 'Wood Plank',         weight = 500,  type = 'item', image = 'wood_plank.png',        unique = false, useable = false, shouldClose = false, description = 'A rough-cut wooden plank used in construction.'                                       }, -- [SHARED: st-crafting]
iron_nail         = { name = 'iron_nail',         label = 'Iron Nail',          weight = 50,   type = 'item', image = 'iron_nail.png',         unique = false, useable = false, shouldClose = false, description = 'Hand-forged iron nails used in construction.'                                         }, -- [SHARED: st-crafting]
stone             = { name = 'stone',             label = 'Stone',              weight = 1000, type = 'item', image = 'stone.png',             unique = false, useable = true,  shouldClose = true,  description = 'A rough stone. Use near water to wash it, or deposit into a building site.'           }, -- [SHARED: st-mining, st-crafting]
iron_bar          = { name = 'iron_bar',          label = 'Iron Bar',           weight = 2000, type = 'item', image = 'iron_bar.png',          unique = false, useable = false, shouldClose = false, description = 'A smelted iron bar used in construction.'                                             }, -- [SHARED: st-crafting]
rope              = { name = 'rope',              label = 'Rope',               weight = 200,  type = 'item', image = 'rope.png',              unique = false, useable = false, shouldClose = false, description = 'A length of sturdy rope used in construction.'                                        }, -- [SHARED: st-crafting]
glass_pane        = { name = 'glass_pane',        label = 'Glass Pane',         weight = 300,  type = 'item', image = 'glass_pane.png',        unique = false, useable = false, shouldClose = false, description = 'A flat pane of glass used for windows.'                                              }, -- [SHARED: st-crafting]
