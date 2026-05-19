# arg-extractor-v2.psm1 - Extractor avanzado con strict schema validation
$global:ToolSchemaCache = @{}

function Load-ToolSchemas($schemaJsonPath) {
    if (Test-Path $schemaJsonPath) {
        $json = Get-Content $schemaJsonPath -Raw | ConvertFrom-Json
        foreach ($prop in $json.PSObject.Properties) {
            $global:ToolSchemaCache[$prop.Name] = $prop.Value
        }
    }
}

function Resolve-WorkflowName($query, $wfMap) {
    $bestMatch = $null
    $bestScore = 0
    $queryLower = $query.ToLower()
    foreach ($entry in $wfMap.GetEnumerator()) {
        $name = $entry.Key
        $id = $entry.Value
        if ($queryLower -eq $name) { return [PSCustomObject]@{ id = $id; name = $entry.Key; score = 100 } }
        if ($queryLower.Contains($name)) { return [PSCustomObject]@{ id = $id; name = $entry.Key; score = 95 } }
        $queryWords = $queryLower -split '\s+' | Where-Object { $_.Length -gt 2 }
        $nameWords = $name -split '\s+' | Where-Object { $_.Length -gt 2 }
        $matches = 0
        foreach ($qw in $queryWords) {
            foreach ($nw in $nameWords) {
                if ($nw.Contains($qw) -or $qw.Contains($nw)) { $matches++; break }
            }
        }
        $score = if ($nameWords.Count -gt 0) { ($matches / $nameWords.Count) * 100 } else { 0 }
        if ($score -gt $bestScore) { $bestScore = $score; $bestMatch = [PSCustomObject]@{ id = $id; name = $entry.Key; score = $score } }
    }
    if ($bestMatch -and $bestScore -ge 40) { $bestMatch } else { $null }
}

function Extract-SearchQuery($query) {
    $patterns = @(
        '(?i)(?:about|for|with|containing|like|named)\s+(.+?)(?:\s+in\s+|\s+from\s+|\?|$)',
        '(?i)(?:search|find|list)\s+(?:workflows|nodes|projects|tables)\s+(?:about|for|with)\s+(.+?)(?:\?|$)'
    )
    foreach ($pat in $patterns) {
        $m = [regex]::Match($query, $pat)
        if ($m.Success) { return $m.Groups[1].Value.Trim() }
    }
    $words = $query -split '\s+' | Where-Object { $_ -notin @('a','an','the','my','all','some','any','this','that','these','those','in','on','at','to','for','of','with','about','find','search','list','show','get','workflow','workflows','node','nodes','project','projects','table','tables','data','integration') }
    if ($words.Count -gt 0) { return ($words -join ' ') } else { return $query }
}

function Extract-WorkflowNameFromQuery($query) {
    $m1 = [regex]::Match($query, '"([^"]+)"')
    if ($m1.Success) { return $m1.Groups[1].Value.Trim() }
    $m2 = [regex]::Match($query, "'([^']+)'")
    if ($m2.Success) { return $m2.Groups[1].Value.Trim() }
    $m3 = [regex]::Match($query, '(?i)(?:of|named|called)\s+([A-Z][A-Za-z0-9\s]+?)(?:\s+(?:workflow|in|from|to|and|or)\b|$)')
    if ($m3.Success) { return $m3.Groups[1].Value.Trim() }
    $m4 = [regex]::Match($query, '(?i)(?:workflow|execution)\s+([A-Za-z0-9\s]+?)(?:\s+(?:in|from|to|and|or)\b|$)')
    if ($m4.Success) { return $m4.Groups[1].Value.Trim() }
    return $null
}

