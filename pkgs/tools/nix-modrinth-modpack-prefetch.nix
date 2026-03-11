{
  runtimeShell,
  writeShellScriptBin,
  curl,
  jq,
  gnused,
  nix,
}:
writeShellScriptBin "nix-modrinth-modpack-prefetch" ''
    set -euo pipefail

    if [ $# -lt 1 ]; then
      echo "Usage: nix-modrinth-modpack-prefetch <modrinth-version-id|modrinth-url|mrpack-url>" >&2
      exit 1
    fi

    input="$1"
    version_id=""
    project_slug=""
    mrpack_url=""

    extract_mrpack_url() {
      ${jq}/bin/jq -r '.files | (.[] | select(.primary == true)) // .[0] | .url // empty'
    }

    resolve_version_id() {
      local ref="$1"
      local response

      response=$(${curl}/bin/curl --no-progress-meter "https://api.modrinth.com/v2/version/$ref")

      if echo "$response" | ${jq}/bin/jq -e '.files | type == "array"' > /dev/null 2>&1; then
        mrpack_url=$(echo "$response" | extract_mrpack_url)
        if [ -n "$mrpack_url" ]; then
          return 0
        fi
      fi

      return 1
    }

    resolve_project_version_ref() {
      local slug="$1"
      local ref="$2"
      local versions
      local selected

      versions=$(${curl}/bin/curl --no-progress-meter "https://api.modrinth.com/v2/project/$slug/version")

      selected=$(echo "$versions" | ${jq}/bin/jq -rc --arg ref "$ref" '
        if type != "array" then
          empty
        else
          map(select(
            .id == $ref
            or .version_number == $ref
            or (.slug // "") == $ref
          ))
          | .[0] // empty
        end
      ')

      if [ -z "$selected" ]; then
        return 1
      fi

      mrpack_url=$(echo "$selected" | extract_mrpack_url)
      [ -n "$mrpack_url" ]
    }

    if [[ "$input" =~ ^https?:// ]]; then
      if [[ "$input" =~ \.mrpack([/?#].*)?$ ]]; then
        mrpack_url="$input"
      elif [[ "$input" == *"/version/"* ]] || [[ "$input" == *"/versions/"* ]]; then
        project_slug=$(echo "$input" | ${gnused}/bin/sed -n 's#.*modrinth.com/modpack/\([^/?#]\+\)/.*#\1#p')
        version_id=$(echo "$input" | ${gnused}/bin/sed -n 's#.*\(/version/\|/versions/\)\([^/?#]\+\).*#\2#p')
        if [ -z "$version_id" ]; then
          echo "Could not extract a Modrinth version reference from URL: $input" >&2
          exit 1
        fi
      else
        echo "Unsupported URL format. Provide a Modrinth version page URL, version id, or direct .mrpack URL." >&2
        exit 1
      fi
    else
      version_id="$input"
    fi

    if [ -n "$version_id" ]; then
      if ! resolve_version_id "$version_id"; then
        if [ -n "$project_slug" ] && resolve_project_version_ref "$project_slug" "$version_id"; then
          :
        else
          echo "Could not resolve Modrinth version reference: $version_id" >&2
          echo "If this is a version label (e.g. 1.3), pass a full modpack version URL." >&2
          exit 1
        fi
      fi

      if [ -z "$mrpack_url" ]; then
        echo "No downloadable file found for Modrinth version: $version_id" >&2
        exit 1
      fi

      if [[ ! "$mrpack_url" =~ \.mrpack([/?#].*)?$ ]]; then
        echo "Resolved file is not a .mrpack archive (url: $mrpack_url)." >&2
        echo "Make sure this version belongs to a Modrinth modpack." >&2
        exit 1
      fi
    fi

    prefetch=$(${nix}/bin/nix store prefetch-file --name modpack.mrpack --json "$mrpack_url")
    pack_hash=$(echo "$prefetch" | ${jq}/bin/jq -r '.hash')

    cat <<EOF
  fetchModrinthModpack {
    url = "$mrpack_url";
    packHash = "$pack_hash";
  }
  EOF
''
