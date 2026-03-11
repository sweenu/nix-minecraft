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
    mrpack_url=""

    if [[ "$input" =~ ^https?:// ]]; then
      if [[ "$input" =~ \.mrpack([/?#].*)?$ ]]; then
        mrpack_url="$input"
      elif [[ "$input" == *"/version/"* ]] || [[ "$input" == *"/versions/"* ]]; then
        version_id=$(echo "$input" | ${gnused}/bin/sed -n 's#.*\(/version/\|/versions/\)\([^/?#]\+\).*#\2#p')
        if [ -z "$version_id" ]; then
          echo "Could not extract a Modrinth version id from URL: $input" >&2
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
      response=$(${curl}/bin/curl --no-progress-meter "https://api.modrinth.com/v2/version/$version_id")

      if [ -z "$response" ] || [ "$response" = "null" ]; then
        echo "Invalid Modrinth version id: $version_id" >&2
        exit 1
      fi

      mrpack_url=$(echo "$response" | ${jq}/bin/jq -r '.files | (.[] | select(.primary == true)) // .[0] | .url // empty')

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

    prefetch=$(${nix}/bin/nix store prefetch-file --json "$mrpack_url")
    pack_hash=$(echo "$prefetch" | ${jq}/bin/jq -r '.hash')

    cat <<EOF
  fetchModrinthModpack {
    url = "$mrpack_url";
    packHash = "$pack_hash";
  }
  EOF
''
