local PluginSettings=require("soweread.plugin_settings")

local M={}

function M.home(plugin)
    plugin:maybe_auto_check_update(false)
    return {
        {text="我的书架",callback=plugin:safe("shelf",function() plugin:show_shelf(false,false,"account") end)},
        {text=plugin:_download_menu_text(),callback=plugin:safe("downloads",function() plugin:show_downloads() end)},
        {text=plugin:_sync_menu_text(),sub_item_table_func=function() return PluginSettings.sync(plugin) end},
        {text="账号",sub_item_table_func=function() return plugin:account_menu() end},
        {text="插件设置",sub_item_table_func=function() return PluginSettings.menu(plugin) end},
    }
end

function M.reader(plugin)
    plugin:maybe_auto_check_update(false)
    return {
        {text="当前书籍",sub_item_table_func=function() return plugin:current_book_menu() end},
        {text="打开轻松读书架",callback=plugin:safe("shelf",function() plugin:show_shelf(false,false,"account") end)},
        {text=plugin:_sync_menu_text(),sub_item_table_func=function() return PluginSettings.sync(plugin) end},
        {text=plugin:_download_menu_text(),callback=function() plugin:show_downloads() end},
        {text="插件设置",sub_item_table_func=function() return PluginSettings.menu(plugin) end},
    }
end

return M
