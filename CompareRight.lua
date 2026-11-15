-- Compare Right
--
-- When you compare an item, the game puts the "Equipped" tooltips on
-- whichever side of the item tooltip has more room. On the right half of the
-- screen that is the left side, so the order flips depending on where your
-- mouse is. This addon always uses the same order: the hovered item starts
-- at the mouse, the equipped item(s) follow to its right. If that doesn't
-- fit on the screen, the whole row moves left until it does.
--
-- Every item comparison (bags, merchants, quest rewards, tooltips from other
-- addons) is laid out by TooltipComparisonManager:AnchorShoppingTooltips.
-- We let Blizzard run it and fix the result in a secure post-hook, so the
-- comparison code itself stays untainted.
--
-- The game lays out the comparison before the item tooltip is shown, while
-- its size is still the old one, and addons often add lines afterwards
-- (Forever Leveling BiS does). So we lay it out again whenever one of the
-- tooltips is shown or changes size.

local issecretvalue = issecretvalue or function() return false end

local CURSOR_ANCHORS = {
    ANCHOR_CURSOR = true,
    ANCHOR_CURSOR_LEFT = true,
    ANCHOR_CURSOR_RIGHT = true,
}

local function IsSecret(value)
    return value ~= nil and issecretvalue(value)
end

-- An owned tooltip (SetOwner with ANCHOR_RIGHT etc.) keeps its position as
-- anchor type + offset. To move one we must know its current offset, which
-- the game can't tell us, so we remember the last SetOwner/SetAnchorType
-- call. "shift" is how far we moved it ourselves (to undo it when the
-- comparison goes away), "cursorX" where the mouse was when it appeared.
local anchors = setmetatable({}, { __mode = "k" })

local function SaveOffset(state, x, y)
    if IsSecret(x) or IsSecret(y) then
        state.x = nil -- unknown, don't move this tooltip
    else
        state.x, state.y = x or 0, y or 0
    end
end

local function Track(tooltip)
    if not tooltip or anchors[tooltip] then return end
    anchors[tooltip] = { x = 0, y = 0, shift = 0 }
    hooksecurefunc(tooltip, "SetOwner", function(self, _, _, x, y)
        local state = anchors[self]
        SaveOffset(state, x, y)
        state.shift = 0
        state.cursorX = nil
    end)
    hooksecurefunc(tooltip, "SetAnchorType", function(self, _, x, y)
        SaveOffset(anchors[self], x, y)
    end)
end

-- Moves a tracked tooltip dx units sideways (its own scale, negative = left).
-- Returns false if we can't move it safely.
local function Move(tooltip, dx)
    local state = anchors[tooltip]
    if not state then return false end

    local anchorType = tooltip:GetAnchorType()
    if anchorType == "ANCHOR_PRESERVE" then
        return false -- a tooltip the player placed, like a linked item
    end

    if anchorType and anchorType ~= "ANCHOR_NONE" then
        if not state.x then return false end
        tooltip:SetAnchorType(anchorType, state.x + dx, state.y)
    else
        -- placed with SetPoint: shift every point
        local count = tooltip:GetNumPoints()
        if count == 0 then return false end
        local points = {}
        for i = 1, count do
            points[i] = { tooltip:GetPoint(i) }
        end
        for _, p in ipairs(points) do
            tooltip:SetPoint(p[1], p[2], p[3], p[4] + dx, p[5])
        end
    end

    state.shift = state.shift + dx
    return true
end

local function HasSecretAnchor(frame)
    return frame.IsAnchoringSecret and frame:IsAnchoringSecret()
end

local function AnySecret(...)
    for i = 1, select("#", ...) do
        local value = select(i, ...)
        if value == nil or issecretvalue(value) then return true end
    end
    return false
end

local movedTooltip -- the tooltip we last moved, to undo it later
local arranging = false