function Build-Args($toolName, $inputText, $wfMap) {
    $queryLower = $inputText.ToLower()
    $result = [PSCustomObject]@{}
    switch ($toolName) {
        'search_workflows' {
            $q = Extract-SearchQuery -query $inputText
            $listAllKeywords = @("list all","show all","all my","get all","my workflows")
            $isListAll = $false
            foreach ($kw in $listAllKeywords) { if ($inputText.ToLower().Contains($kw)) { $isListAll = $true; break } }
            if (-not $isListAll -and $q -and $q.Length -gt 0) { $result | Add-Member -NotePropertyName "query" -NotePropertyValue $q -Force }
            $result | Add-Member -NotePropertyName 'limit' -NotePropertyValue 50 -Force
        }
        'get_workflow_details' {
            $wfName = Extract-WorkflowNameFromQuery -query $inputText
            if ($wfName) {
                $resolved = Resolve-WorkflowName -query $wfName -wfMap $wfMap
                if ($resolved) { $result | Add-Member -NotePropertyName 'workflowId' -NotePropertyValue $resolved.id -Force }
            }
            if ($result.PSObject.Properties.Match('workflowId').Count -eq 0) {
                $resolved = Resolve-WorkflowName -query $inputText -wfMap $wfMap
                if ($resolved) { $result | Add-Member -NotePropertyName 'workflowId' -NotePropertyValue $resolved.id -Force }
            }
        }
        'execute_workflow' {
            $result | Add-Member -NotePropertyName 'executionMode' -NotePropertyValue 'manual' -Force
            $result | Add-Member -NotePropertyName 'inputs' -NotePropertyValue @{} -Force
            $wfName = Extract-WorkflowNameFromQuery -query $inputText
            if ($wfName) {
                $resolved = Resolve-WorkflowName -query $wfName -wfMap $wfMap
                if ($resolved) { $result | Add-Member -NotePropertyName 'workflowId' -NotePropertyValue $resolved.id -Force }
            }
            if ($result.PSObject.Properties.Match('workflowId').Count -eq 0) {
                $resolved = Resolve-WorkflowName -query $inputText -wfMap $wfMap
                if ($resolved) { $result | Add-Member -NotePropertyName 'workflowId' -NotePropertyValue $resolved.id -Force }
            }
        }
        'publish_workflow' {
            $wfName = Extract-WorkflowNameFromQuery -query $inputText
            if ($wfName) {
                $resolved = Resolve-WorkflowName -query $wfName -wfMap $wfMap
                if ($resolved) { $result | Add-Member -NotePropertyName 'workflowId' -NotePropertyValue $resolved.id -Force }
            }
            if ($result.PSObject.Properties.Match('workflowId').Count -eq 0) {
                $resolved = Resolve-WorkflowName -query $inputText -wfMap $wfMap
                if ($resolved) { $result | Add-Member -NotePropertyName 'workflowId' -NotePropertyValue $resolved.id -Force }
            }
        }
        'unpublish_workflow' {
            $wfName = Extract-WorkflowNameFromQuery -query $inputText
            if ($wfName) {
                $resolved = Resolve-WorkflowName -query $wfName -wfMap $wfMap
                if ($resolved) { $result | Add-Member -NotePropertyName 'workflowId' -NotePropertyValue $resolved.id -Force }
            }
            if ($result.PSObject.Properties.Match('workflowId').Count -eq 0) {
                $resolved = Resolve-WorkflowName -query $inputText -wfMap $wfMap
                if ($resolved) { $result | Add-Member -NotePropertyName 'workflowId' -NotePropertyValue $resolved.id -Force }
            }
        }
        'archive_workflow' {
            $wfName = Extract-WorkflowNameFromQuery -query $inputText
            if ($wfName) {
                $resolved = Resolve-WorkflowName -query $wfName -wfMap $wfMap
                if ($resolved) { $result | Add-Member -NotePropertyName 'workflowId' -NotePropertyValue $resolved.id -Force }
            }
            if ($result.PSObject.Properties.Match('workflowId').Count -eq 0) {
                $resolved = Resolve-WorkflowName -query $inputText -wfMap $wfMap
                if ($resolved) { $result | Add-Member -NotePropertyName 'workflowId' -NotePropertyValue $resolved.id -Force }
            }
        }
        'test_workflow' {
            $wfName = Extract-WorkflowNameFromQuery -query $inputText
            if ($wfName) {
                $resolved = Resolve-WorkflowName -query $wfName -wfMap $wfMap
                if ($resolved) { $result | Add-Member -NotePropertyName 'workflowId' -NotePropertyValue $resolved.id -Force }
            }
            if ($result.PSObject.Properties.Match('workflowId').Count -eq 0) {
                $resolved = Resolve-WorkflowName -query $inputText -wfMap $wfMap
                if ($resolved) { $result | Add-Member -NotePropertyName 'workflowId' -NotePropertyValue $resolved.id -Force }
            }
        }
        'update_workflow' {
            $wfName = Extract-WorkflowNameFromQuery -query $inputText
            if ($wfName) {
                $resolved = Resolve-WorkflowName -query $wfName -wfMap $wfMap
                if ($resolved) { $result | Add-Member -NotePropertyName 'workflowId' -NotePropertyValue $resolved.id -Force }
            }
            if ($result.PSObject.Properties.Match('workflowId').Count -eq 0) {
                $resolved = Resolve-WorkflowName -query $inputText -wfMap $wfMap
                if ($resolved) { $result | Add-Member -NotePropertyName 'workflowId' -NotePropertyValue $resolved.id -Force }
            }
            $result | Add-Member -NotePropertyName 'code' -NotePropertyValue '// TODO: Provide valid n8n SDK workflow code' -Force
        }
        'search_nodes' {
            $q = Extract-SearchQuery -query $inputText
            if ($q -and $q.Length -gt 0) { $result | Add-Member -NotePropertyName 'queries' -NotePropertyValue @($q) -Force }
        }
        'get_suggested_nodes' {
            $q = Extract-SearchQuery -query $inputText
            if ($q -and $q.Length -gt 0) { $result | Add-Member -NotePropertyName 'categories' -NotePropertyValue @($q -split '\s+') -Force }
        }
        'search_projects' {
            $q = Extract-SearchQuery -query $inputText
            $listAllKeywords = @("list all","show all","all my","get all","my projects","my folders")
            $isListAll = $false
            foreach ($kw in $listAllKeywords) { if ($inputText.ToLower().Contains($kw)) { $isListAll = $true; break } }
            if (-not $isListAll -and $q -and $q.Length -gt 0) { $result | Add-Member -NotePropertyName "query" -NotePropertyValue $q -Force }
            $result | Add-Member -NotePropertyName 'limit' -NotePropertyValue 50 -Force
        }
        'search_folders' {
            $q = Extract-SearchQuery -query $inputText
            $listAllKeywords = @("list all","show all","all my","get all","my projects","my folders")
            $isListAll = $false
            foreach ($kw in $listAllKeywords) { if ($inputText.ToLower().Contains($kw)) { $isListAll = $true; break } }
            if (-not $isListAll -and $q -and $q.Length -gt 0) { $result | Add-Member -NotePropertyName "query" -NotePropertyValue $q -Force }
            $result | Add-Member -NotePropertyName 'limit' -NotePropertyValue 50 -Force
        }
        'search_data_tables' {
            $q = Extract-SearchQuery -query $inputText
            $listAllKeywords = @("list all","show all","all my","get all","my tables","my data tables")
            $isListAll = $false
            foreach ($kw in $listAllKeywords) { if ($inputText.ToLower().Contains($kw)) { $isListAll = $true; break } }
            if (-not $isListAll -and $q -and $q.Length -gt 0) { $result | Add-Member -NotePropertyName "query" -NotePropertyValue $q -Force }
            $result | Add-Member -NotePropertyName 'limit' -NotePropertyValue 50 -Force
        }
        'validate_workflow' {
            $result | Add-Member -NotePropertyName 'code' -NotePropertyValue '// TODO: Provide valid n8n SDK workflow code to validate' -Force
        }
        'create_workflow_from_code' {
            $template = Resolve-WorkflowTemplate -query $inputText
            if ($template) {
                $result | Add-Member -NotePropertyName "name" -NotePropertyValue $template.name -Force
                $result | Add-Member -NotePropertyName "description" -NotePropertyValue $template.description -Force
                $result | Add-Member -NotePropertyName "code" -NotePropertyValue $template.code -Force
            } else {
                $words = $inputText -split '\s+' | Where-Object { $_ -notin @('a','an','the','my','new','create','build','make','write','save','from','code','workflow','workflows','that','which','this') }
                $name = if ($words.Count -gt 0) { ($words[0..([Math]::Min(5,$words.Count-1))] -join ' ') } else { 'New Workflow' }
                $result | Add-Member -NotePropertyName 'name' -NotePropertyValue ($name.Substring(0, [Math]::Min(128, $name.Length))) -Force
                $result | Add-Member -NotePropertyName 'description' -NotePropertyValue ($inputText.Substring(0, [Math]::Min(255, $inputText.Length))) -Force
                $result | Add-Member -NotePropertyName 'code' -NotePropertyValue '// TODO: Provide valid n8n SDK workflow code' -Force
            }
        }
        'get_sdk_reference' {
            $section = if ($queryLower.Contains('expression')) { 'expressions' }
                       elseif ($queryLower.Contains('pattern')) { 'patterns' }
                       elseif ($queryLower.Contains('function')) { 'functions' }
                       elseif ($queryLower.Contains('rule')) { 'rules' }
                       elseif ($queryLower.Contains('import')) { 'import' }
                       elseif ($queryLower.Contains('guideline')) { 'guidelines' }
                       elseif ($queryLower.Contains('design')) { 'design' }
                       else { 'all' }
            $result | Add-Member -NotePropertyName 'section' -NotePropertyValue $section -Force
        }
        'get_execution' {
            $wfName = Extract-WorkflowNameFromQuery -query $inputText
            if ($wfName) {
                $resolved = Resolve-WorkflowName -query $wfName -wfMap $wfMap
                if ($resolved) { $result | Add-Member -NotePropertyName 'workflowId' -NotePropertyValue $resolved.id -Force }
            }
            if ($result.PSObject.Properties.Match('workflowId').Count -eq 0) {
                $resolved = Resolve-WorkflowName -query $inputText -wfMap $wfMap
                if ($resolved) { $result | Add-Member -NotePropertyName 'workflowId' -NotePropertyValue $resolved.id -Force }
            }
        }
    }
    return $result
}

