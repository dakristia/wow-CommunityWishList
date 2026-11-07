-- Runs every registered test inside wowless at PLAYER_LOGIN, prints PASS/FAIL lines and quits with the result.
local T = CommunityWishList_Tests

local function runAll()
    local passed, failed = 0, 0
    for _, test in ipairs(T.tests) do
        local ok, err = pcall(test.fn)
        if ok then
            passed = passed + 1
            __wowless.printf("PASS %s\n", test.name)
        else
            failed = failed + 1
            __wowless.printf("FAIL %s: %s\n", test.name, tostring(err))
        end
    end
    __wowless.printf("RESULT %d passed, %d failed\n", passed, failed)
    __wowless.quit(failed == 0 and 0 or 1)
end

local f = CreateFrame("Frame")
f:RegisterEvent("PLAYER_LOGIN")
f:SetScript("OnEvent", runAll)
