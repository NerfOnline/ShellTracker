local settings = {
    logDirectory = 'addons\\shelltracker\\logs',
    rosterPollDelay = 1.0,
    rosterPollTimeout = 5.0,
    seaPollTimeout = 10.0,
    commandRateLimitAttempts = 3,
    commandRateLimitCooldown = 30,
    detailedFormat = 'csv',
    clipboardFence = '```',
    rosterMemory = {
        modulePattern = '4D5A',
        retailAnchor = 0x62D014,
        serverPointers = { 0x62D014, 0x62F73C },
        retailRowSize = 76,
        rowSpacings = { 0x4C, 0x50 },
        maxRows = 4096,
        retailMaxRows = 512,
        manager = {
            count = 0x0C,
            rows = 0x20,
        },
        fields = {
            name = { offsets = { 0x08, 0x04 }, lengths = { 16, 15 } },
        },
        strideFields = {
            [0x4C] = {
                zone = 0x2C,
                mainJob = 0x24,
                subJob = 0x25,
                mainLevel = 0x26,
                subLevel = 0x27,
            },
            [0x50] = {
                zone = 0x28,
                mainJob = 0x20,
                subJob = 0x21,
                mainLevel = 0x22,
                subLevel = 0x23,
            },
        },
        retailRow = {
            name = 0x04,
            mainJob = 0x20,
            subJob = 0x21,
            mainLevel = 0x22,
            subLevel = 0x23,
            zone = 0x28,
            nameLength = 15,
            headerSkip = 4,
        },
    },
};

local formatIniHeader = {
    '; ShellTracker format settings.',
    '; Stores the file format used for detailed logs created by /st detailed commands.',
    '; Use /st format to switch between csv and txt.',
    '',
};

local function formatIniPath()
    return AshitaCore:GetInstallPath() .. '\\' .. settings.logDirectory .. '\\format.ini';
end

local function parseFormatIni(contents)
    for line in contents:gmatch('[^\r\n]+') do
        local trimmed = line:match('^%s*(.-)%s*$');
        if trimmed ~= '' and not trimmed:match('^;') and not trimmed:match('^#') then
            local key, value = trimmed:match('^([^=]+)=(.+)$');
            if key ~= nil then
                key = key:match('^%s*(.-)%s*$');
                value = value:match('^%s*(.-)%s*$'):lower();
                if key == 'detailedFormat' and (value == 'csv' or value == 'txt') then
                    settings.detailedFormat = value;
                    return;
                end
            end
        end
    end
end

function settings.loadPersisted()
    local file = io.open(formatIniPath(), 'r');
    if file == nil then
        return;
    end

    local contents = file:read('*a');
    file:close();
    parseFormatIni(contents);
end

function settings.savePersisted()
    local path = formatIniPath();
    local directory = path:match('^(.*)\\[^\\]+$');
    if directory ~= nil then
        ashita.fs.create_dir(directory);
    end

    local file = io.open(path, 'w');
    if file == nil then
        return;
    end

    file:write(table.concat(formatIniHeader, '\n'));
    file:write('detailedFormat=' .. settings.detailedFormat .. '\n');
    file:close();
end

return settings;
