<#
.SYNOPSIS
  Writes declarations.json from a Power BI semantic model saved as a project (<Name>.SemanticModel, TMDL).

.DESCRIPTION
  Reads definition\tables\*.tmdl and definition\relationships.tmdl and keeps the NAMES only:
  tables, columns (data type, sort column, hidden, image URL category), measures (format string,
  hidden, whether the first line of the expression returns text) and which tables are related.

  Never read, never written: partitions and M queries, DAX expressions (beyond the first line of a
  measure, used only to tell text from numbers), annotations, data. Open declarations.json before
  you send it: it is plain text.

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File .\Export-Declarations.ps1 "C:\Reports\Sales\Sales.SemanticModel"
  Right-click the script, "Run with PowerShell", then paste the folder path when asked.

.NOTES
  Windows PowerShell 5.1 or PowerShell 7. No module, no install. Same output as export-declarations.mjs.
#>
param(
  [Parameter(Position = 0)] [string] $Path,
  [string] $Out = "declarations.json"
)
$ErrorActionPreference = 'Stop'

if (-not $Path) { $Path = Read-Host 'Path to the <Name>.SemanticModel folder (or the project folder that contains it)' }

$DATE_WORDS = @('date', 'calendar', 'calendrier', 'calendario', 'fecha', 'datum')
$AUTO_TABLE = [regex]'^(LocalDateTable_|DateTableTemplate_)'
$TEXT_FUNCTIONS = [regex]::new('^(FORMAT|CONCATENATE|CONCATENATEX|COMBINEVALUES|UNICHAR|REPT|UPPER|LOWER|LEFT|RIGHT|MID|SUBSTITUTE|TRIM)\s*\(', 'IgnoreCase')
$CONCAT = [regex]'"\s*&|&\s*"'
$QUOTED = [regex]"^'((?:[^']|'')*)'\s*([\s\S]*)$"
$BARE = [regex]'^([^\s=]+)\s*([\s\S]*)$'
$PROPERTY = [regex]'^([A-Za-z]+)\s*:\s*(.*)$'
$BARE_QUALIFIED = [regex]"^([^\s.']+)\.(.+)$"

function Test-DateTableName([string] $name) {
  foreach ($w in [regex]::Split($name, '[^A-Za-z]+|(?=[A-Z][a-z])')) {
    if ($w.Length -eq 0) { continue }
    $k = $w.ToLowerInvariant() -creplace 's$', ''
    if ($DATE_WORDS -ccontains $k) { return $true }
  }
  return $false
}

function Get-Leading([string] $line) {
  $tabs = 0; $spaces = 0
  foreach ($ch in $line.ToCharArray()) {
    if ($ch -eq "`t") { $tabs++ } elseif ($ch -eq ' ') { $spaces++ } else { break }
  }
  return @{ Tabs = $tabs; Spaces = $spaces }
}

function Get-SpaceUnit([string[]] $lines) {
  $unit = 0
  foreach ($line in $lines) {
    if ($line.Trim().Length -eq 0) { continue }
    $lead = Get-Leading $line
    if ($lead.Tabs -eq 0 -and $lead.Spaces -gt 0 -and ($unit -eq 0 -or $lead.Spaces -lt $unit)) { $unit = $lead.Spaces }
  }
  if ($unit -eq 0) { return 4 } else { return $unit }
}

function Test-Textual([string] $expression) {
  $e = $expression.Trim()
  if ($e.StartsWith('"')) { return $true }
  if ($TEXT_FUNCTIONS.IsMatch($e)) { return $true }
  return $CONCAT.IsMatch($e)
}

function Read-Name([string] $source) {
  $m = $QUOTED.Match($source)
  if ($m.Success) { return @{ Name = ($m.Groups[1].Value -replace "''", "'"); Rest = $m.Groups[2].Value } }
  $m = $BARE.Match($source)
  if ($m.Success) { return @{ Name = $m.Groups[1].Value; Rest = $m.Groups[2].Value } }
  return $null
}

function Read-Property([string] $line) {
  $m = $PROPERTY.Match($line.Trim())
  if ($m.Success) { return @{ Key = $m.Groups[1].Value; Value = $m.Groups[2].Value.Trim() } }
  return $null
}

