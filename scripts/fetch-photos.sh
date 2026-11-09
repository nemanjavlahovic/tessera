#!/usr/bin/env bash
# Downloads the demo photo set (~990 photos from picsum.photos, Unsplash License) and prepares
# the two sizes the app bundles, both at each photo's original shape:
#   Photos/full   long side 1536px (grid tiles are cropped from these; the photo view shows them whole)
#   Photos/thumb  short side 128px
# Re-running skips files that already exist.
set -euo pipefail
cd "$(dirname "$0")/.."

format=2
raw=.photo-cache/raw-1536
mkdir -p "$raw"
if [ "$(cat Photos/.format 2>/dev/null || true)" != "$format" ]; then
  rm -rf Photos/full Photos/thumb
fi
mkdir -p Photos/full Photos/thumb
echo "$format" > Photos/.format

list=.photo-cache/list.json
if [ ! -s "$list" ]; then
  echo "Fetching photo list..."
  for page in $(seq 1 12); do
    curl -fsS "https://picsum.photos/v2/list?page=$page&limit=100"
  done | jq -s 'add' > "$list"
fi

# One line per photo: id, then width and height scaled so the long side is 1536.
sizes=.photo-cache/sizes.txt
jq -r '.[] | (1536 / ([.width, .height] | max)) as $s | "\(.id) \(.width * $s | round) \(.height * $s | round)"' "$list" > "$sizes"

echo "Downloading $(wc -l < "$sizes" | tr -d ' ') photos..."
xargs -P 16 -L 1 sh -c '[ -s "'"$raw"'/$0.jpg" ] || curl -fsSL -o "'"$raw"'/$0.jpg" "https://picsum.photos/id/$0/$1/$2.jpg" || rm -f "'"$raw"'/$0.jpg"' < "$sizes"

echo "Resizing..."
n=0
while read -r id width height; do
  src="$raw/$id.jpg"
  [ -s "$src" ] || continue
  name=$(printf "%04d" "$id")
  [ -s "Photos/full/$name.jpg" ] || sips -s format jpeg -s formatOptions 70 "$src" --out "Photos/full/$name.jpg" >/dev/null
  if [ ! -s "Photos/thumb/$name.jpg" ]; then
    if [ "$width" -ge "$height" ]; then side=--resampleHeight; else side=--resampleWidth; fi
    sips -s format jpeg -s formatOptions 85 "$side" 128 "$src" --out "Photos/thumb/$name.jpg" >/dev/null
  fi
  n=$((n + 1))
done < "$sizes"

jq -r '"# Photo credits\n\nAll photos via picsum.photos, from Unsplash (Unsplash License).\n", (.[] | "- \(.id): \(.author), \(.url)")' "$list" > Photos/CREDITS.md
echo "Done: $n photos in Photos/"
