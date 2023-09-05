@description('This is location default to resource group location')
param location string = resourceGroup().location    
param vnetName string = 'vnet-aci-acr' 
param addressPrefix string = '10.0.0.0/16'
param acrSubnetName string = 'acr-subnet'
param acrSubnetPrefix string = '10.0.0.0/24'
param aciSubnetName string = 'aci-subnet'
param aciSubnetPrefix string = '10.0.1.0/24'
param acrName string = 'acr${uniqueString(resourceGroup().id)}'
@description('This is the URL of Azure DevOps organization')
param AZP_URL string
@description('This is the PAT of Azure DevOps organization')
param AZP_TOKEN string
param AZP_AGENT_NAME string = 'agent${uniqueString(resourceGroup().id)}}'
@description('This is the URL of Git repository')
param GIT_TOKEN string
@description('This is the PAT of Git repository')
param GIT_REPO string


resource virtualNetwork 'Microsoft.Network/virtualNetworks@2023-04-01' = {
  name: vnetName
  location: location
  properties: {
    addressSpace: {
      addressPrefixes: [
        addressPrefix
      ]
    }
    subnets: [
      {
        name: acrSubnetName
        properties: {
          addressPrefix: acrSubnetPrefix
        }
      }
      {
        name: aciSubnetName
        properties: {
          addressPrefix: aciSubnetPrefix
          delegations: [
            {
              name: 'aci-delegation'
              properties: {
                serviceName: 'Microsoft.ContainerInstance/containerGroups'
              }
            }
          ]
        }
      }
    ]
  }
  resource acrSubnet 'subnets' existing = {
    name: acrSubnetName
  }

  resource aciSubnet'subnets' existing = {
    name: aciSubnetName

  }
}
resource acrPrivateEndpoint 'Microsoft.Network/privateEndpoints@2021-02-01' = {
  name: '${acrName}-private-endpoint'
  location: location
  properties: {
    subnet: {
      id: virtualNetwork::acrSubnet.id
    }
    privateLinkServiceConnections: [
      {
        name: '${acrName}-private-link-service-connection'
        properties: {
          privateLinkServiceId: containerRegistry.id
          groupIds: [
            'registry'
          ]
        }
      }
    ]
  }
}
resource privateDNSZone 'Microsoft.Network/privateDnsZones@2020-06-01' = {
  name: 'privatelink.azurecr.io'
  location: 'global'
  
}
resource privateDNSZoneLink 'Microsoft.Network/privateDnsZones/virtualNetworkLinks@2020-06-01' = {
  name: 'private-dns-zone-link'
  location:'global'
  parent: privateDNSZone
  properties: {
    virtualNetwork: {
      id: virtualNetwork.id
    }
    registrationEnabled: true
  }
}
resource acrPrivateDNSZoneGroup 'Microsoft.Network/privateEndpoints/privateDnsZoneGroups@2020-06-01' = {
  name: '${acrName}-private-dns-zone-group'
  parent: acrPrivateEndpoint
  properties: {
    privateDnsZoneConfigs: [
      {
        name: 'privatelink-database-windows-net'
        properties: {
          privateDnsZoneId: privateDNSZone.id
        }
      }
    ]
  }
}
resource containerRegistry 'Microsoft.ContainerRegistry/registries@2023-06-01-preview' = {
  name: acrName
  location: location
  sku: {
    name: 'Premium'
  }
  properties: {
    adminUserEnabled: false
    networkRuleBypassOptions: 'AzureServices'
    publicNetworkAccess: 'Disabled'
    
  }
}
var containerRegistryName = '${containerRegistry.name}.azurecr.io'
resource buildTask 'Microsoft.ContainerRegistry/registries/tasks@2019-06-01-preview' = {
  name: 'build-task'
  parent: containerRegistry
  location: location
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    credentials:{
      customRegistries: {
        '${containerRegistryName}': {
          identity: '[system]'
        }
      }
      sourceRegistry: {
        loginMode: 'Default'
      }
    }
    platform: {
      os: 'linux'
      architecture: 'amd64'
    }
    step: {
      type: 'Docker'
      imageNames: [
        'weatherapipush:latest'
      ]
      isPushEnabled: true
      noCache: false
      dockerFilePath: 'Dockerfile'
      arguments: []
      contextPath: GIT_REPO
      contextAccessToken: GIT_TOKEN
    }
    trigger: {
      sourceTriggers: [
        {
          sourceRepository: {
            sourceControlType: 'Github'
            repositoryUrl: GIT_REPO
            branch: 'master'
            sourceControlAuthProperties: {
              token: GIT_TOKEN
              tokenType: 'PAT'
            }
          }
          sourceTriggerEvents: [
            'commit'
            'pullrequest'
          ]
          status: 'Enabled'
          name: 'defaultSourceTriggerName'
        }
      ]
      baseImageTrigger: {
        baseImageTriggerType: 'Runtime'
        updateTriggerPayloadType: 'Default'
        status: 'Enabled'
        name: 'defaultBaseimageTriggerName'
      }
    }
    isSystemTask: false
  }
}


