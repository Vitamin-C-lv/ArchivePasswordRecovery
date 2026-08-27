#requires -Version 5.1
[CmdletBinding()]
param(
    [string]$ProjectRoot = '',
    [string]$SecListsSourceRoot = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ([string]::IsNullOrWhiteSpace($ProjectRoot)) {
    $scriptDirectory = Split-Path -LiteralPath $MyInvocation.MyCommand.Definition -Parent
    $ProjectRoot = Split-Path -LiteralPath $scriptDirectory -Parent
}

$resourceRoot = Join-Path $ProjectRoot 'resources'
$dictionaryRoot = Join-Path $resourceRoot 'dictionaries'
New-Item -ItemType Directory -Path $dictionaryRoot -Force | Out-Null

# These are intentionally small, offline, project-curated seeds.  They remain
# the deterministic fallback and supplement for builds without SecLists.  The
# build script never downloads data itself; a build may provide a separately
# downloaded SecLists source directory.
$quickCandidates = @(
    '123456', '12345678', '123456789', '12345', 'password', 'Password',
    'password1', 'qwerty', 'qwerty123', 'admin', 'admin123', '123123',
    '111111', '000000', 'abc123', 'letmein', 'welcome', 'iloveyou',
    '1q2w3e4r', 'qazwsx', 'secret', 'root', 'test', 'guest', 'default',
    'pass', 'pass123', '1234', '1234567890'
)

$globalSeeds = @(
    'password', 'passwd', 'pass', 'secret', 'admin', 'administrator', 'root', 'guest', 'welcome', 'login', 'letmein',
    'qwerty', 'qwertyuiop', 'asdfgh', 'asdfghjkl', 'zxcvbn', 'zxcvbnm', 'abc123', 'iloveyou', 'sunshine', 'monkey',
    'dragon', 'football', 'baseball', 'master', 'hello', 'freedom', 'whatever', 'trustno1', 'starwars', 'princess',
    'shadow', 'superman', 'michael', 'jordan', 'harley', 'ranger', 'hunter', 'charlie', 'donald', 'computer',
    'internet', 'testing', 'changeme', 'backup', 'private', 'secure', 'security', 'access', 'office', 'home',
    'family', 'love', 'summer', 'winter', 'spring', 'autumn', 'orange', 'flower', 'purple', 'soccer', 'hockey',
    'liverpool', 'chelsea', 'arsenal', 'welcomehome', 'beautiful', 'whatever1', 'nothing', 'nothing123', 'killer',
    'mustang', 'jennifer', 'jessica', 'joshua', 'matthew', 'daniel', 'andrew', 'jordan', 'thomas', 'robert',
    'james', 'william', 'george', 'charles', 'richard', 'steven', 'boston', 'london', 'paris', 'qwerty1',
    'access14', 'football1', 'baseball1', 'welcome123', 'secret123', 'adminadmin', 'rootroot', 'guest123',
    'coffee', 'cookie', 'computer1', 'internet1', 'sunflower', 'rainbow', 'strawberry', 'blue', 'green', 'red',
    'black', 'white', 'silver', 'orange123', 'pokemon', 'minecraft', 'hello123', 'hello2024', 'hello2025', 'hello2026',
    'forever', 'whatever123', 'password123', 'p@ssword', 'p@ssw0rd', 'passw0rd', 'samsung', 'google', 'youtube',
    'facebook', 'linkedin', 'instagram', 'welcome1', 'login123', 'access123', 'secure123', 'testing123', 'test123',
    'default123', 'backup123', 'private123', 'letmein123', 'trustno1', 'q1w2e3r4', '1qaz2wsx', 'qazxsw', 'zaq12wsx',
    'aa123456', 'aaaaaa', 'bbbbbb', 'cccccc', 'abcdef', 'abcdefg', 'abcd1234', '123qwe', 'qwe123', 'qweasd',
    '1q2w3e', '1qazxsw2', '987654321', '987654', '666666', '888888', '999999', '112233', '121212', '654321',
    '789456', '147258369', '159753', '5201314', '1314520', 'superuser', 'manager', 'service', 'support', 'system',
    'admin1', 'admin01', 'admin2024', 'admin2025', 'admin2026', 'root123', 'root2024', 'root2025', 'root2026',
    'welcome2024', 'welcome2025', 'welcome2026', 'spring2024', 'summer2024', 'autumn2024', 'winter2024',
    'spring2025', 'summer2025', 'autumn2025', 'winter2025', 'spring2026', 'summer2026', 'autumn2026', 'winter2026',
    'january', 'february', 'march', 'april', 'may', 'june', 'july', 'august', 'september', 'october', 'november', 'december',
    'jan', 'feb', 'mar', 'apr', 'jun', 'jul', 'aug', 'sep', 'oct', 'nov', 'dec', 'monday', 'tuesday', 'wednesday',
    'thursday', 'friday', 'saturday', 'sunday', 'morning', 'welcome!', 'hello!', 'secret!', 'password!', 'admin!',
    'pass@123', 'admin@123', 'user123', 'user2024', 'user2025', 'user2026', 'test@123', 'test2024', 'test2025', 'test2026',
    'backup2024', 'backup2025', 'backup2026', 'archive', 'archive123', 'zip', 'zip123', 'sevenzip', 'sevenzip123',
    'rar', 'rar123', 'document', 'documents', 'file', 'files', 'privatekey', 'mycomputer', 'mypassword', 'mysecret'
)

$zhSeeds = @(
    '密码', '密码123', '密码123456', '管理员', '管理员123', '中国', '中国人', '我爱你', '爱你', '老婆', '老公', '宝宝',
    '宝贝', '生日快乐', '新年快乐', '恭喜发财', '发财', '加油', '你好', '欢迎', '幸福', '快乐', '平安', '家人', '家庭',
    '妈妈', '爸爸', '哥哥', '姐姐', '弟弟', '妹妹', '小可爱', '天使', '公主', '王子', '缘分', '爱情', '爱情123',
    '永远', '一生一世', '天长地久', '海阔天空', '美好生活', '万事如意', '心想事成', '天天开心', '身体健康', '一路顺风',
    '顺其自然', '随遇而安', '平平安安', '开开心心', '财源广进', '招财进宝', '吉祥如意', '国庆快乐', '春节快乐',
    '元旦快乐', '情人节快乐', '520', '1314', '521', '666666', '888888', '999999', '123456', '12345678', '111111',
    '000000', '5201314', '1314520', 'woaini', 'woaini123', 'mima', 'mima123', 'guanliyuan', 'zhongguo', 'zhongguo123',
    'beibei', 'baobao', 'laopo', 'laogong', 'mama', 'baba', 'jiejie', 'gege', 'didi', 'meimei', 'xixi', 'haha',
    'nihao', 'huanying', 'jiayou', 'xingfu', 'kuaile', 'pingan', 'jiankang', 'meili', 'tiantian', 'aixin', 'ai123',
    'shenti', 'shunli', 'gongxi', 'facai', 'daji', 'daji123', 'beijing', 'shanghai', 'guangzhou', 'shenzhen', 'tianjin',
    'nanjing', 'hangzhou', 'chengdu', 'wuhan', 'xian', 'suzhou', 'changsha', 'chongqing', 'zhuhai', 'xiamen', 'haerbin',
    'qwerty', 'qwerty123', 'abc123', 'admin123', 'password', 'password123', 'welcome', 'welcome123', 'test123', 'admin',
    'root123', 'user123', 'home123', 'family123', 'love123', 'summer123', 'winter123', 'spring123', 'autumn123',
    'chunjie', 'guoqing', 'yuandan', 'qingrenjie', 'shengri', 'shengri123', 'xin年快乐', '新年快乐123', '生日快乐123',
    '宝宝123', '宝贝123', '老婆123', '老公123', '妈妈123', '爸爸123', '中国加油', '武汉加油', '平安是福', '家和万事兴',
    'zhonghua', 'huaxia', 'long', 'feng', 'meimei123', 'jiejie123', 'gege123', 'didi123', 'xiaoai', 'xiaokeai',
    'xiaoming', 'xiaohong', 'xiaoli', 'xiaowang', 'xiaozhang', 'laowang', 'laoli', 'laozhang', 'yangyang', 'mengmeng',
    '天天向上', '好好学习', '努力工作', '工作顺利', '学习进步', '考试通过', '毕业快乐', '健康长寿', '福如东海', '寿比南山'
)

function New-OrderedCandidateList {
    param(
        [Parameter(Mandatory = $true)][string[]]$Seeds,
        [Parameter(Mandatory = $true)][System.Collections.Generic.HashSet[string]]$Excluded
    )

    $seen = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::Ordinal)
    $items = New-Object 'System.Collections.Generic.List[string]'
    $add = {
        param([AllowNull()][string]$Value)
        if ([string]::IsNullOrEmpty($Value)) { return }
        if ($Excluded.Contains($Value)) { return }
        if ($seen.Add($Value)) { [void]$items.Add($Value) }
    }

    $suffixes = @('', '1', '12', '123', '1234', '01', '007', '111', '321', '666', '888', '2022', '2023', '2024', '2025', '2026', '2027', '!', '@', '#', '$', '_', '01!', '123!', '!@#')
    $prefixes = @('', '1', '12', '!', '@', '#', 'my', 'My', 'the', 'The')
    foreach ($seed in $Seeds) {
        & $add $seed
        if ($seed.Length -gt 0) {
            & $add ($seed.Substring(0, 1).ToUpperInvariant() + $seed.Substring(1))
            & $add $seed.ToUpperInvariant()
        }
        foreach ($suffix in $suffixes) { & $add ($seed + $suffix) }
        foreach ($prefix in $prefixes) { & $add ($prefix + $seed) }
    }

    # A small amount of ordered word pairing covers family/project-style
    # passwords before the larger numeric tail is reached.
    $pairLimit = [math]::Min(180, $Seeds.Count)
    for ($left = 0; $left -lt $pairLimit; $left++) {
        for ($right = 0; $right -lt [math]::Min(60, $Seeds.Count); $right++) {
            if ($left -eq $right) { continue }
            & $add ($Seeds[$left] + $Seeds[$right])
            if ($items.Count -ge 30000) { break }
        }
        if ($items.Count -ge 30000) { break }
    }

    # The final tail keeps the resource at the requested Top-100000 scale
    # without creating a candidate file at runtime.  It is intentionally last
    # so the curated high-probability candidates retain their order.
    $tailIndex = 0
    while ($items.Count -lt 101000) {
        $seed = $Seeds[$tailIndex % $Seeds.Count]
        $serial = '{0:D6}' -f $tailIndex
        & $add ($seed + $serial)
        if (($tailIndex % 5) -eq 0) { & $add (($seed.Substring(0, 1).ToUpperInvariant() + $seed.Substring(1)) + $serial) }
        if (($tailIndex % 11) -eq 0) { & $add ($serial + $seed) }
        $tailIndex++
        if ($tailIndex -gt 250000) { throw 'The deterministic dictionary expansion did not produce enough unique candidates.' }
    }

    return $items.ToArray()
}

