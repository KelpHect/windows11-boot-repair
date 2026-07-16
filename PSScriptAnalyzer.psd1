@{
    # PSScriptAnalyzer settings for this repository.
    #
    # Excluded rules and the rationale for each exclusion:
    #
    #   PSAvoidUsingWriteHost
    #     Repair-Windows11.ps1 is an interactive, colour-coded console repair
    #     tool. Write-Host is the correct API for direct console output with
    #     colours and is intentional throughout.
    #
    #   PSAvoidUsingEmptyCatchBlock
    #     Several cleanup steps (stopping/starting services, renaming cache
    #     folders) are best-effort and intentionally swallow non-fatal errors
    #     so a single failed step never aborts the whole repair run.

    ExcludeRules = @(
        'PSAvoidUsingWriteHost',
        'PSAvoidUsingEmptyCatchBlock'
    )

    Rules = @{
        PSUseApprovedVerbs = @{
            Enable = $true
        }
        PSUseSingularNouns = @{
            Enable = $true
        }
    }
}