-- Furniture NUI shop: split-panel menu with in-world orbit-camera preview.
--
-- ARCHITECTURE:
--   html/furniture_shop.html  ← full-screen NUI overlay
--     Left  40vw : solid dark panel  (categories + item list)
--     Right 60vw : transparent       (game world renders through; preview prop visible here)
--     Bottom bar : full-width        (selected item, qty, buy button)
--
--   PreviewCam  — scripted camera orbiting around the preview prop
--   PreviewProp — local (non-networked) entity spawned at a fixed world position
--
--   NUI callbacks received here:
--     selectItem   → spawn/swap preview prop, update orbit target
--     rotateCam    → adjust azimuth / pitch, update camera
--     zoomCam      → adjust distance, update camera
--     buyFurniture → TriggerServerEvent buyFurniture(model, qty)
--     closeShop    → tear down camera + prop, restore game state

-- =============================================
-- STATE
-- =============================================
local NUIOpen        = false
local PreviewCam     = nil
local PreviewProp    = nil
local PreviewBase    = nil   -- vector3 world position of the preview prop
local CamAzimuth     = 30.0  -- horizontal orbit angle (degrees)
local CamPitch       = 28.0  -- vertical elevation (degrees, 5-70)
local CamDist        = 3.0   -- distance from prop (metres)

-- =============================================
-- CAMERA HELPERS
-- =============================================
local function UpdatePreviewCam()
    if not PreviewCam or not DoesCamExist(PreviewCam) then return end
    if not PreviewBase then return end

    local az  = math.rad(CamAzimuth)
    local el  = math.rad(CamPitch)

    -- Orbit position around prop
    local cx = PreviewBase.x + CamDist * math.cos(el) * math.sin(az)
    local cy = PreviewBase.y - CamDist * math.cos(el) * math.cos(az)
    local cz = PreviewBase.z + CamDist * math.sin(el) + 0.5

    SetCamCoord(PreviewCam, cx, cy, cz)
    -- Always look at the prop's vertical midpoint
    PointCamAtCoord(PreviewCam, PreviewBase.x, PreviewBase.y, PreviewBase.z + 0.5)
end

-- =============================================
-- PREVIEW PROP MANAGEMENT
-- =============================================
local function DeletePreviewProp()
    if PreviewProp and DoesEntityExist(PreviewProp) then
        SetEntityAsMissionEntity(PreviewProp, false)
        FreezeEntityPosition(PreviewProp, false)
        DeleteObject(PreviewProp)
    end
    PreviewProp = nil
end

local function SpawnPreviewProp(model, cb)
    CreateThread(function()
        DeletePreviewProp()
        if not PreviewBase then cb(false) return end

        local hash = joaat(model)
        RequestModel(hash)
        local i = 0
        while not HasModelLoaded(hash) and i < 100 do
            Wait(10)
            i = i + 1
        end
        if not HasModelLoaded(hash) then
            cb(false)
            return
        end

        local obj = CreateObject(hash,
            PreviewBase.x, PreviewBase.y, PreviewBase.z,
            false, false, false)
        SetEntityAsMissionEntity(obj, true)
        SetEntityCoordsNoOffset(obj,
            PreviewBase.x, PreviewBase.y, PreviewBase.z,
            false, false, false, true)
        -- Face the camera's default approach direction (azimuth 30° → opposite = 210°)
        SetEntityRotation(obj, 0.0, 0.0, 210.0, 2, false)
        FreezeEntityPosition(obj, true)
        SetModelAsNoLongerNeeded(hash)

        PreviewProp = obj
        UpdatePreviewCam()
        cb(true)
    end)
end

