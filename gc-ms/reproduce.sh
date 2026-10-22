#!/usr/bin/env bash
#
# Reproduce the GC-MS QC results of the paper (Figure 5) by running the steps of
# readme.md: download the raw data of MetaboLights study MTBLS4827, convert it to
# mzML, compute the mzQC metrics and plot them.
#
# Requires Python (3.10+), ProteoWizard's msconvert and R, plus curl, unzip and
# sha256sum. The raw data are Agilent MassHunter .D folders, which msconvert can
# only read on Windows (run this script e.g. from Git Bash there).
#
# Usage:  bash reproduce.sh [WORK_DIR]
#
# WORK_DIR (default: reproduction/ next to this script) receives everything: the raw
# and mzML files, the Python environment, the mzQC metrics (WORK_DIR/mzQC-metrics)
# and the plots. Steps whose results are already there are skipped, so an
# interrupted run can simply be restarted.
# The tools are taken from PATH, unless given by the environment variables PYTHON,
# MSCONVERT or RSCRIPT, e.g.
#   RSCRIPT="/c/Program Files/R/R-4.4.1/bin/Rscript.exe" bash reproduce.sh

set -euo pipefail

GCMS_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
MTBLS_URL=https://ftp.ebi.ac.uk/pub/databases/metabolights/studies/public/MTBLS4827
MSCONVERT=${MSCONVERT:-msconvert}
RSCRIPT=${RSCRIPT:-Rscript}

die() { echo "ERROR: $*" >&2; exit 1; }

# Python 3.10+, as 'python3' or 'python' (on Windows, 'python3' may only be the
# Microsoft Store placeholder, which fails this check)
if [ -z "${PYTHON:-}" ]; then
  for candidate in python3 python; do
    if "$candidate" -c 'import sys; sys.exit(sys.version_info < (3, 10))' >/dev/null 2>&1; then
      PYTHON=$candidate
      break
    fi
  done
fi
[ -n "${PYTHON:-}" ] || die "Python 3.10 or later not found (set PYTHON to its path)"
for tool in curl unzip sha256sum "$MSCONVERT" "$RSCRIPT"; do
  command -v "$tool" >/dev/null || die "'$tool' not found (see the requirements at the top of $0)"
done

mkdir -p "${1:-$GCMS_DIR/reproduction}"
WORK_DIR=$(cd "${1:-$GCMS_DIR/reproduction}" && pwd)  # absolute, as we cd into it
RAW_DIR=$WORK_DIR/raw
MZML_DIR=$WORK_DIR/mzML
VENV_DIR=$WORK_DIR/venv
mkdir -p "$RAW_DIR" "$MZML_DIR"
cd "$WORK_DIR"
echo "Working directory: $WORK_DIR"

echo "== 1) Download the raw data (MTBLS4827) from MetaboLights"
# the study's checksum file lists all raw files, so it serves as download list too
curl -sSf --retry 3 -o "$RAW_DIR/data_sha256.json" "$MTBLS_URL/HASHES/data_sha256.json"
sed -n 's|^ *"FILES/RAW_FILES/\([^"]*\)": *"\([0-9a-f]*\)".*|\2  \1|p' \
  "$RAW_DIR/data_sha256.json" > "$RAW_DIR/SHA256SUMS"
[ -s "$RAW_DIR/SHA256SUMS" ] || die "no raw files listed in $MTBLS_URL/HASHES/data_sha256.json"
while read -r sha256 raw_file; do
  if (cd "$RAW_DIR" && echo "$sha256  $raw_file" | sha256sum -c --status 2>/dev/null); then
    echo "  $raw_file (already downloaded)"
  else
    echo "  $raw_file"
    curl -sSf --retry 3 -o "$RAW_DIR/$raw_file" "$MTBLS_URL/FILES/RAW_FILES/$raw_file"
  fi
done < "$RAW_DIR/SHA256SUMS"
(cd "$RAW_DIR" && sha256sum -c --quiet SHA256SUMS) || die "checksum mismatch of the downloaded raw files"

echo "== 2) Convert the raw data to mzML using ProteoWizard"
while read -r _ raw_file; do
  run=${raw_file%.D.zip}
  if [ -f "$MZML_DIR/$run.mzML" ]; then
    echo "  $run.mzML (already converted)"
    continue
  fi
  echo "  $run.mzML"
  unzip -q -o "$RAW_DIR/$raw_file" -d "$RAW_DIR"
  # convert into a temporary folder first, so an interrupted conversion is redone next time
  "$MSCONVERT" --mzML --outdir "$MZML_DIR/partial" "$RAW_DIR/$run.D" >/dev/null
  mv "$MZML_DIR/partial/$run.mzML" "$MZML_DIR/$run.mzML"
done < "$RAW_DIR/SHA256SUMS"
rm -rf "$MZML_DIR/partial"

echo "== 3) Install the Python dependencies (into a virtual environment in $VENV_DIR)"
"$PYTHON" -m venv "$VENV_DIR"
VENV_PYTHON=$VENV_DIR/bin/python
[ -x "$VENV_PYTHON" ] || VENV_PYTHON=$VENV_DIR/Scripts/python.exe  # Windows layout
"$VENV_PYTHON" -m pip install --quiet --disable-pip-version-check -r "$GCMS_DIR/requirements.txt"

echo "== 4) Compute the mzQC metrics of each mzML file"
"$VENV_PYTHON" "$GCMS_DIR/py_scripts/GC_MS_pickPeaks_and_match.py" \
  -c "$GCMS_DIR/compounds.csv" -o "$WORK_DIR/mzQC-metrics" "$MZML_DIR"/*.mzML

echo "== 5) Plot the GC-MS QC metrics (missing R packages are installed automatically)"
# plot_GC-MS.R reads ./mzQC-metrics and writes the plots to the current directory
"$RSCRIPT" "$GCMS_DIR/plot_GC-MS.R"

echo "Done: plots in $WORK_DIR (GC-MS_deltaRT.png, GC-MS_intensity.png), mzQC files in $WORK_DIR/mzQC-metrics"
