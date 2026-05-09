#!/bin/bash

# ============================================================
# movie_processor.sh — Rename, Extract, Move, and Tidy Movies
# ============================================================
# Supports: .mkv, .mp4 (direct), and .rar / .r00 archives
# ============================================================

# --- Configuration ---
DEST_DIR="/content/MOVIES"
API_TOKEN="eyJhbGciOiJIUzI1NiJ9.eyJhdWQiOiI2MWI3NjA4Yzc4NGY5ODBkZmY4NGY2NjczMTI1YTk1NyIsIm5iZiI6MTc0ODg1NTUxNS4wNjQ5OTk4LCJzdWIiOiI2ODNkNmFkYmE2MzEwNTZmMjNmZGI0YmUiLCJzY29wZXMiOlsiYXBpX3JlYWQiXSwidmVyc2lvbiI6MX0.Bd3NT8T_77EIql1WuhxeE_59X7o8ioQhV6KNHQAlKJk"
DRY_RUN=false
LOG_FILE="/tmp/movie_processor.log"
MAX_RETRIES=3
RETRY_DELAY=2
UNRAR_BIN="unrar"          # change to "rar" if needed
EXTRACT_TEMP="/tmp/movie_extract_$$"   # unique per run

# --- Logging ---
log_message() {
    local level="$1"
    local message="$2"
    local timestamp
    timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    echo "[$timestamp] [$level] $message"
    echo "[$timestamp] [$level] $message" >> "$LOG_FILE"
}

# --- Sanitise filename for the filesystem ---
sanitize_filename() {
    echo "$1" | sed -E 's/[<>:"/\\|?*]/_/g; s/\.$/_/; s/^\./_/'
}

# --- TMDb lookup ---
get_movie_title() {
    local query="$1"
    local year="$2"
    local response http_code temp_file retry_count=0

    log_message "INFO" "Searching TMDb for: '$query' (year: $year)" >&2
    temp_file=$(mktemp)

    while [[ $retry_count -lt $MAX_RETRIES ]]; do
        if [[ -n "$year" ]]; then
            http_code=$(curl -s -w "%{http_code}" -G "https://api.themoviedb.org/3/search/movie" \
                --data-urlencode "query=$query" \
                --data-urlencode "year=$year" \
                -H "Authorization: Bearer $API_TOKEN" \
                -H "Content-Type: application/json" \
                -o "$temp_file")
        else
            http_code=$(curl -s -w "%{http_code}" -G "https://api.themoviedb.org/3/search/movie" \
                --data-urlencode "query=$query" \
                -H "Authorization: Bearer $API_TOKEN" \
                -H "Content-Type: application/json" \
                -o "$temp_file")
        fi

        if [[ "$http_code" == "200" ]]; then
            response=$(cat "$temp_file")
            break
        elif [[ "$http_code" == "429" ]]; then
            log_message "WARN" "Rate limited, retrying in ${RETRY_DELAY}s... ($((retry_count+1))/$MAX_RETRIES)" >&2
            sleep "$RETRY_DELAY"
            ((retry_count++))
            RETRY_DELAY=$((RETRY_DELAY * 2))
        else
            log_message "ERROR" "HTTP $http_code from TMDb" >&2
            rm -f "$temp_file"
            return 1
        fi
    done

    rm -f "$temp_file"
    [[ $retry_count -eq $MAX_RETRIES ]] && { log_message "ERROR" "Max retries reached"; return 1; }

    local result_count
    result_count=$(echo "$response" | jq -r '.total_results // 0')

    if [[ "$result_count" -eq 0 && -n "$year" ]]; then
        log_message "INFO" "No results with year — retrying without year" >&2
        response=$(curl -s -G "https://api.themoviedb.org/3/search/movie" \
            --data-urlencode "query=$query" \
            -H "Authorization: Bearer $API_TOKEN" \
            -H "Content-Type: application/json")
        result_count=$(echo "$response" | jq -r '.total_results // 0')
    fi

    [[ "$result_count" -eq 0 ]] && { log_message "WARN" "No matches for '$query'" >&2; return 1; }

    local title release_date found_year
    title=$(echo "$response" | jq -r '.results[0].title // empty')
    release_date=$(echo "$response" | jq -r '.results[0].release_date // empty')
    [[ -n "$release_date" ]] && found_year=$(echo "$release_date" | cut -d'-' -f1)
    [[ -z "$title" ]] && { log_message "ERROR" "Could not extract title from TMDb response" >&2; return 1; }

    log_message "INFO" "Found: '$title' ($found_year)" >&2
    echo "$title"
    [[ -n "$found_year" ]] && echo "$found_year"
    return 0
}