function Get-SourceLines {
    param(
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][string[]]$Paths
    )

    $lines = New-Object 'System.Collections.Generic.List[string]'
    foreach ($path in $Paths) {
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { continue }
        $reader = New-Object System.IO.StreamReader($path, [System.Text.Encoding]::UTF8, $true)
        try {
            while (-not $reader.EndOfStream) {
                $line = $reader.ReadLine()
                if ($null -eq $line) { continue }
                $value = $line.Trim()
                if ($value.Length -gt 0 -and $value[0] -eq [char]0xFEFF) {
                    $value = $value.Substring(1)
                }
                if ($value.Length -eq 0 -or $value.StartsWith('#')) { continue }
                [void]$lines.Add($value)
            }
        }
        finally {
            $reader.Dispose()
        }
    }
    return $lines.ToArray()
}

function New-OrderedSourceList {
    param(
        [Parameter(Mandatory = $true)][string[]]$Lines,
        [Parameter(Mandatory = $true)][System.Collections.Generic.HashSet[string]]$Excluded
    )

    $seen = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::Ordinal)
    $items = New-Object 'System.Collections.Generic.List[string]'
    foreach ($line in $Lines) {
        if ([string]::IsNullOrEmpty($line)) { continue }
        if ($Excluded.Contains($line)) { continue }
        if ($seen.Add($line)) { [void]$items.Add($line) }
    }
    return $items.ToArray()
}

