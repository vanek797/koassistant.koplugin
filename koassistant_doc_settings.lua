--[[--
Safe access to a book's DocSettings (KOReader's metadata.lua sidecar).

KOReader owns metadata.lua: it keeps ONE live in-memory DocSettings per open
book and flushes the WHOLE file (all keys) on autosave and book close. If the
plugin opens a second DocSettings instance for a book that is currently open,
two divergent in-memory copies of the same file exist; whichever flushes last
wins wholesale — silently reverting the other's keys, including KOReader's own
annotations and reading progress (issue #72: highlight/note/progress loss).

Therefore every plugin read or write of a book's DocSettings must go through
resolve(), which returns the live ReaderUI instance's doc_settings whenever the
target book is the open one — regardless of what the caller has in hand. A
fresh DocSettings:open() is only returned for books that are NOT open (safe:
no live co-writer exists).

Paths are compared via realpath, not string equality: the same open book can be
reached through different spellings (symlinks; Android's /sdcard vs
/storage/emulated/0 aliases), and a raw == check would silently fall through to
the dangerous fresh-instance path.
]]

local logger = require("koassistant_logger")

local SafeDocSettings = {}

--- Do two paths refer to the same file? Tolerates aliases (symlinks, Android
--- storage mounts). Cheap string equality first; realpath only on mismatch.
--- @return boolean
function SafeDocSettings.samePath(a, b)
    if not a or not b then return false end
    if a == b then return true end
    local ok, ffiutil = pcall(require, "ffi/util")
    if not ok or not ffiutil.realpath then return false end
    local ra = ffiutil.realpath(a)
    return ra ~= nil and ra == ffiutil.realpath(b)
end

--- Resolve the RAW DocSettings instance for a document (KOReader's object,
--- no plugin-key routing). Only the migration and the facade itself need
--- this; every other caller wants resolve().
--- @param document_path string|nil target book (nil = the caller's own open book)
--- @param ui table|nil optional ReaderUI-like instance the caller has in hand
--- @return doc_settings|nil (nil only when document_path is nil and ui has no open book)
--- @return is_live boolean true when the returned instance is the live one
function SafeDocSettings.resolveRaw(document_path, ui)
    if not document_path then
        if ui and ui.document and ui.doc_settings then
            return ui.doc_settings, true
        end
        return nil, false
    end
    -- Caller's instance has this book open
    if ui and ui.doc_settings and ui.document
            and SafeDocSettings.samePath(ui.document.file, document_path) then
        return ui.doc_settings, true
    end
    -- The globally open book may still be this one: caller passed no ui, a
    -- FileManager instance, or an alias path that a raw compare rejected
    local ok, ReaderUI = pcall(require, "apps/reader/readerui")
    local inst = ok and ReaderUI and ReaderUI.instance or nil
    if inst and inst.doc_settings and inst.document
            and SafeDocSettings.samePath(inst.document.file, document_path) then
        logger.dbg("SafeDocSettings: resolved live doc_settings via ReaderUI.instance for", document_path)
        return inst.doc_settings, true
    end
    -- Book not open anywhere: a fresh instance is the only copy — safe
    local DocSettings = require("docsettings")
    return DocSettings:open(document_path), false
end

--- Resolve a book's settings object for plugin use. Since Track 37
--- (2026-09-02) this is a BookStore FACADE: koassistant_* keys live in the
--- plugin's own koassistant_book_settings.lua sidecar file, every other key
--- still reads KOReader's DocSettings (same instance rules as resolveRaw, so
--- the live object is used for the open book). Same signature and returns.
function SafeDocSettings.resolve(document_path, ui)
    local ds, is_live = SafeDocSettings.resolveRaw(document_path, ui)
    if not ds then return nil, is_live end
    local path = document_path
    if not path and ui and ui.document then path = ui.document.file end
    return require("koassistant_book_store").wrap(ds, path), is_live
end

