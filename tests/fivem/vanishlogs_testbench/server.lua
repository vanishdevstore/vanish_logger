-- Local, console-only probes. Never touches a player's inventory or money.
local temporaryInventory, originalEndpoint, lastRun
local function status()
    print('[vanishlogs_testbench] ' .. json.encode(exports.vanish_logger:GetStatus()))
end
local function probe(id, action)
    return exports.vanish_logger:Log({
        eventId = id, category = 'inventory', action = action,
        actor = { name = 'Local FiveM Test', characterId = '900001' },
        resource = 'vanishlogs_testbench', correlationId = lastRun,
        data = { item = 'water', itemLabel = 'Water', quantity = 1, test = true }
    })
end
RegisterCommand('vanishlogs_test', function(source, args)
    if source ~= 0 then return end
    CreateThread(function()
        local ok, err = pcall(function()
            assert(GetResourceState('vanish_logger') == 'started', 'Start vanish_logger first')
            local mode = args[1] or 'status'
            if mode == 'run' then
                lastRun = ('local-fivem-%d-%d'):format(os.time(), GetGameTimer())
                assert(probe(lastRun .. '-custom', 'item_transfer'), 'Custom event rejected')
                assert(probe(lastRun .. '-custom', 'item_transfer'), 'Duplicate probe rejected locally')
                assert(not exports.vanish_logger:Log({ action = 'missing_category' }), 'Malformed event accepted')
                temporaryInventory = exports.ox_inventory:CreateTemporaryStash({ label = 'Vanish Logs E2E (temporary)', slots = 5, maxWeight = 10000, items = {} })
                assert(temporaryInventory, 'Temporary stash creation failed')
                local added, response = exports.ox_inventory:AddItem(temporaryInventory, 'water', 3, { vanishlogsTest = lastRun })
                assert(added, 'Inventory AddItem failed: ' .. tostring(response))
                Wait(300)
                exports.vanish_logger:Flush()
                print('[vanishlogs_testbench] ' .. json.encode({runId=lastRun, inventoryId=temporaryInventory, added=added, duplicateQueued=true, invalidRejected=true}))
            elseif mode == 'demo' then
                lastRun = ('live-demo-%d-%d'):format(os.time(), GetGameTimer())
                local actions = {'item_added','item_transfer','stash_deposit','stash_withdrawal','item_used','item_transfer','item_added','stash_deposit'}
                local items = {{'water','Water'},{'bread','Bread'},{'lockpick','Lockpick'},{'water','Water'},{'bread','Bread'},{'water','Water'},{'weapon_pistol','Pistol'},{'lockpick','Lockpick'}}
                for index, action in ipairs(actions) do
                    assert(exports.vanish_logger:Log({
                        eventId = lastRun .. '-' .. index, category = 'inventory', action = action,
                        actor = {name = 'Live Demo Player', characterId = '900001'},
                        resource = 'vanishlogs_testbench', correlationId = lastRun,
                        severity = items[index][1] == 'weapon_pistol' and 'notice' or 'info',
                        context = {fromInventory={id='vanishlogs_demo_player',type='player'},toInventory={id='vanishlogs_demo_stash',type='stash'}},
                        data = {item=items[index][1],itemLabel=items[index][2],quantity=index,test=true,demo=true}
                    }), 'Demo event refused')
                    exports.vanish_logger:Flush()
                    Wait(1500)
                end
                print('[vanishlogs_testbench] Sent 8 synthetic live demo events: ' .. lastRun)
            elseif mode == 'outage' then
                assert(not originalEndpoint, 'Outage test already active')
                lastRun = ('local-recovery-%d-%d'):format(os.time(), GetGameTimer())
                originalEndpoint = GetConvar('vanishlogs_endpoint', '')
                SetConvar('vanishlogs_endpoint', 'http://127.0.0.1:9')
                assert(probe(lastRun .. '-queued', 'recovery_probe'), 'Recovery event rejected')
                exports.vanish_logger:Flush()
                print('[vanishlogs_testbench] Recovery probe queued: ' .. lastRun)
            elseif mode == 'restore' then
                assert(originalEndpoint, 'No outage test active')
                SetConvar('vanishlogs_endpoint', originalEndpoint)
                originalEndpoint = nil
                exports.vanish_logger:Flush()
                print('[vanishlogs_testbench] Original endpoint restored')
            elseif mode == 'cleanup' then
                if temporaryInventory then exports.ox_inventory:RemoveInventory(temporaryInventory); temporaryInventory=nil end
                print('[vanishlogs_testbench] Temporary inventory removed')
            end
            status()
        end)
        if not ok then print('[vanishlogs_testbench] FAILED: ' .. tostring(err)) end
    end)
end, false)
AddEventHandler('onResourceStop', function(resource)
    if resource ~= GetCurrentResourceName() then return end
    if originalEndpoint then SetConvar('vanishlogs_endpoint', originalEndpoint) end
    if temporaryInventory then exports.ox_inventory:RemoveInventory(temporaryInventory) end
end)