function Write-GzipText {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string[]]$Lines
    )

    $utf8 = New-Object System.Text.UTF8Encoding($false)
    $file = [System.IO.File]::Create($Path)
    try {
        $gzip = New-Object System.IO.Compression.GZipStream($file, [System.IO.Compression.CompressionMode]::Compress)
        try {
            $writer = New-Object System.IO.StreamWriter($gzip, $utf8)
            try {
                foreach ($line in $Lines) { $writer.WriteLine($line) }
            }
            finally { $writer.Dispose() }
        }
        finally { $gzip.Dispose() }
    }
    finally { $file.Dispose() }
}

$quickSet = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::Ordinal)
foreach ($candidate in $quickCandidates) { [void]$quickSet.Add($candidate) }

$secListsSourceRootResolved = $null
if (-not [string]::IsNullOrWhiteSpace($SecListsSourceRoot)) {
    $secListsSourceRootResolved = [System.IO.Path]::GetFullPath($SecListsSourceRoot)
}

$globalSourceNames = @(
    'xato-net-10-million-passwords-1000.txt',
    'xato-net-10-million-passwords-10000.txt',
    'xato-net-10-million-passwords-100000.txt'
)
$zhSourceNames = @(
    'Chinese-common-password-list-top-1000.txt',
    'Chinese-common-password-list-top-10000.txt',
    'Chinese-common-password-list-top-100000.txt'
)
$globalSourcePaths = @()
$zhSourcePaths = @()
if ($null -ne $secListsSourceRootResolved) {
    foreach ($name in $globalSourceNames) { $globalSourcePaths += (Join-Path $secListsSourceRootResolved $name) }
    foreach ($name in $zhSourceNames) { $zhSourcePaths += (Join-Path $secListsSourceRootResolved $name) }
}

