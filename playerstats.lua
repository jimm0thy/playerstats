addon.name    = 'playerstats';
addon.author  = 'Semil';
addon.version = '1.3';
addon.desc    = 'Displays job, level, gil and experience on screen.';
addon.link    = '';

require('common');
local fonts      = require('fonts');
local primitives = require('primitives');
local settings   = require('settings');

-- ---------------------------------------------------------------------------
-- Themes
-- ---------------------------------------------------------------------------

--[[ Colors are 0xAARRGGBB. `texture` is a file in this addon's assets folder,
     or '' for a flat color. The texture is stretched to the box, so the ones
     shipped have no baked-in border; the border is drawn separately so it stays
     crisp at any size. ]]
local THEMES = T{
    dark = T{
        texture      = 'dark.png',
        bg_color     = 0xFFFFFFFF,   -- tint over the texture (white = untinted)
        border       = true,
        border_color = 0xFFB8924A,
        label_color  = 0xFFE6C36A,
        value_color  = 0xFFFFFFFF,
        outline      = true,
        outline_color= 0xFF000000,
        font_family  = 'Arial',
        font_height  = 12,
        bold         = true,
        padding      = 6,
    },
    parchment = T{
        texture      = 'parchment.png',
        bg_color     = 0xFFFFFFFF,
        border       = true,
        border_color = 0xFF6B4A24,
        label_color  = 0xFF7A3E12,
        value_color  = 0xFF2B1A0C,
        outline      = false,
        outline_color= 0xFF000000,
        font_family  = 'Georgia',
        font_height  = 12,
        bold         = true,
        padding      = 6,
    },
    glass = T{
        texture      = '',
        bg_color     = 0x90000000,
        border       = false,
        border_color = 0xFF000000,
        label_color  = 0xFF9FD3FF,
        value_color  = 0xFFFFFFFF,
        outline      = true,
        outline_color= 0xFF000000,
        font_family  = 'Arial',
        font_height  = 12,
        bold         = false,
        padding      = 5,
    },
    plain = T{
        texture      = '',
        bg_color     = 0x00000000,
        border       = false,
        border_color = 0xFF000000,
        label_color  = 0xFFE6C36A,
        value_color  = 0xFFFFFFFF,
        outline      = true,
        outline_color= 0xFF000000,
        font_family  = 'Arial',
        font_height  = 12,
        bold         = true,
        padding      = 0,
    },
};

local default_settings = T{
    zone_delay = 3,          -- seconds to stay hidden after zoning in
    visible    = true,
    position_x = 100,
    position_y = 100,
    theme      = 'dark',
    style      = THEMES.dark:copy(true),
};

local playerstats = T{
    settings = settings.load(default_settings),
    bg       = nil,
    text     = nil,          -- {gil_l, gil_v, exp_l, exp_v} font objects
    pos      = nil,          -- live position {x, y}; saved only when a drag ends
    rect     = {x = 0, y = 0, w = 0, h = 0},

    zoning     = false,
    hide_until = 0,
    last_zone  = nil,

    press = nil,
};

-- Rows, top to bottom. `key` names the font objects; `label` is the text shown.
local ROWS = {
    {key = 'job', label = 'Job'},
    {key = 'gil', label = 'Gil'},
    {key = 'exp', label = 'EXP'},
};

local SLOP = 3
local GAP  = 12              -- space between the label and value columns
local LINE_SPACING = 2

local WM_MOUSEMOVE   = 0x0200;
local WM_LBUTTONDOWN = 0x0201;
local WM_LBUTTONUP   = 0x0202;

local OUTLINED = (FontDrawFlags ~= nil and FontDrawFlags.Outlined) or 0x10;

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------

local function comma(n)
    local s = tostring(n or 0):reverse():gsub('(%d%d%d)', '%1,'):reverse();
    return (s:gsub('^,', ''));
end