resource selfHostAgentInstance 'Microsoft.ContainerInstance/containerGroups@2023-05-01' = {
  name: 'self-host-agent'
  location: location
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    containers: [
      {
        name: 'self-host-agent'
        properties: {
          image: 'duongthaiha/dockeragent:latest'
          ports: [
            {
              protocol: 'TCP'
              port: 80
            }
          ]
          resources: {
            requests: {
              cpu: 1
              memoryInGB: 2
            }
          }
          environmentVariables: [
            {
              name: 'AZP_TOKEN'
              secureValue: AZP_TOKEN
            }
            {
              name: 'AZP_URL'
              value: AZP_URL
            }
            {
              name: 'AZP_AGENT_NAME'
              value: AZP_AGENT_NAME
            }
          ]
        }
      }
    ]
    osType: 'Linux'
    restartPolicy: 'Always'
    ipAddress: {
     type: 'Private'
      ports: [
        {
        port: 80
        protocol: 'TCP'
        }
      ]
    }
    subnetIds: [
     {
      id: virtualNetwork::aciSubnet.id
     }
    ]
  }
}

@description('This is the built-in Reader role. See https://docs.microsoft.com/azure/role-based-access-control/built-in-roles#contributor')
resource readerRoleDefinition 'Microsoft.Authorization/roleDefinitions@2022-05-01-preview' existing = {
  scope: subscription()
  name: 'acdd72a7-3385-48ef-bd42-f606fba81ae7'
} 
@description('This is the built-in ArcPush role')
resource arcPushRoleDefinition 'Microsoft.Authorization/roleDefinitions@2022-05-01-preview' existing = {
  scope: subscription()
  name: '8311e382-0749-4cb8-b61a-304f252e45ec'
} 

resource customTaskRoleDefinition 'Microsoft.Authorization/roleDefinitions@2022-05-01-preview' = {
  name: guid('acr-task-role')
  properties: {
    roleName: 'acr-task-role'
    description: 'Custom role for Self-hosted agent to write task'
      assignableScopes: [
        resourceGroup().id
      ]
    permissions:[
      {
        actions:[
          'Microsoft.ContainerRegistry/registries/tasks/write'
        ]
      }
    ]
  }
}
resource customAcrRoleDefinition 'Microsoft.Authorization/roleDefinitions@2022-05-01-preview' = {
  name: guid('acr-role')
  properties: {
    roleName: 'acr-role'
    description: 'Custom role for Self-hosted agent to run ACR Task'
      assignableScopes: [
        resourceGroup().id
      ]
    permissions:[
      {
        actions:[
          'Microsoft.ContainerRegistry/registries/tasks/listDetails/action'
          'Microsoft.ContainerRegistry/registries/read'
          'Microsoft.ContainerRegistry/registries/scheduleRun/action'  
          'Microsoft.ContainerRegistry/registries/runs/listLogSasUrl/action'      
        ]
      }
    ]
  }
}

resource acrTaskArcPushRoleAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(buildTask.id, arcPushRoleDefinition.id, resourceGroup().name)
  properties: {
    principalId: buildTask.identity.principalId
    roleDefinitionId: arcPushRoleDefinition.id
    principalType: 'ServicePrincipal'
  }
  scope:containerRegistry
}



resource assignmentReadRoleSelfHostIdentity 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(selfHostAgentInstance.id, readerRoleDefinition.id, resourceGroup().name)
  properties: {
    principalId: selfHostAgentInstance.identity.principalId
    roleDefinitionId: readerRoleDefinition.id
    principalType: 'ServicePrincipal'
  }
  scope:selfHostAgentInstance
}
resource registryAcrTaskRoleAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(selfHostAgentInstance.id, customAcrRoleDefinition.id, resourceGroup().name)
  properties: {
    principalId: selfHostAgentInstance.identity.principalId
    roleDefinitionId: customAcrRoleDefinition.id
    principalType: 'ServicePrincipal'
  }
  scope:containerRegistry
}

resource registryTaskRoleAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(selfHostAgentInstance.id, customTaskRoleDefinition.id, resourceGroup().name)
  properties: {
    principalId: selfHostAgentInstance.identity.principalId
    roleDefinitionId: customTaskRoleDefinition.id
    principalType: 'ServicePrincipal'
  }
  scope:buildTask
}

output selfHostAgentInstanceName string = selfHostAgentInstance.name
output acrName string = containerRegistry.name
 