SyncMe Rescue Kit (runs without a healthy Host UI)
==================================================
From an elevated or normal PowerShell in the SyncMe install folder:

  .\RescueKit\SyncMe-Rescue.ps1 -Action Diagnostics
  .\RescueKit\SyncMe-Rescue.ps1 -Action Stop
  .\RescueKit\SyncMe-Rescue.ps1 -Action ValidateConfig
  .\RescueKit\SyncMe-Rescue.ps1 -Action RestorePrevious
  .\RescueKit\SyncMe-Rescue.ps1 -Action SafeMode
  .\RescueKit\SyncMe-Rescue.ps1 -Action Health
  .\RescueKit\SyncMe-Rescue.ps1 -Action Help

Actions:
  Diagnostics      Write Logs\rescue-<stamp>\ (no secrets)
  Stop             Stop SyncMe Host/Backup/Restore PowerShell processes
  ValidateConfig   Parse-check Config.ps1
  RestorePrevious  Restore Logs\previous-release application tree
  SafeMode         Start Host with -NoBrowser
  Health           Run Get-SyncMeHealthProbe if modules load
  Help             Print this summary

Full DR steps (passworded restore): docs\DISASTER-RECOVERY.md
Printable operator sheet: Operations → More → Export Rescue Kit (HTML)