$globalSourceLines = @(Get-SourceLines -Paths $globalSourcePaths)
$globalCandidates = @()
if ($globalSourceLines.Count -gt 0) {
    $globalCandidates = @(New-OrderedSourceList -Lines $globalSourceLines -Excluded $quickSet)
    if ($globalCandidates.Count -lt 101000) {
        $globalSupplementalExcluded = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::Ordinal)
        foreach ($candidate in $quickCandidates) { [void]$globalSupplementalExcluded.Add($candidate) }
        foreach ($candidate in $globalCandidates) { [void]$globalSupplementalExcluded.Add($candidate) }
        $globalSupplemental = @(New-OrderedCandidateList -Seeds $globalSeeds -Excluded $globalSupplementalExcluded)
        $globalCandidates = @($globalCandidates + $globalSupplemental)
    }
}
else {
    $globalCandidates = @(New-OrderedCandidateList -Seeds $globalSeeds -Excluded $quickSet)
}

$zhExcluded = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::Ordinal)
foreach ($candidate in $quickCandidates) { [void]$zhExcluded.Add($candidate) }
foreach ($candidate in $globalCandidates) { [void]$zhExcluded.Add($candidate) }
$zhSourceLines = @(Get-SourceLines -Paths $zhSourcePaths)
$zhCandidates = @()
if ($zhSourceLines.Count -gt 0) {
    $zhCandidates = @(New-OrderedSourceList -Lines $zhSourceLines -Excluded $zhExcluded)
    if ($zhCandidates.Count -lt 101000) {
        $zhSupplementalExcluded = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::Ordinal)
        foreach ($candidate in $zhExcluded) { [void]$zhSupplementalExcluded.Add($candidate) }
        foreach ($candidate in $zhCandidates) { [void]$zhSupplementalExcluded.Add($candidate) }
        $zhSupplemental = @(New-OrderedCandidateList -Seeds $zhSeeds -Excluded $zhSupplementalExcluded)
        $zhCandidates = @($zhCandidates + $zhSupplemental)
    }
}
else {
    $zhCandidates = @(New-OrderedCandidateList -Seeds $zhSeeds -Excluded $zhExcluded)
}

