#!/usr/bin/env bash
# Génère l'index du site (texte pour curl, HTML pour navigateur)
# à partir des lignes "# DESC:" présentes dans chaque script.
#
# Usage : build-index.sh <dossier_repo> <dossier_sortie> [url_de_base]
set -euo pipefail

REPO="${1:?Usage : build-index.sh <repo> <sortie> [url]}"
OUT="${2:?Usage : build-index.sh <repo> <sortie> [url]}"
BASE_URL="${3:-https://get.andries.icu}"

# Dossiers qui ne contiennent pas de scripts publics
EXCLUDE_DIRS=(site templates .git .github)

html_escape() {
  local s="$1"
  s="${s//&/&amp;}"; s="${s//</&lt;}"; s="${s//>/&gt;}"; s="${s//\"/&quot;}"
  printf '%s' "$s"
}

main() {
  mkdir -p "$OUT"
  local tmp_txt tmp_html
  tmp_txt="$(mktemp)"; tmp_html="$(mktemp)"

  local prune=()
  local d
  for d in "${EXCLUDE_DIRS[@]}"; do
    prune+=(-path "$REPO/$d" -prune -o)
  done

  # Liste triée des scripts : chemin relatif sans extension
  local scripts=()
  local f
  while IFS= read -r f; do
    scripts+=("$f")
  done < <(find "$REPO" "${prune[@]}" -type f -name '*.sh' -print | sed "s#^$REPO/##" | sort)

  local commit
  commit="$(git -C "$REPO" rev-parse --short HEAD 2>/dev/null || echo '?')"

  # ---------- Version texte (curl)
  {
    echo "get.andries.icu — scripts d'Alexis (commit $commit)"
    echo
    echo "Usage : curl -fsSL $BASE_URL/<script> | bash"
    echo "Avec options : curl -fsSL $BASE_URL/<script> | bash -s -- --help"
    echo
    local rel name desc
    for rel in "${scripts[@]}"; do
      name="${rel%.sh}"
      desc="$(grep -m1 '^# DESC:' "$REPO/$rel" | sed 's/^# DESC:[[:space:]]*//' || true)"
      printf '  %-28s %s\n' "$name" "${desc:-(pas de description)}"
    done
    echo
    echo "Lire un script avant de l'exécuter : curl -fsSL $BASE_URL/<script>"
  } > "$tmp_txt"

  # ---------- Version HTML (navigateur)
  {
    cat <<EOF
<!doctype html>
<html lang="fr">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>get.andries.icu</title>
<style>
  :root { --bg:#0f1115; --fg:#e6e6e6; --muted:#8b93a1; --card:#171a21; --accent:#7aa2f7; --line:#262a33; }
  @media (prefers-color-scheme: light) {
    :root { --bg:#f6f7f9; --fg:#1b1f24; --muted:#5b6370; --card:#ffffff; --accent:#2f5bd3; --line:#e2e5ea; }
  }
  * { box-sizing:border-box; }
  body { margin:0; background:var(--bg); color:var(--fg); font:15px/1.5 ui-monospace,SFMono-Regular,Menlo,Consolas,monospace; }
  main { max-width:880px; margin:0 auto; padding:40px 16px; }
  h1 { font-size:22px; margin:0 0 4px; }
  .sub { color:var(--muted); margin:0 0 28px; }
  .card { background:var(--card); border:1px solid var(--line); border-radius:10px; padding:16px; margin-bottom:12px; }
  .name { color:var(--accent); font-weight:600; }
  .desc { color:var(--muted); margin:4px 0 10px; }
  .cmd { display:flex; gap:8px; align-items:center; }
  code { flex:1; overflow-x:auto; white-space:nowrap; background:var(--bg); border:1px solid var(--line); border-radius:6px; padding:8px 10px; }
  button { font:inherit; cursor:pointer; background:var(--accent); color:#fff; border:0; border-radius:6px; padding:8px 12px; }
  a { color:var(--accent); }
  footer { color:var(--muted); margin-top:28px; font-size:13px; }
</style>
</head>
<body>
<main>
<h1>get.andries.icu</h1>
<p class="sub">Mes scripts, exécutables avec un simple <b>curl | bash</b>. Lis toujours un script avant de le lancer.</p>
EOF
    local rel name desc url
    for rel in "${scripts[@]}"; do
      name="${rel%.sh}"
      desc="$(grep -m1 '^# DESC:' "$REPO/$rel" | sed 's/^# DESC:[[:space:]]*//' || true)"
      url="$BASE_URL/$name"
      cat <<EOF
<div class="card">
  <div class="name"><a href="/$(html_escape "$name")">$(html_escape "$name")</a></div>
  <div class="desc">$(html_escape "${desc:-(pas de description)}")</div>
  <div class="cmd"><code>curl -fsSL $(html_escape "$url") | bash</code><button onclick="copyCmd(this)">Copier</button></div>
</div>
EOF
    done
    cat <<EOF
<footer>Commit $(html_escape "$commit") · source : <a href="https://github.com/MortalDemon3/scripts">github.com/MortalDemon3/scripts</a></footer>
</main>
<script>
function copyCmd(btn) {
  var txt = btn.previousElementSibling.textContent;
  navigator.clipboard.writeText(txt).then(function () {
    btn.textContent = "Copié !";
    setTimeout(function () { btn.textContent = "Copier"; }, 1500);
  });
}
</script>
</body>
</html>
EOF
  } > "$tmp_html"

  # Remplacement atomique : nginx ne sert jamais un fichier à moitié écrit
  install -m 644 "$tmp_txt" "$OUT/index.txt.new" && mv -f "$OUT/index.txt.new" "$OUT/index.txt"
  install -m 644 "$tmp_html" "$OUT/index.html.new" && mv -f "$OUT/index.html.new" "$OUT/index.html"
  rm -f "$tmp_txt" "$tmp_html"
  echo "Index généré : ${#scripts[@]} script(s), commit $commit"
}

main "$@"