function Filter-StrictArgs($toolName, $argsObj) {
    if ($global:ToolSchemaCache.Count -eq 0) { return $argsObj }
    if (-not $global:ToolSchemaCache.ContainsKey($toolName)) { return $argsObj }
    $schema = $global:ToolSchemaCache[$toolName]
    $allowedProps = $schema.properties
    $filtered = [PSCustomObject]@{}
    foreach ($prop in $argsObj.PSObject.Properties) {
        if ($allowedProps -contains $prop.Name) {
            $filtered | Add-Member -NotePropertyName $prop.Name -NotePropertyValue $prop.Value -Force
        } else {
            Write-Host "  [strict] Removing invalid arg '$($prop.Name)' for $toolName" -ForegroundColor DarkRed
        }
    }
    return $filtered
}

function Is-Invalid($val) {
    if ($val -eq $null) { return $true }
    if ($val -is [string] -and ($val -eq '' -or $val -eq 'your-workflow-id-here' -or $val -eq 'your-workflow-code-here' -or $val -eq 'your_project_id' -or $val -match '^\s*$')) { return $true }
    if ($val -is [int] -and $val -le 0) { return $true }
    return $false
}

function Fill-Arguments($toolName, $arguments, $inputText, $wfMap) {
    $base = Build-Args -toolName $toolName -inputText $inputText -wfMap $wfMap
    $clean = [PSCustomObject]@{}
    
    foreach ($prop in $base.PSObject.Properties) {
        $clean | Add-Member -NotePropertyName $prop.Name -NotePropertyValue $prop.Value -Force
    }
    
    if ($arguments) {
        $arguments.PSObject.Properties | ForEach-Object {
            $key = $_.Name
            $val = $_.Value
            if ($key -in @('Count','Keys','Values','IsReadOnly','IsFixedSize','IsSynchronized','SyncRoot')) { return }
            if ($key -eq 'WORKFLOW') { $key = 'workflowId' }
            if ($key -eq 'execution_mode') { $key = 'executionMode' }
            
            if ($key -eq 'workflowId' -and -not (Is-Invalid $val)) {
                $wid = $val.ToString()
                if ($wid -match '\s' -or $wid.Length -gt 30 -or $wid -eq 'your-workflow-id-here') {
                    Write-Host "  [extractor] workflowId '$wid' invalido, usando extractor..." -ForegroundColor DarkYellow
                    return
                }
            }
            
            if ($key -eq 'executionMode' -and -not (Is-Invalid $val)) {
                $em = $val.ToString().ToLower()
                if ($em -notin @('manual','production')) {
                    Write-Host "  [extractor] executionMode '$em' invalido, usando extractor..." -ForegroundColor DarkYellow
                    return
                }
            }
            
            if ((-not (Is-Invalid $val)) -and ($clean.PSObject.Properties.Match($key).Count -eq 0 -or (Is-Invalid $clean.$key))) {
                $clean | Add-Member -NotePropertyName $key -NotePropertyValue $val -Force
            }
        }
    }
    
    switch ($toolName) {
        'search_workflows' {
            if ((Is-Invalid $clean.limit) -or ($clean.limit -is [int] -and $clean.limit -le 0)) { $clean | Add-Member -NotePropertyName 'limit' -NotePropertyValue 50 -Force }
        }
        'search_projects' {
            if ((Is-Invalid $clean.limit) -or ($clean.limit -is [int] -and $clean.limit -le 0)) { $clean | Add-Member -NotePropertyName 'limit' -NotePropertyValue 50 -Force }
        }
        'search_folders' {
            if ((Is-Invalid $clean.limit) -or ($clean.limit -is [int] -and $clean.limit -le 0)) { $clean | Add-Member -NotePropertyName 'limit' -NotePropertyValue 50 -Force }
        }
        'search_data_tables' {
            if ((Is-Invalid $clean.limit) -or ($clean.limit -is [int] -and $clean.limit -le 0)) { $clean | Add-Member -NotePropertyName 'limit' -NotePropertyValue 50 -Force }
        }
        'execute_workflow' {
            if ((Is-Invalid $clean.executionMode) -or ($clean.executionMode -notin @('manual','production'))) { $clean | Add-Member -NotePropertyName 'executionMode' -NotePropertyValue 'manual' -Force }
            if (Is-Invalid $clean.inputs) { $clean | Add-Member -NotePropertyName 'inputs' -NotePropertyValue @{} -Force }
        }
    }
    
    # Cleanup: remove null or empty string values
    $propsToRemove = $clean.PSObject.Properties | Where-Object { (Is-Invalid $_.Value) } | Select-Object -ExpandProperty Name
    foreach ($p in $propsToRemove) { $clean.PSObject.Properties.Remove($p) }

    $clean = Filter-StrictArgs -toolName $toolName -argsObj $clean
    return $clean
}


