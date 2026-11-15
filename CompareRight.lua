-- Compare Right
--
-- When you compare an item, the game puts the "Equipped" tooltips on
-- whichever side of the item tooltip has more room. On the right half of the
-- screen that is the left side, so the order flips depending on where your
-- mouse is. This addon always uses the same order: the hovered item starts
-- at the left edge of what you hover (a bag slot, a list row), the equipped
-- item(s) follow to its right. If that doesn't fit on the screen, the whole
-- row moves left until it does.
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
--
-- Bag slots are protected (you can use items there), and a tooltip hanging
-- off one has secret anchors: the game ignores addons anchoring anything to
-- it. There we only move the item tooltip, anchored by its left edge with a
-- little room to its right. The bag lays out its comparison again right
-- after, with Blizzard's own (allowed) code, and that code puts it on the
-- right side when the tooltip is anchored that way and there is room.

local issecretvalue = issecretvalue or function() return false end

local CURSOR_ANCHORS = {
    ANCHOR_CURSOR = true,
    ANCHOR_CURSOR_LEFT = true,
    ANCHOR_CURSOR_RIGHT = true,
}

-- Room kept at the right screen edge (screen units). Blizzard only picks the
-- right side when the comparison fits with room to spare.
local EDGE = 4

local function IsSecret(value)
    return value ~= nil and issecretvalue(value)
end

-- An owned tooltip (SetOwner with ANCHOR_RIGHT etc.) keeps its position as
-- anchor type + offset. To move one we must know its current offset, which
-- the game can't tell us, so we remember the last SetOwner/SetAnchorType
-- call. To undo our move when the comparison goes away, "home" keeps the
-- game's anchor and "shift" how far we moved a hand-placed tooltip.
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
        state.home, state.shift = nil, 0
    end)
    hooksecurefunc(tooltip, "SetAnchorType", function(self, _, x, y)
        SaveOffset(anchors[self], x, y)
    end)
end

local function AnySecret(...)
    for i = 1, select("#", ...) do
        local value = select(i, ...)
        if value == nil or issecretvalue(value) then return true end
    end
    return false
end

-- "/compareright debug" prints what the addon does, for bug reports.
local debugging = false
local lastMessage

local function Debug(message, ...)
    if not debugging then return end
    local args = { ... }
    for i = 1, select("#", ...) do
        local value = args[i]
        if IsSecret(value) then
            args[i] = "secret"
        elseif type(value) == "number" then
            args[i] = ("%.0f"):format(value)
        else
            args[i] = tostring(value)
        end
    end
    message = message:format(unpack(args, 1, select("#", ...)))
    if message ~= lastMessage then -- bags redo the tooltip 5 times a second
        lastMessage = message
        print("|cff88ccffCompareRight:|r " .. message)
    end
end

-- Shifts a tooltip placed with SetPoint dx units sideways (its own scale).
local function ShiftPoints(tooltip, dx)
    local count = tooltip:GetNumPoints()
    if count == 0 then return false end
    local points = {}
    for i = 1, count do
        local point, relativeTo, relativePoint, x, y = tooltip:GetPoint(i)
        if AnySecret(point, x, y) or IsSecret(relativeTo) or IsSecret(relativePoint) then
            return false
        end
        points[i] = { point, relativeTo, relativePoint, x, y }
    end
    for _, p in ipairs(points) do
        tooltip:SetPoint(p[1], p[2], p[3], p[4] + dx, p[5])
    end
    anchors[tooltip].shift = anchors[tooltip].shift + dx
    return true
end