-- 'AARRGGBB' or 'RRGGBB' (with or without # / 0x) -> number, or nil
local function parse_color(s)
    if (s == nil) then return nil; end
    s = s:gsub('^#', ''):gsub('^0[xX]', '');
    if (#s == 6) then s = 'FF' .. s; end
    if (#s ~= 8 or s:match('[^%x]')) then return nil; end
    return tonumber(s, 16);
end

-- Job id -> 'WAR', 'WHM', ...; falls back to the id if the lookup fails
local function job_abbr(id)
    local ok, s = pcall(function ()
        return AshitaCore:GetResourceManager():GetString('jobs.names_abbr', id);
    end);
    if (ok and s ~= nil and s ~= '') then return s; end
    return tostring(id);
end

-- 'WAR 37 / NIN 18', or just 'WAR 37' with no support job
local function job_text(player)
    local main, mlvl = player:GetMainJob(), player:GetMainJobLevel();
    local sub,  slvl = player:GetSubJob(),  player:GetSubJobLevel();
    local s = ('%s %d'):fmt(job_abbr(main), mlvl);
    if (sub ~= nil and sub > 0 and slvl ~= nil and slvl > 0) then
        s = s .. (' / %s %d'):fmt(job_abbr(sub), slvl);
    end
    return s;
end

local function texture_path(file)
    if (file == nil or file == '') then return ''; end
    return ('%sassets\\%s'):fmt(addon.path, file);
end

local function font_settings(color, st)
    return T{
        visible       = false,
        font_family   = st.font_family,
        font_height   = st.font_height,
        color         = color,
        bold          = st.bold,
        color_outline = st.outline_color,
        draw_flags    = st.outline and OUTLINED or 0,
        position_x    = 0,
        position_y    = 0,
        background    = T{ visible = false },
    };
end

local function text_size(f)
    local ok, w, h = pcall(function () return f:get_text_size(); end);
    if (ok and tonumber(w) and tonumber(h) and w > 0 and h > 0) then
        return w, h;
    end
    local fh = playerstats.settings.style.font_height;
    return math.ceil(#(f.text or '') * fh * 0.6), math.ceil(fh * 1.4);
end

-- ---------------------------------------------------------------------------
-- Building and styling
-- ---------------------------------------------------------------------------

local function destroy_all()
    if (playerstats.text ~= nil) then
        for _, f in pairs(playerstats.text) do f:destroy(); end
        playerstats.text = nil;
    end
    if (playerstats.bg ~= nil) then
        playerstats.bg:destroy();
        playerstats.bg = nil;
    end
end

--[[ Created background first, then text, so the text draws on top. Rebuilt
     from scratch on a style change rather than patched, because font family,
     size and flags are cheaper to get right by recreating than by tracking
     which ones changed. ]]
local function build()
    destroy_all();
    local st = playerstats.settings.style;

    playerstats.bg = primitives.new(T{
        visible        = false,
        texture        = texture_path(st.texture),
        color          = st.bg_color,
        border_visible = st.border,
        border_color   = st.border_color,
        border_flags   = 0x0F,        -- all four sides
        border_sizes   = '1,1,1,1',
        position_x     = 0,
        position_y     = 0,
        width          = 10,
        height         = 10,
        can_focus      = false,
    });

    -- One label font and one value font per row, created after the background.
    playerstats.text = {};
    for _, row in ipairs(ROWS) do
        local l = fonts.new(font_settings(st.label_color, st));
        local v = fonts.new(font_settings(st.value_color, st));
        l.text = row.label;
        playerstats.text[row.key .. '_l'] = l;
        playerstats.text[row.key .. '_v'] = v;
    end
end

local function set_visible(v)
    if (playerstats.bg ~= nil) then playerstats.bg.visible = v; end
    if (playerstats.text ~= nil) then
        for _, f in pairs(playerstats.text) do f.visible = v; end
    end
end

-- Positions every piece relative to the box's top-left corner
local function layout()
    local t, st = playerstats.text, playerstats.settings.style;
    local x0, y0 = playerstats.pos.x, playerstats.pos.y;
    local pad = st.padding;

    -- Measure every row: widest label, widest value, tallest line
    local lw, vw, lh = 0, 0, 0;
    local sizes = {};
    for _, row in ipairs(ROWS) do
        local a, ah = text_size(t[row.key .. '_l']);
        local b, bh = text_size(t[row.key .. '_v']);
        sizes[row.key] = b;
        lw = math.max(lw, a);
        vw = math.max(vw, b);
        lh = math.max(lh, ah, bh);
    end

    local right = x0 + pad + lw + GAP + vw;   -- values are right-aligned here
    local y = y0 + pad;
    for _, row in ipairs(ROWS) do
        local l, v = t[row.key .. '_l'], t[row.key .. '_v'];
        l.position_x, l.position_y = x0 + pad, y;
        v.position_x, v.position_y = right - sizes[row.key], y;
        y = y + lh + LINE_SPACING;
    end

    local w = pad * 2 + lw + GAP + vw;
    local h = pad * 2 + lh * #ROWS + LINE_SPACING * (#ROWS - 1);
    playerstats.bg.position_x, playerstats.bg.position_y = x0, y0;
    playerstats.bg.width, playerstats.bg.height = w, h;
    playerstats.rect = {x = x0, y = y0, w = w, h = h};
end

local function apply_theme(name)
    local th = THEMES[name];
    if (th == nil) then return false; end
    playerstats.settings.theme = name;
    playerstats.settings.style = th:copy(true);
    settings.save();
    build();
    return true;
end

local function hold_after_zone()
    playerstats.hide_until = os.clock() + (tonumber(playerstats.settings.zone_delay) or 0);
end

local function hit(x, y)
    local r = playerstats.rect;
    if (playerstats.bg == nil or not playerstats.bg.visible) then return false; end
    return x >= r.x and x <= r.x + r.w and y >= r.y and y <= r.y + r.h;
end

-- ---------------------------------------------------------------------------
-- Events
-- ---------------------------------------------------------------------------

ashita.events.register('load', 'playerstats_load', function ()
    -- Older settings files from v1.0/1.1 have no style table; fill it in.
    if (playerstats.settings.style == nil or playerstats.settings.style.label_color == nil) then
        playerstats.settings.style = THEMES.dark:copy(true);
    end
    playerstats.pos = {x = playerstats.settings.position_x, y = playerstats.settings.position_y};
    build();
    settings.register('settings', 'playerstats_settings_update', function (s)
        if (s ~= nil) then playerstats.settings = s; end
        playerstats.pos = {x = playerstats.settings.position_x, y = playerstats.settings.position_y};
        build();
        settings.save();
    end);
end);

ashita.events.register('unload', 'playerstats_unload', function ()
    destroy_all();
    settings.save();
end);

ashita.events.register('packet_in', 'playerstats_packet_in', function (e)
    if (e.id == 0x00B) then
        playerstats.zoning = true;
        playerstats.press  = nil;
    elseif (e.id == 0x00A) then
        playerstats.zoning = false;
        hold_after_zone();
    end
end);

ashita.events.register('mouse', 'playerstats_mouse', function (e)
    if (playerstats.bg == nil) then return; end

    if (e.message == WM_LBUTTONDOWN) then
        if (hit(e.x, e.y)) then
            playerstats.press = {
                ox = e.x - playerstats.pos.x, oy = e.y - playerstats.pos.y,
                sx = e.x, sy = e.y, moved = false,
            };
            e.blocked = true;
        end
    elseif (e.message == WM_MOUSEMOVE) then
        local p = playerstats.press;
        if (p ~= nil) then
            if (not p.moved and (math.abs(e.x - p.sx) > SLOP or math.abs(e.y - p.sy) > SLOP)) then
                p.moved = true;
            end
            if (p.moved) then
                playerstats.pos.x, playerstats.pos.y = e.x - p.ox, e.y - p.oy;
            end
        end
    elseif (e.message == WM_LBUTTONUP) then
        local p = playerstats.press;
        if (p ~= nil) then
            playerstats.press = nil;
            e.blocked = true;
            if (p.moved) then
                playerstats.settings.position_x = playerstats.pos.x;
                playerstats.settings.position_y = playerstats.pos.y;
                settings.save();
            end
        end
    end
end);

local USAGE = {
    '[playerstats] Commands:',
    '  /playerstats theme <dark|parchment|glass|plain>',
    '  /playerstats color <label|value|border|bg> <AARRGGBB or RRGGBB>',
    '  /playerstats texture <file.png|off>   (file goes in playerstats/assets)',
    '  /playerstats font <name>  |  size <n>  |  bold  |  outline  |  border',
    '  /playerstats pos <x> <y>  |  reset  |  delay <secs>',
};

ashita.events.register('command', 'playerstats_command', function (e)
    local args = e.command:args();
    local cmd = (args[1] or ''):lower();
    if (cmd ~= '/playerstats' and cmd ~= '/pstats') then return; end
    e.blocked = true;

    local st  = playerstats.settings.style;
    local sub = (args[2] or ''):lower();
    local restyle = false;

    if (sub == 'theme' and args[3]) then
        if (not apply_theme(args[3]:lower())) then
            print('[playerstats] Themes: dark, parchment, glass, plain');
        end
        return;
    elseif (sub == 'color' and args[3] and args[4]) then
        local c = parse_color(args[4]);
        local key = ({label = 'label_color', value = 'value_color',
                      border = 'border_color', bg = 'bg_color'})[args[3]:lower()];
        if (c == nil or key == nil) then
            print('[playerstats] Usage: /playerstats color <label|value|border|bg> <AARRGGBB or RRGGBB>');
            return;
        end
        st[key] = c;
        restyle = true;
    elseif (sub == 'texture' and args[3]) then
        st.texture = (args[3]:lower() == 'off') and '' or args[3];
        restyle = true;
    elseif (sub == 'font' and args[3]) then
        st.font_family = table.concat(args, ' ', 3);
        restyle = true;
    elseif (sub == 'size' and tonumber(args[3])) then
        st.font_height = tonumber(args[3]);
        restyle = true;
    elseif (sub == 'bold') then
        st.bold = not st.bold;
        restyle = true;
    elseif (sub == 'outline') then
        st.outline = not st.outline;
        restyle = true;
    elseif (sub == 'border') then
        st.border = not st.border;
        restyle = true;
    elseif (sub == 'pos' and tonumber(args[3]) and tonumber(args[4])) then
        playerstats.settings.position_x, playerstats.settings.position_y = tonumber(args[3]), tonumber(args[4]);
        playerstats.pos = {x = playerstats.settings.position_x, y = playerstats.settings.position_y};
        settings.save();
    elseif (sub == 'reset') then
        playerstats.settings.position_x, playerstats.settings.position_y = 100, 100;
        playerstats.pos = {x = 100, y = 100};
        settings.save();
    elseif (sub == 'delay' and tonumber(args[3])) then
        playerstats.settings.zone_delay = math.max(0, tonumber(args[3]));
        settings.save();
        print(('[playerstats] Zone delay: %s seconds'):fmt(tostring(playerstats.settings.zone_delay)));
    else
        for _, line in ipairs(USAGE) do print(line); end
        return;
    end

    if (restyle) then
        playerstats.settings.theme = 'custom';
        settings.save();
        build();
    end
end);

ashita.events.register('d3d_present', 'playerstats_present', function ()
    if (playerstats.bg == nil or playerstats.text == nil) then return; end

    local mm    = AshitaCore:GetMemoryManager();
    local party = mm:GetParty();

    if (party:GetMemberIsActive(0) == 0 or party:GetMemberServerId(0) == 0) then
        set_visible(false);
        playerstats.last_zone = nil;
        return;
    end

    local zone = party:GetMemberZone(0);
    if (zone ~= playerstats.last_zone) then
        if (playerstats.last_zone ~= nil) then hold_after_zone(); end
        playerstats.last_zone = zone;
    end

    if (not playerstats.settings.visible or playerstats.zoning or os.clock() < playerstats.hide_until) then
        set_visible(false);
        return;
    end

    local player  = mm:GetPlayer();
    local gilItem = mm:GetInventory():GetContainerItem(0, 0);
    local gil     = (gilItem ~= nil) and gilItem.Count or 0;

    playerstats.text.job_v.text = job_text(player);
    playerstats.text.gil_v.text = comma(gil);
    playerstats.text.exp_v.text = ('%s / %s'):fmt(comma(player:GetExpCurrent()), comma(player:GetExpNeeded()));

    layout();
    set_visible(true);
end);