extract_year() {
    echo "$1" | grep -oE '(19|20)[0-9]{2}' | head -n 1
}

clean_title() {
    local title="$1" year="$2"
    [[ -n "$year" ]] && title=$(echo "$title" | sed -E "s/[[:space:]]*${year}.*//")
    echo "$title" \
        | sed -E 's/[-_.]/ /g' \
        | sed -E 's/[[:space:]]+/ /g' \
        | sed -E 's/^[[:space:]]+|[[:space:]]+$//'
}

check_dependencies() {
    local missing=()
    for tool in curl jq "$UNRAR_BIN"; do
        command -v "$tool" >/dev/null 2>&1 || missing+=("$tool")
    done
    if [[ ${#missing[@]} -gt 0 ]]; then
        log_message "ERROR" "Missing tools: ${missing[*]}"
        return 1
    fi
}

# --- Move + rename a single video file ---
install_video_file() {
    local filepath="$1"
    local filename
    filename=$(basename "$filepath")
    local name="${filename%.*}"
    local extension="${filename##*.}"

    local year
    year=$(extract_year "$name")
    local clean_name
    clean_name=$(clean_title "$name" "$year")

    [[ -z "$clean_name" ]] && { log_message "WARN" "No title from: $name"; return 1; }

    log_message "INFO" "Cleaned title: '$clean_name'  Year: ${year:-unknown}"

    local tmdb_result movie_title tmdb_year
    tmdb_result=$(get_movie_title "$clean_name" "$year") || { log_message "WARN" "TMDb lookup failed, skipping"; return 1; }

    movie_title=$(echo "$tmdb_result" | head -n 1)
    tmdb_year=$(echo "$tmdb_result" | tail -n 1)
    [[ "$tmdb_year" == "$movie_title" ]] && tmdb_year="$year"

    local sanitized_title final_name new_path
    sanitized_title=$(sanitize_filename "$movie_title")
    if [[ -n "$tmdb_year" ]]; then
        final_name="${sanitized_title} (${tmdb_year}).${extension}"
    else
        final_name="${sanitized_title}.${extension}"
    fi
    new_path="$DEST_DIR/$final_name"

    if [[ -e "$new_path" ]]; then
        log_message "WARN" "Target already exists: $new_path"
        return 1
    fi

    if [[ "$DRY_RUN" == true ]]; then
        log_message "INFO" "DRY RUN — would move '$filepath' → '$new_path' (chmod 644, chown root:root)"
    else
        mkdir -p "$DEST_DIR" || { log_message "ERROR" "Cannot create $DEST_DIR"; return 1; }
        mv "$filepath" "$new_path"  || { log_message "ERROR" "mv failed"; return 1; }
        chmod 644 "$new_path"       2>/dev/null || log_message "WARN" "chmod failed on $new_path"
        chown root:root "$new_path" 2>/dev/null || log_message "WARN" "chown failed on $new_path"
        log_message "INFO" "Installed: $filename → $final_name"
    fi
    return 0
}

# --- Find the largest video inside an extraction directory ---
find_main_video() {
    local dir="$1"
    # Return the first .mkv or .mp4 that is not a sample (prefer mkv)
    find "$dir" -type f -iname "*.mkv" ! -iname "*sample*" | head -n 1 || \
    find "$dir" -type f -iname "*.mp4" ! -iname "*sample*" | head -n 1
}

# --- Process a RAR archive (or .r00 if no .rar) ---
process_rar() {
    local rar_file="$1"
    local source_dir
    source_dir=$(dirname "$rar_file")

    log_message "INFO" "Extracting: $rar_file"

    local work_dir="$EXTRACT_TEMP/$(basename "$source_dir")_$$"
    mkdir -p "$work_dir"

    if [[ "$DRY_RUN" == true ]]; then
        log_message "INFO" "DRY RUN — would extract '$rar_file' to '$work_dir'"
        rmdir "$work_dir" 2>/dev/null
        return 0
    fi

    # Extract — unrar exits 0 on success
    if ! "$UNRAR_BIN" x -o+ -inul "$rar_file" "$work_dir/"; then
        log_message "ERROR" "Extraction failed for: $rar_file"
        rm -rf "$work_dir"
        return 1
    fi

    local video_file
    video_file=$(find_main_video "$work_dir")
    if [[ -z "$video_file" ]]; then
        log_message "WARN" "No video found after extraction of: $rar_file"
        rm -rf "$work_dir"
        return 1
    fi

    log_message "INFO" "Extracted video: $video_file"
    install_video_file "$video_file"
    local ret=$?

    rm -rf "$work_dir"
    return $ret
}

# --- Process one directory / file entry ---
process_entry() {
    local path="$1"

    # If a direct video file
    if [[ -f "$path" ]]; then
        case "${path,,}" in
            *.mkv|*.mp4) install_video_file "$path" ;;
            *.rar)        process_rar "$path" ;;
            *)            log_message "WARN" "Unhandled file type: $path" ; return 1 ;;
        esac
        return $?
    fi

    # If a directory, determine what to process inside it
    if [[ -d "$path" ]]; then
        # Prefer the .rar if present
        local rar_file
        rar_file=$(find "$path" -maxdepth 1 -iname "*.rar" ! -iname "*sample*" | sort | head -n 1)

        if [[ -n "$rar_file" ]]; then
            process_rar "$rar_file"
            return $?
        fi

        # Fall back to .r00 (multi-part without a named .rar)
        local r00_file
        r00_file=$(find "$path" -maxdepth 1 -iname "*.r00" | sort | head -n 1)
        if [[ -n "$r00_file" ]]; then
            process_rar "$r00_file"
            return $?
        fi

        # No archive — look for a plain video file
        local video_file
        video_file=$(find "$path" -maxdepth 2 -type f \( -iname "*.mkv" -o -iname "*.mp4" \) \
            ! -iname "*sample*" | head -n 1)
        if [[ -n "$video_file" ]]; then
            install_video_file "$video_file"
            return $?
        fi

        log_message "WARN" "Nothing to process in: $path"
        return 1
    fi

    log_message "WARN" "Path does not exist or is unsupported: $path"
    return 1
}

