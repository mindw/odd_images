# Bitnami Secure Image for OS Shell + Utility

> OS Shell + Utility is a general-purpose minimal image, well-suited for helper tasks such as running initialization in initContainers from Helm charts.

[Overview of OS Shell + Utility](https://bitnami.com)
Trademarks: This software listing is packaged by Bitnami. The respective trademarks
mentioned in the offering are owned by the respective companies, and use of them does
not imply any affiliation or endorsement.

## Engageli notes

### Updating to a new version:

1. Pull image changes from [upstream](https://github.com/bitnami/containers/tree/main/bitnami/os-shell)
2. Bump `current/debian-12/Dockerfile` to the new version
3. Open a pull request — the `os-shell` GitHub Actions workflow builds the image for `linux/amd64` and `linux/arm64` and runs a smoke test to confirm it still works. No image is pushed for pull requests.
4. Once the PR is merged to `main`, the same workflow builds, smoke-tests, and pushes the image to GHCR, tagged as `VERSION`, `vAPP_VERSION`, `vMAJOR.MINOR`, and `latest` in one step.

## TL;DR

```console
docker run -ti --rm --name os-shell ghcr.io/mindw/odd_images/os-shell:latest
```

## Get this image

The recommended way to get the os-shell Docker image is to pull the prebuilt image
from the Engageli GitHub Container Registry.

```console
docker pull ghcr.io/mindw/odd_images/os-shell:latest
```
To use a specific version, you can pull a versioned tag. You can view the list of
available versions on the [package page](https://github.com/mindw/odd_images/pkgs/container/odd_images%2Fos-shell).

```console
docker pull ghcr.io/mindw/odd_images/os-shell:[TAG]
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
docker run --rm --name os-shell ghcr.io/mindw/odd_images/os-shell:latest echo hello world
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
