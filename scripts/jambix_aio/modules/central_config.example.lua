-- Jambix AIO / central_config -- where the shared network lives
-- (intel/central.lua; CENTRAL_NETWORK.md).
--
-- Copy this file to central_config.lua (same folder), fill ONE of the two
-- forms in, and ship it with the plugin: every player's client then knows
-- the address. Contribution and downloads still stay OFF on every client
-- until the player turns them on (the Reactions page). A player can
-- override or switch the address off in scripts_data/jambix.aio.central.json
-- (the same keys).
return {
    -- Form 1: the GitHub repository as the service (CENTRAL_NETWORK.md §9).
    -- The uploads become issues the repository's Action files away; the
    -- model is read off the data branch. The token is a fine-grained
    -- personal access token for THIS repository only, with Issues: write,
    -- Contents: read, Metadata: read -- nothing else -- and an expiry; it is
    -- shared with every player, so rotate it with a plugin update when it
    -- expires or leaks. Anyone holding it can open issues here and read the
    -- repository; nothing more.
    github = {
        repo = "MrJambix/PS-Plugin",
        branch = "jambix-data",
        token = "github_pat_change_me",
    },

    -- Form 2: a central service (tools/fightlog_server/server.js) at an
    -- address of your own; the key is sent as X-Jambix-Key.
    -- url = "https://your-host.example/jambix",
    -- key = "change-me",
}
