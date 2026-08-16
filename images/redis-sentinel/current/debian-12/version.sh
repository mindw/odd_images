script_dir=$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )
docker_file=$(realpath "${script_dir}/Dockerfile")

export $("${script_dir}/../../../extract-version-bitnami-images.sh" "${docker_file}" REDIS_SENTINEL | xargs)
unset script_dir
unset docker_file