-- Moves a tracked tooltip so its left edge is at `target` (screen units;
-- `left` is where it is now). Returns false if we can't move it safely.
local function MoveTo(tooltip, target, left)
    local state = anchors[tooltip]
    if not state then return false end
    local scale = tooltip:GetEffectiveScale()

    local anchorType = tooltip:GetAnchorType()
    if anchorType == "ANCHOR_PRESERVE" then
        return false -- a tooltip the player placed, like a linked item
    end
    if not anchorType or anchorType == "ANCHOR_NONE" then
        return ShiftPoints(tooltip, (target - left) / scale)
    end
    if not state.x then return false end
    state.home = state.home or { anchorType, state.x, state.y }

    -- ANCHOR_LEFT (the game's choice on the right half of the screen) hangs
    -- the tooltip by its right edge. Hang it by its left edge instead, at the
    -- same height: then Blizzard's layout also prefers the right side.
    local owner = tooltip:GetOwner()
    local ownerRight = anchorType == "ANCHOR_LEFT" and owner and not IsSecret(owner)
        and owner.GetRight and owner:GetRight()
    if ownerRight and not IsSecret(ownerRight) then
        ownerRight = ownerRight * owner:GetEffectiveScale()
        tooltip:SetAnchorType("ANCHOR_RIGHT", (target - ownerRight) / scale, state.y)
    else
        tooltip:SetAnchorType(anchorType, state.x + (target - left) / scale, state.y)
    end
    return true
end

-- Tooltips hanging off bag slots have secret anchors; anchoring our
-- comparison to them doesn't work (see the top of the file).
local function CanAnchorTo(frame)
    if not frame.IsAnchoringSecret then return true end
    local secret = frame:IsAnchoringSecret()
    return not (IsSecret(secret) or secret)
end

-- Where an item tooltip hanging off `owner` should start, in screen units:
-- at the owner's left edge. That is right above a bag slot, or above the
-- start of a list row where its icon is (the game would put it at the far
-- end of the row, or left of a bag slot on the right half of the screen).
-- It is tied to the frame, not the mouse, so it doesn't wander.
local function StartAt(owner)
    if not owner or IsSecret(owner) or owner == UIParent or owner == WorldFrame
        or not owner.GetLeft then
        return nil
    end
    local ownerLeft = owner:GetLeft()
    if AnySecret(ownerLeft) then return nil end
    return ownerLeft * owner:GetEffectiveScale()
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

    -- All sizes in screen units, since tooltips can have their own scale.
    -- In some places (secret anchors) the game hides positions from addons;
    -- then we leave the layout alone.
    local left, right = itemFrame:GetLeft(), itemFrame:GetRight()
    if AnySecret(left, right) then
        Debug("stopped: item tooltip position is hidden (left %s, right %s)", left, right)
        return
    end
    local itemScale = itemFrame:GetEffectiveScale()
    left, right = left * itemScale, right * itemScale
    local itemWidth = right - left

    local width = 0
    for _, compare in ipairs({ primaryShown and primary, secondaryShown and secondary }) do
        if compare then
            local w = compare:GetWidth()
            if AnySecret(w) then
                Debug("stopped: comparison width is hidden (%s)", w)
                return
            end
            width = width + w * compare:GetEffectiveScale()
        end
    end

    local screenRight = GetScreenWidth() * UIParent:GetEffectiveScale()

    -- Where the item tooltip should start. One hanging off something you
    -- hover starts at its left edge; one at a fixed spot (or at the cursor)
    -- stays where it is.
    local target = left
    local anchorType = mover.GetAnchorType and mover:GetAnchorType()
    if anchors[mover] and anchorType and anchorType ~= "ANCHOR_NONE" and anchorType ~= "ANCHOR_PRESERVE"
        and not CURSOR_ANCHORS[anchorType] then
        target = StartAt(mover:GetOwner()) or left
    end
    if target + itemWidth + width + EDGE > screenRight then
        target = screenRight - itemWidth - width - EDGE
    end
    if target < 0 then
        target = 0 -- wider than the screen: start at the left edge
    end

    local canAnchor = CanAnchorTo(itemFrame) and CanAnchorTo(anchorFrame)
    Debug("%s, item %s-%s, comparison %s wide, screen %s: start at %s%s",
        anchorType, left, right, width, screenRight, target,
        canAnchor and "" or " (bag: Blizzard places the comparison)")
    if math.abs(target - left) >= 0.5 or (not canAnchor and anchorType == "ANCHOR_LEFT") then
        if MoveTo(mover, target, left) then
            movedTooltip = mover
            anchors[mover].owner = mover:GetOwner()
        elseif right + width > screenRight then
            -- can't move it and there's no room on the right: rather keep
            -- Blizzard's layout than let the comparison hang off the screen
            Debug("stopped: can't move this tooltip (%s) and there's no room", anchorType)
            return
        end
    end

    if not canAnchor then return end

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
    if tooltip:IsShown() and tooltip:GetOwner() == state.owner then
        if state.home then
            tooltip:SetAnchorType(unpack(state.home))
        elseif state.shift ~= 0 then
            ShiftPoints(tooltip, -state.shift)
        end
    end
    state.home, state.shift = nil, 0
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

SLASH_COMPARERIGHT1 = "/compareright"
SlashCmdList.COMPARERIGHT = function(msg)
    if msg and msg:lower():match("debug") then
        debugging = not debugging
        lastMessage = nil
        print("|cff88ccffCompareRight:|r debug " .. (debugging and "on" or "off"))
    else
        print("|cff88ccffCompareRight:|r no settings needed. /compareright debug prints what it does.")
    end
end
