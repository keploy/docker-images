# keploy-ci-awscli: AWS CLI v2 + tar + gzip
# Used by: fuzzer-linux.yml, static-dedup-fuzzer-linux.yml
FROM public.ecr.aws/aws-cli/aws-cli:latest

RUN yum install -y tar gzip && yum clean all