function Resolve-WorkflowTemplate($query) {
    $templatePath = Join-Path $PSScriptRoot "workflow-templates.json"
    if (-not (Test-Path $templatePath)) { return $null }
    $templates = Get-Content $templatePath -Raw | ConvertFrom-Json
    $queryLower = $query.ToLower()
    $bestMatch = $null
    $bestScore = 0
    foreach ($prop in $templates.PSObject.Properties) {
        $template = $prop.Value
        $templateKeywords = if ($template.keywords) { $template.keywords } else { $template.description.ToLower() -split "\s+" | Where-Object { $_.Length -gt 2 } }
        $queryWords = $queryLower -split "\s+" | Where-Object { $_.Length -gt 2 }
        $matches = 0
        foreach ($qw in $queryWords) {
            foreach ($kw in $templateKeywords) {
                if ($kw.Contains($qw) -or $qw.Contains($kw)) { $matches++; break }
            }
        }
        $score = ($matches / [Math]::Max(1, $templateKeywords.Count)) * 100
        if ($score -gt $bestScore) { $bestScore = $score; $bestMatch = $template }
    }
    if ($bestScore -ge 15) { $bestMatch } else { $null }
}


# ============================================================
# TEMPLATE FILLING CON SLOTS
# ============================================================
function Get-TemplateSlots() {
    $tempFile = [System.IO.Path]::GetTempFileName() + ".js"
    Set-Content -Path $tempFile -Value $templateCode -Encoding UTF8
    try {
        $output = node "$PSScriptRoot\n8n-validator\template-filler.js" detect $tempFile 2>&1
        $result = $output | ConvertFrom-Json
        return $result.slots
    } finally {
        if (Test-Path $tempFile) { Remove-Item $tempFile -Force }
    }
}