if ($globalCandidates.Count -lt 101000 -or $zhCandidates.Count -lt 101000) {
    throw 'Built-in dictionary generation produced fewer than 100000 candidates.'
}

$secListsAvailable = ($globalSourceLines.Count -gt 0 -or $zhSourceLines.Count -gt 0)
$dictionarySource = if ($secListsAvailable) { 'SecLists + project-curated-offline-v1' } else { 'project-curated-offline-v1' }

$definitions = New-Object 'System.Collections.Generic.List[object]'
foreach ($language in @('global', 'zh')) {
    $all = if ($language -eq 'global') { $globalCandidates } else { $zhCandidates }
    foreach ($level in 1..3) {
        $start = if ($level -eq 1) { 0 } elseif ($level -eq 2) { 1000 } else { 10000 }
        $count = if ($level -eq 1) { 1000 } elseif ($level -eq 2) { 9000 } else { 90000 }
        $lines = [string[]]$all[$start..($start + $count - 1)]
        $fileName = 'level{0}-{1}.txt.gz' -f $level, $language
        $path = Join-Path $dictionaryRoot $fileName
        Write-GzipText -Path $path -Lines $lines
        $definitions.Add([ordered]@{
                Id = ('builtin:L{0}-{1}:v1' -f $level, $language)
                CoverageId = ('builtin:L{0}-{1}:v1' -f $level, $language)
                Language = $language
                Level = $level
                CandidateCount = $count
                RelativePath = ('resources/dictionaries/' + $fileName)
                Source = $dictionarySource
            })
    }
}

