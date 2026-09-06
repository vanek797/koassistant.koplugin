--[[--
Persistent raw-XPointer cache for passive X-Ray marking.

A sidecar is admitted only after this module has streamed the complete book
through SHA-256 and bound that digest to the live CRE/KOReader identity. The
cache is strictly an optimization. Missing persistence APIs and rejected/corrupt
identities suppress cold search for that open session so an error cannot turn
into a blocking whole-book fallback.
]]

local UIManager = require("ui/uimanager")
local lfs = require("libs/libkoreader-lfs")
local Index = {}

-- KOReader's common/json (LuaJSON) exposes decode/encode as callable
-- TABLES (metatable __call), not plain functions; plain functions must also
-- keep working (dkjson and other json modules).
local function callableJson(value)
    if type(value) == "function" then return true end
    if type(value) == "table" then
        local mt = getmetatable(value)
        return mt ~= nil and type(mt.__call) == "function"
    end
    return false
end

Index.FILENAME = "koassistant_xray_marks_index.json"
Index.TEMP_FILENAME = Index.FILENAME .. ".tmp"
-- Earlier experimental builds used executable Lua and predecessor rotations.
-- They are never loaded; listing every known name keeps move/delete/migration
-- lifecycle handling complete until resolvePath safely removes them.
Index.OBSOLETE_FILENAMES = {
    Index.FILENAME .. ".old",
    Index.FILENAME .. ".old.tmp",
    "koassistant_xray_marks_index.lua",
    "koassistant_xray_marks_index.lua.tmp",
    "koassistant_xray_marks_index.lua.old",
    "koassistant_xray_marks_index.lua.old.tmp",
}
Index.SCHEMA = 3
Index.IDENTITY_SCHEMA = 2
Index.SEARCH_SCHEMA = 2
Index.SEARCH_CAP = 2000
Index.PLAIN_FLAGS = 0x00FF
Index.REGEX_FLAGS = 0x0001
Index.HASH_CHUNK_BYTES = 32 * 1024
Index.MAX_FILE_BYTES = 2 * 1024 * 1024
Index.MAX_AGGREGATE_BYTES = 1536 * 1024
Index.MAX_TERMS = 512
Index.MAX_QUERY_KEY_BYTES = 1024
Index.MAX_XPOINTER_BYTES = 2048
Index.MAX_HITS_PER_TERM = Index.SEARCH_CAP - 1
Index.FLUSH_DELAY_S = 10

local function finiteInteger(n)
    return type(n) == "number" and n == n and n >= 0 and n < math.huge and n % 1 == 0
end

local function fileAttributes(path)
    local ok, attr = pcall(lfs.attributes, path)
    if not ok or type(attr) ~= "table" or attr.mode ~= "file"
        or not finiteInteger(attr.size) or type(attr.modification) ~= "number"
        or attr.modification ~= attr.modification then
        return nil
    end
    return attr
end

local function sameFileSnapshot(a, b)
    if not a or not b or a.mode ~= b.mode or a.size ~= b.size
        or a.modification ~= b.modification then
        return false
    end
    -- LuaFileSystem exposes these only on some platforms. When either side
    -- exposes one, require the other side and exact equality.
    for _, key in ipairs({ "dev", "ino" }) do
        if a[key] ~= nil or b[key] ~= nil then
            if a[key] == nil or b[key] == nil or a[key] ~= b[key] then return false end
        end
    end
    return true
end

local function exactString(value, max_bytes)
    return type(value) == "string" and value ~= "" and #value <= max_bytes
end

local function boundedString(value, max_bytes)
    return type(value) == "string" and #value <= max_bytes
end

local function searchIdentity()
    return {
        schema = Index.SEARCH_SCHEMA,
        cap = Index.SEARCH_CAP,
        plain_flags = Index.PLAIN_FLAGS,
        regex_flags = Index.REGEX_FLAGS,
        boundary_schema = 1,
    }
end

local IDENTITY_KEYS = {
    schema = true, bytes_sha256 = true, byte_size = true, document_provider = true,
    document_format = true, cre_dom_version = true, koreader_revision = true,
    open_modification = true, open_partial_md5 = true, dom_open_identity = true,
    xpointer_kind = true,
}

local function sameIdentity(a, b)
    if type(a) ~= "table" or type(b) ~= "table" then return false end
    for key in pairs(a) do if not IDENTITY_KEYS[key] then return false end end
    for key in pairs(IDENTITY_KEYS) do if a[key] ~= b[key] then return false end end
    return true
