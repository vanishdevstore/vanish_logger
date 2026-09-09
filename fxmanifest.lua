fx_version 'cerulean'
game 'gta5'
lua54 'yes'

author 'vanishdev'
description 'Ships structured gameplay events to the Vanish Logs platform'
version '1.0.2'
repository 'https://github.com/vanishdevstore/vanish_logger'

-- Server scripts only. Load config first and main.lua last.
server_scripts {
    'config.lua',
    'server/limits.lua',
    'server/util.lua',
    'server/store.js',
    'server/queue.lua',
    'server/transport.lua',
    'bridge/framework/esx.lua',
    'bridge/inventory/ox_inventory.lua',
    'server/api.lua',
    'server/main.lua',
}

-- Framework and inventory dependencies are detected at runtime.
dependencies {
    '/server:6116',
}
