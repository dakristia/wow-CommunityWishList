-- Shared helpers. Test files register checks with T.add, and Run.lua runs them at PLAYER_LOGIN.
local T = { tests = {} }
CommunityWishList_Tests = T

function T.add(name, fn)
    table.insert(T.tests, { name = name, fn = fn })
end

function T.check(cond, reason)
    if not cond then error(reason or "assertion failed", 2) end
end

function T.eq(actual, expected, what)
    if actual ~= expected then
        error(("%s: expected %s, got %s"):format(what or "value", tostring(expected), tostring(actual)), 2)
    end
end

-- A clock and a timer queue that tests advance by hand, so jitter and throttling are deterministic.
function T.fakeClock(start)
    local clock = { t = start or 1000, timers = {} }
    function clock.now() return clock.t end
    function clock.after(seconds, fn)
        table.insert(clock.timers, { at = clock.t + seconds, fn = fn })
    end
    function clock.advance(seconds)
        local target = clock.t + seconds
        while true do
            table.sort(clock.timers, function(a, b) return a.at < b.at end)
            local nextTimer = clock.timers[1]
            if not nextTimer or nextTimer.at > target then break end
            table.remove(clock.timers, 1)
            clock.t = nextTimer.at
            nextTimer.fn()
        end
        clock.t = target
    end
    return clock
end

-- A fresh store on an empty db, for tests that must not share state.
function T.newStore(me, guildName, clock)
    clock = clock or T.fakeClock()
    return CommunityWishList.Store.new({
        db = {},
        me = me,
        now = clock.now,
        guild = function() return guildName end,
    }), clock
end
