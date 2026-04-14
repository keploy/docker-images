# keploy-ci-azurecli: Azure CLI + tar + gzip
# Used by: release pipelines for artifact upload to Azure Blob Storage
FROM mcr.microsoft.com/azure-cli:latest

RUN tdnf install -y tar gzip && tdnf clean all
