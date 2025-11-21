#!/usr/bin/env bash

help() {
  cat <<EOF
Usage: $(basename "$0") [OPTIONS]

Options:
  -h, --help       Show this help message.
  --tag <version>  Set chart and app version to <version> (remove leading 'v' if present).

This script removes the "-prerelease" suffix from chart & dependencies versions in Chart.yaml,
or sets the version/appVersion to the supplied tag.
EOF
}

update_chart_yaml() {
  if [ -n "$TAG" ]; then
    # Remove leading 'v' from tag if present
    VERSION="${TAG#v}"
    # Set chart version & appVersion to VERSION
    yq_ibl ".version = \"$VERSION\" | .appVersion = \"$VERSION\"" "$CHART_YAML"
    yq_ibl "(.dependencies[] | select(.name == \"openebs-crds\") | .version) = \"$VERSION\"" "$CHART_YAML"
    yq_ibl ".version = \"$VERSION\"" "$CRD_CHART_YAML"
  else
    # Existing logic: remove '-prerelease' suffix
    yq_ibl '.version |= sub("-prerelease$"; "") | .appVersion |= sub("-prerelease$"; "")' "$CHART_YAML"
    yq_ibl '(.dependencies[] | select(.name == "openebs-crds") | .version) |= sub("-prerelease$"; "")' "$CHART_YAML"
    yq_ibl '.version |= sub("-prerelease$"; "")' "$CRD_CHART_YAML"
  fi

  # The rest of the existing dependencies updates
  yq_ibl '(.dependencies[] | select(.name == "localpv-provisioner") | .version) |= sub("-prerelease$"; "")' "$CHART_YAML"
  yq_ibl '(.dependencies[] | select(.name == "zfs-localpv") | .version) |= sub("-prerelease$"; "")' "$CHART_YAML"
  yq_ibl '(.dependencies[] | select(.name == "lvm-localpv") | .version) |= sub("-prerelease$"; "")' "$CHART_YAML"
  yq_ibl '(.dependencies[] | select(.name == "mayastor") | .version) |= sub("-prerelease$"; "")' "$CHART_YAML"
}

# Determine script and chart directory
SCRIPT_DIR="$(dirname "$(realpath "${BASH_SOURCE[0]:-"$0"}")")"
ROOT_DIR="$SCRIPT_DIR/../../"
CHART_DIR="$ROOT_DIR/charts"
CHART_YAML="$CHART_DIR/Chart.yaml"
CRD_CHART_NAME="openebs-crds"
CRD_CHART_YAML="$CHART_DIR/charts/$CRD_CHART_NAME/Chart.yaml"

# Import
source "$ROOT_DIR/mayastor/scripts/utils/yaml.sh"
source "$ROOT_DIR/mayastor/scripts/utils/log.sh"

TAG=""

# Parse arguments
while [ "$#" -gt 0 ]; do
  case $1 in
    -h|--help)
      help
      exit 0
      ;;
    --tag)
      shift
      TAG="$1"
      ;;
    *)
      help
      die "Unknown option: $1"
      ;;
  esac
  shift
done

update_chart_yaml
