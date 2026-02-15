fx_version 'cerulean'
game 'gta5'

name 'kid_farm'
author 'you'
description 'Kid-friendly farming loop with NUI tablet and MySQL-Async persistence'
version '2.0.0'

lua54 'yes'

ui_page 'html/index.html'

files {
    'html/index.html',
    'html/style.css',
    'html/app.js'
}

shared_script 'config.lua'

server_scripts {
    '@mysql-async/lib/MySQL.lua',
    'server/db.lua',
    'server/main.lua'
}

client_scripts {
    'client/main.lua'
}

dependencies {
    'mysql-async'
}