-- =============================================
-- OPEN THE FURNITURE NUI SHOP
-- =============================================
function OpenFurnitureNUI()
    if NUIOpen then return end
    NUIOpen = true

    -- ── Fixed preview position — always the same open location ──
    local ped   = PlayerPedId()
    PreviewBase = vector3(-345.06, 751.29, 207.50)

    -- ── Reset camera state ──
    CamAzimuth = 30.0
    CamPitch   = 28.0
    CamDist    = 3.0

    -- ── Create orbit camera ──
    PreviewCam = CreateCam('DEFAULT_SCRIPTED_CAMERA', true)
    UpdatePreviewCam()
    SetCamFov(PreviewCam, 50.0)
    SetCamActive(PreviewCam, true)
    RenderScriptCams(true, false, 0, true, false)

    -- Freeze player in place while browsing (HUD stays — DisplayHud is GTA5-only)
    FreezeEntityPosition(ped, true)

    -- ── Build lightweight category data for NUI ──
    -- (send label + icon + price + prop list for every category)
    local cats = {}
    for _, cat in ipairs(Config.FurnitureCategories) do
        local props = {}
        for _, prop in ipairs(cat.props) do
            local label = prop.model:gsub('^[ps]_', ''):gsub('_', ' ')
            label = label:gsub('^%l', string.upper)
            table.insert(props, { model = prop.model, label = label, price = prop.price })
        end
        table.insert(cats, {
            label = cat.label,
            icon  = cat.icon,
            props = props,
        })
    end

    SetNuiFocus(true, true)
    SendNuiMessage(json.encode({ action = 'openShop', categories = cats }))
end

-- OpenFurnitureNUI is intentionally global so client.lua can call it directly
-- (all client scripts in the same resource share one Lua state)

-- =============================================
-- CLOSE THE FURNITURE NUI SHOP
-- =============================================
function CloseFurnitureNUI()
    if not NUIOpen then return end
    NUIOpen = false

    SetNuiFocus(false, false)
    SendNuiMessage(json.encode({ action = 'closeShop' }))

    -- Destroy orbit camera, return to game camera
    if PreviewCam and DoesCamExist(PreviewCam) then
        SetCamActive(PreviewCam, false)
        DestroyCam(PreviewCam, false)
        PreviewCam = nil
    end
    RenderScriptCams(false, false, 0, true, false)

    -- Clean up preview prop
    DeletePreviewProp()
    PreviewBase = nil

    FreezeEntityPosition(PlayerPedId(), false)
end

-- =============================================
-- NUI CALLBACKS
-- =============================================

-- Player clicked an item in the list → spawn preview prop
RegisterNuiCallback('selectItem', function(data, cb)
    local model = data.model
    if not model then cb({ ok = false }) return end
    SpawnPreviewProp(model, function(ok)
        cb({ ok = ok })
    end)
end)

-- Player dragged the viewport → orbit camera
RegisterNuiCallback('rotateCam', function(data, cb)
    CamAzimuth = (CamAzimuth + (data.dx or 0) * 0.45) % 360.0
    CamPitch   = math.max(5.0, math.min(70.0, CamPitch - (data.dy or 0) * 0.3))
    UpdatePreviewCam()
    cb({})
end)

-- Player scrolled the viewport → zoom
RegisterNuiCallback('zoomCam', function(data, cb)
    CamDist = math.max(1.0, math.min(9.0, CamDist + (data.delta or 0) * 0.35))
    UpdatePreviewCam()
    cb({})
end)

-- Player clicked Purchase
RegisterNuiCallback('buyFurniture', function(data, cb)
    local model = data.model
    local qty   = math.max(1, math.min(10, math.floor(tonumber(data.qty) or 1)))
    if model then
        TriggerServerEvent('st-housing:server:buyFurniture', model, qty)
    end
    cb({})
end)

-- Player clicked ✕ or pressed ESC
RegisterNuiCallback('closeShop', function(data, cb)
    CloseFurnitureNUI()
    cb({})
end)

-- =============================================
-- CLEANUP
-- =============================================
AddEventHandler('onResourceStop', function(resource)
    if resource ~= GetCurrentResourceName() then return end
    if NUIOpen then CloseFurnitureNUI() end
end)