function New-List { return New-Object System.Collections.ArrayList }

function Read-Table([string] $text) {
  $table = $null
  $member = $null
  $awaiting = $null
  $text = $text -creplace '^\uFEFF', ''
  $lines = $text -split "`r?`n"
  $unit = Get-SpaceUnit $lines
  foreach ($raw in $lines) {
    if ($raw.Trim().Length -eq 0) { continue }
    $lead = Get-Leading $raw
    $depth = $lead.Tabs + [math]::Floor($lead.Spaces / $unit)
    $line = $raw.Trim()

    if ($depth -eq 0) {
      if ($line.StartsWith('table ')) {
        $read = Read-Name $line.Substring(6)
        if ($read) {
          $table = [ordered]@{ name = $read.Name; hidden = $false; isDateTable = (Test-DateTableName $read.Name); columns = (New-List); measures = (New-List) }
        }
      }
      $member = $null
      $awaiting = $null
      continue
    }
    if (-not $table) { continue }

    if ($depth -ge 3 -and $awaiting) {
      if ($line -cne '```') {
        if (Test-Textual $line) { $awaiting.isText = $true }
        $awaiting = $null
      }
      continue
    }

    if ($depth -eq 1) {
      $member = $null
      $awaiting = $null
      if ($line.StartsWith('column ')) {
        $read = Read-Name $line.Substring(7)
        if ($read) {
          $column = [ordered]@{ name = $read.Name; dataType = 'string'; sortByColumn = $null; hidden = $false; imageUrl = $false }
          [void]$table.columns.Add($column)
          $member = @{ Kind = 'column'; Ref = $column }
        }
      } elseif ($line.StartsWith('measure ')) {
        $read = Read-Name $line.Substring(8)
        if ($read) {
          $expression = $read.Rest -creplace '^=\s*', ''
          $measure = [ordered]@{ name = $read.Name; formatString = $null; isText = (Test-Textual $expression); hidden = $false }
          [void]$table.measures.Add($measure)
          $member = @{ Kind = 'measure'; Ref = $measure }
          if ($expression -ceq '' -or $expression -ceq '```') { $awaiting = $measure }
        }
      } elseif ($line -ceq 'isHidden') {
        $table.hidden = $true
      } else {
        $prop = Read-Property $line
        if ($prop -and $prop.Key -ceq 'dataCategory' -and $prop.Value -match '^time$') { $table.isDateTable = $true }
        $member = @{ Kind = 'other'; Ref = $null }
      }
      continue
    }

    if ($depth -eq 2 -and $member) {
      $awaiting = $null
      if ($member.Kind -eq 'column') {
        if ($line -ceq 'isHidden') { $member.Ref.hidden = $true }
        $prop = Read-Property $line
        if (-not $prop) { continue }
        if ($prop.Key -ceq 'dataType') { $member.Ref.dataType = $prop.Value }
        elseif ($prop.Key -ceq 'sortByColumn') { $n = Read-Name $prop.Value; if ($n) { $member.Ref.sortByColumn = $n.Name } else { $member.Ref.sortByColumn = $prop.Value } }
        elseif ($prop.Key -ceq 'dataCategory' -and $prop.Value -match '^imageurl$') { $member.Ref.imageUrl = $true }
      } elseif ($member.Kind -eq 'measure') {
        if ($line -ceq 'isHidden') { $member.Ref.hidden = $true }
        $prop = Read-Property $line
        if ($prop -and $prop.Key -ceq 'formatString') { $member.Ref.formatString = $prop.Value }
      }
    }
  }
  return $table
}

function Read-Qualified([string] $value) {
  $v = $value.Trim()
  $first = Read-Name $v
  if (-not $first -or -not $first.Rest.StartsWith('.')) {
    $m = $BARE_QUALIFIED.Match($v)
    if (-not $m.Success) { return $null }
    $column = Read-Name $m.Groups[2].Value
    if ($column) { return @{ Table = $m.Groups[1].Value; Column = $column.Name } } else { return $null }
  }
  $column = Read-Name $first.Rest.Substring(1)
  if ($column) { return @{ Table = $first.Name; Column = $column.Name } } else { return $null }
}

