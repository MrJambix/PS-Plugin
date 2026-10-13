-- Jambix AIO / react / intel / replay -- Stage 13 of PVP_INTEL_PLAN.md (the
-- Stage 11 bench's last piece): your recorded fights as test-bench
-- situations, and a reaction replayed over all of them.
--
-- Each decision episode the debrief kept (scripts_data/jambix.aio.fights.json,
-- the newest fights first) carries a compact picture of the moment before:
-- your health, the threat, the target's band and distance, how many were on
-- you, whether you were controlled, the defensives you had ready, the
-- target's health and whether it was on you, its class, the time into the
-- fight, the move and the bait advised. That picture becomes a bench
-- situation (react/custom.lua's), so:
--
--   situations()   the recorded moments, newest first, for the bench's list
--                  ("Replay: lost vs rogue, a rogue opens on you, 4 s in")
--   run(r)         a reaction (a draft or a saved one) judged at each of them
--                  by custom.bench: where it would have acted, where its
--                  conditions held but nothing could go, where it would not
--
-- What a moment does not carry is not invented: your mana, the target's
-- cooldowns, the tactical state, a second enemy's class -- the bench's
-- defaults stand for them, and each situation's `unrecorded` says which.

return function(P, lib, data, K)
    local floor, max, min = math.floor, math.max, math.min
    local KR = K.REPLAY

    local M = {}

    local TYPE_LABEL = {}
    for _, t in ipairs(data.EPISODE_TYPES or {}) do TYPE_LABEL[t.key] = t.label end

    M.UNRECORDED = "your mana, the target's cooldowns, the tactical state and any second player's class are not recorded: the bench's defaults stand in"

    local function pct(x, default) return x and floor(x * 100 + 0.5) or default end

    --- One recorded moment as a bench situation.
    function M.situation_of(ep, fight)
        local b = ep.before or {}
        local class = type(ep.enemy_class) == "string" and ep.enemy_class ~= "?" and ep.enemy_class:lower() or nil
        local attackers = tonumber(b.attackers) or 0
        local zone = b.zone
        local rec = ep.recommendation or {}
        return {
            in_combat = true, hp = pct(b.hp, 100), power = 70, target = true,
            t_hp = pct(b.foe_hp, 80), t_distance = max(0, tonumber(b.gap) or 20),
            on_me = attackers, melee_on_me = (zone == "melee" and b.foe_on_me) and 1 or 0, engaged = max(1, attackers),
            t_player = true, t_on_me = b.foe_on_me == true, pvp = true, players = max(1, attackers),
            where = (fight and fight.mode == "bg") and "bg" or "world_pvp", combat_time = tonumber(ep.t) or 0,
            t_name = class and ("a " .. class) or "a player", pet = true, pet_hp = 90,
            pvp_threat = b.threat or "INFORMATIONAL", controlled = b.controlled == true, control_helpless = b.controlled == true,
            me_dead_zone = zone == "dead_zone", me_safe_escape = nil,
            pvp_advice = rec.move or "none", pvp_bait = rec.bait or "none",
            t_kill_verdict = "NO_KILL_OPPORTUNITY", t_kill_conf = 0,
        }
    end

    --- The recorded moments, newest fight first, at most KR.max_moments.
    ---@return table[] { key, label, s, type, enemy_class, t, outcome, did, advised }
    function M.situations()
        local out = {}
        local D = lib.debrief
        local log = D and D.log and D.log() or {}
        for fi = #log, 1, -1 do
            local f = log[fi]
            local eps = type(f) == "table" and f.episodes or nil
            if type(eps) == "table" then
                for _, ep in ipairs(eps) do
                    if type(ep) == "table" and type(ep.before) == "table" and not (ep.quality and ep.quality.test_data) then
                        local class = type(ep.enemy_class) == "string" and ep.enemy_class:lower() or "?"
                        out[#out + 1] = {
                            key = "replay_" .. tostring(ep.id or (#out + 1)),
                            label = string.format("Replay: %s vs %s, %s, %d s in", tostring(f.outcome or "?"), class,
                                TYPE_LABEL[ep.type] or tostring(ep.type), floor((tonumber(ep.t) or 0) + 0.5)),
                            s = M.situation_of(ep, f), type = ep.type, enemy_class = ep.enemy_class, t = ep.t,
                            outcome = f.outcome, did = ep.actions or {}, advised = ep.recommendation and ep.recommendation.action or nil,
                            unrecorded = M.UNRECORDED,
                        }
                        if #out >= KR.max_moments then return out end
                    end
                end
            end
        end
        return out
    end

    --- A reaction replayed over every recorded moment.
    ---@param r table a reaction (custom.lua's shape)
    ---@return table { moments, acted, held, not_here, list = { {label, verdict, tone, did, advised} }, line }
    function M.run(r)
        local C = P.react and P.react.custom or nil
        local res = { moments = 0, acted = 0, held = 0, not_here = 0, list = {}, line = "" }
        if not (C and C.bench and r) then res.line = "the reaction engine did not load" return res end
        local list = M.situations()
        for i = 1, #list do
            local m = list[i]
            local ok, b = pcall(C.bench, r, m.s)
            res.moments = res.moments + 1
            if ok and type(b) == "table" then
                if b.tone == "ok" then res.acted = res.acted + 1
                elseif b.tone == "wait" then res.held = res.held + 1
                else res.not_here = res.not_here + 1 end
                res.list[#res.list + 1] = { label = m.label, verdict = b.verdict, tone = b.tone,
                                            did = table.concat(m.did or {}, ", "), advised = m.advised }
            else
                res.not_here = res.not_here + 1
                res.list[#res.list + 1] = { label = m.label, verdict = "failed: " .. tostring(b), tone = "off" }
            end
        end
        res.line = res.moments == 0 and "No recorded fight with a player yet: fight one with the fight debriefs on."
            or string.format("Over your recorded fights it would have acted at %d of %d moments (%d with its conditions not holding, %d not there).",
                res.acted, res.moments, res.held, res.not_here)
        return res
    end

    return M
end