function Extract-SlotValuesFromQuery($query, $slots) {
    $values = @{}
    foreach ($slot in $slots) {
        switch ($slot) {
            "channel" {
                $m = [regex]::Match($query, '(?i)#([a-z0-9_-]+)')
                if ($m.Success) { $values["channel"] = "#$($m.Groups[1].Value)" }
            }
            "text" {
                $m = [regex]::Match($query, '(?i)(?:sends?|with|saying|message)\s+[""'']?([^""'']+?)[""'']?\s*(?:to|via|in|$)')
                if ($m.Success) { $values["text"] = $m.Groups[1].Value.Trim() }
            }
            "url" {
                $m = [regex]::Match($query, '(?i)https?://[^\s]+')
                if ($m.Success) { $values["url"] = $m.Groups[0].Value }
            }
            "to" {
                $m = [regex]::Match($query, '(?i)(?:to|for)\s+([a-z0-9._%+-]+@[a-z0-9.-]+\.[a-z]{2,})')
                if ($m.Success) { $values["to"] = $m.Groups[1].Value }
            }
            "subject" {
                $m = [regex]::Match($query, '(?i)(?:subject|about)\s+[""'']?([^""'']+?)[""'']?\s*(?:$|to|for)')
                if ($m.Success) { $values["subject"] = $m.Groups[1].Value.Trim() }
            }
        }
    }
    return $values
}

function Fill-TemplateWithSlots($templateCode, $slotValues) {
    $tempFile = [System.IO.Path]::GetTempFileName() + ".js"
    $jsonFile = [System.IO.Path]::GetTempFileName() + ".json"
    Set-Content -Path $tempFile -Value $templateCode -Encoding UTF8
    $slotValues | ConvertTo-Json -Compress | Set-Content -Path $jsonFile -Encoding UTF8
    try {
        $output = node "$PSScriptRoot\n8n-validator\template-filler.js" fill $tempFile ($slotValues | ConvertTo-Json -Compress)
        $result = $output | ConvertFrom-Json
        return $result.filled
    } finally {
        if (Test-Path $tempFile) { Remove-Item $tempFile -Force }
        if (Test-Path $jsonFile) { Remove-Item $jsonFile -Force }
    }
}
Export-ModuleMember -Function Resolve-WorkflowName, Extract-SearchQuery, Extract-WorkflowNameFromQuery, Build-Args, Fill-Arguments, Load-ToolSchemas, Resolve-WorkflowTemplate, Get-TemplateSlots, Extract-SlotValuesFromQuery, Fill-TemplateWithSlots







