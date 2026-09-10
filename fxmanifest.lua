fx_version 'cerulean'
game 'gta5'
lua54 'yes'

author 'vanishdev'
description 'Ships structured gameplay events to the Vanish Logs platform'
version '1.0.4'
repository 'https://github.com/vanishdevstore/vanish_logger'

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

dependencies {
    '/server:6116',
}
