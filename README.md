# UMH-Backup

WARNING: This is a work in progress. It is not yet ready for production use.

## Description
This repo contains utilities for backing up and restoring UMH data.

It will back up the following:

 - All Node-RED flows
 - All Grafana dashboards
 - The current Helm values for the united-manufacturing-hub chart
 - All timescale tables used by the united-manufacturing-hub chart
 - Settings of the Management Console Companion (configmap, secret, statefulset)

We do *NOT* back up:

 - Other grafana data like Alerts, Users, ...
 - Timescale data unrelated to the united-manufacturing-hub chart
 - Any other data in the cluster
 - TimescaleDB continuous aggregates
   - If you want to back them up, please follow [this guide](https://docs.timescale.com/self-hosted/latest/migration/schema-then-data/#recreate-continuous-aggregates)
 - TimescaleDB policies
   - If you want to back them up, please follow [this guide](https://docs.timescale.com/self-hosted/latest/migration/schema-then-data/#recreate-policies)

### Backup

Checkout our Documentation for a full Tutorial.
TODO: Add link to documentation


#### TL;DR

```powershell
.\backup.ps1 `
	-IP <IP_OF_THE_SERVER_TO_BACK_UP> `
	-GrafanaToken <YOUR_GRAFANA_API_ADMIN_TOKEN> `
	-KubeconfigPath <PATH_TO_KUBECONFIG> `
	-OutputPath <PATH_TO_LOTS_OF_SPACE> `
```


### Restore

Checkout our Documentation for a full Tutorial.
TODO: Add link to documentation

#### TL;DR

1) Restoring Helm
   ```powershell
   .\restore-helm.ps1 `
	    -KubeconfigPath <PATH_TO_KUBECONFIG_OF_THE_NEW_SERVER> `
        -BackupPath <FULL_PATH_TO_BACKUP_FOLDER>
   ```
2) Wait after the Helm restore is done, for all pods to be running again
3) Restoring Grafana
    ```powershell
   .\restore-grafana.ps1 `
        -FullUrl http://<IP_OF_YOUR_NEW_SERVER>:8080 `
        -Token <YOUR_GRAFANA_API_ADMIN_TOKEN_ON_THE_NEW_SERVER> `
        -BackupPath <FULL_PATH_TO_BACKUP_FOLDER>
   ```
4) Restoring Node-RED
    ```powershell
    .\restore-nodered.ps1 `
	    -KubeconfigPath <PATH_TO_KUBECONFIG_OF_THE_NEW_SERVER> `
        -BackupPath <FULL_PATH_TO_BACKUP_FOLDER>
    ```
5) Restoring factoryinsight database in TimescaleDB
    ```powershell
    .\restore-timescale.ps1 `
	-Ip <IP_OF_YOUR_NEW_SERVER> `
    -BackupPath <FULL_PATH_TO_BACKUP_FOLDER>
	-PatroniSuperUserPassword <TIMESCALEDB_SUPERUSERPASSWORD>
    ```
6) Restoring umh_v2 database in TimescaleDB
    ```powershell
    .\restore-timescale-v2.ps1 `
	-Ip <IP_OF_YOUR_NEW_SERVER> `
    -BackupPath <FULL_PATH_TO_BACKUP_FOLDER>
	-PatroniSuperUserPassword <TIMESCALEDB_SUPERUSERPASSWORD>
    ```
7) Restoring the Management Console Companion
    ```powershell
    .\restore-companion.ps1
    -KubeconfigPath <PATH_TO_KUBECONFIG_OF_THE_NEW_SERVER>
    -BackupPath <FULL_PATH_TO_BACKUP_FOLDER>
    ```