function Read-Relationships([string] $text) {
  $out = New-List
  $current = $null
  $text = $text -creplace '^\uFEFF', ''
  foreach ($raw in ($text -split "`r?`n")) {
    $line = $raw.Trim()
    if ($line.Length -eq 0) { continue }
    $lead = Get-Leading $raw
    if ($line -cmatch '^relationship\b' -and $lead.Tabs -eq 0 -and $lead.Spaces -eq 0) {
      if ($current -and $current.fromTable -and $current.toTable) { [void]$out.Add([ordered]@{ fromTable = $current.fromTable; toTable = $current.toTable }) }
      $current = @{ fromTable = $null; toTable = $null }
      continue
    }
    if (-not $current) { continue }
    $prop = Read-Property $line
    if (-not $prop) { continue }
    if ($prop.Key -ceq 'fromColumn' -or $prop.Key -ceq 'toColumn') {
      $ref = Read-Qualified $prop.Value
      if (-not $ref) { continue }
      if ($prop.Key -ceq 'fromColumn') { $current.fromTable = $ref.Table } else { $current.toTable = $ref.Table }
    }
  }
  if ($current -and $current.fromTable -and $current.toTable) { [void]$out.Add([ordered]@{ fromTable = $current.fromTable; toTable = $current.toTable }) }
  return ,$out
}

