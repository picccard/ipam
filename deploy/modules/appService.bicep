@description('App Service Name')
param appServiceName string

@description('App Service Plan Name')
param appServicePlanName string

@description('CosmosDB URI')
param cosmosDbUri string

@description('CosmosDB Database Name')
param databaseName string

@description('CosmosDB Container Name')
param containerName string

@description('KeyVault URI')
param keyVaultUri string

@description('Deployment Location')
param location string = resourceGroup().location

@description('Azure Cloud Enviroment')
param azureCloud string = 'AZURE_PUBLIC'

@description('Managed Identity Id')
param managedIdentityId string

@description('Managed Identity ClientId')
param managedIdentityClientId string

@description('Log Analytics Worskpace ID')
param workspaceId string

@description('Flag to Deploy IPAM as a Container')
param deployAsContainer bool = false

@description('Flag to Deploy Private Container Registry')
param privateAcr bool

@description('Uri for Private Container Registry')
param privateAcrUri string

// ACR Uri Variable
var acrUri = privateAcr ? privateAcrUri : 'azureipam.azurecr.io'

// Disable Build Process Internet-Restricted Clouds
var runFromPackage = azureCloud == 'AZURE_US_GOV_SECRET' ? true : false

// Current Python Version
var engineVersion = loadJsonContent('../../engine/app/version.json')
var pythonVersion = engineVersion.python

module serverfarm 'br/public:avm/res/web/serverfarm:0.2.2' = {
  name: '${deployment().name}-serverfarmDeployment'
  params: {
    name: appServicePlanName
    skuCapacity: 1
    skuName: 'P1v3'
    diagnosticSettings: [
      {
        metricCategories: [{ category: 'AllMetrics' }]
        name: 'diagSettings'
        workspaceResourceId: workspaceId
      }
    ]
    kind: 'Linux'
    location: location
    zoneRedundant: false
  }
}

module appService 'br/public:avm/res/web/site:0.3.8' = {
  name: '${deployment().name}-appServiceDeployment'
  params: {
    name: appServiceName
    location: location
    kind: deployAsContainer ? 'app,linux,container' : 'app,linux'
    serverFarmResourceId: serverfarm.outputs.resourceId
    httpsOnly: true
    managedIdentities: {
      systemAssigned: false
      userAssignedResourceIds: [managedIdentityId]
    }
    keyVaultAccessIdentityResourceId: managedIdentityId
    diagnosticSettings: [
      {
        name: 'diagSettings'
        logCategoriesAndGroups: [
          // { category: 'allLogs' }
          { category: 'AppServiceAntivirusScanAuditLogs' }
          { category: 'AppServiceHTTPLogs' }
          { category: 'AppServiceConsoleLogs' }
          { category: 'AppServiceAppLogs' }
          { category: 'AppServiceFileAuditLogs' }
          { category: 'AppServiceAuditLogs' }
          { category: 'AppServiceIPSecAuditLogs' }
          { category: 'AppServicePlatformLogs' }
        ]
        metricCategories: [{ category: 'AllMetrics' }]
        workspaceResourceId: workspaceId
      }
    ]
    scmSiteAlsoStopped: true
    siteConfig: {
      acrUseManagedIdentityCreds: privateAcr ? true : false
      acrUserManagedIdentityID: privateAcr ? managedIdentityClientId : null
      alwaysOn: true
      linuxFxVersion: deployAsContainer ? 'DOCKER|${acrUri}/ipam:latest' : 'PYTHON|${pythonVersion}'
      appCommandLine: !deployAsContainer ? 'bash ./init.sh 8000' : null
      healthCheckPath: '/api/status'
      appSettings: concat(
        [
          {
            name: 'AZURE_ENV'
            value: azureCloud
          }
          {
            name: 'COSMOS_URL'
            value: cosmosDbUri
          }
          {
            name: 'DATABASE_NAME'
            value: databaseName
          }
          {
            name: 'CONTAINER_NAME'
            value: containerName
          }
          {
            name: 'MANAGED_IDENTITY_ID'
            value: '@Microsoft.KeyVault(SecretUri=${keyVaultUri}secrets/IDENTITY-ID/)'
          }
          {
            name: 'UI_APP_ID'
            value: '@Microsoft.KeyVault(SecretUri=${keyVaultUri}secrets/UI-ID/)'
          }
          {
            name: 'ENGINE_APP_ID'
            value: '@Microsoft.KeyVault(SecretUri=${keyVaultUri}secrets/ENGINE-ID/)'
          }
          {
            name: 'ENGINE_APP_SECRET'
            value: '@Microsoft.KeyVault(SecretUri=${keyVaultUri}secrets/ENGINE-SECRET/)'
          }
          {
            name: 'TENANT_ID'
            value: '@Microsoft.KeyVault(SecretUri=${keyVaultUri}secrets/TENANT-ID/)'
          }
          {
            name: 'KEYVAULT_URL'
            value: keyVaultUri
          }
          {
            name: 'WEBSITE_HEALTHCHECK_MAXPINGFAILURES'
            value: '2'
          }
        ],
        deployAsContainer ? [
          {
            name: 'WEBSITE_ENABLE_SYNC_UPDATE_SITE'
            value: 'true'
          }
          {
            name: 'DOCKER_REGISTRY_SERVER_URL'
            value: privateAcr ? 'https://${privateAcrUri}' : 'https://index.docker.io/v1'
          }
        ] : runFromPackage ? [
          {
            name: 'WEBSITE_RUN_FROM_PACKAGE'
            value: '1'
          }
        ] : [
          {
            name: 'SCM_DO_BUILD_DURING_DEPLOYMENT'
            value: 'true'
          }
        ]
      )
    }
  }
}

// https://github.com/Azure/bicep-registry-modules/issues/2537
resource appConfigLogs 'Microsoft.Web/sites/config@2021-02-01' = {
  name: '${appServiceName}/logs'
  properties: {
    detailedErrorMessages: {
      enabled: true
    }
    failedRequestsTracing: {
      enabled: true
    }
    httpLogs: {
      fileSystem: {
        enabled: true
        retentionInDays: 7
        retentionInMb: 50
      }
    }
  }
}

output appServiceHostName string = appService.outputs.defaultHostname