--- Effective book props: KOReader keeps metadata edited in Book information
--- (title, authors, series, ...) in the sidecar's custom_metadata.lua and
--- NEVER rewrites metadata.lua's doc_props, which stays the original. ReaderUI's
--- own `ui.doc_props` carries that overlay already; a doc_props read off any
--- DocSettings (live or fresh) does NOT. Every plugin site that turns doc_props
--- into a title/author must pass it through here (tests/unit/test_effective_props.lua
--- greps for it). Applies KOReader's own BookInfo.extendProps when a custom
--- metadata file exists; returns the raw table untouched otherwise, so callers
--- keep their `if props then` semantics (nil in, no custom file = nil out).
--- Note: the overlay result carries only BookInfo.props + display_title + pages —
--- DOI identifiers must be read from the RAW props (main.lua getRawDocProps).
--- @param raw_props table|nil doc_props as read from DocSettings
--- @param document_path string|nil the book (nil = no overlay possible)
--- @return table|nil
function SafeDocSettings.overlayCustomProps(raw_props, document_path)
    if not document_path then return raw_props end
    local ok_ds, DocSettings = pcall(require, "docsettings")
    if not ok_ds or type(DocSettings) ~= "table" or not DocSettings.findCustomMetadataFile then
        return raw_props
    end
    local ok_find, custom_file = pcall(DocSettings.findCustomMetadataFile, DocSettings, document_path)
    if not ok_find or not custom_file then return raw_props end
    local ok_bi, BookInfo = pcall(require, "apps/filemanager/filemanagerbookinfo")
    if not ok_bi or type(BookInfo) ~= "table" or not BookInfo.extendProps then
        return raw_props
    end
    local ok_ext, props = pcall(BookInfo.extendProps, raw_props, document_path)
    if ok_ext and type(props) == "table" then return props end
    return raw_props
end

-- Props derived for books whose sidecar carries no doc_props (never opened
-- in the reader): path -> props table, or false when even the metadata-only
-- open found nothing. Session-scoped by design: once the reader opens the
-- book, the sidecar's doc_props win before this memo is consulted.
local derived_props = {}

--- Effective props for any book, opened or not. The custom-metadata overlay
--- first; when the sidecar has no doc_props (KOReader only writes them at
--- reader open, so a never-opened book has none), KOReader's own
--- BookInfo:getDocProps chain fills in: cover browser cache, custom metadata
--- file, then a metadata-only document open. opts.no_open skips that last,
--- e-ink-costly step (bulk lists such as the book picker). Derived hits are
--- memoized per path for the session; misses only when the open was allowed.
--- @param raw_props table|nil doc_props as read from DocSettings
--- @param document_path string|nil the book (nil = overlay only)
--- @param ui table|nil ReaderUI/FileManager instance (its cover browser cache is used when present)
--- @param opts table|nil { no_open = boolean }
--- @return table|nil props, nil only when nothing at all could be read
function SafeDocSettings.effectiveProps(raw_props, document_path, ui, opts)
    local props = SafeDocSettings.overlayCustomProps(raw_props, document_path)
    local function named(t)
        return type(t) == "table" and ((t.title and t.title ~= "") or t.authors) and true or false
    end
    if named(props) or not document_path then return props end
    local memo = derived_props[document_path]
    if memo then return memo end
    if memo == false then return props end
    local no_open = opts and opts.no_open or false
    local ok_bi, BookInfo = pcall(require, "apps/filemanager/filemanagerbookinfo")
    if not ok_bi or type(BookInfo) ~= "table" or type(BookInfo.getDocProps) ~= "function" then
        return props
    end
    local ok_lfs, lfs = pcall(require, "libs/libkoreader-lfs")
    if ok_lfs and lfs and lfs.attributes(document_path, "mode") ~= "file" then
        return props
    end
    -- getDocProps only touches self.ui (the cover browser cache), so a bare
    -- shim serves callers with no instance in hand
    local bookinfo = ui and ui.bookinfo or setmetatable({ ui = ui or {} }, { __index = BookInfo })
    local ok, derived = pcall(bookinfo.getDocProps, bookinfo, document_path, nil, no_open)
    if ok and named(derived) then
        derived_props[document_path] = derived
        return derived
    end
    if not no_open then derived_props[document_path] = false end
    return props
end

return SafeDocSettings
