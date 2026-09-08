#!/bin/sh
set -e

DEPS_FILE="videojs-dependencies.yml"
DEST_DIR="assets/videojs"

mkdir -p "$DEST_DIR"

current_dep=""
current_version=""
current_shasum=""

parse_deps() {
    while IFS= read -r line; do
        case "$line" in
            [a-z]*:) 
                # Skip non-dependency keys
                case "$line" in
                    version:*|shasum:*) ;;
                    *) current_dep=$(echo "$line" | sed 's/:$//' | xargs) ;;
                esac
                ;;
            *version:*)
                current_version=$(echo "$line" | sed 's/.*version:\s*//' | xargs)
                ;;
            *shasum:*)
                current_shasum=$(echo "$line" | sed 's/.*shasum:\s*//' | xargs)
                if [ -n "$current_dep" ] && [ -n "$current_version" ]; then
                    echo "${current_dep}|${current_version}|${current_shasum}"
                fi
                current_dep=""
                current_version=""
                current_shasum=""
                ;;
        esac
    done < "$DEPS_FILE"
}

parse_deps | while IFS='|' read -r dep version shasum; do
    dest_path="$DEST_DIR/$dep"
    tmp_dir="/tmp/invidious-videojs-dep-$dep"

    # Check if already installed
    if [ -f "$dest_path/versions.yml" ]; then
        installed_version=$(grep 'version' "$dest_path/versions.yml" | head -1 | sed 's/.*"\(.*\)"/\1/')
        if [ "$installed_version" = "$version" ]; then
            echo "OK $dep $version (cached)"
            continue
        fi
    fi

    echo "Fetching $dep $version..."

    mkdir -p "$tmp_dir" "$dest_path"

    # Download from npm
    curl -sL "https://registry.npmjs.org/$dep/-/$dep-$version.tgz" -o "$tmp_dir/package.tgz"

    # Verify checksum
    actual_shasum=$(openssl dgst -sha1 "$tmp_dir/package.tgz" | sed 's/.*= //')
    if [ "$actual_shasum" != "$shasum" ]; then
        echo "ERROR: Checksum mismatch for $dep: expected $shasum, got $actual_shasum"
        exit 1
    fi

    # Extract
    tar -xzf "$tmp_dir/package.tgz" -C "$tmp_dir"

    pkg_dir="$tmp_dir/package"

    # video.js has a different structure
    dep_name="$dep"
    if [ "$dep" = "video.js" ]; then
        dep_name="video"
    fi

    # Some packages have js/ subfolder
    js_subdir=""
    case "$dep" in
        silvermine-videojs-quality-selector|videojs-contrib-quality-menu)
            js_subdir="js/"
            ;;
    esac

    # Move JS
    if [ -f "$pkg_dir/dist/${js_subdir}${dep_name}.min.js" ]; then
        cp "$pkg_dir/dist/${js_subdir}${dep_name}.min.js" "$dest_path/${dep_name}.js"
    elif [ -f "$pkg_dir/dist/${js_subdir}${dep_name}.js" ]; then
        cp "$pkg_dir/dist/${js_subdir}${dep_name}.js" "$dest_path/${dep_name}.js"
    fi

    # Move CSS
    css_dep="$dep_name"
    if [ "$dep_name" = "video" ]; then
        css_dep="video-js"
    fi
    if [ "$dep_name" = "videojs-markers" ]; then
        css_dep="videojs.markers"
    fi

    if [ -f "$pkg_dir/dist/${css_dep}.min.css" ]; then
        cp "$pkg_dir/dist/${css_dep}.min.css" "$dest_path/${css_dep}.css"
    elif [ -f "$pkg_dir/dist/${css_dep}.css" ]; then
        cp "$pkg_dir/dist/${css_dep}.css" "$dest_path/${css_dep}.css"
    fi

    # Special case: silvermine CSS
    if [ "$dep" = "silvermine-videojs-quality-selector" ] && [ -f "$pkg_dir/dist/css/quality-selector.css" ]; then
        cp "$pkg_dir/dist/css/quality-selector.css" "$dest_path/quality-selector.css"
    fi

    # Write versions file
    cat > "$dest_path/versions.yml" <<EOF
version: "$version"
minified: false
EOF

    echo "OK $dep $version"

    rm -rf "$tmp_dir"
done

echo "Done."
