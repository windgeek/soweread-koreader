local Dispatcher=require("dispatcher")

local Actions={}
local registered=false

local general_actions={
    {"soweread_show","ShowSoweRead","轻松读：打开轻松读书架"},
    {"soweread_return_home","SoweReadReturnHome","轻松读：退出阅读并返回轻松读"},
    {"soweread_toggle_progress_sync","ToggleSoweReadProgressSync","轻松读：开关自动同步进度"},
    {"soweread_toggle_time_sync","ToggleSoweReadTimeSync","轻松读：开关自动同步时间"},
    {"soweread_downloads","ShowSoweReadDownloads","轻松读：下载管理"},
    {"soweread_sync_status","ShowSoweReadSyncStatus","轻松读：同步状态"},
    {"soweread_qr_login","SoweReadQRLogin","轻松读：扫码登录"},
    {"soweread_logout","SoweReadLogout","轻松读：退出登录"},
}

local reader_actions={
    {"soweread_reader_panel","SoweReadReaderPanel","轻松读：打开阅读控制中心"},
    {"soweread_reader_font","SoweReadReaderFont","轻松读：字体与字号"},
    {"soweread_reader_typeset","SoweReadReaderTypeset","轻松读：完整排版面板"},
    {"soweread_reader_progress","SoweReadReaderProgress","轻松读：阅读进度"},
    {"soweread_upload_progress","SoweReadUploadProgress","轻松读：上传当前进度"},
    {"soweread_pull_progress","SoweReadPullProgress","轻松读：读取云端进度"},
    {"soweread_current_book","SoweReadCurrentBook","轻松读：当前书籍"},
}

function Actions.register()
    if registered then return end
    registered=true
    for _,row in ipairs(general_actions) do
        Dispatcher:registerAction(row[1],{
            category="none",event=row[2],title=row[3],general=true,
        })
    end
    for _,row in ipairs(reader_actions) do
        Dispatcher:registerAction(row[1],{
            category="none",event=row[2],title=row[3],reader=true,
        })
    end
    Dispatcher:registerAction("soweread_close_book",{
        category="none",event="SoweReadCloseBook",title="轻松读：退出阅读并返回书架",reader=true,
    })
end

return Actions
