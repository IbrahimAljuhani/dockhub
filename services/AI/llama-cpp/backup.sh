# backup.sh (services/AI/llama-cpp)
#
# Function definitions ONLY — services.sh sources this on demand when you
# pick Backup or Restore. Top-level code here would run at the wrong time,
# with the wrong working directory.
#
# Why this file exists: the generic fallback tars every named volume, and
# this service's volume holds the GGUF file llama.cpp downloaded.
# That is gigabytes of already-compressed binary, gzip cannot shrink it, and
# none of it is yours — to get it back you:
#   restart it — LLAMA_ARG_HF_REPO in .env drives the re-download
# Meanwhile the generic path needs roughly double that space free and a long
# compression pass, to preserve nothing.
#
# So: back up the CONFIGURATION, which is small and cannot be re-downloaded
# — .env carries the model choice, the GPU/CPU decision, the port and the
# memory limit.
#
# Restore needs no override: restore_service_generic() skips the volumes
# block when the archive has none.
#
# ⚠️ The function name must be backup_<slug> EXACTLY as services.sh spells
# the slug, hyphens included — it dispatches with declare -F "backup_$name".
# Bash allows a hyphen in a function name defined this way; substituting an
# underscore compiles fine and is then never called, silently falling back
# to the generic backup this file exists to avoid.
#
# $1 = instance name (empty for single-instance services), $2 = install dir.

backup_llama-cpp() {
    backup_service_config_only "llama-cpp" "$1" "$2"
}
