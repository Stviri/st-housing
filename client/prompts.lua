-- RDR2 Prompt registration for placement controls

local HousingPromptGroup = GetRandomIntInRange(0, 0xffffff)

-- Expose group ID so other files can use it
SetPrompt         = nil
CancelPrompt      = nil
RotateLeftPrompt  = nil
RotateRightPrompt = nil
HeightUpPrompt    = nil
HeightDownPrompt  = nil

CreateThread(function()
    -- Confirm placement (hold)
    SetPrompt = PromptRegisterBegin()
    PromptSetControlAction(SetPrompt, 0xC7B5340A)
    local str = CreateVarString(10, 'LITERAL_STRING', Config.PromptPlaceName)
    PromptSetText(SetPrompt, str)
    PromptSetEnabled(SetPrompt, true)
    PromptSetVisible(SetPrompt, true)
    PromptSetHoldMode(SetPrompt, true)
    PromptSetGroup(SetPrompt, HousingPromptGroup)
    PromptRegisterEnd(SetPrompt)

    -- Cancel (hold)
    CancelPrompt = PromptRegisterBegin()
    PromptSetControlAction(CancelPrompt, 0xF84FA74F)
    str = CreateVarString(10, 'LITERAL_STRING', Config.PromptCancelName)
    PromptSetText(CancelPrompt, str)
    PromptSetEnabled(CancelPrompt, true)
    PromptSetVisible(CancelPrompt, true)
    PromptSetHoldMode(CancelPrompt, true)
    PromptSetGroup(CancelPrompt, HousingPromptGroup)
    PromptRegisterEnd(CancelPrompt)

    -- Rotate left (press)
    RotateLeftPrompt = PromptRegisterBegin()
    PromptSetControlAction(RotateLeftPrompt, 0xA65EBAB4)
    str = CreateVarString(10, 'LITERAL_STRING', Config.PromptRotateLeft)
    PromptSetText(RotateLeftPrompt, str)
    PromptSetEnabled(RotateLeftPrompt, true)
    PromptSetVisible(RotateLeftPrompt, true)
    PromptSetStandardMode(RotateLeftPrompt, true)
    PromptSetGroup(RotateLeftPrompt, HousingPromptGroup)
    PromptRegisterEnd(RotateLeftPrompt)

    -- Rotate right (press)
    RotateRightPrompt = PromptRegisterBegin()
    PromptSetControlAction(RotateRightPrompt, 0xDEB34313)
    str = CreateVarString(10, 'LITERAL_STRING', Config.PromptRotateRight)
    PromptSetText(RotateRightPrompt, str)
    PromptSetEnabled(RotateRightPrompt, true)
    PromptSetVisible(RotateRightPrompt, true)
    PromptSetStandardMode(RotateRightPrompt, true)
    PromptSetGroup(RotateRightPrompt, HousingPromptGroup)
    PromptRegisterEnd(RotateRightPrompt)

    -- Height up (press) — INPUT_FRONTEND_UP (up arrow)
    HeightUpPrompt = PromptRegisterBegin()
    PromptSetControlAction(HeightUpPrompt, joaat('INPUT_FRONTEND_UP'))
    str = CreateVarString(10, 'LITERAL_STRING', Config.PromptHeightUp)
    PromptSetText(HeightUpPrompt, str)
    PromptSetEnabled(HeightUpPrompt, true)
    PromptSetVisible(HeightUpPrompt, true)
    PromptSetStandardMode(HeightUpPrompt, true)
    PromptSetGroup(HeightUpPrompt, HousingPromptGroup)
    PromptRegisterEnd(HeightUpPrompt)

    -- Height down (press) — INPUT_FRONTEND_DOWN (down arrow)
    HeightDownPrompt = PromptRegisterBegin()
    PromptSetControlAction(HeightDownPrompt, joaat('INPUT_FRONTEND_DOWN'))
    str = CreateVarString(10, 'LITERAL_STRING', Config.PromptHeightDown)
    PromptSetText(HeightDownPrompt, str)
    PromptSetEnabled(HeightDownPrompt, true)
    PromptSetVisible(HeightDownPrompt, true)
    PromptSetStandardMode(HeightDownPrompt, true)
    PromptSetGroup(HeightDownPrompt, HousingPromptGroup)
    PromptRegisterEnd(HeightDownPrompt)
end)

exports('GetHousingPromptGroup', function()
    return HousingPromptGroup
end)