$secListsFiles = @(
    [ordered]@{
        Name = $globalSourceNames[0]
        Role = 'global'
        Level = 1
        OriginalKaliPath = '/usr/share/seclists/Passwords/Common-Credentials/xato-net-10-million-passwords-1000.txt'
        OfficialUrl = 'https://gitlab.com/pentesting-tools/SecLists/-/raw/master/Passwords/Common-Credentials/xato-net-10-million-passwords-1000.txt'
    },
    [ordered]@{
        Name = $globalSourceNames[1]
        Role = 'global'
        Level = 2
        OriginalKaliPath = '/usr/share/seclists/Passwords/Common-Credentials/xato-net-10-million-passwords-10000.txt'
        OfficialUrl = 'https://gitlab.com/pentesting-tools/SecLists/-/raw/master/Passwords/Common-Credentials/xato-net-10-million-passwords-10000.txt'
    },
    [ordered]@{
        Name = $globalSourceNames[2]
        Role = 'global'
        Level = 3
        OriginalKaliPath = '/usr/share/seclists/Passwords/Common-Credentials/xato-net-10-million-passwords-100000.txt'
        OfficialUrl = 'https://gitlab.com/pentesting-tools/SecLists/-/raw/master/Passwords/Common-Credentials/xato-net-10-million-passwords-100000.txt'
    },
    [ordered]@{
        Name = $zhSourceNames[0]
        Role = 'zh'
        Level = 1
        OriginalKaliPath = '/usr/share/seclists/Passwords/Common-Credentials/Language-Specific/Chinese-common-password-list-top-1000.txt'
        OfficialUrl = 'https://gitlab.com/pentesting-tools/SecLists/-/raw/master/Passwords/Common-Credentials/Language-Specific/Chinese-common-password-list-top-1000.txt'
    },
    [ordered]@{
        Name = $zhSourceNames[1]
        Role = 'zh'
        Level = 2
        OriginalKaliPath = '/usr/share/seclists/Passwords/Common-Credentials/Language-Specific/Chinese-common-password-list-top-10000.txt'
        OfficialUrl = 'https://gitlab.com/pentesting-tools/SecLists/-/raw/master/Passwords/Common-Credentials/Language-Specific/Chinese-common-password-list-top-10000.txt'
    },
    [ordered]@{
        Name = $zhSourceNames[2]
        Role = 'zh'
        Level = 3
        OriginalKaliPath = '/usr/share/seclists/Passwords/Common-Credentials/Language-Specific/Chinese-common-password-list-top-100000.txt'
        OfficialUrl = 'https://gitlab.com/pentesting-tools/SecLists/-/raw/master/Passwords/Common-Credentials/Language-Specific/Chinese-common-password-list-top-100000.txt'
    }
)
$sourceRecords = New-Object 'System.Collections.Generic.List[object]'
[void]$sourceRecords.Add([ordered]@{
        Id = 'project-curated-offline-v1'
        Type = 'ProjectCurated'
        Description = 'Existing Quick baseline plus small project-curated candidates and bounded structural expansions used as fallback and source completion.'
        ExternalDownload = $false
        UsedFor = @('global L1/L2/L3', 'Chinese L1/L2/L3')
    })
if ($secListsAvailable) {
    [void]$sourceRecords.Add([ordered]@{
            Id = 'SecLists-official-master-2026-08-27'
            Type = 'SecLists'
            Repository = 'https://gitlab.com/pentesting-tools/SecLists'
            License = 'MIT'
            LicenseFile = 'resources/licenses/SecLists-LICENSE.txt'
            PackageVersion = 'Kali seclists package was absent; official SecLists master snapshot downloaded at build time on 2026-08-27.'
            Files = $secListsFiles
            UsedFor = @('global L1/L2/L3', 'Chinese L1/L2/L3')
        })
}
[void]$sourceRecords.Add([ordered]@{
        Id = 'kali-readonly-check-2026-08-27'
        Type = 'KaliReadOnlyInventory'
        Description = 'Checked through Windows wsl.exe -d kali-linux before the authorized source download.'
        Found = @('/usr/share/wordlists/rockyou.txt.gz')
        NotPackaged = @('/usr/share/wordlists/rockyou.txt.gz', '/usr/share/seclists', '/usr/share/john/password.lst')
        UsedFor = @('advanced user import record only')
    })

$manifest = [ordered]@{
    SchemaVersion = 1
    ResourceVersion = 'v1'
    GeneratedUtc = [datetime]::UtcNow.ToString('o')
    Description = 'Ordered, mutually-exclusive offline password candidates for ArchivePasswordRecovery.'
    Sources = $sourceRecords.ToArray()
    Dictionaries = @($definitions.ToArray())
}
$manifestPath = Join-Path $resourceRoot 'dictionary-manifest.json'
$manifest | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $manifestPath -Encoding UTF8

'Built-in dictionary resources generated:'
foreach ($definition in $definitions) {
    $file = Join-Path $ProjectRoot $definition.RelativePath.Replace('/', '\')
    '{0}: {1} candidates, {2} bytes' -f $definition.CoverageId, $definition.CandidateCount, (Get-Item -LiteralPath $file).Length
}
