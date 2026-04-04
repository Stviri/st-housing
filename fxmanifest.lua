fx_version 'cerulean'
game 'rdr3'
rdr3_warning 'I acknowledge that this is a prerelease build of RedM, and I am aware my resources *will* become incompatible once RedM ships.'

name 'st-housing'
description 'Stviri Systems — Player Housing System'
version '1.0.0'

shared_scripts {
    '@ox_lib/init.lua',
    'shared/config.lua',
}

ui_page 'html/furniture_shop.html'

files {
    'html/furniture_shop.html',
}

client_scripts {
    'client/prompts.lua',
    'client/doors.lua',
    'client/placement.lua',
    'client/building.lua',
    'client/furniture.lua',
    'client/furniture_nui.lua',
    'client/client.lua',
}

server_scripts {
    '@oxmysql/lib/MySQL.lua',
    'server/tax.lua',
    'server/server.lua',
}

dependencies {
    'rsg-core',
    'ox_lib',
    'oxmysql',
    'ox_target',
    'rsg-inventory',
    'three_houses'
}

lua54 'yes'
