# Bitnami Secure Image for OS Shell + Utility

## What is OS Shell + Utility?

> OS Shell + Utility is a general-purpose minimal image, well-suited for helper tasks such as running initialization in initContainers from Helm charts.

[Overview of OS Shell + Utility](https://bitnami.com)
Trademarks: This software listing is packaged by Bitnami. The respective trademarks
mentioned in the offering are owned by the respective companies, and use of them does
not imply any affiliation or endorsement.

## Engageli notes

### Updating to a new version:

1. Pull image changes from [upstream](https://github.com/bitnami/containers/tree/main/bitnami/os-shell)
2. backup image source files:  `AWS_PROFILE=shared_assets ./copy-image-sources-s3.sh`
3. Build and push using `AWS_PROFILE=shared_assets ./os-shell-12-build-and-push.sh`
4. Deploy on a dev cluster
5. Once merged, promote tag as `latest` and VERSION latest :
   ```
   . 12/debian-12/version.sh
   # add "latest"
   AWS_PROFILE=shared_assets ../add-tag-to-engageli-private-ecr-image.sh bitnami/os-shell ${OS_SHELL_VERSION}
   # add VERSION latest
   AWS_PROFILE=shared_assets ../add-tag-to-engageli-private-ecr-image.sh bitnami/os-shell ${OS_SHELL_VERSION} v${OS_SHELL_APP_VERSION} 
   ```
6. Once merged, propagate image to `test` and `prod` repos using `aws/misc/ecr.py`: 
   ``` 
   . 12/debian-12/version.sh 
   AWS_PROFILE=shared_assets ../../aws/misc/ecr.py ${OS_SHELL_VERSION} --ci -s dev -d test -r bitnami/os-shell
   # and to production once the PR is merged
   AWS_PROFILE=shared_assets ../../aws/misc/ecr.py ${OS_SHELL_VERSION} --ci -r bitnami/os-shell
   ```

## TL;DR

```console
docker run -ti --rm --name os-shell 569129334545.dkr.ecr.us-east-1.amazonaws.com/bitnami/os-shell-dev:latest
```

## Get this image

The recommended way to get the Bitnami os-shell Docker Image is to pull the prebuilt image
from the Engageli private ECR repository.

```console
docker pull 569129334545.dkr.ecr.us-east-1.amazonaws.com/bitnami/os-shell-dev:latest
```

To use a specific version, you can pull a versioned tag. You can view the list of 
available versions using `skopeo`:
```
skopeo list-tags docker://569129334545.dkr.ecr.us-east-1.amazonaws.com/bitnami/os-shell-dev | jq .Tags[] -r
```

```console
docker pull 569129334545.dkr.ecr.us-east-1.amazonaws.com/bitnami/os-shell:[TAG]
```

If you wish, you can also build the image yourself by cloning the repository, changing to the directory containing the Dockerfile and executing the `docker build` command. Remember to replace the `APP`, `VERSION` and `OPERATING-SYSTEM` path placeholders in the example command below with the correct values.

```console
git clone https://github.com/bitnami/containers.git
cd bitnami/APP/VERSION/OPERATING-SYSTEM
docker build -t bitnami/APP:latest .
```

## Configuration

### Running commands

To run commands inside this container you can use `docker run`, for example to execute `echo Hello world` you can follow the example below:

```console
docker run --rm --name os-shell 569129334545.dkr.ecr.us-east-1.amazonaws.com/bitnami/os-shell:latest echo hello world
```

### FIPS configuration in Bitnami Secure Images

The Bitnami OS Shell + Utility Docker image from the [Bitnami Secure Images](https://go-vmware.broadcom.com/contact-us) catalog includes extra features and settings to configure the container with FIPS capabilities. You can configure the next environment variables:

- `OPENSSL_FIPS`: whether OpenSSL runs in FIPS mode or not. `yes` (default), `no`.

## Notable Changes

### Starting January 16, 2024

- The `docker-compose.yaml` file has been removed, as it was solely intended for internal testing purposes.

## Contributing

We'd love for you to contribute to this container. You can request new features by creating an [issue](https://github.com/bitnami/containers/issues) or submitting a [pull request](https://github.com/bitnami/containers/pulls) with your contribution.

## Issues

If you encountered a problem running this container, you can file an [issue](https://github.com/bitnami/containers/issues/new/choose). For us to provide better support, be sure to fill the issue template.

## License

Copyright &copy; 2026 Broadcom. The term "Broadcom" refers to Broadcom Inc. and/or its subsidiaries.

Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at

<http://www.apache.org/licenses/LICENSE-2.0>

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and
limitations under the License.