function Find-ModelFolder([string] $input0) {
  # ProviderPath : sur un chemin UNC, .Path garde le préfixe du fournisseur PowerShell.
  $p = (Resolve-Path -LiteralPath $input0).ProviderPath.TrimEnd('\')
  if ((Split-Path $p -Leaf) -match '\.SemanticModel$' -and (Test-Path -LiteralPath $p -PathType Container)) { return $p }
  if (Test-Path -LiteralPath $p -PathType Container) {
    foreach ($d in Get-ChildItem -LiteralPath $p -Directory) { if ($d.Name -match '\.SemanticModel$') { return $d.FullName } }
  }
  throw "No .SemanticModel folder found at $p. Point the script at <Name>.SemanticModel or at the folder that contains it."
}

# JSON by hand: two-space indent, keys in order, same bytes as JSON.stringify(x, null, 2).
function ConvertTo-JsonText([string] $s) {
  $sb = New-Object System.Text.StringBuilder
  [void]$sb.Append('"')
  foreach ($ch in $s.ToCharArray()) {
    switch ($ch) {
      '"' { [void]$sb.Append('\"') }
      '\' { [void]$sb.Append('\\') }
      "`n" { [void]$sb.Append('\n') }
      "`r" { [void]$sb.Append('\r') }
      "`t" { [void]$sb.Append('\t') }
      "`b" { [void]$sb.Append('\b') }
      "`f" { [void]$sb.Append('\f') }
      default { $code = [int][char]$ch; if ($code -lt 32) { [void]$sb.Append(('\u{0:x4}' -f $code)) } else { [void]$sb.Append($ch) } }
    }
  }
  [void]$sb.Append('"')
  return $sb.ToString()
}

function Write-Json($value, [int] $indent) {
  $pad = ' ' * $indent
  $padIn = ' ' * ($indent + 2)
  if ($value -is [System.Collections.IDictionary]) {
    if ($value.Count -eq 0) { return '{}' }
    $parts = New-List
    foreach ($k in $value.Keys) { [void]$parts.Add($padIn + (ConvertTo-JsonText ([string]$k)) + ': ' + (Write-Json $value[$k] ($indent + 2))) }
    return "{`n" + ($parts -join ",`n") + "`n" + $pad + '}'
  }
  if ($value -is [System.Collections.IList]) {
    if ($value.Count -eq 0) { return '[]' }
    $parts = New-List
    foreach ($v in $value) { [void]$parts.Add($padIn + (Write-Json $v ($indent + 2))) }
    return "[`n" + ($parts -join ",`n") + "`n" + $pad + ']'
  }
  if ($value -is [bool]) { if ($value) { return 'true' } else { return 'false' } }
  return ConvertTo-JsonText ([string]$value)
}

# The canonical shape: false and empty values left out, keys in a fixed order.
function ConvertTo-Canonical([string] $modelFolder, $tables, $relationships) {
  $outTables = New-List
  foreach ($t in $tables) {
    $o = [ordered]@{ name = $t.name }
    if ($t.isDateTable) { $o.isDateTable = $true }
    if ($t.hidden) { $o.hidden = $true }
    $cols = New-List
    foreach ($c in $t.columns) {
      $col = [ordered]@{ name = $c.name; dataType = $c.dataType }
      if ($c.sortByColumn) { $col.sortByColumn = $c.sortByColumn }
      if ($c.hidden) { $col.hidden = $true }
      if ($c.imageUrl) { $col.imageUrl = $true }
      [void]$cols.Add($col)
    }
    $o.columns = $cols
    $meas = New-List
    foreach ($m in $t.measures) {
      $me = [ordered]@{ name = $m.name }
      if ($m.formatString) { $me.formatString = $m.formatString }
      if ($m.isText) { $me.isText = $true }
      if ($m.hidden) { $me.hidden = $true }
      [void]$meas.Add($me)
    }
    $o.measures = $meas
    [void]$outTables.Add($o)
  }
  $out = [ordered]@{ modelFolder = $modelFolder; tables = $outTables }
  if ($null -ne $relationships) { $out.relationships = $relationships }
  return $out
}

$folder = Find-ModelFolder $Path
$tablesDir = Join-Path $folder 'definition\tables'
if (-not (Test-Path -LiteralPath $tablesDir -PathType Container)) { throw "No definition\tables folder in $folder. Is the model saved as a project (TMDL)?" }

$tables = New-List
$skipped = New-List
$files = @(Get-ChildItem -LiteralPath $tablesDir -File | Where-Object { $_.Name.EndsWith('.tmdl') } | Sort-Object -Property @{ Expression = { $_.Name } } -Culture 'en-US')
$files = @($files | Sort-Object { $_.Name } )
foreach ($f in $files) {
  $t = Read-Table ([IO.File]::ReadAllText($f.FullName, [Text.Encoding]::UTF8))
  if (-not $t -or $AUTO_TABLE.IsMatch($t.name)) { [void]$skipped.Add($f.Name); continue }
  [void]$tables.Add($t)
}
$sorted = $tables.ToArray()
[Array]::Sort($sorted, [System.Comparison[object]] { param($a, $b) [string]::CompareOrdinal($a.name, $b.name) })

$relPath = Join-Path $folder 'definition\relationships.tmdl'
$relationships = $null
if (Test-Path -LiteralPath $relPath -PathType Leaf) { $relationships = Read-Relationships ([IO.File]::ReadAllText($relPath, [Text.Encoding]::UTF8)) }

$declarations = ConvertTo-Canonical (Split-Path $folder -Leaf) $sorted $relationships
$json = (Write-Json $declarations 0) + "`n"
if ([IO.Path]::IsPathRooted($Out)) { $outPath = $Out } else { $outPath = Join-Path (Get-Location).ProviderPath $Out }
[IO.File]::WriteAllText($outPath, $json, (New-Object System.Text.UTF8Encoding $false))

$nCols = 0; $nMeas = 0
foreach ($t in $sorted) { $nCols += $t.columns.Count; $nMeas += $t.measures.Count }
$relText = if ($null -ne $relationships) { "$($relationships.Count) relationships" } else { 'no relationships.tmdl' }
Write-Host "$($declarations.modelFolder): $($sorted.Count) tables, $nCols columns, $nMeas measures, $relText."
foreach ($t in $sorted) {
  $extra = ''
  if ($t.isDateTable) { $extra += ', date table' }
  if ($t.hidden) { $extra += ', hidden' }
  Write-Host "  $($t.name): $($t.columns.Count) columns, $($t.measures.Count) measures$extra"
}
if ($skipped.Count -gt 0) { Write-Host "  Skipped (automatic date tables or unreadable): $($skipped -join ', ')" }
Write-Host "Written: $outPath. Names only: no data, no DAX, no M. Open it, read it, then send it."
