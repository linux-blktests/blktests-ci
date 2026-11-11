#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
#
# Copyright (c) 2026 Western Digital Corporation or its affiliates.
#
# Authors: Dennis Maisenbacher (dennis.maisenbacher@wdc.com)

_registry_error() {
  printf 'registry: %s\n' "$*" >&2
  return 1
}

_registry_sha256() {
  local digest
  digest=$(sha256sum "$1") || return 1
  printf 'sha256:%s\n' "${digest%% *}"
}

_registry_resolve_location() {
  if [[ $# -ne 2 ]]; then
    _registry_error "usage: _registry_resolve_location <upload_start_url> <location>"
    return 1
  fi

  local start_url=$1 location=$2 scheme remainder authority origin start_path
  local relative_path suffix base_dir combined segment resolved_path
  local -a path_parts normalized_parts
  [[ -n $start_url && -n $location ]] || {
    _registry_error "upload start URL and location are required"
    return 1
  }
  case "$start_url" in
    http://*) scheme=http; remainder=${start_url#http://} ;;
    https://*) scheme=https; remainder=${start_url#https://} ;;
    *)
      _registry_error "upload start URL must use http or https"
      return 1
      ;;
  esac
  authority=${remainder%%/*}
  [[ -n $authority ]] || {
    _registry_error "upload start URL has no host"
    return 1
  }
  origin="${scheme}://${authority}"

  case "$location" in
    http://*|https://*)
      printf '%s\n' "$location"
      return 0
      ;;
    //*)
      printf '%s:%s\n' "$scheme" "$location"
      return 0
      ;;
    /*)
      printf '%s%s\n' "$origin" "$location"
      return 0
      ;;
  esac

  if [[ $remainder == "$authority" ]]; then
    start_path=/
  else
    start_path="/${remainder#*/}"
  fi
  start_path=${start_path%%\?*}
  start_path=${start_path%%#*}
  base_dir="${start_path%/*}/"
  if [[ $location == *\?* ]]; then
    relative_path=${location%%\?*}
    suffix="?${location#*\?}"
  elif [[ $location == *#* ]]; then
    relative_path=${location%%#*}
    suffix="#${location#*#}"
  else
    relative_path=$location
    suffix=''
  fi
  combined="${base_dir}${relative_path}"
  IFS=/ read -r -a path_parts <<< "$combined" || {
    _registry_error "could not parse upload Location"
    return 1
  }
  normalized_parts=()
  for segment in "${path_parts[@]}"; do
    case "$segment" in
      ''|.) ;;
      ..)
        if (( ${#normalized_parts[@]} > 0 )); then
          local last_index
          last_index=$((${#normalized_parts[@]} - 1))
          unset "normalized_parts[${last_index}]" || {
            _registry_error "could not normalize upload Location"
            return 1
          }
        fi
        ;;
      *) normalized_parts+=("$segment") ;;
    esac
  done
  resolved_path=''
  for segment in "${normalized_parts[@]}"; do
    resolved_path+="/${segment}"
  done
  [[ -n $resolved_path ]] || resolved_path=/
  if [[ $combined == */ && $resolved_path != */ ]]; then
    resolved_path+='/'
  fi
  printf '%s%s%s\n' "$origin" "$resolved_path" "$suffix"
}

_registry_arch() {
  local machine
  if [[ -n ${REGISTRY_ARCH:-} ]]; then
    printf '%s\n' "$REGISTRY_ARCH"
    return 0
  fi
  machine=$(uname -m) || {
    _registry_error "could not determine the machine architecture"
    return 1
  }
  case "$machine" in
    x86_64) printf 'amd64\n' ;;
    aarch64) printf 'arm64\n' ;;
    ppc64le) printf 'ppc64le\n' ;;
    *) printf '%s\n' "$machine" ;;
  esac
}

_registry_upload_blob() {
  if [[ $# -ne 5 ]]; then
    _registry_error "invalid arguments to blob upload"
    return 1
  fi

  local registry_url=$1 repository=$2 digest=$3 blob=$4 headers status location upload_url
  local upload_start_url
  headers=$5

  if ! status=$(curl -sS -I -o /dev/null -w '%{http_code}' \
    "${registry_url}/v2/${repository}/blobs/${digest}"); then
    _registry_error "could not check blob ${digest}"
    return 1
  fi
  [[ $status == 200 ]] && return 0

  if ! status=$(curl -sS -D "$headers" -o /dev/null -w '%{http_code}' \
    -X POST "${registry_url}/v2/${repository}/blobs/uploads/"); then
    _registry_error "could not start upload for blob ${digest}"
    return 1
  fi
  [[ $status == 202 ]] || {
    _registry_error "starting upload for blob ${digest} returned HTTP ${status}"
    return 1
  }
  location=$(awk 'tolower($1) == "location:" { sub(/\r$/, "", $2); value=$2 } END { if (value) print value }' "$headers") || {
    _registry_error "could not read upload Location for blob ${digest}"
    return 1
  }
  [[ -n $location ]] || {
    _registry_error "registry did not return an upload Location for blob ${digest}"
    return 1
  }
  upload_start_url="${registry_url}/v2/${repository}/blobs/uploads/"
  upload_url=$(_registry_resolve_location "$upload_start_url" "$location") || {
    _registry_error "could not resolve upload Location for blob ${digest}"
    return 1
  }
  if [[ $upload_url == *\?* ]]; then
    upload_url="${upload_url}&digest=${digest}"
  else
    upload_url="${upload_url}?digest=${digest}"
  fi

  if ! status=$(curl -sS -T "$blob" -H 'Content-Type: application/octet-stream' \
    -o /dev/null -w '%{http_code}' "$upload_url"); then
    _registry_error "uploading blob ${digest} failed"
    return 1
  fi
  [[ $status == 201 ]] || {
    _registry_error "uploading blob ${digest} returned HTTP ${status}"
    return 1
  }
}

registry_push_boot_image() {
  if [[ $# -ne 4 ]]; then
    _registry_error "usage: registry_push_boot_image <registry_url> <repository> <tag> <src_dir>"
    return 1
  fi

  local registry_url=${1%/} repository=$2 tag=$3 src_dir=$4 work result
  local source_file file_count diff_id layer_digest layer_size config_digest config_size
  local created architecture manifest_digest status reported_digest
  local -a source_files
  [[ -n $registry_url && -n $repository && -n $tag && -d $src_dir ]] || {
    _registry_error "registry URL, repository, tag, and source directory are required"
    return 1
  }
  [[ $tag != */* ]] || {
    _registry_error "invalid image tag: ${tag}"
    return 1
  }

  work=$(mktemp -d) || {
    _registry_error "could not create a temporary directory"
    return 1
  }
  if result=$(
    trap 'rm -rf -- "$work" || true' EXIT
    file_count=0
    mkdir -m 0755 "$work/boot" || {
      _registry_error "could not create boot layer directory"
      exit 1
    }
    shopt -s nullglob dotglob
    source_files=("$src_dir"/*) || {
      _registry_error "could not list boot source files"
      exit 1
    }
    for source_file in "${source_files[@]}"; do
      [[ -f $source_file ]] || continue
      cp -p -- "$source_file" "$work/boot/" || {
        _registry_error "could not copy boot file ${source_file}"
        exit 1
      }
      file_count=$((file_count + 1))
    done
    if (( file_count == 0 )); then
      _registry_error "source directory contains no regular files"
      exit 1
    fi

    tar --format=gnu --owner=107 --group=107 --numeric-owner \
      -cf "$work/layer.tar" -C "$work" boot || {
      _registry_error "could not create boot layer tar"
      exit 1
    }
    diff_id=$(_registry_sha256 "$work/layer.tar") || {
      _registry_error "could not hash boot layer tar"
      exit 1
    }
    gzip -n -c "$work/layer.tar" > "$work/layer.tar.gz" || {
      _registry_error "could not gzip boot layer"
      exit 1
    }
    layer_digest=$(_registry_sha256 "$work/layer.tar.gz") || {
      _registry_error "could not hash compressed boot layer"
      exit 1
    }
    layer_size=$(stat -c '%s' "$work/layer.tar.gz") || {
      _registry_error "could not read compressed boot layer size"
      exit 1
    }

    created=$(date -u +%Y-%m-%dT%H:%M:%SZ) || {
      _registry_error "could not read the current UTC time"
      exit 1
    }
    architecture=$(_registry_arch) || exit 1
    jq -cn --arg created "$created" --arg diff_id "$diff_id" \
      --arg architecture "$architecture" \
      '{architecture:$architecture,os:"linux",created:$created,config:{},rootfs:{type:"layers",diff_ids:[$diff_id]},history:[{created:$created,created_by:"blktests-ci kernel-build-job"}]}' \
      > "$work/config.json" || {
      _registry_error "could not create image config"
      exit 1
    }
    config_digest=$(_registry_sha256 "$work/config.json") || {
      _registry_error "could not hash image config"
      exit 1
    }
    config_size=$(stat -c '%s' "$work/config.json") || {
      _registry_error "could not read image config size"
      exit 1
    }

    jq -cn --arg config_digest "$config_digest" --argjson config_size "$config_size" \
      --arg layer_digest "$layer_digest" --argjson layer_size "$layer_size" \
      '{schemaVersion:2,mediaType:"application/vnd.docker.distribution.manifest.v2+json",config:{mediaType:"application/vnd.docker.container.image.v1+json",size:$config_size,digest:$config_digest},layers:[{mediaType:"application/vnd.docker.image.rootfs.diff.tar.gzip",size:$layer_size,digest:$layer_digest}]}' \
      > "$work/manifest.json" || {
      _registry_error "could not create image manifest"
      exit 1
    }
    manifest_digest=$(_registry_sha256 "$work/manifest.json") || {
      _registry_error "could not hash image manifest"
      exit 1
    }

    _registry_upload_blob "$registry_url" "$repository" "$config_digest" \
      "$work/config.json" "$work/headers" || exit 1
    _registry_upload_blob "$registry_url" "$repository" "$layer_digest" \
      "$work/layer.tar.gz" "$work/headers" || exit 1

    status=$(curl -sS -X PUT \
      -H 'Content-Type: application/vnd.docker.distribution.manifest.v2+json' \
      -D "$work/manifest-headers" -o /dev/null -w '%{http_code}' \
      --data-binary "@$work/manifest.json" \
      "${registry_url}/v2/${repository}/manifests/${tag}") || {
      _registry_error "publishing manifest ${repository}:${tag} failed"
      exit 1
    }
    [[ $status == 201 ]] || {
      _registry_error "publishing manifest ${repository}:${tag} returned HTTP ${status}"
      exit 1
    }
    reported_digest=$(awk 'tolower($1) == "docker-content-digest:" { sub(/\r$/, "", $2); value=$2 } END { if (value) print value }' "$work/manifest-headers") || {
      _registry_error "could not read the published manifest digest"
      exit 1
    }
    [[ $reported_digest == "$manifest_digest" ]] || {
      _registry_error "registry manifest digest mismatch: expected ${manifest_digest}, got ${reported_digest:-missing}"
      exit 1
    }
    printf '%s\n' "$manifest_digest"
  ); then
    printf '%s\n' "$result"
  else
    return 1
  fi
}

_registry_bearer_token() {
  local challenge=$1 repository=$2 realm service token_response token
  if ! realm=$(sed -nE 's/.*realm="([^"]+)".*/\1/p' <<< "$challenge"); then
    _registry_error "could not parse registry authentication realm"
    return 1
  fi
  if ! service=$(sed -nE 's/.*service="([^"]+)".*/\1/p' <<< "$challenge"); then
    _registry_error "could not parse registry authentication service"
    return 1
  fi
  [[ -n $realm ]] || {
    _registry_error "registry returned an unsupported authentication challenge"
    return 1
  }
  token_response=$(mktemp) || {
    _registry_error "could not create a temporary token file"
    return 1
  }
  if [[ -n $service ]]; then
    curl -fsS -G --data-urlencode "service=${service}" \
      --data-urlencode "scope=repository:${repository}:pull" \
      -o "$token_response" "$realm" || {
      rm -f "$token_response" || true
      _registry_error "could not fetch an anonymous pull token"
      return 1
    }
  else
    curl -fsS -G --data-urlencode "scope=repository:${repository}:pull" \
      -o "$token_response" "$realm" || {
      rm -f "$token_response" || true
      _registry_error "could not fetch an anonymous pull token"
      return 1
    }
  fi
  if ! token=$(jq -r '.token // .access_token // empty' "$token_response"); then
    rm -f "$token_response" || true
    _registry_error "could not parse anonymous pull token response"
    return 1
  fi
  if ! rm -f "$token_response"; then
    _registry_error "could not remove temporary token file"
    return 1
  fi
  [[ -n $token ]] || {
    _registry_error "anonymous pull token response did not contain a token"
    return 1
  }
  printf '%s\n' "$token"
}

_registry_fetch_manifest() {
  local url=$1 headers=$2 body=$3 token status
  token=${4:-}
  if [[ -n $token ]]; then
    if ! status=$(curl -sS -H "Accept: ${_REGISTRY_ACCEPT}" \
      -H "Authorization: Bearer ${token}" \
      -D "$headers" -o "$body" -w '%{http_code}' "$url"); then
      _registry_error "could not fetch manifest ${url}"
      return 1
    fi
  else
    if ! status=$(curl -sS -H "Accept: ${_REGISTRY_ACCEPT}" -D "$headers" \
      -o "$body" -w '%{http_code}' "$url"); then
      _registry_error "could not fetch manifest ${url}"
      return 1
    fi
  fi
  printf '%s\n' "$status"
}

# Download a blob into a file and print the final HTTP status. On a slow link
# ghcr.io resets the HTTP/2 stream of a large layer part-way. Each new curl call
# resumes from the current file size with -C -, while curl's own --retry would
# restart from byte 0. HTTP errors are final (the caller handles 401), and so is
# a server that cannot resume (exit 33). A 416 means the file was already
# complete, which the digest check in the caller confirms.
_registry_download_blob() {
  local url=$1 file=$2 headers=$3 token=${4:-} attempt status rc
  local -a auth=()
  [[ -z $token ]] || auth=(-H "Authorization: Bearer ${token}")
  for attempt in 1 2 3 4 5 6; do
    rc=0
    status=$(curl -fsSL -C - "${auth[@]}" -D "$headers" -o "$file" -w '%{http_code}' "$url") || rc=$?
    if (( rc == 22 )) && [[ $status == 416 ]]; then
      rc=0
    fi
    (( rc == 0 || rc == 22 || rc == 33 )) && break
    (( attempt < 6 )) && sleep 5
  done
  printf '%s\n' "$status"
  return "$rc"
}

_registry_extract_impl() (
  local registry_url=${1%/} repository=$2 reference=$3 dest_dir=$4 member_prefix=${5:-}
  local work token status challenge actual_digest index_digest architecture manifest_kind
  token=''
  local layers layer_type layer_digest layer_file layer_url rc

  [[ -n $registry_url && -n $repository && -n $reference && -n $dest_dir ]] || {
    _registry_error "registry URL, repository, reference, and destination are required"
    exit 1
  }
  if [[ -n $member_prefix && ! $member_prefix =~ ^[A-Za-z0-9._/-]+$ ]] ||
     [[ $member_prefix == *..* ]]; then
    _registry_error "invalid member prefix: ${member_prefix}"
    exit 1
  fi
  work=$(mktemp -d) || {
    _registry_error "could not create a temporary directory"
    exit 1
  }
  trap 'rm -rf -- "$work" || true' EXIT
  mkdir -p "$dest_dir" || {
    _registry_error "could not create destination directory ${dest_dir}"
    exit 1
  }

  _REGISTRY_ACCEPT='application/vnd.oci.image.index.v1+json, application/vnd.docker.distribution.manifest.list.v2+json, application/vnd.oci.image.manifest.v1+json, application/vnd.docker.distribution.manifest.v2+json'
  status=$(_registry_fetch_manifest \
    "${registry_url}/v2/${repository}/manifests/${reference}" \
    "$work/headers" "$work/manifest.json") || exit 1
  if [[ $status == 401 ]]; then
    challenge=$(awk 'tolower($1) == "www-authenticate:" { sub(/^[^:]+:[[:space:]]*/, ""); sub(/\r$/, ""); value=$0 } END { if (value) print value }' "$work/headers") || {
      _registry_error "could not read registry authentication challenge"
      exit 1
    }
    token=$(_registry_bearer_token "$challenge" "$repository") || exit 1
    status=$(_registry_fetch_manifest \
      "${registry_url}/v2/${repository}/manifests/${reference}" \
      "$work/headers" "$work/manifest.json" "$token") || exit 1
  fi
  [[ $status == 200 ]] || {
    _registry_error "fetching manifest ${repository}:${reference} returned HTTP ${status}"
    exit 1
  }
  jq -e 'type == "object"' "$work/manifest.json" >/dev/null || {
    _registry_error "registry returned invalid manifest JSON"
    exit 1
  }

  if [[ $reference =~ ^sha256:[0-9a-f]{64}$ ]]; then
    actual_digest=$(_registry_sha256 "$work/manifest.json") || {
      _registry_error "could not calculate manifest digest"
      exit 1
    }
    [[ $actual_digest == "$reference" ]] || {
      _registry_error "manifest digest mismatch: expected ${reference}, got ${actual_digest}"
      exit 1
    }
  fi

  manifest_kind=$(jq -r 'if (.manifests | type) == "array" then "index" elif (.manifests == null) then "manifest" else "invalid" end' "$work/manifest.json") || {
    _registry_error "could not read manifest type"
    exit 1
  }
  [[ $manifest_kind != invalid ]] || {
    _registry_error "manifest has an invalid manifests field"
    exit 1
  }
  if [[ $manifest_kind == index ]]; then
    architecture=$(_registry_arch) || exit 1
    index_digest=$(jq -r --arg architecture "$architecture" \
      '[.manifests[] | select(.platform.os == "linux" and .platform.architecture == $architecture and .platform.architecture != "unknown" and ((.annotations // {})["vnd.docker.reference.type"] // "") == "")][0].digest // empty' \
      "$work/manifest.json") || {
      _registry_error "could not select an image from manifest index"
      exit 1
    }
    [[ -n $index_digest ]] || {
      _registry_error "manifest index has no linux/${architecture} image"
      exit 1
    }
    status=$(_registry_fetch_manifest \
      "${registry_url}/v2/${repository}/manifests/${index_digest}" \
      "$work/headers" "$work/manifest.json" "$token") || exit 1
    if [[ $status == 401 ]]; then
      challenge=$(awk 'tolower($1) == "www-authenticate:" { sub(/^[^:]+:[[:space:]]*/, ""); sub(/\r$/, ""); value=$0 } END { if (value) print value }' "$work/headers") || {
        _registry_error "could not read registry authentication challenge"
        exit 1
      }
      if [[ -z $token ]]; then
        token=$(_registry_bearer_token "$challenge" "$repository") || exit 1
      fi
      status=$(_registry_fetch_manifest \
        "${registry_url}/v2/${repository}/manifests/${index_digest}" \
        "$work/headers" "$work/manifest.json" "$token") || exit 1
    fi
    [[ $status == 200 ]] || {
      _registry_error "fetching linux/${architecture} manifest returned HTTP ${status}"
      exit 1
    }
    actual_digest=$(_registry_sha256 "$work/manifest.json") || {
      _registry_error "could not calculate manifest digest"
      exit 1
    }
    [[ $actual_digest == "$index_digest" ]] || {
      _registry_error "index child digest mismatch: expected ${index_digest}, got ${actual_digest}"
      exit 1
    }
  fi

  layers=$(jq -r '.layers[]? | [.mediaType, .digest] | @tsv' "$work/manifest.json") || {
    _registry_error "could not read manifest layers"
    exit 1
  }
  [[ -n $layers ]] || {
    _registry_error "manifest contains no image layers"
    exit 1
  }
  # This extractor targets single-layer images and does not process whiteouts.
  while IFS=$'\t' read -r layer_type layer_digest; do
    [[ $layer_digest =~ ^sha256:[0-9a-f]{64}$ ]] || {
      _registry_error "invalid layer digest: ${layer_digest}"
      exit 1
    }
    layer_file="$work/${layer_digest#sha256:}"
    layer_url="${registry_url}/v2/${repository}/blobs/${layer_digest}"
    rc=0
    status=$(_registry_download_blob "$layer_url" "$layer_file" "$work/blob-headers" "$token") || rc=$?
    if [[ $status == 401 && -z $token ]]; then
      challenge=$(awk 'tolower($1) == "www-authenticate:" { sub(/^[^:]+:[[:space:]]*/, ""); sub(/\r$/, ""); value=$0 } END { if (value) print value }' "$work/blob-headers") || {
        _registry_error "could not read registry authentication challenge"
        exit 1
      }
      token=$(_registry_bearer_token "$challenge" "$repository") || exit 1
      rc=0
      status=$(_registry_download_blob "$layer_url" "$layer_file" "$work/blob-headers" "$token") || rc=$?
    fi
    [[ $rc -eq 0 && ( $status == 200 || $status == 206 || $status == 416 ) ]] || {
      _registry_error "downloading layer ${layer_digest} failed: HTTP ${status:-000}, curl exit ${rc}"
      exit 1
    }
    actual_digest=$(_registry_sha256 "$layer_file") || {
      _registry_error "could not calculate layer digest"
      exit 1
    }
    [[ $actual_digest == "$layer_digest" ]] || {
      _registry_error "layer digest mismatch: expected ${layer_digest}, got ${actual_digest}"
      exit 1
    }
    case "$layer_type" in
      application/vnd.docker.image.rootfs.diff.tar.gzip|application/vnd.oci.image.layer.v1.tar+gzip)
        if [[ -n $member_prefix ]]; then
          tar -xzf "$layer_file" -C "$dest_dir" -- "$member_prefix" || {
            _registry_error "extracting layer member ${member_prefix} failed"
            exit 1
          }
        else
          tar -xzf "$layer_file" -C "$dest_dir" || {
            _registry_error "extracting image layer failed"
            exit 1
          }
        fi
        ;;
      application/vnd.docker.image.rootfs.diff.tar|application/vnd.oci.image.layer.v1.tar)
        if [[ -n $member_prefix ]]; then
          tar -xf "$layer_file" -C "$dest_dir" -- "$member_prefix" || {
            _registry_error "extracting layer member ${member_prefix} failed"
            exit 1
          }
        else
          tar -xf "$layer_file" -C "$dest_dir" || {
            _registry_error "extracting image layer failed"
            exit 1
          }
        fi
        ;;
      *)
        _registry_error "unsupported image layer media type: ${layer_type}"
        exit 1
        ;;
    esac
  done <<< "$layers"
)

registry_extract() {
  if [[ $# -lt 4 || $# -gt 5 ]]; then
    _registry_error "usage: registry_extract <registry_url> <repository> <reference> <dest_dir> [<member_prefix>]"
    return 1
  fi
  _registry_extract_impl "$@"
}

registry_parse_ref() {
  if [[ $# -ne 1 ]]; then
    _registry_error "usage: registry_parse_ref <host/org/name:tag|host/name@sha256:digest>"
    return 1
  fi

  local image_ref=$1 image_path host repository reference last_component
  [[ -n $image_ref ]] || {
    _registry_error "image reference must not be empty"
    return 1
  }
  [[ $image_ref != *://* ]] || {
    _registry_error "image reference must not include a URL scheme"
    return 1
  }
  if [[ $image_ref == *@* ]]; then
    image_path=${image_ref%@*}
    reference=${image_ref##*@}
    [[ $reference =~ ^sha256:[0-9a-f]{64}$ ]] || {
      _registry_error "invalid image digest: ${reference}"
      return 1
    }
  else
    last_component=${image_ref##*/}
    if [[ $last_component == *:* ]]; then
      reference=${last_component##*:}
      image_path=${image_ref%:*}
      [[ -n $reference ]] || {
        _registry_error "image tag must not be empty"
        return 1
      }
    else
      reference=latest
      image_path=$image_ref
    fi
  fi
  [[ $image_path == */* ]] || {
    _registry_error "image reference must include an explicit registry host"
    return 1
  }
  host=${image_path%%/*}
  repository=${image_path#*/}
  [[ -n $host && -n $repository ]] || {
    _registry_error "image reference must include a registry host and repository"
    return 1
  }
  [[ $host == *.* || $host == *:* || $host == localhost ]] || {
    _registry_error "image reference must include an explicit registry host"
    return 1
  }
  printf 'https://%s %s %s\n' "$host" "$repository" "$reference"
}