local function Arrange(manager, primaryShown, secondaryShown)
    local tooltip, anchorFrame = manager.tooltip, manager.anchorFrame
    if not tooltip or not anchorFrame or not tooltip.shoppingTooltips then return end
    if not primaryShown and not secondaryShown then return end
    local primary, secondary = tooltip.shoppingTooltips[1], tooltip.shoppingTooltips[2]

    -- The frame the comparison goes next to. For an item shown inside
    -- another tooltip (quest rewards) that is the outer tooltip.
    local itemFrame = anchorFrame
    if anchorFrame.IsEmbedded then
        itemFrame = anchorFrame:GetParent():GetParent()
    end
    local mover = itemFrame.SetAnchorType and itemFrame or tooltip

    if HasSecretAnchor(itemFrame) or HasSecretAnchor(mover) or HasSecretAnchor(anchorFrame) then
        return
    end

    -- All sizes in screen units, since tooltips can have their own scale.
    local left, right = itemFrame:GetLeft(), itemFrame:GetRight()
    if AnySecret(left, right) then return end
    local itemScale = itemFrame:GetEffectiveScale()
    left, right = left * itemScale, right * itemScale
    local itemWidth = right - left

    local width = 0
    for _, compare in ipairs({ primaryShown and primary, secondaryShown and secondary }) do
        if compare then
            local w = compare:GetWidth()
            if AnySecret(w) then return end
            width = width + w * compare:GetEffectiveScale()
        end
    end

    local screenRight = GetScreenWidth() * UIParent:GetEffectiveScale()

    -- Where the item tooltip should start. A tooltip hanging off something
    -- you hover starts at the mouse; one at a fixed spot (or at the cursor
    -- already) stays where it is.
    local target = left
    local state = anchors[mover]
    local anchorType = mover.GetAnchorType and mover:GetAnchorType()
    if state and anchorType and anchorType ~= "ANCHOR_NONE" and anchorType ~= "ANCHOR_PRESERVE"
        and not CURSOR_ANCHORS[anchorType] then
        if not state.cursorX then
            local x = GetCursorPosition()
            if not IsSecret(x) then state.cursorX = x end
        end
        target = state.cursorX or left
    end
    if target + itemWidth + width > screenRight then
        target = screenRight - itemWidth - width
    end
    if target < 0 then
        target = 0 -- wider than the screen: start at the left edge
    end

    local dx = target - left
    if math.abs(dx) >= 0.5 then
        if Move(mover, dx / mover:GetEffectiveScale()) then
            movedTooltip = mover
            anchors[mover].owner = mover:GetOwner()
        elseif right + width > screenRight then
            -- can't move it and there's no room on the right: rather keep
            -- Blizzard's layout than let the comparison hang off the screen
            return
        end
    end

    primary:ClearAllPoints()
    secondary:ClearAllPoints()
    local first = primaryShown and primary or secondary
    first:SetPoint("TOP", anchorFrame, 0, 0)
    first:SetPoint("LEFT", itemFrame, "RIGHT")
    if primaryShown and secondaryShown then
        secondary:SetPoint("TOPLEFT", primary, "TOPRIGHT")
    end
end

-- Lays out the current comparison again, after a tooltip got its real size.
local function Rearrange()
    local manager = TooltipComparisonManager
    local tooltip = manager.tooltip
    if arranging or not tooltip or not tooltip.shoppingTooltips then return end
    local primaryShown = tooltip.shoppingTooltips[1]:IsShown()
    local secondaryShown = tooltip.shoppingTooltips[2]:IsShown()
    if not primaryShown and not secondaryShown then return end
    arranging = true
    Arrange(manager, primaryShown, secondaryShown)
    arranging = false
end

-- Comparison gone: put the item tooltip back where the game had it.
local function Restore(manager)
    if manager.tooltip or not movedTooltip then return end -- nothing was cleared
    local tooltip = movedTooltip
    movedTooltip = nil

    local state = anchors[tooltip]
    if state.shift ~= 0 and tooltip:IsShown() and tooltip:GetOwner() == state.owner then
        Move(tooltip, -state.shift)
    end
    state.shift = 0
end

for _, tooltip in ipairs({ GameTooltip, ItemRefTooltip }) do
    Track(tooltip)
    hooksecurefunc(tooltip, "Show", Rearrange)
end
for _, name in ipairs({ "GameTooltip", "ItemRefTooltip", "ShoppingTooltip1", "ShoppingTooltip2",
    "ItemRefShoppingTooltip1", "ItemRefShoppingTooltip2" }) do
    local frame = _G[name]
    if frame then frame:HookScript("OnSizeChanged", Rearrange) end
end
hooksecurefunc(TooltipComparisonManager, "AnchorShoppingTooltips", Arrange)
hooksecurefunc(TooltipComparisonManager, "Clear", Restore)
