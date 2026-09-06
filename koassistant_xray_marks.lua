--[[--
Ambient X-Ray marking (A10 slice 2, ref #78): while reading, entities the
book's X-Ray knows are underlined on the page — a passive "this has an entry"
layer with no search session behind it. Tapping a marked word rides the
EXISTING selection intercept (round 9/10) straight to the entity, so this
module paints and nothing else.

Mechanics (donor-verified, xray_marking_plan.md §1/§6; DEFERRED since round 7
— the scan used to run inside the onPageUpdate dispatch and the page turn
WAITED on it, device: "page turns very slow"):
- Paint = ONE `ReaderView:registerViewModule` widget (public API, zero
  patching); dotted DARK_GRAY strip at each box bottom (the maintainer-picked
  ambient default — full invert is an on-demand emphasis style, not this).
- Per page turn: the onPageUpdate handler only CLEARS stale boxes (the fresh
  page must never paint the old page's marks) and schedules the scan for
  SCAN_SETTLE_S after the turn — well after the page's own repaint, and
  rapid flipping never scans at all (each turn invalidates the last
  schedule's token). The scan resolves terms — steady state
  is pure memo lookups (NO page-text read, NO searches); a term never yet
  searched costs one whole-book `findAllText`, so at most ONE runs per tick
  with the rest chained on scheduleIn (the native call still blocks the UI;
  this is NOT an asynchronous search backend) — then boxes for current-page hits via
  `getScreenBoxesFromPositions` → dedupe/merge → ONE partial refresh sized
  to the strips, skipped entirely on mark-free pages.
- EPUB page mode only in v1: scroll mode clears (boxes go stale mid-scroll
  with no per-scroll event granularity worth paying for), PDFs are excluded
  (the donor rides the native highlight.temp slot there, which the search
  session also owns — conflict; follow-up).

Spoiler stance (round 5, per the standing round-7 ruling): the LIVE X-Ray is
the marking truth in every posture — installed content already reveals
through its coverage, and demoting to an at-position checkpoint silently
split the mark set from the lookup set (entities added as the X-Ray grew
existed for lookup/tap yet never marked). All section X-Rays fold in,
range-free, for the same one-truth reason. The entity index rebuilds only
when the cache or user-alias sidecar changes on disk (mtime+size stamps —
stats per turn, parses only on change).

State is module-resident and owned by one open ReaderUI/document session
(reader-scoped, like the Attachments staging list). Teardown retires that
session; callbacks from an older session cannot replace or mutate a newer one.
]]

local UIManager = require("ui/uimanager")
local logger = require("koassistant_logger")
local lfs = require("libs/libkoreader-lfs")
local PersistentIndex = require("koassistant_xray_marks_index")

local XrayMarks = {}

local MODULE_NAME = "koassistant_xray_marks"

-- Plain native search is case-insensitive over Unicode, while Lua's
-- string.lower folds ASCII only. Descriptor keys and persisted-hit text
-- verification must share one Unicode-aware, strict 1:1 lowercase so a
-- valid cached hit for "Élodie" pointing at "élodie" is not rejected.
local Utf8Proc
local function validUtf8(s)
  local i, n = 1, #s
  while i <= n do
    local c = s:byte(i)
    if c < 0x80 then
      i = i + 1
    else
      local len
      if c >= 0xC2 and c <= 0xDF then len = 2
      elseif c >= 0xE0 and c <= 0xEF then len = 3
      elseif c >= 0xF0 and c <= 0xF4 then len = 4
      else return false end
      if i + len - 1 > n then return false end
      local b2 = s:byte(i + 1)
      -- RFC 3629: reject overlong forms (E0 80..9F, F0 80..8F), UTF-16
      -- surrogate code points (ED A0..BF), and code points above U+10FFFF
      -- (F4 90..BF) that a generic continuation check would accept.
      if len == 3 and c == 0xE0 and b2 < 0xA0 then return false end
      if len == 3 and c == 0xED and b2 > 0x9F then return false end
      if len == 4 and c == 0xF0 and b2 < 0x90 then return false end
      if len == 4 and c == 0xF4 and b2 > 0x8F then return false end
      for j = i + 1, i + len - 1 do
        local b = s:byte(j)
        if b < 0x80 or b > 0xBF then return false end
      end
      i = i + len
    end
  end
  return true
end
--- @return string|nil lowercased text; nil when the text is not valid UTF-8
---   (utf8proc truncates at invalid bytes, which could make two different
---   strings compare equal — fail closed instead)
local function lowercaseText(text)
  if type(text) ~= "string" then return nil end
  if not validUtf8(text) then return nil end
  if Utf8Proc == nil then
    local ok, mod = pcall(require, "ffi/utf8proc")
    Utf8Proc = ok and type(mod) == "table" and type(mod.lowercase) == "function" and mod or false
  end
  if Utf8Proc then
    local ok, lowered = pcall(Utf8Proc.lowercase, text, false)
    if ok and type(lowered) == "string" then return lowered end
    return nil
  end
  return text:lower()
end

--- Verification-side fold: mirror the native 0x00FF search folding as far
--- as Lua can — NFKC compatibility+casefold, soft hyphens and zero-width
--- format characters removed, NBSP and whitespace collapsed. KOReader's
--- readersearch.lua documents 0x00FF as NORMALIZE_CANONICAL (0x0004) +
--- NORMALIZE_COMPATIBILITY (0x0008) + FOLD_*/IGNORE_FORMAT_CONTROL_CHARS,
--- so the NFKC fold is the deliberate Lua approximation of the flags the
--- native search actually runs with. Descriptor keys stay strict 1:1
--- (lowercaseText, normalize=false = simple per-codepoint tolower) so
--- unrelated strings never share a cache entry.
local function foldText(text)
  if type(text) ~= "string" or not validUtf8(text) then return nil end
  if Utf8Proc == nil then
    local ok, mod = pcall(require, "ffi/utf8proc")
    Utf8Proc = ok and type(mod) == "table" and type(mod.lowercase) == "function" and mod or false
  end
  local folded
  if Utf8Proc then
    local ok, f = pcall(Utf8Proc.lowercase, text, true)
    if not ok or type(f) ~= "string" then return nil end
    folded = f
  else
    folded = text:lower()
  end
  return folded:gsub("\194\173", "")      -- soft hyphen (U+00AD)
      :gsub("\226\128[\139-\143]", "")   -- U+200B..U+200F format controls
      :gsub("\226\129\160", "")          -- U+2060 WORD JOINER
      :gsub("\45", "")                     -- U+002D hyphen-minus
      :gsub("\226\128[\144-\149]", "")    -- U+2010..U+2015 hyphens
      :gsub("\226\136\146", "")           -- U+2212 minus
      :gsub("'", "")                       -- U+0027 apostrophe
      :gsub("\226\128[\152\153]", "")     -- U+2018/U+2019 quotes
      :gsub("\202\188", "")               -- U+02BC modifier apostrophe
      :gsub("\194\160", " ")             -- NBSP (NFKC folds it too)
      :gsub("%s+", " "):match("^%s*(.-)%s*$")
end

-- Marks draw only after the reader SETTLES on a page (round 9, maintainer:
-- rushing through pages shouldn't pay a scan-and-draw per page). Every turn
-- bumps the token; the delayed tick aborts instantly for pages already left,
-- so fast flipping costs nothing — and the page's own repaint always lands
-- well before the marks pass.
local SCAN_SETTLE_S = 0.3
local SEARCH_CAP = 2000
-- Bounds Lua/native-call count, not the duration of an individual mapping call.
local MAP_BATCH = 100

-- st = {
--   file, families (nil = all),
--   spacing,           -- 0 = every occurrence, 1 = once per page, N = only
--                      -- after N pages unseen, math.huge = first appearance
--                      -- only (round 7 "another level of space": the window
--                      -- is measured in reference pages from the entity's
--                      -- nearest PREVIOUS hit, so it is deterministic from
--                      -- book position, not from what the reader viewed)
--   debug,             -- features.debug captured at sync
--   scan_token,        -- bumped per turn; stale deferred ticks abort
--   hits_page_count,   -- last observed page count; a changed count and the
--                      -- explicit rerender hook both invalidate page buckets,
--                      -- while same-session raw xpointers remain available
--   stamps,            -- cache+aliases disk stamp gating the reloads
--   live,              -- in-memory live entry, reloaded on stamp change
--   sections,          -- { {key, stamp, data} }; marking is range-free like
--                      -- lookup and never resolves section page ranges
--   artifact_key,      -- identity of the artifacts the entity index came from
--   entities,          -- XrayParser.buildMarkEntities output (main + range-free sections)
--   term_hits = {},    -- query descriptor -> session outcome plus raw hits
--                      -- and layout-specific page buckets; every descriptor
--                      -- is searched at most once per document session
--   page_marks,        -- current page: { {x,y,w,h, name, text}, ... } — FULL word
--                      -- boxes, the tap targets (round 2, d2)
--   paint_boxes,       -- same-line-merged union rects the strips paint from
--                      -- (round 3: overlapping strips double-painted each
--                      -- other — only a word's tail stayed marked; still
--                      -- wanted for dotted paint so overlapping dot grids
--                      -- never clash)
-- }
local st = nil

local function ownsDocument(plugin)
  local ui = plugin and plugin.ui
  return st and ui and st.ui == ui and st.document == ui.document
      and ui.document.file == st.file
end

local function searchActive(ui)
  local search = ui.search
  return search and (search._koassistant_search_session
      or (search.search_dialog and UIManager:isWidgetShown(search.search_dialog)))
end

local function withdraw()
  if not st then return end
  local had_boxes = st.paint_boxes ~= nil
  st.page_marks, st.paint_boxes = nil, nil
  if had_boxes and st.ui.dialog then UIManager:setDirty(st.ui.dialog, "ui") end
end

local function cancelScan()
  if not st then return end
  st.scan_token = (st.scan_token or 0) + 1
  if st.pending then UIManager:unschedule(st.pending) end
  st.pending, st.scan = nil, nil
end

local function scheduleScan(plugin, pageno, delay)
  local session, token = st, st.scan_token
  local callback
  callback = function()
    -- Table identity cannot repeat when the same path is reopened.
    if st ~= session or st.scan_token ~= token or st.pending ~= callback then return end
    st.pending = nil
    XrayMarks._scanTick(plugin, pageno, token)
  end
  st.pending = callback
  UIManager:scheduleIn(delay, callback)
end

-- registerViewModule injects .view/.ui. Each document session gets its own
-- widget closure, so an already-dispatched paint from an old same-path view
-- cannot read a reopened session's boxes. paintTo only READS prepared state.
local function newPaintWidget(session)
  return {
    paintTo = function(_w, bb, _x, _y)
      local boxes = session.paint_boxes
      if st ~= session or not boxes or session.suspended or session.layout_unstable
          or session.document ~= session.ui.document
          or session.ui.view.view_mode == "scroll" or searchActive(session.ui) then return end
      local Screen = require("device").screen
      local Blitbuffer = require("ffi/blitbuffer")
      local strip = math.max(2, Screen:scaleBySize(2))
      local dot = math.max(3, Screen:scaleBySize(3))
      local dash = math.max(7, Screen:scaleBySize(7))
      local gap = math.max(2, Screen:scaleBySize(2))
      for _i, box in ipairs(boxes) do
        if box.x and box.y and box.w and box.h and box.w > 0 and box.h > strip then
          local seg = box.ahead and dash or dot
          local y = box.y + box.h - strip
          local x_end = box.x + box.w
          local x = box.x
          while x < x_end do
            bb:paintRect(x, y, math.min(seg, x_end - x), strip,
              Blitbuffer.COLOR_DARK_GRAY)
            x = x + seg + gap
          end
        end
      end
    end,
  }
end

--- Disk stamp over everything the entity index depends on. Stats only.
--- The ladder joins (point-4): the index folds the newest built checkpoint
--- ahead of the live artifact, so a fresh rung must re-index.
local function diskStamps(ActionCache, file)
  local parts = {}
  local cache_path = ActionCache.getPath(file)
  local attr = cache_path and lfs.attributes(cache_path)
  parts[#parts + 1] = attr and (tostring(attr.modification) .. ":" .. tostring(attr.size)) or "-"
  local apath = ActionCache.getUserAliasesPath(file)
  local aattr = apath and lfs.attributes(apath)
  parts[#parts + 1] = aattr and (tostring(aattr.modification) .. ":" .. tostring(aattr.size)) or "-"
  local lpath = ActionCache.getXrayLadderPath and ActionCache.getXrayLadderPath(file)
  local lattr = lpath and lfs.attributes(lpath)
  parts[#parts + 1] = lattr and (tostring(lattr.modification) .. ":" .. tostring(lattr.size)) or "-"
  return table.concat(parts, "|")
end

--- The artifact behind the marks: the LIVE X-Ray, always (round 5). The
--- earlier draft demoted to a ladder checkpoint at-or-below the reading
--- position under spoiler protection — but that contradicts the standing
--- round-7 ruling ("installed content already reveals through its coverage;
--- a complete install reveals everything"), and it silently split the mark
--- set from the lookup set: entities added as the X-Ray grew (the minor
--- ones) existed for lookup/tap yet never marked. Installed = revealed;
--- marked = findable, one truth. ai_knowledge/non-JSON lineages never mark.
local function pickArtifact()
  local XrayParser = require("koassistant_xray_parser")
  local live = st.live
  if not (live and live.result) or live.source_mode == "ai_knowledge"
      or not XrayParser.isJSON(live.result) then
    return nil
  end
  return live
end

--- Reload disk state on stamp change, re-pick the artifacts, rebuild the
--- entity index when the pick changed. Cheap when nothing moved.
local function ensureIndex(plugin, pageno)
  local ActionCache = require("koassistant_action_cache")
  local stamps = diskStamps(ActionCache, st.file)
  if stamps ~= st.stamps then
    st.stamps = stamps
    st.live = ActionCache.getXrayCache(st.file)
    -- Sections are range-free, just like lookup. Native range mapping is
    -- neither needed nor a prerequisite for a section's entities to mark.
    st.sections = {}
    for _idx, sec in ipairs(ActionCache.getSectionXrays(st.file)) do
      if sec.data and sec.data.result then
        st.sections[#st.sections + 1] = { key = sec.key,
          stamp = tostring(sec.data.timestamp), data = sec.data }
      end
    end
    -- Point-4 identification peek: the newest built checkpoint AHEAD of the
    -- live artifact joins the index, so entities that first appear past the
    -- installed coverage get marked (and card-identified) when the reader
    -- meets them. Full entries stay position-gated in the card router.
    -- P5: the Upcoming Entities setting stands the peek down (default on);
    -- with it off the key drops its "|ahead:" part, so a flip rebuilds the
    -- index on the next sync/scan by itself. Round 3: book override > global
    -- via the marking resolver, like the other marking keys.
    -- B269: the ladder is loaded once per disk change; the ONE rung the
    -- peek may read is re-picked below on every call, from the reader's
    -- position (pure arithmetic — the index key carries the pick, so a
    -- page turn into the next checkpoint's stretch rebuilds by itself)
    st.ladder = nil
    local marks_feats = plugin.settings and plugin.settings:readSetting("features") or {}
    if require("koassistant_book_settings").resolveXrayMarking(
        plugin.ui and plugin.ui.doc_settings, marks_feats).ahead then
      st.ladder = ActionCache.getXrayLadder(st.file)
    end
  end
  st.ahead = nil
  if st.ladder and #st.ladder > 0 then
    local live_p = st.live and (st.live.full_document and 1.0
      or tonumber(st.live.progress_decimal)) or 0
    local total = plugin.ui and plugin.ui.document and plugin.ui.document.info
      and plugin.ui.document.info.number_of_pages
    local position = (pageno and total and total > 0) and (pageno / total) or nil
    local rg = require("koassistant_xray_auto").pickAheadRung(st.ladder, live_p, position)
    if rg then
      st.ahead = { result = rg.result, stamp = tostring(rg.timestamp),
        p = rg.full_document and 1.0 or tonumber(rg.progress_decimal) or 0 }
    end
  end
  local art = pickArtifact()
  -- Predecessor tier (S2 Q4, ref #90): the nearest earlier X-Rayed book in
  -- the group marks too — marked = findable, and the lookup/route surfaces
  -- now answer from it. Memoized inside ActionCache (stamp-keyed), so the
  -- steady-state cost here is stats, not parses. A book with NO artifacts
  -- of its own still marks its predecessor's entities (the "never X-Rayed
  -- this volume" case).
  local group_list, group_stamp = ActionCache.groupXrays(st.file)
  -- Round 5: ALL section X-Rays fold in, range-free — the lookup/intercept
  -- surfaces search every section regardless of range (searchAllXrays), so
  -- a section-only entity was findable-but-never-marked outside its span
  -- (device: ents jumped 153→181 across a section boundary while "Danny
  -- Lloyd" matched lookups everywhere and marks nowhere). Marked = findable,
  -- one truth; the spoiler angle is covered by the round-7 ruling (installed
  -- content reveals through its coverage — sections are installed content).
  if not art and #(st.sections or {}) == 0 and #group_list == 0 then
    st.entities = nil
    st.artifact_key = nil
    return
  end
  local key = art and (tostring(art.timestamp) .. "|" .. tostring(art.progress_decimal)) or "-"
  for _idx, s in ipairs(st.sections or {}) do
    key = key .. "|" .. s.key .. ":" .. s.stamp
  end
  if st.ahead then
    key = key .. "|ahead:" .. st.ahead.stamp
  end
  key = key .. "|" .. st.stamps
  key = key .. "|group:" .. group_stamp
  if st.artifact_key == key and st.entities then return end
  local XrayParser = require("koassistant_xray_parser")
  local user_aliases = ActionCache.getUserAliases(st.file)
  local ents = {}
  local seen_names = {}
  local included, skipped = {}, {}
  local function addFrom(result, is_ahead)
    local data = XrayParser.parse(result)
    if not data then return end
    XrayParser.mergeUserAliases(data, user_aliases)
    for _idx, e in ipairs(XrayParser.buildMarkEntities(data)) do
      -- First writer wins across sources (main → sections → ahead): the
      -- ahead rung contributes only entities the position truth lacks
      local nk = type(e.name) == "string" and e.name:lower() or nil
      if not (nk and seen_names[nk]) then
        if nk then seen_names[nk] = true end
        -- Ahead-only entities paint differently (dashes) — the reader can
        -- tell "new, identification only" from an established mark
        if is_ahead then e.ahead = true end
        ents[#ents + 1] = e
        included[e.category_key] = (included[e.category_key] or 0) + 1
      end
    end
    -- Tally what the category gate dropped — the one line that separates
    -- "entity in a non-marking category" from "entity not in this artifact"
    -- on the next logged round
    for _idx, cat in ipairs(XrayParser.getCategories(data) or {}) do
      if XrayParser.TEXT_MATCH_EXCLUDED[cat.key] and #cat.items > 0 then
        skipped[cat.key] = (skipped[cat.key] or 0) + #cat.items
      end
    end
    return data
  end
  local main_data
  if art then main_data = addFrom(art.result) end
  for _idx, s in ipairs(st.sections or {}) do addFrom(s.data.result) end
  -- Carried tier (S1 D1/Q1, ref #90): the ledger's stubs mark DOTTED like
  -- live entities — the identity is known and spoiler-safe — and OUTRANK the
  -- ahead peek (first-writer-wins keeps an ahead duplicate from re-tagging
  -- a carried name as dashed). Position in this chain: after the position
  -- truth (main + sections), before the peek.
  if main_data then
    for _idx, e in ipairs(XrayParser.buildLedgerMarkEntities(main_data)) do
      local nk = type(e.name) == "string" and e.name:lower() or nil
      if not (nk and seen_names[nk]) then
        if nk then seen_names[nk] = true end
        ents[#ents + 1] = e
        included[e.category_key] = (included[e.category_key] or 0) + 1
      end
    end
  end
  -- Predecessor tier (S2 Q4, ref #90): the nearest earlier book's entities
  -- and ITS carried list mark DOTTED like live ones (already-read content;
  -- the card carries the "From <title>" provenance). After every local
  -- source, before the peek — a local duplicate keeps its own style.
  -- S4: every group book the direction rule allows (earlier first, later
  -- only while unprotected, every member of a project) — same style
  for _g, g in ipairs(group_list) do
    for _idx, e in ipairs(XrayParser.buildMarkEntities(g.data)) do
      local nk = type(e.name) == "string" and e.name:lower() or nil
      if not (nk and seen_names[nk]) then
        if nk then seen_names[nk] = true end
        ents[#ents + 1] = e
        included[e.category_key] = (included[e.category_key] or 0) + 1
      end
    end
    for _idx, e in ipairs(XrayParser.buildLedgerMarkEntities(g.data)) do
      local nk = type(e.name) == "string" and e.name:lower() or nil
      if not (nk and seen_names[nk]) then
        if nk then seen_names[nk] = true end
        ents[#ents + 1] = e
        included[e.category_key] = (included[e.category_key] or 0) + 1
      end
    end
  end
  if st.ahead then addFrom(st.ahead.result, true) end
  -- Cross-entity containment (B266): an entity whose term sits inside
  -- another entity's longer handle ("Kubrick" in "Vivian Kubrick") records
  -- those entities; the paint pass drops its hits that lie inside theirs.
  -- Index-time only, so the per-turn scan pays nothing for it.
  for i, a in ipairs(ents) do
    local longer
    for j, b in ipairs(ents) do
      if i ~= j then
        local hit = false
        for _ta, ta in ipairs(a.terms) do
          for _tb, tb in ipairs(b.terms) do
            if XrayParser.handleContainsWord(tb.norm, ta.norm) then
              hit = true
              break
            end
          end
          if hit then break end
        end
        if hit then
          longer = longer or {}
          longer[#longer + 1] = b.name
        end
      end
    end
    a.longer = longer
  end
  -- Cache exact query descriptors on this policy snapshot. Never let a
  -- regex and a plain query with the same display text share results.
  for _i, ent in ipairs(ents) do
    for _j, term in ipairs(ent.terms) do
      -- Plain searches are case-insensitive, so case-only variants share
      -- one native search. Regex payloads stay exact: lowercasing a pattern
      -- could change its syntax or character classes.
      term.query_key = term.regex and ("regex:1:" .. term.regex)
          or ("plain:255:" .. (lowercaseText(term.text) or term.text))
    end
  end
  st.entities = #ents > 0 and ents or nil
  st.artifact_key = key
  local function tally(t)
    local parts = {}
    for k, v in pairs(t) do parts[#parts + 1] = k .. "=" .. v end
    table.sort(parts)
    return table.concat(parts, " ")
  end
  local src = "none"
  if art then
    local pct = art.full_document and 100
        or math.floor((tonumber(art.progress_decimal) or 0) * 100 + 0.5)
    src = (art == st.live and "live@" or "checkpoint@") .. pct .. "%"
  end
  logger.dbg("KOAssistant marks: index rebuilt from " .. src
    .. " +" .. tostring(#(st.sections or {})) .. " sections"
    .. (#group_list > 0 and (" +group:" .. #group_list) or "")
    .. (st.ahead and (" +ahead@" .. math.floor(st.ahead.p * 100 + 0.5) .. "%") or "")
    .. ": " .. tally(included)
    .. (next(skipped) and (" | skipped: " .. tally(skipped)) or ""))
end

-- Word-boundary honesty for plain terms (round 3, device: an entity name
-- marked inside a longer word containing it): crengine's own word
-- segmentation arrives as matched_word_prefix/suffix — leftover LETTERS in
-- the same word mean a mid-word substring match, dropped for marking.
-- Possessive tails ('s) and pure punctuation stay markable (a possessive
-- "name's" must mark). Arabic regex
-- terms are exempt: their pattern already consumes article/diacritic
-- variants, and attached-prefix morphology needs the looseness.
local function blockingAffix(s)
  if not s or s == "" then return false end
  if s == "'s" or s == "\226\128\153s" then return false end
  if s:find("%a") or s:find("[\128-\255]") then return true end
  return false
end

--- B265: crengine reports a suffix for any match that does not end on a
--- visible word end, so a term ending in punctuation ("D.B.", "Jr.") gets
--- the NEXT word as its suffix on every occurrence and was never marked.
--- When the term's own edge is a non-word char, the affix on that side
--- describes a neighbour, not a mid-word leftover; ignore it.
local function edgeIsWordChar(term_text, side)
  local ch = side == "prefix" and term_text:sub(1, 1) or term_text:sub(-1)
  return ch ~= "" and (ch:find("%w") ~= nil or ch:find("[\128-\255]") ~= nil)
end

--- Whole-doc hit index for one term: hits bucketed per page plus the sorted
--- page list (the spacing window walks it for the nearest previous hit).
--- Memoized by the caller; runs at most once per term per session — this is
--- THE expensive call (whole-book search), which is why the scan chain
--- budgets it to one per tick.
--- Search flags are LOAD-BEARING (round 4, a styled two-word name went
--- unmarked):
--- without them crengine matches nothing across DOM text-node boundaries
--- (MATCH_ACROSS_TEXT_NODES) and folds no NBSP/soft-hyphen/curly-apostrophe
--- (FOLD_* / IGNORE_FORMAT_CONTROL_CHARS) — a styled or NBSP-joined name
--- passes the page-TEXT presence check yet returns zero search hits, and
--- the empty result memoizes. 0x00FF = stock's default-search flag set;
--- regex rides 0x0001 exactly like stock's regex search type.
local function searchTerm(document, term)
  local ok, res = pcall(document.findAllText, document, term.regex or term.text,
      true, 1, SEARCH_CAP, not not term.regex, term.regex and 0x0001 or 0x00FF)
  if not ok then return { outcome = "error" } end
  -- CRE's nil does not distinguish no matches from all failure paths.
  -- Retain legacy availability of OTHER handles, without claiming coverage.
  if res == nil then return { outcome = "unknown" } end
  if type(res) ~= "table" then return { outcome = "error" } end
  local count = #res
  if count >= SEARCH_CAP then return { outcome = "partial" } end
  for k in pairs(res) do
    if type(k) ~= "number" or k < 1 or k > count or k % 1 ~= 0 then
      return { outcome = "error" }
    end
  end
  local hits = {}
  for i = 1, count do
    local r = res[i]
    if type(r) ~= "table" or type(r.start) ~= "string" or r.start == ""
        or type(r["end"]) ~= "string" or r["end"] == ""
        or (r.matched_word_prefix ~= nil and type(r.matched_word_prefix) ~= "string")
        or (r.matched_word_suffix ~= nil and type(r.matched_word_suffix) ~= "string") then
      return { outcome = "error" }
    end
    if term.regex or not (
        (edgeIsWordChar(term.text, "prefix") and blockingAffix(r.matched_word_prefix))
        or (edgeIsWordChar(term.text, "suffix") and blockingAffix(r.matched_word_suffix))) then
      hits[#hits + 1] = { start = r.start, e = r["end"],
        prefix = r.matched_word_prefix, suffix = r.matched_word_suffix }
    end
  end
  -- Only a non-capped, structurally complete result reaches these terminal
  -- outcomes. The persistent layer still waits for full identity verification
  -- and live-document XPointer mapping before publishing hits.
  return { outcome = #hits == 0 and "empty" or "hits", hits = hits }
end

local function comparablePlainText(text)
  local folded = foldText(text)
  if not folded then return nil end
  return require("koassistant_xray_parser").normalizeArabic(folded)
end

local function persistedPlainRangeMatches(document, term, hit)
  if term.regex or type(document.getTextFromXPointers) ~= "function" then
    return false
  end
  local ok_text, pointed_text = pcall(document.getTextFromXPointers,
      document, hit.start, hit.e)
  local pointed, expected = comparablePlainText(pointed_text), comparablePlainText(term.text)
  if not ok_text or not pointed or not expected or pointed ~= expected then
    return false
  end
  -- Re-apply the exact whole-word policy used when the hit was found: the
  -- persisted prefix/suffix are CRE's own matched_word_* leftovers, so a
  -- corrupted or stale range pointing into a larger word still fails closed.
  -- Walking getPrevVisibleChar/getNextVisibleChar instead is NOT equivalent:
  -- those APIs skip whitespace and report the neighbouring WORD's letters,
  -- which would reject every correctly bounded hit (device 2026-09-06).
  if edgeIsWordChar(term.text, "prefix") and blockingAffix(hit.prefix) then
    return false
  end
  if edgeIsWordChar(term.text, "suffix") and blockingAffix(hit.suffix) then
    return false
  end
  return true
end

local function mapTerm(document, term, th, layout)
  if th.layout ~= layout then
    th.layout, th.cursor = layout, 1
    th.by_page, th.pages = {}, {}
  end
  local last = math.min(#th.hits, th.cursor + MAP_BATCH - 1)
  for i = th.cursor, last do
    local h = th.hits[i]
    local ok, page = pcall(document.getPageFromXPointer, document, h.start)
    local oke, end_page = pcall(document.getPageFromXPointer, document, h.e)
    local okc, order = pcall(document.compareXPointers, document, h.start, h.e)
    local text_ok = not th.persisted or persistedPlainRangeMatches(document, term, h)
    if not text_ok or not ok or not oke or not okc or type(page) ~= "number" or page ~= page
        or page < 1 or page == math.huge or page % 1 ~= 0
        or type(end_page) ~= "number" or end_page ~= end_page
        or end_page < page or end_page == math.huge or end_page % 1 ~= 0
        or type(order) ~= "number" or order ~= order or order < 0 then
      th.outcome, th.hits, th.by_page, th.pages = "error", nil, nil, nil
      return true
    end
    local bucket = th.by_page[page]
    if not bucket then
      bucket = {}
      th.by_page[page] = bucket
      th.pages[#th.pages + 1] = page
    end
    bucket[#bucket + 1] = h
  end
  th.cursor = last + 1
  if th.cursor <= #th.hits then return false end
  table.sort(th.pages)
  return true
end

local function previousPage(pages, pageno)
  local lo, hi = 1, #pages
  while lo <= hi do
    local mid = math.floor((lo + hi) / 2)
    if pages[mid] < pageno then lo = mid + 1 else hi = mid - 1 end
  end
  return pages[hi]
end

local function dedupeMarks(marks)
  local seen, out = {}, {}
  for _i, b in ipairs(marks) do
    local k = tostring(b.x) .. "|" .. tostring(b.y) .. "|" .. tostring(b.w)
    if not seen[k] then
      seen[k] = true
      out[#out + 1] = b
    end
  end
  return out
end

-- Union overlapping same-line boxes into single paint rects (round 3):
-- invertRect is self-cancelling, so two entities matching overlapping spans
-- (Arabic article variants, main+section duplicates) XOR each other back to
-- normal — the only-the-word-tail-marked artifact. Tap targets
-- keep the raw per-entity boxes; only the painted strips merge.
local function mergeLineBoxes(marks)
  local rows = {}
  for _i, m in ipairs(marks) do
    local placed = false
    for _j, row in ipairs(rows) do
      if math.abs(row.y - m.y) < math.max(row.h, m.h) / 2 then
        row.boxes[#row.boxes + 1] = m
        placed = true
        break
      end
    end
    if not placed then
      rows[#rows + 1] = { y = m.y, h = m.h, boxes = { m } }
    end
  end
  local out = {}
  for _i, row in ipairs(rows) do
    table.sort(row.boxes, function(a, b) return a.x < b.x end)
    local cur
    for _j, b in ipairs(row.boxes) do
      if cur and b.x <= cur.x + cur.w then
        local right = math.max(cur.x + cur.w, b.x + b.w)
        local bottom = math.max(cur.y + cur.h, b.y + b.h)
        cur.y = math.min(cur.y, b.y)
        cur.w = right - cur.x
        cur.h = bottom - cur.y
        -- A merged strip stays "ahead" (dashed) only when EVERY contributor
        -- is — an established mark makes the whole strip established
        cur.ahead = cur.ahead and b.ahead or nil
      else
        cur = { x = b.x, y = b.y, w = b.w, h = b.h, ahead = b.ahead }
        out[#out + 1] = cur
      end
    end
  end
  return out
end

local function startPersistentIndex(plugin)
  if st.persistence_attempted then return end
  st.persistence_attempted = true
  local session = st
  local disposition
  st.persistent_index, disposition = PersistentIndex.start {
    file = st.file,
    document = st.document,
    doc_settings = st.ui.doc_settings,
    dom_open_identity = st.ui.rolling and st.ui.rolling.rendering_hash,
    is_owner = function()
      return st == session and ownsDocument(plugin)
    end,
    on_ready = function()
      if st ~= session or not ownsDocument(plugin) then return end
      local okp, pageno = pcall(session.document.getCurrentPage, session.document)
      XrayMarks.onPageTurn(plugin, okp and pageno or nil)
    end,
  }
  st.persistence_disposition = disposition
  if disposition then
    logger.dbg("KOAssistant marks: persistence unavailable (" .. disposition
      .. ") — session-native marking runs, nothing is cached")
  elseif st.persistent_index then
    logger.dbg("KOAssistant marks: persistence verifying book identity...")
  else
    logger.warn("KOAssistant marks: persistence start returned no state and no reason")
  end
end

--- One deferred scan step (round 7 — the perf split). Resolve phase: a term
--- present on this page but never searched costs one whole-book findAllText
--- (~100ms+ on device), so at most ONE runs per tick and the rest chain on
--- scheduleIn; the normalized page text (hay) is built lazily on the first
--- unsearched term and carried through the chain. Paint phase (every term
--- memoized — the steady state): page hits are pure table lookups, boxes
--- resolve for this page only, then ONE partial refresh sized to the strips
--- — a mark-free page schedules nothing and refreshes nothing.
function XrayMarks._scanTick(plugin, pageno, token)
  if not ownsDocument(plugin) or st.scan_token ~= token then return end
  local ui = plugin.ui
  if not ui.rolling or st.suspended or st.layout_unstable or st.scan_error
      or (ui.view and ui.view.view_mode == "scroll") or searchActive(ui) then
    cancelScan()
    withdraw()
    return
  end
  local ok, err = pcall(function()
    local time = require("ui/time")
    local t0 = time.now()
    local idx_ms, hay_ms = 0, 0
    if not st.scan then
      ensureIndex(plugin, pageno)
      idx_ms = time.to_ms(time.now() - t0)
      if not st.entities or #st.entities == 0 then withdraw(); return end
      -- Do not hash every opened EPUB: begin only after an actual X-Ray entity
      -- set exists. Once begun, no cold native search may run until the
      -- identity verifier either succeeds or safely disables persistence.
      startPersistentIndex(plugin)
      if PersistentIndex.isPending(st.persistent_index) then return end
      local scan = { entities = st.entities, queue = {}, cursor = 1 }
      st.scan = scan
      local seen, hay = {}, nil
      for _i, ent in ipairs(scan.entities) do
        if not st.families or st.families[ent.family] then
          for _j, term in ipairs(ent.terms) do
            local key = term.query_key
            if not seen[key] then
              seen[key] = true
              local th = st.term_hits[key]
              if not term.regex and not th and PersistentIndex.isReady(st.persistent_index) then
                th = PersistentIndex.get(st.persistent_index, key)
                if th then st.term_hits[key] = th end
              end
              if not th and hay == nil then
                local hay_t = time.now()
                local page_text = require("koassistant_context_extractor"):new(ui):getVisiblePageText().text or ""
                hay = require("koassistant_xray_parser").normalizeArabic(page_text:lower())
                    :gsub("\194\160", " "):gsub("%s+", " ")
                hay_ms = time.to_ms(time.now() - hay_t)
              end
              if (th and th.hits and (th.layout ~= st.layout_generation or th.cursor <= #th.hits))
                  or (not th and hay ~= "" and hay:find(term.norm, 1, true)) then
                scan.queue[#scan.queue + 1] = term
              end
            end
          end
        end
      end
    end
    local scan = st.scan
    while scan.cursor <= #scan.queue do
      local term = scan.queue[scan.cursor]
      local th = st.term_hits[term.query_key]
      if not th then
        if not PersistentIndex.allowColdSearch(st.persistent_index) then
          st.term_hits[term.query_key] = { outcome = "error", persistence_rejected = true }
          scan.cursor = scan.cursor + 1
          scheduleScan(plugin, pageno, 0.05)
          return
        end
        th = searchTerm(ui.document, term)
        st.term_hits[term.query_key] = th
        if not term.regex and PersistentIndex.isReady(st.persistent_index) then
          if th.outcome == "hits" then
            -- Publish only after normal batched live-document mapping has
            -- validated every returned raw XPointer.
            th.needs_persist = true
          end
        end
        -- Keep native search separate from mapping work. Failures stay
        -- quarantined for this session, even across settings/layout changes.
        scheduleScan(plugin, pageno, 0.05)
        return
      end
      if th.hits and (th.layout ~= st.layout_generation or th.cursor <= #th.hits) then
        local done = mapTerm(ui.document, term, th, st.layout_generation)
        if done then
          if th.outcome == "error" and th.persisted then
            -- A cache hit is not trusted merely because its bytes and DOM
            -- identity matched. Quarantine this descriptor for the session
            -- and evict it without a same-session cold-search fallback.
            PersistentIndex.evict(st.persistent_index, term.query_key)
          elseif th.outcome == "hits" and th.needs_persist then
            PersistentIndex.put(st.persistent_index, term.query_key, "hits", th.hits)
          end
          th.needs_persist = nil
          scan.cursor = scan.cursor + 1
        end
        scheduleScan(plugin, pageno, 0.05)
        return
      end
      scan.cursor = scan.cursor + 1
    end

    -- Paint: entity-level spacing + box resolution from the memo
    local paint_t = time.now()
    local dbg = st.debug and { marked = {} } or nil
    local marks = {}
    -- Pass 1: hits on this page per entity (pageno+1 covers two-page
    -- spreads) and, for the spacing window, the entity's nearest hit page
    -- BEFORE this page
    local per_ent, hits_by_name = {}, {}
    local unavailable_names = {}
    for _i, ent in ipairs(scan.entities) do
      if not st.families or st.families[ent.family] then
        local page_hits = {}
        local prev_page
        for _j, term in ipairs(ent.terms) do
          local th = st.term_hits[term.query_key]
          if th and (th.outcome == "error" or th.outcome == "partial"
              or th.outcome == "unknown") then
            unavailable_names[ent.name] = true
          end
          if th and th.by_page and th.layout == st.layout_generation then
            for p = pageno, pageno + 1 do
              local bucket = th.by_page[p]
              if bucket then
                for _k, h in ipairs(bucket) do
                  -- The matched TEXT rides with the hit: a mark tap must
                  -- open the card on the words the reader tapped, never on
                  -- the entry name (an alias mark printing the entry name
                  -- revealed the alias link on sight)
                  page_hits[#page_hits + 1] = { h = h, text = term.text }
                end
              end
            end
            if st.spacing > 1 then
              local prev = previousPage(th.pages, pageno)
              if prev and (not prev_page or prev > prev_page) then prev_page = prev end
            end
          end
        end
        per_ent[#per_ent + 1] = { ent = ent, hits = page_hits, prev_page = prev_page }
        hits_by_name[ent.name] = page_hits
      end
    end
    -- Pass 2: containment (B266) — a hit lying inside a longer entity's hit
    -- on this page is that entity's mention (xpointer range comparison on
    -- the memo, no box work); then spacing + boxes
    for _i, pe in ipairs(per_ent) do
      local ent, page_hits, prev_page = pe.ent, pe.hits, pe.prev_page
      -- A failed alias does not hide this entity's independently available
      -- handles (legacy demand-driven availability). An unavailable LONGER
      -- entity does hide a contained short handle: without its positions we
      -- cannot safely decide that the short hit belongs to another entity.
      local containment_unknown = false
      for _l, lname in ipairs(ent.longer or {}) do
        if unavailable_names[lname] then containment_unknown = true end
      end
      if containment_unknown then page_hits = {} end
      if ent.longer and #page_hits > 0 then
        local kept = {}
        for _k, ph in ipairs(page_hits) do
          local inside = false
          for _l, lname in ipairs(ent.longer) do
            for _m, lh in ipairs(hits_by_name[lname] or {}) do
              local ok1, c1 = pcall(ui.document.compareXPointers, ui.document, lh.h.start, ph.h.start)
              local ok2, c2 = pcall(ui.document.compareXPointers, ui.document, ph.h.e, lh.h.e)
              if not ok1 or not ok2 or type(c1) ~= "number" or type(c2) ~= "number"
                  or c1 ~= c1 or c2 ~= c2 or (c1 >= 0 and c2 >= 0) then
                inside = true
                break
              end
            end
            if inside then break end
          end
          if not inside then kept[#kept + 1] = ph end
        end
        page_hits = kept
      end
      do
        -- Spacing window: the entity appeared within the last N pages —
        -- stay quiet (math.huge = first appearance only). Measured from
        -- book positions, so it is deterministic under back-jumps too.
        local suppressed = #page_hits > 0 and st.spacing > 1 and prev_page
            and (pageno - prev_page) < st.spacing
        if #page_hits > 0 and not suppressed then
          local ent_done = false
          for _k, ph in ipairs(page_hits) do
            local h = ph.h
            -- Off-view positions return no/off-screen boxes; y-filter drops
            local bok, bxs = pcall(ui.document.getScreenBoxesFromPositions,
              ui.document, h.start, h.e, true)
            if bok and bxs then
              local added = false
              for _b, box in ipairs(bxs) do
                if box.y and box.y >= 0 and box.h and box.h > 0 then
                  marks[#marks + 1] = { x = box.x, y = box.y,
                    w = box.w, h = box.h, name = ent.name,
                    text = ph.text, ahead = ent.ahead }
                  added = true
                end
              end
              if added then ent_done = true end
            end
            -- Any spacing except "every occurrence": one mark per entity
            if st.spacing >= 1 and ent_done then break end
          end
          if dbg and ent_done then table.insert(dbg.marked, ent.name) end
        end
      end
    end
    if #marks > 0 then
      st.page_marks = dedupeMarks(marks)
      st.paint_boxes = mergeLineBoxes(st.page_marks)
    else
      withdraw()
    end
    -- Phase-split timing line (the round-9 device-slowness arbiter). The
    -- old full-hay dump is GONE — multi-KB synchronous log writes per page
    -- turn were themselves a device cost, and its forensic job (presence
    -- replay) is done. `text` covers page read+normalize, the presence
    -- finds are total minus the named phases.
    if dbg then
      logger.info("KOAssistant marks dbg: page " .. tostring(pageno)
        .. " ents=" .. tostring(#st.entities)
        .. " marked=[" .. table.concat(dbg.marked, ", ") .. "]"
        .. " boxes=" .. tostring(st.page_marks and #st.page_marks or 0)
        .. " idx=" .. string.format("%.0f", idx_ms)
        .. "ms text=" .. string.format("%.0f", hay_ms)
        .. "ms paint=" .. string.format("%.0f", time.to_ms(time.now() - paint_t))
        .. "ms total=" .. string.format("%.0f", time.to_ms(time.now() - t0)) .. "ms")
    end
    -- One targeted partial refresh over the union of the current strips.
    -- Withdrawals already request a full UI redraw for removed geometry.
    if st.paint_boxes and ui.dialog then
      local Geom = require("ui/geometry")
      local first = st.paint_boxes[1]
      local rx, ry = first.x, first.y
      local rx2, ry2 = first.x + first.w, first.y + first.h
      for _b = 2, #st.paint_boxes do
        local b = st.paint_boxes[_b]
        rx = math.min(rx, b.x)
        ry = math.min(ry, b.y)
        rx2 = math.max(rx2, b.x + b.w)
        ry2 = math.max(ry2, b.y + b.h)
      end
      UIManager:setDirty(ui.dialog, "ui", Geom:new{
        x = math.floor(rx), y = math.floor(ry),
        w = math.ceil(rx2 - rx), h = math.ceil(ry2 - ry),
      })
    end
  end)
  if not ok then
    logger.warn("KOAssistant marks: scan failed:", err)
    st.scan_error = true -- circuit breaker until explicit sync/reopen
    cancelScan()
    withdraw()
  end
end

--- Per-page-turn entry. Called from AskGPT:onPageUpdate (inside the
--- dispatch, BEFORE the repaint) and from sync() for the current page.
--- Synchronous work is only what must not wait: clearing stale boxes (the
--- fresh page must never paint the old page's marks) and the search-session
--- state machine; the actual scan runs SCAN_SETTLE_S after the turn (round
--- 7 moved it off the dispatch — the turn waited on searches and boxes;
--- round 9 added the settle so rapid flipping pays nothing per page).
function XrayMarks.onPageTurn(plugin, pageno)
  if not ownsDocument(plugin) then return end
  cancelScan()
  withdraw()
  local ui = plugin.ui
  if not (ui.rolling and pageno) or st.suspended or st.layout_unstable
      or st.scan_error or PersistentIndex.isPending(st.persistent_index) then return end
  local total = ui.document.info and ui.document.info.number_of_pages
  if total ~= st.hits_page_count then
    st.layout_generation = st.layout_generation + 1
    st.hits_page_count = total
  end
  if ui.view and ui.view.view_mode == "scroll" then return end

  -- A live search session owns the page visuals: our findAllText shares
  -- crengine's selection state with the session's hit highlighting, so a
  -- scan mid-session ERASES the highlights (round 3, device: "hits are no
  -- longer highlighted"). The session flag is set by the onShowSearchDialog
  -- wrap BEFORE the initial jump (do_search runs before UIManager:show, so
  -- isWidgetShown alone misses the first hit); once the dialog has been
  -- seen shown, its close ends the session and marks resume.
  local search = ui.search
  local sd = search and search.search_dialog
  if sd and UIManager:isWidgetShown(sd) then
    search._koassistant_search_session = "shown"
    return
  end
  local sess = search and search._koassistant_search_session
  if sess == true then
    return
  elseif sess then
    -- Was shown, now closed: session over
    search._koassistant_search_session = nil
  end

  scheduleScan(plugin, pageno, SCAN_SETTLE_S)
end

--- Reflow can leave the page count unchanged. Keep only same-DOM raw hits;
--- remapping is demand-driven and batched, never a new whole-book search.
function XrayMarks.onLayoutChanged(plugin, unstable)
  if not ownsDocument(plugin) then return end
  st.layout_generation = st.layout_generation + 1
  st.layout_unstable = unstable and true or nil
  local ok, page = pcall(st.document.getCurrentPage, st.document)
  XrayMarks.onPageTurn(plugin, ok and page or nil)
end

function XrayMarks.onViewModeChanged(plugin)
  if not ownsDocument(plugin) then return end
  if plugin.ui.view.view_mode == "scroll" then
    XrayMarks.pause(plugin)
  else
    -- Entering scroll mode pauses hashing/writes; explicitly resume them
    -- before remapping when page mode returns.
    PersistentIndex.resume(st.persistent_index)
    -- Returning to page mode changes viewport geometry and may follow a
    -- reflow. Remap retained positions before publishing fresh targets.
    XrayMarks.onLayoutChanged(plugin)
  end
end

function XrayMarks.pause(plugin, suspended)
  if not ownsDocument(plugin) then return end
  if suspended then st.suspended = true end
  PersistentIndex.pause(st.persistent_index)
  cancelScan()
  withdraw()
end

function XrayMarks.resume(plugin)
  if not ownsDocument(plugin) then return end
  st.suspended = nil
  PersistentIndex.resume(st.persistent_index)
  local ok, page = pcall(st.document.getCurrentPage, st.document)
  XrayMarks.onPageTurn(plugin, ok and page or nil)
end

--- Fence the search-dialog close callback too: an old dialog must not sync
--- a reopened document (even with the same path and reader instance).
function XrayMarks.resumeCallback(plugin)
  local session = st
  return function()
    if session and st == session and ownsDocument(plugin) then
      XrayMarks.resume(plugin)
    end
  end
end

--- d2 tap layer (round 2): entity name under a tap, or nil. The FULL word
--- box is the target (the painted strip alone would be a sliver); small
--- padding helps e-ink finger accuracy. Gated on the tap setting per call.
--- @param plugin table AskGPT instance
--- @param ges table Tap gesture ({pos = {x, y}})
--- @return string|nil entity name
--- @return table|nil word box {x, y, w, h} (screen coords, fresh copy) —
---   anchors the floating-popup card style
function XrayMarks.tapTarget(plugin, ges)
  if not ownsDocument(plugin) then return nil end
  if st.suspended or plugin.ui.view.view_mode == "scroll" or searchActive(plugin.ui) then
    XrayMarks.pause(plugin)
    return nil
  end
  local marks = st.page_marks
  if not (marks and ges and ges.pos) then return nil end
  local features = plugin and plugin.settings
      and plugin.settings:readSetting("features") or {}
  -- Book override > global (2026-08-15: the popup's quick settings write the
  -- book layer; sidecar reads are memory-cached, so this stays a cheap tap)
  local marking = require("koassistant_book_settings").resolveXrayMarking(
      plugin and plugin.ui and plugin.ui.doc_settings, features)
  if not marking.enabled or not marking.tap then return nil end
  local Screen = require("device").screen
  local pad = Screen:scaleBySize(3)
  local tx, ty = ges.pos.x, ges.pos.y
  for _i, m in ipairs(marks) do
    if tx >= m.x - pad and tx <= m.x + m.w + pad
        and ty >= m.y - pad and ty <= m.y + m.h + pad then
      -- The tapped TEXT (name or alias as it stands in the book), so the
      -- card resolves it like a long-press would and shows what was tapped
      return m.text or m.name, { x = m.x, y = m.y, w = m.w, h = m.h }
    end
  end
  return nil
end

--- Install/refresh/remove per settings + book state. Call on reader ready,
--- setting changes, and whenever a surface wants marks to reflect NOW.
local function teardownCurrent()
  if not st then return end
  local session, ui = st, st.ui
  cancelScan()
  withdraw()
  -- Flush only a verified dirty index, while its owning document/session
  -- fence still holds; a pending hash is simply cancelled and discarded.
  PersistentIndex.close(session.persistent_index)
  st = nil
  if ui and ui.view and ui.view.view_modules
      and ui.view.view_modules[MODULE_NAME] == session.paint_widget then
    ui.view.view_modules[MODULE_NAME] = nil
  end
end

function XrayMarks.sync(plugin)
  local ui = plugin and plugin.ui
  -- Public sync is session-owned. A delayed callback from another ReaderUI
  -- must be a true no-op before it reads settings or mutates any state.
  if st and st.ui ~= ui then return end
  local features = plugin and plugin.settings
      and plugin.settings:readSetting("features") or {}
  -- Opt-out since round 10 (default ON — read pattern must match the schema
  -- default): nil counts as enabled, explicit false is the opt-out.
  -- 2026-08-15: book override > global (the X-Ray popup's quick settings
  -- write the book layer, Settings menu stays the global default)
  local marking = require("koassistant_book_settings").resolveXrayMarking(
      ui and ui.doc_settings, features)
  local eligible = marking.enabled
      and ui and ui.document and ui.rolling and ui.view
  if not eligible then
    -- A delayed callback from a closed ReaderUI must not tear down a newer
    -- session. The owning UI may already have cleared its document, so UI
    -- identity (rather than ownsDocument) is the teardown fence here.
    if st and st.ui == ui then teardownCurrent() end
    return
  end

  if st and not ownsDocument(plugin) then
    -- Replacing a document in the same owning UI is intentional and may
    -- retire that UI's old state.
    teardownCurrent()
  end
  if not st then
    st = { file = ui.document.file, document = ui.document, ui = ui,
      term_hits = {}, layout_generation = 0 }
  end
  cancelScan()
  withdraw()
  st.scan_error = nil
  -- Density → spacing (round 7): "all" marks every occurrence, "first" once
  -- per page, "10"/"25" only after that many pages unseen, "once" only the
  -- first appearance in the book. Default flipped to "10" round 9 —
  -- returning names stand out, constant companions stay quiet.
  local density = marking.density
  if density == "all" then
    st.spacing = 0
  elseif density == "once" then
    st.spacing = math.huge
  else
    st.spacing = tonumber(density) or 1
  end
  st.debug = features.debug and true or nil
  local fam = marking.families
  if fam == "people" then
    st.families = { people = true }
  elseif fam == "people_places" then
    st.families = { people = true, places = true }
  else
    st.families = nil
  end
  -- Settings may have changed what the index feeds on — force a re-pick.
  -- st.stamps too (P5 device round): the sections + ahead-rung snapshot only
  -- refreshes when file stamps change, so a flip of the Upcoming Entities
  -- setting kept the STALE st.ahead until the book was reopened.
  st.artifact_key = nil
  st.stamps = nil

  if not ui.view.view_modules[MODULE_NAME] then
    st.paint_widget = st.paint_widget or newPaintWidget(st)
    ui.view:registerViewModule(MODULE_NAME, st.paint_widget)
  end
  local okp, pageno = pcall(ui.document.getCurrentPage, ui.document)
  XrayMarks.onPageTurn(plugin, okp and pageno or nil)
  if ui.dialog then
    UIManager:setDirty(ui.dialog, "ui")
  end
end

function XrayMarks.teardown(plugin)
  -- Close notifications from an old ReaderUI can arrive after a new book
  -- has installed its state, including for the same path.
  if st and plugin and st.ui == plugin.ui then teardownCurrent() end
end

return XrayMarks