# ============================================================
# Main
# ============================================================
main() {
    log_message "INFO" "=== Movie Processor started (DRY_RUN=$DRY_RUN) ==="

    check_dependencies || return 1
    [[ -z "$API_TOKEN" ]] && { log_message "ERROR" "API_TOKEN not set"; return 1; }

    mkdir -p "$EXTRACT_TEMP"

    local processed=0 failed=0

    # Mode 1 — explicit paths passed as arguments
    if [[ $# -gt 0 ]]; then
        for entry in "$@"; do
            echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
            if process_entry "$entry"; then
                ((processed++))
            else
                ((failed++))
            fi
            sleep 0.5
        done

    # Mode 2 — scan current directory tree
    # Strategy: collect unique directories that contain media/archives,
    # then let process_entry() pick the best file in each dir.
    else
        # Build a list of unique directories containing relevant files
        declare -A seen_dirs

        while IFS= read -r filepath; do
            dir=$(dirname "$filepath")
            seen_dirs["$dir"]=1
        done < <(find . -type f \( -iname "*.rar" -o -iname "*.r00" -o -iname "*.mkv" -o -iname "*.mp4" \) ! -iname "*sample*" | sort)

        if [[ ${#seen_dirs[@]} -eq 0 ]]; then
            log_message "WARN" "No media files found in current directory tree"
        fi

        for dir in "${!seen_dirs[@]}"; do
            echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
            if process_entry "$dir"; then
                ((processed++))
            else
                ((failed++))
            fi
            sleep 0.5
        done
    fi

    rm -rf "$EXTRACT_TEMP"
    log_message "INFO" "=== Done. Processed: $processed  Failed: $failed ==="
    [[ "$DRY_RUN" == true ]] && log_message "INFO" "Dry run — set DRY_RUN=false to apply changes."
}

main "$@"
