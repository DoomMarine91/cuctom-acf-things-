-- Client-side visual-only XYZ scaling for Clean Slate ACF missiles.
-- Physics, collision bounds, native guidance and flight are not modified.
if not CLIENT then return end

local nextScaleRefresh = 0

hook.Add("Think", "ACFM_CleanSlate_ApplyVisualScale", function()
    local now = CurTime()
    if now < nextScaleRefresh then return end
    nextScaleRefresh = now + 0.10

    for _, missile in ipairs(ents.FindByClass("acf_missile")) do
        if not IsValid(missile) then continue end

        local active = missile:GetNWBool("ACFM_CleanModelScaleActive", false)
        local scale = missile:GetNWVector("ACFM_CleanModelScale", Vector(1, 1, 1))
        local previous = missile.ACFM_CleanAppliedScale

        if active then
            if not isvector(previous) or previous:DistToSqr(scale) > 0.000001 then
                local matrix = Matrix()
                matrix:Scale(scale)
                missile:EnableMatrix("RenderMultiply", matrix)
                missile.ACFM_CleanAppliedScale = Vector(scale.x, scale.y, scale.z)
            end
        elseif previous then
            missile:DisableMatrix("RenderMultiply")
            missile.ACFM_CleanAppliedScale = nil
        end
    end
end)
