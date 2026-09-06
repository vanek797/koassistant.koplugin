--[[--
Group pages (G0, docs/group_hub_plan.md, 2026-09-06): two full-screen
singletons in the Book Hub's shape.

- The GROUP HUB: THE per-group screen — GroupsUI.showGroup opens it, so every
  entry point and every group flow's reopen lands here. Rows: a dim hint, the
  members in order (tap = that book's Book Hub, hold = the move / open /
  remove dialog; the open book's row says "open"), then Add books…, Add all
  books in a folder…, the fold row, Library chat…. The title-bar hamburger
  holds Rename…, Kind…, Delete group…. Subtitle = the members' authors, the
  kind and the count. Up-arrow = the Groups list.
- The GROUPS LIST: THE all-groups screen — GroupsUI.showManager opens it.
  Rows: every group (tap = its hub), then New group…, New group from
  folder…, and with a book open New group with this book… + the series
  suggestion.

Both are strictly VIEWS: nothing generated, nothing stored. Group settings
(G1) and the series view (G3) arrive as hub rows.

Stacking rule: overlays (pickers, dialogs, the library input dialog, a
member's Book Hub, an X-Ray browser a fold opens, the hub over the list)
stack on top, and a page REBUILDS its rows on the repaint that reveals it
again (the Book Hub's paintTo hook + stale flag). The flows' reopen calls
(`GroupsUI.showGroup` / `GroupsUI.showManager`) mark the page stale instead
of reopening; entry points pass `front = true` for a fresh page on top.
Closing a page runs opts.on_close (the per-book screen's or Book Settings'
reopen), except when code closes it (a deleted group, the up-arrow, the
book-open ghost sweep in main.lua, which nils `_menu` / `_list_menu`).
]]

local UIManager = require("ui/uimanager")
local Menu = require("ui/widget/menu")
local Screen = require("device").screen
local Constants = require("koassistant_constants")
local T = require("ffi/util").template
local _ = require("koassistant_gettext")
local logger = require("koassistant_logger")

local GroupPage = {}

local function groups() return require("koassistant_book_groups") end
local function groupsUI() return require("koassistant_book_groups_ui") end

-- Conditional emoji: the Book Hub's rule (only with the icons setting on)
local function E(emoji, text, enable) return Constants.getEmojiText(emoji, text, enable) end

local function emojiSetting(plugin, given)
    if given ~= nil then return given end
    local f = plugin and plugin.settings and plugin.settings:readSetting("features") or {}
    return f.enable_emoji_icons == true
end

-- ---------------------------------------------------------------- page plumbing
-- Two singletons share it: slot "" = the hub (fields _menu/_ctx/…), slot
-- "_list" = the groups list (_list_menu/_list_ctx/…). The ghost sweep in
-- main.lua closes both by field name.
local function closePage(slot, opts)
    local menu = GroupPage[slot .. "_menu"]
    if not menu then return end
    GroupPage[slot .. "_silent"] = (opts and opts.silent) and true or nil
    UIManager:close(menu)
end

--- Open a page, or refresh the open one when it already shows `ctx.key`
--- (the flows' reopen; `ctx.front` forces a fresh page on top).
--- build(ctx) → { title, subtitle, items } or nil (gone).
--- extra: { hamburger = fn(ctx), on_return = fn(ctx) }
local function openPage(slot, ctx, build, extra)
    local mk, ck, sk = slot .. "_menu", slot .. "_ctx", slot .. "_stale"
    local cur = GroupPage[ck]
    if GroupPage[mk] and cur and cur.key == ctx.key and not ctx.front then
        GroupPage[sk] = true
        UIManager:setDirty(GroupPage[mk], "ui")
        return
    end
    closePage(slot, { silent = true })
    GroupPage[ck] = ctx
    GroupPage[sk] = nil
    local first = build(ctx)
    if not first then GroupPage[ck] = nil return end
    extra = extra or {}
    local menu
    menu = Menu:new{
        title = first.title,
        subtitle = first.subtitle,
        item_table = first.items,
        is_borderless = true,
        is_popout = false,
        width = Screen:getWidth(),
        height = Screen:getHeight(),
        single_line = true,
        items_font_size = 18,
        items_mandatory_font_size = 14,
        title_bar_left_icon = extra.hamburger and "appbar.menu" or nil,
        onLeftButtonTap = extra.hamburger and function() extra.hamburger(ctx) end or nil,
        onReturn = extra.on_return and function() extra.on_return(ctx) end or nil,
        -- NOTE: no close_callback — Menu fires it after EVERY item tap (the
        -- Book Hub's trap); on_close rides onCloseWidget below
        onMenuSelect = function(_menu, item)
            if item and item.callback then
                GroupPage[sk] = true
                item.callback()
            end
            return true
        end,
        onMenuHold = function(_menu, item)
            if item and item.hold_callback then
                GroupPage[sk] = true
                item.hold_callback()
            end
            return true
        end,
    }
    GroupPage[mk] = menu
    if extra.on_return then
        -- The bottom-left return arrow shows with onReturn and enables with a
        -- non-empty path trace (the X-Ray browser's seed)
        table.insert(menu.paths, true)
        menu:updatePageInfo()
    end
    local orig_onCloseWidget = menu.onCloseWidget
    menu.onCloseWidget = function(menu_self)
        local mine = GroupPage[mk] == menu_self
        local silent = GroupPage[slot .. "_silent"]
        GroupPage[slot .. "_silent"] = nil
        local on_close = mine and GroupPage[ck] and GroupPage[ck].on_close or nil
        if mine then GroupPage[mk] = nil end
        -- The ghost sweep nils the menu before closing: ours too, silently
        if not GroupPage[mk] then GroupPage[ck] = nil end
        if orig_onCloseWidget then orig_onCloseWidget(menu_self) end
        if mine and not silent and on_close then on_close() end
    end
    -- Lazy in-place refresh: the first repaint after a row opened something
    -- (or a flow asked for a reopen) rebuilds rows + title bar from disk
    -- truth; itemnumber -1 keeps the page the reader was on
    local orig_paintTo = menu.paintTo
    menu.paintTo = function(menu_self, ...)
        if GroupPage[sk] and GroupPage[mk] == menu_self then
            GroupPage[sk] = nil
            local fresh = build(ctx)
            if fresh then
                menu_self:switchItemTable(fresh.title, fresh.items, -1, nil, fresh.subtitle)
            end
        end
        return orig_paintTo(menu_self, ...)
    end
    UIManager:show(menu)
end

-- ---------------------------------------------------------------- the hub
local function authorsLine(authors)
    if #authors == 0 then return nil end
    if #authors == 1 then return authors[1] end
    if #authors == 2 then return authors[1] .. ", " .. authors[2] end
    return T(_("%1, %2 +%3"), authors[1], authors[2], #authors - 2)
end

local function hubBuild(ctx)
    local BookGroups = groups()
    local GroupsUI = groupsUI()
    local group = BookGroups.byId(ctx.group_id)
    if not group then return nil end
    local items = {}
    local flow_opts = { plugin = ctx.plugin, ui = ctx.ui, on_close = ctx.on_close }
    local open_file = ctx.ui and ctx.ui.document and ctx.ui.document.file
    local em = ctx.enable_emoji
    -- Help line at the top (maintainer): the hold gesture is the one thing a
    -- reader cannot see
    items[#items + 1] = {
        text = _("Tap a book for its hub. Hold it to move, open or remove it."),
        dim = true,
        callback = function() end,
    }
    local authors, seen = {}, {}
    for i, path in ipairs(group.books) do
        local captured = path
        local raw_title, author = BookGroups.displayProps(captured, ctx.ui)
        if author then
            -- KOReader joins several authors with newlines; the first one names the book
            local first = author:match("^[^\n]+") or author
            if not seen[first] then
                seen[first] = true
                authors[#authors + 1] = first
            end
        end
        local title = raw_title
        if not BookGroups.fileExists(captured) then
            title = title .. " " .. _("(missing)")
        end
        items[#items + 1] = {
            text = E("\u{1F4D6}", i .. ". " .. title, em),
            mandatory = captured == open_file and _("open") or nil,
            callback = function()
                -- A member row opens the member's Book Hub; it stacks over this
                -- page, and its up-arrow comes back here
                require("koassistant_book_page").show({
                    file = captured, plugin = ctx.plugin, ui = ctx.ui,
                    title = raw_title, author = author, enable_emoji = em,
                })
            end,
            hold_callback = function()
                GroupsUI.showMoveDialog(ctx.group_id, captured, flow_opts)
            end,
        }
    end
    if #group.books == 0 then
        items[#items + 1] = {
            text = _("No books yet. Add some below."),
            dim = true,
            callback = function() end,
        }
    end
    local function row(text, fn)
        items[#items + 1] = { text = text, callback = fn }
    end
    row(E("\u{2795}", _("Add books…"), em),
        function() GroupsUI.addBooksFlow(ctx.group_id, flow_opts) end)
    row(E("\u{2795}", _("Add all books in a folder…"), em),
        function() GroupsUI.addFolderFlow(ctx.group_id, flow_opts) end)
    local kind = BookGroups.kindOf(group)
    -- A2/A3: the fold surface the kind picker promises — series chain or
    -- project fan-in. Plain groups share nothing by design: no row.
    if #group.books > 1 and ctx.plugin and ctx.plugin._startCrossBookXrayFlow
        and BookGroups.sharesKnowledge(group) then
        row(E("\u{1F500}", kind == BookGroups.KIND_PROJECT
                and _("Fold X-Rays into one book…") or _("Merge series X-Rays…"), em),
            function() GroupsUI.foldFlow(ctx.group_id, flow_opts) end)
    end
    -- Item 48(a): the group as launch surface — library chat/actions with the
    -- members pre-selected
    if #group.books > 0 and ctx.plugin and ctx.plugin.openLibraryDialogForGroup then
        row(E("\u{1F4DA}", _("Library chat…"), em),
            function() ctx.plugin:openLibraryDialogForGroup(ctx.group_id) end)
    end
    local subtitle = T(_("%1 \u{00B7} %2 books"), GroupsUI.kindLabel(kind), #group.books)
    local by = authorsLine(authors)
    if by then subtitle = by .. " \u{00B7} " .. subtitle end
    return { title = GroupsUI.displayName(group), subtitle = subtitle, items = items }
end

local function hubHamburger(ctx)
    local ButtonDialog = require("ui/widget/buttondialog")
    local GroupsUI = groupsUI()
    local group = groups().byId(ctx.group_id)
    if not group then return end
    local flow_opts = { plugin = ctx.plugin, ui = ctx.ui, on_close = ctx.on_close }
    local dialog
    local function pick(fn)
        return function()
            UIManager:close(dialog)
            GroupPage._stale = true
            fn()
        end
    end
    dialog = ButtonDialog:new{
        title = GroupsUI.displayName(group),
        buttons = {
            {{ text = _("Rename…"), callback = pick(function() GroupsUI.renameFlow(ctx.group_id, flow_opts) end) }},
            {{ text = T(_("Kind: %1"), GroupsUI.kindLabel(groups().kindOf(group))),
                callback = pick(function() GroupsUI.kindPicker(ctx.group_id, flow_opts) end) }},
            {{ text = _("Delete group…"), callback = pick(function() GroupsUI.deleteFlow(ctx.group_id, flow_opts) end) }},
        },
    }
    UIManager:show(dialog)
end

--- Close the hub. opts.silent = do not run on_close (code-driven closes).
function GroupPage.close(opts) closePage("", opts) end

--- Show (or refresh) the hub for one group.
--- @param opts table { group_id (required), plugin, ui, on_close, front,
---   enable_emoji (nil = the icons setting) }
function GroupPage.show(opts)
    local group_id = opts and opts.group_id
    if not group_id then return end
    if not groups().byId(group_id) then
        -- Gone (the delete flow's reopen lands here): drop the page and hand
        -- control back the way the old screen did
        local on_close = (GroupPage._ctx and GroupPage._ctx.on_close) or opts.on_close
        GroupPage.close({ silent = true })
        if on_close then on_close() end
        return
    end
    logger.dbg("KOAssistant GroupHub: show", group_id)
    openPage("", {
        key = group_id, group_id = group_id, plugin = opts.plugin, ui = opts.ui,
        on_close = opts.on_close, front = opts.front,
        enable_emoji = emojiSetting(opts.plugin, opts.enable_emoji),
    }, hubBuild, {
        hamburger = hubHamburger,
        on_return = function(ctx)
            -- Up = the Groups list: refreshed underneath when the hub was
            -- opened from it, fresh otherwise (on_close stays unrun: this is
            -- navigation, not a close)
            GroupPage.close({ silent = true })
            GroupPage.showList({ plugin = ctx.plugin, ui = ctx.ui, enable_emoji = ctx.enable_emoji })
        end,
    })
end

-- ---------------------------------------------------------------- the list
local function listBuild(ctx)
    local BookGroups = groups()
    local GroupsUI = groupsUI()
    local items = {}
    local em = ctx.enable_emoji
    for _idx, group in ipairs(BookGroups.all()) do
        local captured = group
        items[#items + 1] = {
            text = E("\u{1F5C2}\u{FE0F}", GroupsUI.displayName(captured), em),
            mandatory = #captured.books == 1 and _("1 book") or T(_("%1 books"), #captured.books),
            callback = function()
                GroupsUI.showGroup(captured.id, { plugin = ctx.plugin, ui = ctx.ui,
                    front = true, enable_emoji = em })
            end,
        }
    end
    if #items == 0 then
        items[#items + 1] = {
            text = _("No groups yet. A group is an ordered set of books: a series, an author, a project."),
            dim = true,
            callback = function() end,
        }
    end
    local flow_opts = { plugin = ctx.plugin, ui = ctx.ui }
    local function row(text, fn)
        items[#items + 1] = { text = text, callback = fn }
    end
    row(E("\u{2795}", _("New group…"), em), function() GroupsUI.newGroupFlow(flow_opts) end)
    row(E("\u{2795}", _("New group from folder…"), em),
        function() GroupsUI.newGroupFromFolderFlow(flow_opts) end)
    local open_file = ctx.ui and ctx.ui.document and ctx.ui.document.file
    if open_file then
        row(E("\u{2795}", _("New group with this book…"), em),
            function() GroupsUI.newGroupWithBookFlow(open_file, flow_opts) end)
        -- P5 item 7: the open book's series tag, one tap to a group named
        -- after it (then the find-the-rest scan)
        local series_row = GroupsUI.seriesRowFor(open_file, flow_opts)
        if series_row then row(E("\u{2795}", series_row.text, em), series_row.callback) end
    end
    return { title = _("Groups"), items = items }
end

--- Close the list. opts.silent = do not run on_close.
function GroupPage.closeList(opts) closePage("_list", opts) end

--- Show (or refresh) the Groups list.
--- @param opts table { plugin, ui, on_close, front, enable_emoji }
function GroupPage.showList(opts)
    opts = opts or {}
    logger.dbg("KOAssistant GroupHub: list")
    openPage("_list", {
        key = "list", plugin = opts.plugin, ui = opts.ui,
        on_close = opts.on_close, front = opts.front,
        enable_emoji = emojiSetting(opts.plugin, opts.enable_emoji),
    }, listBuild)
end

return GroupPage