end

local function validSearchIdentity(value)
    local wanted = searchIdentity()
    if type(value) ~= "table" then return false end
    for key in pairs(value) do if wanted[key] == nil then return false end end
    for key, expected in pairs(wanted) do
        if value[key] ~= expected then return false end
    end
    return true
end

local function cleanTerms(terms)
    if type(terms) ~= "table" then return nil end
    local clean, count, aggregate = {}, 0, 0
    for key, entry in pairs(terms) do
        count = count + 1
        if count > Index.MAX_TERMS or not exactString(key, Index.MAX_QUERY_KEY_BYTES)
            or not key:match("^plain:255:.") or type(entry) ~= "table" then return nil end
        local outcome = entry.outcome
        -- Empty observations cannot be independently checked against the
        -- already-open DOM, so they deliberately remain session-only.
        if outcome ~= "hits" then return nil end
        local hits = entry.hits
        if type(hits) ~= "table" or #hits < 1 or #hits > Index.MAX_HITS_PER_TERM then
            return nil
        end
        local copied = {}
        for i = 1, #hits do
            local hit = hits[i]
            if type(hit) ~= "table"
                or not exactString(hit.start, Index.MAX_XPOINTER_BYTES)
                or not exactString(hit.e, Index.MAX_XPOINTER_BYTES) then return nil end
            local prefix, suffix = hit.prefix, hit.suffix
            if (prefix ~= nil and not boundedString(prefix, 64))
                or (suffix ~= nil and not boundedString(suffix, 64)) then return nil end
            for hit_field in pairs(hit) do
                if hit_field ~= "start" and hit_field ~= "e"
                    and hit_field ~= "prefix" and hit_field ~= "suffix" then return nil end
            end
            copied[i] = { start = hit.start, e = hit.e,
                prefix = prefix, suffix = suffix }
            aggregate = aggregate + #hit.start + #hit.e + 80
                + (prefix and #prefix or 0) + (suffix and #suffix or 0)
            if aggregate > Index.MAX_AGGREGATE_BYTES then return nil end
        end
        -- Reject sparse arrays and unexpected fields: both indicate a malformed
        -- or newer schema rather than data this reader can safely interpret.
        for hit_key in pairs(hits) do
            if type(hit_key) ~= "number" or hit_key < 1 or hit_key > #hits
                or hit_key % 1 ~= 0 then return nil end
        end
        for entry_key in pairs(entry) do
            if entry_key ~= "outcome" and entry_key ~= "hits" then return nil end
        end
        aggregate = aggregate + #key + 64
        if aggregate > Index.MAX_AGGREGATE_BYTES then return nil end
        clean[key] = { outcome = outcome, hits = copied }
    end
    return clean, aggregate, count
end

local function validateCache(data, identity)
    if type(data) ~= "table" or data.schema ~= Index.SCHEMA
        or not sameIdentity(data.identity, identity)
        or not validSearchIdentity(data.search) then return nil end
    for key in pairs(data) do
        if key ~= "schema" and key ~= "identity" and key ~= "search" and key ~= "terms" then
            return nil
        end
    end
    return cleanTerms(data.terms)
end

local function removeFile(path)
    if type(path) == "string" then pcall(os.remove, path) end
end

local function loadOne(path, identity)
    local attr = fileAttributes(path)
    if not attr then return nil, nil, nil, "absent" end
    if attr.size > Index.MAX_FILE_BYTES then
        removeFile(path)
        return nil, nil, nil, "rejected"
    end
    local file = io.open(path, "rb")
    if not file then return nil, nil, nil, "rejected" end
    local ok_read, bytes = pcall(file.read, file, Index.MAX_FILE_BYTES + 1)
    pcall(file.close, file)
    if not ok_read or type(bytes) ~= "string" or #bytes > Index.MAX_FILE_BYTES then
        removeFile(path)
        return nil, nil, nil, "rejected"
    end
    -- JSON is data-only. Unlike dofile/LuaSettings, a corrupt sidecar cannot
    -- execute code or loop before schema validation.
    local ok_json, json = pcall(require, "json")
    local ok, data = false, nil
    if ok_json and type(json) == "table" and callableJson(json.decode) then
        ok, data = pcall(json.decode, bytes)
    end
    if not ok then
        removeFile(path)
        return nil, nil, nil, "rejected"
    end
    local terms, aggregate, count = validateCache(data, identity)
    if not terms then
        removeFile(path)
        return nil, nil, nil, "rejected"
    end
    return terms, aggregate, count, "valid"
end

local function resolvePath(file)
    local ok_doc, DocSettings = pcall(require, "docsettings")
    if not ok_doc or type(DocSettings) ~= "table" or type(DocSettings.getSidecarDir) ~= "function" then
        return nil
    end
    local ok_dir, dir = pcall(DocSettings.getSidecarDir, DocSettings, file)
    if not ok_dir or not exactString(dir, 8192) then return nil end
    local path = dir .. "/" .. Index.FILENAME
    local ok_registry, Registry = pcall(require, "koassistant_storage_registry")
    if not ok_registry or type(Registry) ~= "table"
        or type(Registry.migrateSidecarFile) ~= "function" then return nil end
    if not fileAttributes(path) then
        pcall(Registry.migrateSidecarFile, file, path, Index.FILENAME)
    end
    -- A crash may leave a fully encoded temporary publication in an alternate
    -- metadata location. Bring it alongside the primary so loadVerified can
    -- either recover it or reject/remove it under the same identity checks.
    local tmp = dir .. "/" .. Index.TEMP_FILENAME
    if not fileAttributes(tmp) then
        pcall(Registry.migrateSidecarFile, file, tmp, Index.TEMP_FILENAME)
    end
    -- Never execute or recover predecessor formats. Pull any known straggler
    -- out of alternate metadata locations only so it can be removed here; the
    -- registry also names these files so unopened books still move/delete cleanly.
    for _, name in ipairs(Index.OBSOLETE_FILENAMES) do
        local obsolete = dir .. "/" .. name
        if not fileAttributes(obsolete) then
            pcall(Registry.migrateSidecarFile, file, obsolete, name)
        end
        removeFile(obsolete)
    end
    return path
end

function Index.getPath(file)
    return resolvePath(file)
end

local function domIdentity(value)
    if type(value) == "string" and value ~= "" and #value <= 256 then return value end
    if type(value) == "number" and value == value and value ~= 0 and value < math.huge then
        return tostring(value)
    end
end

local function liveDomIdentity(document)
    if type(document.getDocumentRenderingHash) ~= "function" then return nil end
    local ok, value = pcall(document.getDocumentRenderingHash, document, true)
    return ok and domIdentity(value) or nil
end

local function buildIdentityBase(opts, before, util)
    local document, doc_settings = opts.document, opts.doc_settings
    if type(opts.file) ~= "string" or opts.file == "" or type(document) ~= "table"
        or document.file ~= opts.file or document.provider ~= "crengine"
        or type(doc_settings) ~= "table" or type(doc_settings.readSetting) ~= "function" then
        return nil
    end
    local ok_format, format = pcall(document.getDocumentFormat, document)
    if not ok_format or not exactString(format, 128) then return nil end
    local ok_dom, dom = pcall(doc_settings.readSetting, doc_settings, "cre_dom_version")
    if not ok_dom or not finiteInteger(dom) then return nil end
    local ok_open_md5, open_md5 = pcall(doc_settings.readSetting,
        doc_settings, "partial_md5_checksum")
    if not ok_open_md5 or not exactString(open_md5, 128) then return nil end
    local ok_disk_md5, disk_md5 = pcall(util.partialMD5, opts.file)
    if not ok_disk_md5 or disk_md5 ~= open_md5 then return nil end
    local opened_dom = domIdentity(opts.dom_open_identity)
    if not opened_dom then return nil end
    local current_dom = liveDomIdentity(document)
    if current_dom ~= opened_dom then return nil end
    -- Document:_readMetadata captures this from the source used to open the
    -- live DOM. CRE exposes it on supported KOReader revisions; requiring its
    -- exact agreement closes the same-path replacement gap before hashing.
    local open_modification = document.mod_time
    if type(open_modification) ~= "number" or open_modification ~= open_modification
        or open_modification == math.huge or open_modification == -math.huge then
        return nil
    end
    if open_modification ~= before.modification then return nil end
    local ok_version, version = pcall(require, "version")
    local ok_revision, revision = false, nil
    if ok_version and type(version) == "table" and type(version.getCurrentRevision) == "function" then
        ok_revision, revision = pcall(version.getCurrentRevision, version)
    end
    if not ok_revision or not exactString(revision, 256) then return nil end
    return {
        schema = Index.IDENTITY_SCHEMA,
        byte_size = before.size,
        open_modification = open_modification,
        document_provider = "crengine",
        document_format = format,
        cre_dom_version = dom,
        koreader_revision = revision,
        open_partial_md5 = open_md5,
        dom_open_identity = opened_dom,
        xpointer_kind = "raw-cre-xpointer",
    }
end

local function owns(state)
    return state.status ~= "closed" and type(state.is_owner) == "function"
        and state.is_owner()
end

local function closeHash(state)
    if state.handle then pcall(state.handle.close, state.handle) end
    state.handle, state.feeder = nil, nil
end

local function notifyReady(state)
    if owns(state) and type(state.on_ready) == "function" then
        state.on_ready(state)
    end
end

local function loadVerified(state)
    local terms, aggregate, count, primary_disposition = loadOne(state.path, state.identity)
    if terms then
        removeFile(state.path .. ".tmp")
        state.terms, state.aggregate_bytes, state.term_count = terms, aggregate, count
        state.disposition = "valid"
        return
    end
    local tmp = state.path .. ".tmp"
    local recovered, recovered_bytes, recovered_count, tmp_disposition = loadOne(tmp, state.identity)
    if recovered then
        local ok_rename, renamed = pcall(os.rename, tmp, state.path)
        if ok_rename and renamed then
            state.terms = recovered
            state.aggregate_bytes = recovered_bytes
            state.term_count = recovered_count
            state.disposition = "valid"
            return
        end
        -- Promotion failed with no valid primary. The complete, identity-
        -- verified temp is the only surviving copy: keep it for a later
        -- verified open, serve it read-only now (every hit still passes live
        -- XPointer verification), and fail closed for everything it lacks.
        -- Writes stay off so nothing can remove or overwrite that temp.
        state.terms = recovered
        state.aggregate_bytes = recovered_bytes
        state.term_count = recovered_count
        state.disposition = "recovered_read_only"
        state.write_disabled = true
        return
    end
    state.terms, state.aggregate_bytes, state.term_count = {}, 0, 0
    state.disposition = (primary_disposition == "rejected" or tmp_disposition == "rejected")
        and "rejected" or "absent"
end

local scheduleHash
local function hashTick(state)
    if state.paused or state.status ~= "pending" then return end
    if not owns(state) then
        closeHash(state)
        state.status = "closed"
        return
    end
    state.hash_callback = nil
    local ok_read, chunk = pcall(state.handle.read, state.handle, Index.HASH_CHUNK_BYTES)
    if not ok_read then
        closeHash(state)
        state.status, state.disposition = "disabled", "disabled"
        notifyReady(state)
        return
    end
    if chunk ~= nil then
        if type(chunk) ~= "string" or chunk == "" then
            closeHash(state)
            state.status, state.disposition = "disabled", "disabled"
            notifyReady(state)
            return
        end
        state.bytes_read = state.bytes_read + #chunk
        local ok_feed = pcall(state.feeder, chunk)
        if not ok_feed or state.bytes_read > state.before.size then
            closeHash(state)
            state.status, state.disposition = "disabled", "disabled"
            notifyReady(state)
            return
        end
        scheduleHash(state)
        return
    end

    local ok_digest, digest = pcall(state.feeder)
    closeHash(state)
    local after = fileAttributes(state.file)
    local after_dom = liveDomIdentity(state.document)
    local ok_partial, after_partial = pcall(state.util.partialMD5, state.file)
    if not ok_digest or type(digest) ~= "string" or not digest:match("^[0-9a-f]+$")
        or #digest ~= 64 or state.bytes_read ~= state.before.size
        or not sameFileSnapshot(state.before, after)
        or state.document.mod_time ~= state.identity.open_modification
        or not ok_partial or after_partial ~= state.identity.open_partial_md5
        or after_dom ~= state.identity.dom_open_identity or not owns(state) then
        state.status, state.disposition = "disabled", "disabled"
        notifyReady(state)
        return
    end
    state.identity.bytes_sha256 = digest
    state.status = "ready"
    loadVerified(state)
    notifyReady(state)
end

scheduleHash = function(state)
    if state.hash_callback or state.paused or state.status ~= "pending" or not owns(state) then return end
    local callback
    callback = function()
        if state.hash_callback ~= callback then return end
        hashTick(state)
    end
    state.hash_callback = callback
    UIManager:scheduleIn(0, callback)
end

--- Begin identity verification. A nil state carries an explicit unsupported or
--- disabled disposition; callers must fail closed for that open-book session.
function Index.start(opts)
    if type(opts) ~= "table" or type(opts.is_owner) ~= "function" then return nil, "unsupported" end
    local path, path_reason = resolvePath(opts.file)
    local before = fileAttributes(opts.file)
    if not path or not before then
        return nil, "disabled"
    end
    local ok_util, util = pcall(require, "util")
    if not ok_util or type(util) ~= "table" or type(util.writeToFile) ~= "function"
        or type(util.makePath) ~= "function" or type(util.partialMD5) ~= "function"
        or type(os.rename) ~= "function" then
        return nil, "unsupported"
    end
    local identity, identity_reason = buildIdentityBase(opts, before, util)
    if not identity then
        return nil, "disabled"
    end
    local ok_json, json = pcall(require, "json")
    if not ok_json or type(json) ~= "table" or not callableJson(json.decode)
        or not callableJson(json.encode) then
        return nil, "unsupported"
    end
    local ok_sha, sha = pcall(require, "ffi/sha2")
    if not ok_sha or type(sha) ~= "table" or type(sha.sha256) ~= "function" then
        return nil, "unsupported"
    end
    local ok_feeder, feeder = pcall(sha.sha256, nil)
    if not ok_feeder or type(feeder) ~= "function" then
        return nil, "unsupported"
    end
    local handle = io.open(opts.file, "rb")
    if not handle then
        return nil, "disabled"
    end
    local state = {
        status = "pending", file = opts.file, path = path, before = before,
        identity = identity, document = opts.document,
        feeder = feeder, handle = handle, bytes_read = 0,
        terms = {}, aggregate_bytes = 0, term_count = 0, util = util,
        is_owner = opts.is_owner, on_ready = opts.on_ready,
    }
    scheduleHash(state)
    return state
end

function Index.isPending(state)
    return state and state.status == "pending"
end

function Index.isReady(state)
    return state and state.status == "ready"
end

function Index.allowColdSearch(state)
    -- Session-native marking NEVER depends on the index: it is a strictly
    -- additive cache (warm reads when fully verified, writes when ready and
    -- owned). This gate only withholds a search while a verified warm cache
    -- may still be pending (avoiding a duplicate whole-book search right
    -- before it lands) and for a read-only recovery whose sole surviving
    -- temp must not be bypassed by an in-session rebuild. Unavailable,
    -- unsupported, disabled (hash aborted by a mutation), and rejected
    -- (unusable on-disk cache removed) states fall back to the normal
    -- one-search-per-tick session behavior — exactly what marking did before
    -- the index existed.
    if Index.isPending(state) then return false end
    if state and state.status == "ready"
        and state.disposition == "recovered_read_only" then return false end
    return true
end

function Index.get(state, key)
    if not Index.isReady(state) or type(key) ~= "string" then return nil end
    local entry = state.terms[key]
    if not entry then return nil end
    local hits = {}
    for i, hit in ipairs(entry.hits or {}) do
        hits[i] = { start = hit.start, e = hit.e,
            prefix = hit.prefix, suffix = hit.suffix }
    end
    return { outcome = entry.outcome, hits = hits, persisted = true }
end

local function scheduleFlush(state)
    if state.paused or not state.dirty or not Index.isReady(state)
        or state.write_disabled or not owns(state) then return end
    -- Trailing-edge debounce: a cold chain of terms produces one idle write,
    -- rather than repeatedly rewriting the growing whole index.
    if state.flush_callback then
        UIManager:unschedule(state.flush_callback)
        state.flush_callback = nil
    end
    local callback
    callback = function()
        if state.flush_callback ~= callback then return end
        state.flush_callback = nil
        Index.flush(state)
    end
    state.flush_callback = callback
    UIManager:scheduleIn(Index.FLUSH_DELAY_S, callback)
end

local function entryCost(key, entry)
    local bytes = #key + 64
    for _, hit in ipairs(entry.hits or {}) do
        bytes = bytes + #hit.start + #hit.e + 80
            + (hit.prefix and #hit.prefix or 0) + (hit.suffix and #hit.suffix or 0)
    end
    return bytes
end

function Index.put(state, key, outcome, hits)
    if not Index.isReady(state) or state.write_disabled
        or not exactString(key, Index.MAX_QUERY_KEY_BYTES) or not key:match("^plain:255:.")
        or outcome ~= "hits" or type(hits) ~= "table" then return false end
    if #hits < 1 or #hits > Index.MAX_HITS_PER_TERM then return false end
    local copied = {}
    for i = 1, #hits do
        local hit = hits[i]
        if type(hit) ~= "table" or not exactString(hit.start, Index.MAX_XPOINTER_BYTES)
            or not exactString(hit.e, Index.MAX_XPOINTER_BYTES) then return false end
        local prefix, suffix = hit.prefix, hit.suffix
        if (prefix ~= nil and not boundedString(prefix, 64))
            or (suffix ~= nil and not boundedString(suffix, 64)) then return false end
        copied[i] = { start = hit.start, e = hit.e,
            prefix = prefix, suffix = suffix }
    end
    local entry = { outcome = outcome, hits = copied }
    local old = state.terms[key]
    local next_count = state.term_count + (old and 0 or 1)
    local next_bytes = state.aggregate_bytes - (old and entryCost(key, old) or 0) + entryCost(key, entry)
    if next_count > Index.MAX_TERMS or next_bytes > Index.MAX_AGGREGATE_BYTES then return false end
    state.terms[key], state.term_count, state.aggregate_bytes = entry, next_count, next_bytes
    state.dirty = true
    scheduleFlush(state)
    return true
end

function Index.evict(state, key)
    if not Index.isReady(state) or type(key) ~= "string" then return end
    local old = state.terms[key]
    if not old then return end
    state.terms[key] = nil
    state.term_count = math.max(0, state.term_count - 1)
    state.aggregate_bytes = math.max(0, state.aggregate_bytes - entryCost(key, old))
    state.dirty = true
    scheduleFlush(state)
end

function Index.flush(state)
    if not Index.isReady(state) or not state.dirty or state.write_disabled or not owns(state) then
        return false
    end
    if state.flush_callback then UIManager:unschedule(state.flush_callback); state.flush_callback = nil end
    local cache = {
        schema = Index.SCHEMA, identity = state.identity,
        search = searchIdentity(), terms = state.terms,
    }
    local ok_json, json = pcall(require, "json")
    local ok_encode, serialized = false, nil
    if ok_json and type(json) == "table" and callableJson(json.encode) then
        ok_encode, serialized = pcall(json.encode, cache)
    end
    if not ok_encode or type(serialized) ~= "string" or #serialized > Index.MAX_FILE_BYTES then
        state.write_disabled = true
        state.dirty = nil
        return false
    end
    local util = state.util
    local dir = state.path:match("(.*/)")
    if dir then pcall(util.makePath, dir) end
    local tmp = state.path .. ".tmp"
    removeFile(tmp)
    local ok_write, wrote = pcall(util.writeToFile, serialized, tmp, true, false)
    local tmp_attr = ok_write and wrote and fileAttributes(tmp) or nil
    if not tmp_attr or tmp_attr.size ~= #serialized then
        removeFile(tmp)
        state.write_disabled = true
        state.dirty = nil
        return false
    end
    -- Same-directory rename is the sole atomic publication point. On failure
    -- the previous primary remains intact and the complete temp is recoverable
    -- on the next verified open.
    local rename_call, ok_rename = pcall(os.rename, tmp, state.path)
    if not rename_call or not ok_rename then
        state.write_disabled = true
        state.dirty = nil
        return false
    end
    state.dirty = nil
    return true
end

function Index.pause(state)
    if not state or state.status == "closed" then return end
    state.paused = true
    if state.hash_callback then UIManager:unschedule(state.hash_callback); state.hash_callback = nil end
    if state.flush_callback then UIManager:unschedule(state.flush_callback); state.flush_callback = nil end
end

function Index.resume(state)
    if not state or state.status == "closed" then return end
    state.paused = nil
    if state.status == "pending" then scheduleHash(state) else scheduleFlush(state) end
end

function Index.close(state)
    if not state or state.status == "closed" then return end
    if state.hash_callback then UIManager:unschedule(state.hash_callback); state.hash_callback = nil end
    if state.flush_callback then UIManager:unschedule(state.flush_callback); state.flush_callback = nil end
    closeHash(state)
    if state.status == "ready" and state.dirty then Index.flush(state) end
    state.status = "closed"
end

-- Focused tests use this to validate bounded parsing without starting a reader.
function Index._validateCache(data, identity)
    return validateCache(data, identity)
end

return Index
